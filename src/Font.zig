const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("stb_rect_pack.h");
    @cInclude("stb_truetype.h");
});

const zig_ui = @import("../zig_ui.zig");
const gl = zig_ui.gl;
const vec2 = zig_ui.vec2;
const uvec2 = zig_ui.uvec2;
const ivec2 = zig_ui.ivec2;
const gfx = @import("graphics.zig");
const utils = @import("utils.zig");

const prof = if (@import("profiler.zig").root_has_prof) &@import("root").prof else &@import("profiler.zig").dummy;

const Font = @This();

allocator: Allocator,
file_data: [:0]u8,
font_info: c.stbtt_fontinfo,

kerning_data: KerningMap,

texture: gfx.Texture,
texture_data: []u8,
raster_cache: RasterCache,
packing_ctx: c.stbtt_pack_context,

const RasterCache = utils.StaticHashTable(RasterCacheKey, GlyphData, 64, 8);
const RasterCacheKey = struct { codepoint: u21, size: f32 };

/// call 'deinit' when you're done with the Font
pub fn fromTTF(allocator: Allocator, filepath: []const u8) !Font {
    const file_data = try std.fs.cwd().readFileAllocOptions(
        allocator,
        filepath,
        std.math.maxInt(usize),
        null,
        @alignOf(u8),
        0,
    );
    var font_info: c.stbtt_fontinfo = undefined;
    std.debug.assert(c.stbtt_InitFont(&font_info, &file_data[0], 0) == 1);

    var self = Font{
        .allocator = allocator,
        .file_data = file_data,
        .font_info = font_info,
        .texture = undefined,
        .texture_data = undefined,
        .raster_cache = .{},
        .packing_ctx = undefined,
        .kerning_data = KerningMap.init(allocator),
    };
    try self.setupPacking(512);

    return self;
}

pub fn deinit(self: *Font) void {
    self.allocator.free(self.texture_data);
    self.texture.deinit();
    self.kerning_data.deinit();
    self.allocator.free(self.file_data);
    self.raster_cache.deinit(self.allocator);
}

pub const ScaledMetrics = struct {
    ascent: f32, // how much above baseline the font reaches
    descent: f32, // how much below baseline the font reaches
    line_gap: f32, // between two lines
    line_advance: f32, // vertical space taken by one line
    scale: f32,
};

pub fn getScaledMetrics(self: Font, pixel_size: f32) ScaledMetrics {
    var ascent: i32 = undefined;
    var descent: i32 = undefined;
    var line_gap: i32 = undefined;
    c.stbtt_GetFontVMetrics(&self.font_info, &ascent, &descent, &line_gap);
    const scale = c.stbtt_ScaleForPixelHeight(&self.font_info, pixel_size);
    return .{
        .ascent = @as(f32, @floatFromInt(ascent)) * scale,
        .descent = @as(f32, @floatFromInt(descent)) * scale,
        .line_gap = @as(f32, @floatFromInt(line_gap)) * scale,
        .line_advance = @as(f32, @floatFromInt(ascent - descent + line_gap)) * scale,
        .scale = scale,
    };
}

pub const Quad = extern struct {
    /// points are given in counter clockwise order starting from bottom left
    points: [4]Vertex,
    const Vertex = packed struct { pos: vec2, uv: vec2 };
};

/// Quad data uses (0, 0) as starting cursor. Caller owns returned memory.
pub fn buildText(
    self: *Font,
    allocator: Allocator,
    str: []const u8,
    pixel_size: f32,
) ![]Quad {
    prof.startZoneN("Font." ++ @src().fn_name);
    defer prof.stopZone();

    const metrics = self.getScaledMetrics(pixel_size);
    var quads = try std.ArrayList(Quad).initCapacity(allocator, str.len);

    var cursor = vec2{ 0, 0 };

    var utf8_iter = utils.Utf8Iterator{ .bytes = str };
    while (utf8_iter.next()) |codepoint| {
        const next_codepoint = utf8_iter.peek();

        if (codepoint == '\n') {
            if (next_codepoint != null) {
                cursor[0] = 0;
                cursor[1] -= metrics.line_advance; // stb uses +y up
            }
            continue;
        }

        // TODO: kerning

        const glyph_data = try self.getGlyphRasterData(codepoint, pixel_size);

        const pos_bl = glyph_data.pos_btm_left;
        const pos_tr = glyph_data.pos_top_right;
        const pos_br = vec2{ pos_tr[0], pos_bl[1] };
        const pos_tl = vec2{ pos_bl[0], pos_tr[1] };
        const uv_bl = glyph_data.uv_btm_left;
        const uv_tr = glyph_data.uv_top_right;
        const uv_br = vec2{ uv_tr[0], uv_bl[1] };
        const uv_tl = vec2{ uv_bl[0], uv_tr[1] };
        const quad = Quad{ .points = [4]Quad.Vertex{
            .{ .pos = cursor + pos_bl, .uv = uv_bl },
            .{ .pos = cursor + pos_br, .uv = uv_br },
            .{ .pos = cursor + pos_tr, .uv = uv_tr },
            .{ .pos = cursor + pos_tl, .uv = uv_tl },
        } };
        quads.append(quad) catch unreachable;
        cursor[0] += @as(f32, @floatFromInt(glyph_data.advance[0])) * metrics.scale;
        cursor[1] += @as(f32, @floatFromInt(glyph_data.advance[1])) * metrics.scale;
    }

    return try quads.toOwnedSlice();
}

pub const GlyphData = struct {
    pos_btm_left: vec2,
    pos_top_right: vec2,
    uv_btm_left: vec2,
    uv_top_right: vec2,
    advance: ivec2,

    codepoint: u21,
    pixel_size: f32,
};

pub fn getGlyphRasterData(self: *Font, codepoint: u21, pixel_size: f32) !GlyphData {
    // prof.startZoneN("Font." ++ @src().fn_name);
    // defer prof.stopZone();

    const key = .{ .codepoint = codepoint, .size = pixel_size };
    const gop = self.raster_cache.getOrPut(key) catch |err| switch (err) {
        error.Overflow => blk: {
            try self.raster_cache.grow(self.allocator);
            break :blk try self.raster_cache.getOrPut(key);
        },
        else => return err,
    };

    if (!gop.found_existing) {
        gop.value.codepoint = codepoint;
        gop.value.pixel_size = pixel_size;

        if (self.rasterGlyph(codepoint, pixel_size)) |data| {
            gop.value.* = data;
        } else {
            // ran out of space in texture atlas: increase size and rebuild it
            // (maybe we could copy over the already existing rastered glyphs
            // but this happens so rarely that it's not really a problem for now)
            const new_text_size = self.texture.width * 2;
            self.resetPacking();
            try self.setupPacking(new_text_size);
            var cache_it = self.raster_cache.iterator();
            while (cache_it.next()) |entry| {
                const glyph_data: *GlyphData = entry.value;
                glyph_data.* = self.rasterGlyph(glyph_data.codepoint, glyph_data.pixel_size) orelse unreachable;
            }
        }

        self.texture.updateData(self.texture_data);
    }

    return gop.value.*;
}

fn setupPacking(self: *Font, texture_size: u32) !void {
    self.texture_data = try self.allocator.alloc(u8, texture_size * texture_size);
    self.texture = gfx.Texture.init(texture_size, texture_size, gl.RED, null, gl.TEXTURE_2D, &.{
        .{ .name = gl.TEXTURE_MIN_FILTER, .value = gl.LINEAR },
        .{ .name = gl.TEXTURE_MAG_FILTER, .value = gl.LINEAR },
        .{ .name = gl.TEXTURE_WRAP_S, .value = gl.CLAMP_TO_EDGE },
        .{ .name = gl.TEXTURE_WRAP_T, .value = gl.CLAMP_TO_EDGE },
    });

    std.debug.assert(c.stbtt_PackBegin(
        &self.packing_ctx,
        self.texture_data.ptr,
        @intCast(self.texture.width),
        @intCast(self.texture.height),
        0,
        2, // padding between characters
        null,
    ) == 1);
    c.stbtt_PackSetOversampling(&self.packing_ctx, 2, 2);
}

fn resetPacking(self: *Font) void {
    self.allocator.free(self.texture_data);
    self.texture.deinit();
    c.stbtt_PackEnd(&self.packing_ctx);
}

fn rasterGlyph(self: *Font, codepoint: u21, size: f32) ?GlyphData {
    var p: c.stbtt_packedchar = undefined;
    if (c.stbtt_PackFontRange(&self.packing_ctx, self.file_data.ptr, 0, size, @intCast(codepoint), 1, &p) == 0)
        return null;

    var advance: i32 = undefined;
    c.stbtt_GetCodepointHMetrics(&self.font_info, codepoint, &advance, null);

    const tex_size: vec2 = @floatFromInt(uvec2{ self.texture.width, self.texture.height });
    return GlyphData{
        .pos_btm_left = vec2{ p.xoff, -p.yoff2 },
        .pos_top_right = vec2{ p.xoff2, -p.yoff },
        .uv_btm_left = vec2{ @floatFromInt(p.x0), @floatFromInt(p.y1) } / tex_size,
        .uv_top_right = vec2{ @floatFromInt(p.x1), @floatFromInt(p.y0) } / tex_size,
        .advance = ivec2{ advance, 0 },
        .codepoint = codepoint,
        .pixel_size = size,
    };
}

const CharPair = [2]u21;
const KerningMap = std.HashMap(CharPair, i32, struct {
    pub fn hash(_: @This(), key: CharPair) u64 {
        return @as(u64, @intCast(key[0])) * 7 + @as(u64, @intCast(key[1])) * 11;
    }
    pub fn eql(_: @This(), key_a: CharPair, key_b: CharPair) bool {
        return key_a[0] == key_b[0] and key_a[1] == key_b[1];
    }
}, std.hash_map.default_max_load_percentage);

fn getKerningAdvance(self: *Font, char_pair: [2]u21) !i32 {
    const entry = try self.kerning_data.getOrPut(char_pair);
    if (!entry.found_existing) {
        entry.value_ptr.* = c.stbtt_GetCodepointKernAdvance(&self.font_info, char_pair[0], char_pair[1]);
    }
    return entry.value_ptr.*;
}
