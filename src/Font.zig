const std = @import("std");
const Allocator = std.mem.Allocator;
const zig_ui = @import("../zig_ui.zig");
const gl = zig_ui.gl;
const vec2 = zig_ui.vec2;
const gfx = @import("graphics.zig");
const c = @cImport({
    @cInclude("stb_rect_pack.h");
    @cInclude("stb_truetype.h");
});

const Font = @This();

allocator: Allocator,
file_data: [:0]u8,

texture: gfx.Texture,
texture_data: []u8,

font_info: c.stbtt_fontinfo,
char_maps: SizedCharMaps,
kerning_data: KerningMap,
packing_ctx: c.stbtt_pack_context,

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
        .texture = undefined,
        .texture_data = undefined,
        .font_info = font_info,
        .char_maps = SizedCharMaps.init(allocator),
        .kerning_data = KerningMap.init(allocator),
        .packing_ctx = undefined,
    };
    try self.setupPacking(512);

    return self;
}

pub fn deinit(self: *Font) void {
    self.allocator.free(self.texture_data);
    self.texture.deinit();
    {
        var iter = self.char_maps.valueIterator();
        while (iter.next()) |sized_map| sized_map.map.deinit();
        self.char_maps.deinit();
    }
    self.kerning_data.deinit();
    self.allocator.free(self.file_data);
}

pub const ScaledMetrics = struct {
    ascent: f32, // how much above baseline the font reaches
    descent: f32, // how much below baseline the font reaches
    line_gap: f32, // between two lines
    line_advance: f32, // vertical space taken by one line
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
    };
}

pub const Quad = extern struct {
    /// points are given in counter clockwise order starting from bottom left
    points: [4]Vertex,
    const Vertex = packed struct { pos: vec2, uv: vec2 };
};

/// caller owns returned memory
pub fn buildQuads(self: *Font, allocator: Allocator, str: []const u8, pixel_size: f32) ![]Quad {
    return self.buildQuadsAt(allocator, str, pixel_size, vec2{ 0, 0 });
}

/// caller owns returned memory
pub fn buildQuadsAt(self: *Font, allocator: Allocator, str: []const u8, pixel_size: f32, start_pos: vec2) ![]Quad {
    return self.buildTextAt(.quad, allocator, str, pixel_size, start_pos);
}

pub const Rect = struct {
    min: vec2,
    max: vec2,
};

pub fn textRect(self: *Font, str: []const u8, pixel_size: f32) !Rect {
    return self.buildTextAt(.rect, undefined, str, pixel_size, vec2{ 0, 0 });
}

fn buildTextAt(
    self: *Font,
    comptime mode: enum { rect, quad },
    allocator: Allocator,
    str: []const u8,
    pixel_size: f32,
    start_pos: vec2,
) !switch (mode) {
    .rect => Rect,
    .quad => []Quad,
} {
    const char_map = try self.getSizedCharMap(pixel_size);
    const metrics = char_map.metrics;
    const scale = char_map.scale;

    var quads = switch (mode) {
        .rect => @as(std.ArrayList(Quad), undefined),
        .quad => try std.ArrayList(Quad).initCapacity(allocator, str.len),
    };

    var cursor = @as([2]f32, start_pos);
    var max_x: f32 = 0;

    if (mode == .rect) {
        std.debug.assert(utf8Validate(str));
    }
    var utf8_iter = std.unicode.Utf8View.initUnchecked(str).iterator();
    while (utf8_iter.nextCodepoint()) |codepoint| {
        const next_codepoint: ?u21 = if (utf8_iter.i >= utf8_iter.bytes.len)
            null
        else
            std.unicode.utf8Decode(utf8_iter.peek(1)) catch @panic("Invalid utf8");

        if (codepoint == '\n') {
            if (next_codepoint != null) {
                cursor[0] = start_pos[0];
                cursor[1] += metrics.line_advance; // stb uses +y up
            }
            continue;
        }

        // TODO: kerning

        const char_data = try self.getCharDataFromMap(char_map, codepoint);
        if (mode == .quad) {
            const pos_bl = char_data.pos_btm_left;
            const pos_tr = char_data.pos_top_right;
            const pos_br = vec2{ pos_tr[0], pos_bl[1] };
            const pos_tl = vec2{ pos_bl[0], pos_tr[1] };
            const uv_bl = char_data.uv_btm_left;
            const uv_tr = char_data.uv_top_right;
            const uv_br = vec2{ uv_tr[0], uv_bl[1] };
            const uv_tl = vec2{ uv_bl[0], uv_tr[1] };
            const quad = Quad{ .points = [4]Quad.Vertex{
                .{ .pos = cursor + pos_bl, .uv = uv_bl },
                .{ .pos = cursor + pos_br, .uv = uv_br },
                .{ .pos = cursor + pos_tr, .uv = uv_tr },
                .{ .pos = cursor + pos_tl, .uv = uv_tl },
            } };
            quads.append(quad) catch unreachable;
        }
        cursor[0] += @as(f32, @floatFromInt(char_data.advance[0])) * scale;
        cursor[1] += @as(f32, @floatFromInt(char_data.advance[1])) * scale;

        max_x = @max(max_x, cursor[0]);
    }

    return switch (mode) {
        .rect => .{
            .min = vec2{ start_pos[0], cursor[1] + metrics.descent },
            .max = vec2{ max_x, start_pos[1] + metrics.ascent },
        },
        .quad => quads.toOwnedSlice(),
    };
}

pub const Codepoint = u21;
pub const CharData = struct {
    pos_btm_left: vec2,
    pos_top_right: vec2,
    uv_btm_left: vec2,
    uv_top_right: vec2,
    advance: @Vector(2, i32),
};
pub const CharMap = std.AutoHashMap(Codepoint, CharData);

pub const SizedCharMap = struct {
    pixel_size: f32,
    metrics: ScaledMetrics,
    scale: f32,
    map: CharMap,
};
pub const SizedCharMaps = std.HashMap(f32, SizedCharMap, struct {
    /// Floats cannot use the 'auto hash' because floats values are not
    /// guaranteed to have unique representations. For example, there's
    /// multiple bit patterns for NaN, inf., +0 vs -0, etc.
    /// This function will treats those as if they are distinct values.
    pub fn hash(ctx: @This(), key: f32) u64 {
        // on the inside we're all the same: just a bunch'a bytes
        return std.hash_map.getAutoHashFn(u32, @This())(ctx, @bitCast(key));
    }
    pub fn eql(_: @This(), a: f32, b: f32) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

const CharPair = [2]u21;
const KerningMap = std.HashMap(CharPair, i32, struct {
    pub fn hash(_: @This(), key: CharPair) u64 {
        return @as(u64, @intCast(key[0])) * 7 + @as(u64, @intCast(key[1])) * 11;
    }
    pub fn eql(_: @This(), key_a: CharPair, key_b: CharPair) bool {
        return key_a[0] == key_b[0] and key_a[1] == key_b[1];
    }
}, std.hash_map.default_max_load_percentage);

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
        1, // padding between characters
        null,
    ) == 1);
    //c.stbtt_PackSetOversampling(&self.packing_ctx, 2, 2);
}

fn resetPacking(self: *Font) void {
    self.allocator.free(self.texture_data);
    self.texture.deinit();
    c.stbtt_PackEnd(&self.packing_ctx);
}

fn packCodepoint(self: *Font, codepoint: u21, size: f32) ?CharData {
    var p: c.stbtt_packedchar = undefined;
    if (c.stbtt_PackFontRange(&self.packing_ctx, self.file_data.ptr, 0, size, @intCast(codepoint), 1, &p) == 0)
        return null;

    var advance: i32 = undefined;
    c.stbtt_GetCodepointHMetrics(&self.font_info, codepoint, &advance, null);

    const tex_size = vec2{ @floatFromInt(self.texture.width), @floatFromInt(self.texture.height) };
    return CharData{
        .pos_btm_left = vec2{ p.xoff, -p.yoff2 },
        .pos_top_right = vec2{ p.xoff2, -p.yoff },
        .uv_btm_left = vec2{ @floatFromInt(p.x0), @floatFromInt(p.y1) } / tex_size,
        .uv_top_right = vec2{ @floatFromInt(p.x1), @floatFromInt(p.y0) } / tex_size,
        .advance = @Vector(2, i32){ advance, 0 },
    };
}

// call this if we run out of space in texture. creates a bigger texture and repacks all
// the glyphs we already had in there.
fn increaseTextureAndRepack(self: *Font) !void {
    const old_tex_size = self.texture.width;
    const new_tex_size = old_tex_size * 2;

    self.resetPacking();
    try self.setupPacking(new_tex_size);

    var map_iter = self.char_maps.valueIterator();
    while (map_iter.next()) |sized_map| {
        var char_iter = sized_map.map.iterator();
        while (char_iter.next()) |entry| {
            entry.value_ptr.* = self.packCodepoint(
                entry.key_ptr.*,
                sized_map.pixel_size,
            ).?;
        }
    }

    self.texture.updateData(self.texture_data);
}

pub fn ensureCharData(self: *Font, codepoint: u21, pixel_size: f32) !void {
    _ = try self.getCharData(codepoint, pixel_size);
}

fn getCharDataFromMap(self: *Font, sized_map: *SizedCharMap, codepoint: u21) !CharData {
    return sized_map.map.get(codepoint) orelse data: {
        const char_data = self.packCodepoint(codepoint, sized_map.pixel_size) orelse {
            // we ran out of space in the texture
            try self.increaseTextureAndRepack();
            return self.getCharDataFromMap(sized_map, codepoint);
        };

        try sized_map.map.put(codepoint, char_data);
        self.texture.updateData(self.texture_data);

        break :data char_data;
    };
}

fn getCharData(self: *Font, codepoint: u21, pixel_size: f32) !CharData {
    const char_map = try self.getSizedCharMap(pixel_size);
    return self.getCharDataFromMap(char_map, codepoint);
}

fn getSizedCharMap(self: *Font, pixel_size: f32) !*SizedCharMap {
    const gop = try self.char_maps.getOrPut(pixel_size);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .pixel_size = pixel_size,
            .metrics = self.getScaledMetrics(pixel_size),
            .scale = c.stbtt_ScaleForPixelHeight(&self.font_info, pixel_size),
            .map = CharMap.init(self.allocator),
        };
    }
    return gop.value_ptr;
}

fn getKerningAdvance(self: *Font, char_pair: [2]u21) !i32 {
    const entry = try self.kerning_data.getOrPut(char_pair);
    if (!entry.found_existing) {
        entry.value_ptr.* = c.stbtt_GetCodepointKernAdvance(&self.font_info, char_pair[0], char_pair[1]);
    }
    return entry.value_ptr.*;
}

/// wrapper for `std.unicode.utf8ValidateSlice` with early-out
/// optimization for slices that only contains ASCII
// TODO: fully implement this using SIMD, theres a bunch of papers online on how to do that
fn utf8Validate(str: []const u8) bool {
    const vec_size = comptime std.simd.suggestVectorSize(u8) orelse 64 / 8;
    const V = @Vector(vec_size, u8);
    // TODO: make this better
    var chunk_start: usize = 0;
    while (chunk_start < str.len) {
        const rest_of_str = str[chunk_start..];

        // TODO: we can prob. fill this in a smarted way without if/else, just a single @max
        const chunk: V = if (rest_of_str.len < vec_size) chunk: {
            var chunk: V = @splat(0);
            for (rest_of_str, 0..) |char, idx| chunk[idx] = char;
            break :chunk chunk;
        } else str[chunk_start..][0..vec_size].*;

        const topbit: V = @splat(0x80);
        _ = topbit;

        const any_non_ascii = @reduce(.Or, chunk & @as(V, @splat(0x80)) != @as(V, @splat(0)));
        if (any_non_ascii) {
            break;
        } else {
            chunk_start += vec_size;
        }
    }

    if (chunk_start > str.len) {
        return true;
    } else {
        return std.unicode.utf8ValidateSlice(str[chunk_start..]);
    }
}

// TODO: also implement SIMD accelerated utf8 decoding
