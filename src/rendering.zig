const std = @import("std");
const zig_ui = @import("../zig_ui.zig");
const gl = zig_ui.gl;
const vec2 = zig_ui.vec2;
const vec4 = zig_ui.vec4;
const UI = @import("UI.zig");
const Node = UI.Node;
const Rect = UI.Rect;
const FontType = UI.FontType;
const Font = @import("Font.zig");
const gfx = @import("graphics.zig");
const indexOfNthScalar = UI.indexOfNthScalar;

const prof = &@import("root").prof;

pub var hot_reload_shaders: bool = false;
pub var hot_reload_frame_interval: usize = 10;

// this struct must have the exact layout expected by the shader
pub const ShaderInput = extern struct {
    btm_left_pos: [2]f32,
    top_right_pos: [2]f32,
    btm_left_uv: [2]f32,
    top_right_uv: [2]f32,
    top_left_color: [4]f32,
    btm_left_color: [4]f32,
    top_right_color: [4]f32,
    btm_right_color: [4]f32,
    corner_radii: [4]f32,
    edge_softness: f32,
    border_thickness: [4]f32,
    clip_rect_min: [2]f32,
    clip_rect_max: [2]f32,
    which_font: u32,

    pub fn fromNode(node: *const Node) ShaderInput {
        // note: the `align(32)` is to side step a zig bug (prob this one https://github.com/ziglang/zig/issues/11154)
        // where llvm emits a `vmovaps` on something that *isn't* 32 byte aligned
        // which triggers a segfault when initing the vec4's
        const rect align(32) = ShaderInput{
            .btm_left_pos = node.rect.min,
            .top_right_pos = node.rect.max,
            .btm_left_uv = vec2{ 0, 0 },
            .top_right_uv = vec2{ 0, 0 },
            .top_left_color = vec4{ 0, 0, 0, 0 },
            .btm_left_color = vec4{ 0, 0, 0, 0 },
            .top_right_color = vec4{ 0, 0, 0, 0 },
            .btm_right_color = vec4{ 0, 0, 0, 0 },
            .corner_radii = node.corner_radii,
            .edge_softness = node.edge_softness,
            .border_thickness = @as(vec4, @splat(node.border_thickness)),
            .clip_rect_min = node.clip_rect.min,
            .clip_rect_max = node.clip_rect.max,
            .which_font = @intFromEnum(node.font_type),
        };
        return rect;
    }

    /// A, single color, 1px border rect, for debugging
    pub fn dbg(min: vec2, max: vec2, color: vec4) ShaderInput {
        const rect align(32) = ShaderInput{
            .btm_left_pos = min,
            .top_right_pos = max,
            .btm_left_uv = vec2{ 0, 0 },
            .top_right_uv = vec2{ 0, 0 },
            .top_left_color = color,
            .btm_left_color = color,
            .top_right_color = color,
            .btm_right_color = color,
            .corner_radii = [4]f32{ 0, 0, 0, 0 },
            .edge_softness = 1,
            .border_thickness = [4]f32{ 1, 1, 1, 1 },
            .clip_rect_min = vec2{ 0, 0 },
            .clip_rect_max = @as(vec2, @splat(std.math.floatMax(f32))),
            .which_font = 0,
        };
        return rect;
    }
};

pub fn render(self: *UI) !void {
    prof.startZoneN("UI.render");
    defer prof.stopZone();

    const arena = self.build_arena.allocator();
    var estimated_rect_count = self.node_table.count() * 2;
    var node_it = self.node_table.valueIterator();
    while (node_it.next()) |node| estimated_rect_count += node.display_string.len;
    var shader_inputs = try std.ArrayList(ShaderInput).initCapacity(arena, estimated_rect_count);

    try setupTreeForRender(self, &shader_inputs, self.root.?);
    for (self.window_roots.items) |node| try setupTreeForRender(self, &shader_inputs, node);
    if (self.ctx_menu_root) |node| try setupTreeForRender(self, &shader_inputs, node);
    if (self.tooltip_root) |node| try setupTreeForRender(self, &shader_inputs, node);

    // create vertex buffer
    var inputs_vao: u32 = 0;
    gl.genVertexArrays(1, &inputs_vao);
    defer gl.deleteVertexArrays(1, &inputs_vao);
    gl.bindVertexArray(inputs_vao);
    var inputs_vbo: u32 = 0;
    gl.genBuffers(1, &inputs_vbo);
    defer gl.deleteBuffers(1, &inputs_vbo);
    gl.bindBuffer(gl.ARRAY_BUFFER, inputs_vbo);
    const stride = @sizeOf(ShaderInput);
    gl.bufferData(gl.ARRAY_BUFFER, @as(isize, @intCast(shader_inputs.items.len * stride)), shader_inputs.items.ptr, gl.STATIC_DRAW);
    var field_offset: usize = 0;
    inline for (@typeInfo(ShaderInput).Struct.fields, 0..) |field, i| {
        const elems = switch (@typeInfo(field.type)) {
            .Float, .Int => 1,
            .Array => |array| array.len,
            else => @compileError("new type in ShaderInput struct: " ++ @typeName(field.type)),
        };
        const child_type = switch (@typeInfo(field.type)) {
            .Array => |array| array.child,
            else => field.type,
        };

        const offset_ptr = if (field_offset == 0) null else @as(*const anyopaque, @ptrFromInt(field_offset));
        switch (@typeInfo(child_type)) {
            .Float => {
                const gl_type = gl.FLOAT;
                gl.vertexAttribPointer(i, elems, gl_type, gl.FALSE, stride, offset_ptr);
            },
            .Int => {
                const type_info = @typeInfo(child_type).Int;
                std.debug.assert(type_info.signedness == .unsigned);
                std.debug.assert(type_info.bits == 32);
                const gl_type = gl.UNSIGNED_INT;
                gl.vertexAttribIPointer(i, elems, gl_type, stride, offset_ptr);
            },
            else => @compileError("new type in ShaderInput struct: " ++ @typeName(child_type)),
        }
        gl.enableVertexAttribArray(i);
        field_offset += @sizeOf(field.type);
    }

    // save current blend state and set it how we need it
    const blend_was_on = gl.isEnabled(gl.BLEND) == gl.TRUE;
    var saved_state: struct {
        BLEND_SRC_RGB: u32,
        BLEND_SRC_ALPHA: u32,
        BLEND_DST_RGB: u32,
        BLEND_DST_ALPHA: u32,
        BLEND_EQUATION_RGB: u32,
        BLEND_EQUATION_ALPHA: u32,
    } = undefined;
    inline for (@typeInfo(@TypeOf(saved_state)).Struct.fields) |field|
        gl.getIntegerv(@field(gl, field.name), @ptrCast(&@field(saved_state, field.name)));
    defer {
        if (blend_was_on) gl.enable(gl.BLEND) else gl.disable(gl.BLEND);
        gl.blendFuncSeparate(
            saved_state.BLEND_SRC_RGB,
            saved_state.BLEND_DST_RGB,
            saved_state.BLEND_SRC_ALPHA,
            saved_state.BLEND_DST_ALPHA,
        );
        gl.blendEquationSeparate(saved_state.BLEND_EQUATION_RGB, saved_state.BLEND_EQUATION_ALPHA);
    }
    gl.enable(gl.BLEND);
    gl.blendFuncSeparate(
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
        gl.SRC_ALPHA,
        gl.ONE_MINUS_SRC_ALPHA,
    );
    gl.blendEquationSeparate(gl.FUNC_ADD, gl.MAX);

    if (hot_reload_shaders and self.frame_idx % hot_reload_frame_interval == 0) blk: {
        const updated_shader = gfx.Shader.from_files(self.allocator, "ui_generic", .{
            .vertex = "src/shader.vert",
            .geometry = "src/shader.geom",
            .fragment = "src/shader.frag",
        }) catch break :blk;
        self.generic_shader.deinit();
        self.generic_shader = updated_shader;
    }

    self.generic_shader.bind();
    self.generic_shader.set("screen_size", self.screen_size);
    inline for (@typeInfo(FontType).Enum.fields) |field| {
        self.generic_shader.set(field.name ++ "_atlas", @as(i32, field.value));
        const font = self.font_cache.getFont(@enumFromInt(field.value));
        font.texture.bind(field.value);
    }
    gl.bindVertexArray(inputs_vao);
    gl.drawArrays(gl.POINTS, 0, @intCast(shader_inputs.items.len));
}

fn setupTreeForRender(self: *UI, shader_inputs: *std.ArrayList(ShaderInput), root: *Node) !void {
    var node_iterator = RenderOrderNodeIterator{ .cur_node = root };
    while (node_iterator.next()) |node| {
        try addShaderInputsForNode(self, shader_inputs, node);
    }
}

// turn a UI.Node into Shader quads
fn addShaderInputsForNode(self: *UI, shader_inputs: *std.ArrayList(ShaderInput), node: *Node) !void {
    if (node.custom_draw_fn) |draw_fn| return draw_fn(self, shader_inputs, node);

    // // don't bother adding inputs for fully clipped nodes
    if (node.parent) |parent| {
        const clipped_rect = node.rect.intersection(parent.clip_rect);
        if (@reduce(.Or, clipped_rect.size() == vec2{ 0, 0 })) return;
    }

    const base_rect = ShaderInput.fromNode(node);

    // draw background
    if (node.flags.draw_background) {
        var rect = base_rect;
        rect.top_left_color = node.bg_color;
        rect.btm_left_color = node.bg_color;
        rect.top_right_color = node.bg_color;
        rect.btm_right_color = node.bg_color;
        rect.border_thickness = [4]f32{ -1, -1, -1, -1 };
        try shader_inputs.append(rect);

        const hot_remove_factor = if (node.flags.draw_active_effects) node.active_trans else 0;
        const effective_hot_trans = node.hot_trans * (1 - hot_remove_factor);

        if (node.flags.draw_hot_effects) {
            rect = base_rect;
            const top_color = vec4{ 1, 1, 1, 0.1 * effective_hot_trans };
            rect.top_left_color = top_color;
            rect.top_right_color = top_color;
            try shader_inputs.append(rect);
        }
        if (node.flags.draw_active_effects) {
            rect = base_rect;
            const btm_color = vec4{ 1, 1, 1, 0.1 * node.active_trans };
            rect.btm_left_color = btm_color;
            rect.btm_right_color = btm_color;
            try shader_inputs.append(rect);
        }
    }

    // draw border
    if (node.flags.draw_border) {
        var rect = base_rect;
        rect.top_left_color = node.border_color;
        rect.btm_left_color = node.border_color;
        rect.top_right_color = node.border_color;
        rect.btm_right_color = node.border_color;
        try shader_inputs.append(rect);

        if (node.flags.draw_hot_effects) {
            rect = base_rect;
            const top_color = vec4{ 1, 1, 1, 0.2 * node.hot_trans };
            rect.top_left_color = top_color;
            rect.top_right_color = top_color;
            const btm_color = vec4{ 1, 1, 1, 0.2 * node.hot_trans };
            rect.btm_left_color = btm_color;
            rect.btm_right_color = btm_color;
            try shader_inputs.append(rect);
        }
    }

    // draw text
    if (node.flags.draw_text) blk: {
        if (node.display_string.len == 0) break :blk;

        const font = self.font_cache.getFont(node.font_type);

        var text_base = self.textPosFromNode(node);
        if (node.flags.draw_active_effects)
            text_base[1] -= (node.inner_padding[1] / 2) * node.active_trans;

        const display_text = if (estimateLineCount(node, font.*) < 100)
            node.display_string
        else text: {
            const res = largeInputOptimizationVisiblePartOfText(self, node);
            text_base[1] -= res.offset;
            break :text res.string;
        };

        const text_info = try self.font_cache.buildText(display_text, node.font_type, node.font_size);
        const quads = text_info.quads;
        const ellipsis_text_info = try self.font_cache.buildText("...", node.font_type, node.font_size);
        const ellipsis_quads = ellipsis_text_info.quads;

        const node_inner_rect = Rect{
            .min = node.rect.min + node.inner_padding,
            .max = node.rect.max - node.inner_padding,
        };
        const text_width = text_info.rect.size()[0];
        const ellipsis_width = ellipsis_text_info.rect.size()[0];
        const max_text_width = node_inner_rect.size()[0];
        // here we give 0.5px of leeway to allow for floating precision shenanigans
        // (and because overflowing by less than 0.5px is imperceptible anyway)
        const needs_truncation = (text_width - max_text_width > 0.5) and !node.flags.disable_text_truncation;

        const ellipsis_text_base = vec2{ node_inner_rect.max[0] - ellipsis_width, text_base[1] };

        const show_dbg_rects = false;
        if (show_dbg_rects) {
            // std.debug.print("needs_truncation: {}\n", .{needs_truncation});
            // std.debug.print("text_base: {d}\n", .{text_base});
            // std.debug.print("ellipsis_text_base: {d}\n", .{ellipsis_text_base});
            // std.debug.print("ellipsis_width: {d}\n", .{ellipsis_width});
            // std.debug.print("node.parent.?.rect: {d}\n", .{node.parent.?.rect});
            // std.debug.print("node.parent.?.rect.size(): {d}\n", .{node.parent.?.rect.size()});
            // std.debug.print("text_info.rect: {d}\n", .{text_info.rect});
            // std.debug.print("text_info.rect.size(): {d}\n", .{text_info.rect.size()});
            // std.debug.print("node.rect: {d}\n", .{node.rect});
            // std.debug.print("node.rect.size(): {d}\n", .{node.rect.size()});
            // std.debug.print("node_inner_rect: {d}\n", .{node_inner_rect});
            // std.debug.print("node_inner_rect.size(): {d}\n", .{node_inner_rect.size()});
            // std.debug.print("ellipsis_text_info.rect: {d}\n", .{ellipsis_text_info.rect});
            // std.debug.print("ellipsis_text_info.rect.size(): {d}\n", .{ellipsis_text_info.rect.size()});
            try shader_inputs.append(ShaderInput.dbg(
                ellipsis_text_base + ellipsis_text_info.rect.min,
                ellipsis_text_base + ellipsis_text_info.rect.max,
                vec4{ 1, 1, 0, 1 },
            ));
            try shader_inputs.append(ShaderInput.dbg(node.rect.min, node.rect.max, vec4{ 0, 1, 0, 1 }));
            try shader_inputs.append(ShaderInput.dbg(node_inner_rect.min, node_inner_rect.max, vec4{ 0.3, 0, 1, 1 }));
            try shader_inputs.append(ShaderInput.dbg(
                text_base + text_info.rect.min,
                text_base + text_info.rect.max,
                vec4{ 1, 0, 0, 1 },
            ));
        }

        var base_text_rect = base_rect;
        base_text_rect.top_left_color = node.text_color;
        base_text_rect.btm_left_color = node.text_color;
        base_text_rect.top_right_color = node.text_color;
        base_text_rect.btm_right_color = node.text_color;
        base_text_rect.corner_radii = [4]f32{ 0, 0, 0, 0 };
        base_text_rect.edge_softness = 0;
        base_text_rect.border_thickness = [4]f32{ -1, -1, -1, -1 };
        for (quads) |quad| {
            const quad_rect = Rect{ .min = quad.points[0].pos, .max = quad.points[2].pos };
            var rect = base_text_rect;
            rect.btm_left_pos = text_base + quad_rect.min;
            rect.top_right_pos = text_base + quad_rect.max;
            rect.btm_left_uv = quad.points[0].uv;
            rect.top_right_uv = quad.points[2].uv;

            // check if text truncation is needed
            const quad_overflows = rect.top_right_pos[0] - ellipsis_text_base[0] > 1;
            if (needs_truncation and quad_overflows) {
                // draw ellpsis and ignore the rest of the characters
                for (ellipsis_quads) |ell_quad| {
                    rect = base_text_rect;
                    rect.btm_left_pos = ellipsis_text_base + ell_quad.points[0].pos;
                    rect.top_right_pos = ellipsis_text_base + ell_quad.points[2].pos;
                    rect.btm_left_uv = ell_quad.points[0].uv;
                    rect.top_right_uv = ell_quad.points[2].uv;
                    try shader_inputs.append(rect);
                    if (show_dbg_rects) {
                        try shader_inputs.append(ShaderInput.dbg(rect.btm_left_pos, rect.top_right_pos, vec4{ 0, 1, 1, 1 }));
                    }
                }
                node.text_truncated = true;
                break;
            }

            try shader_inputs.append(rect);
            if (show_dbg_rects) {
                try shader_inputs.append(ShaderInput.dbg(rect.btm_left_pos, rect.top_right_pos, vec4{ 0, 1, 1, 1 }));
            }
        }
    } else node.text_truncated = false;
}

pub const RenderOrderNodeIterator = struct {
    cur_node: *Node,
    first_iteration: bool = true,
    parent_level: usize = 0, // how many times have we gone down the hierarchy

    pub fn next(self: *RenderOrderNodeIterator) ?*Node {
        if (self.first_iteration) {
            self.first_iteration = false;
            return self.cur_node;
        }

        if (self.cur_node.child_count > 0) {
            self.parent_level += 1;
            self.cur_node = self.cur_node.first.?;
        } else if (self.cur_node.next) |next_sibling| {
            self.cur_node = next_sibling;
        } else {
            while (self.cur_node.next == null) {
                self.cur_node = self.cur_node.parent orelse return null;
                self.parent_level -= 1;
                if (self.parent_level == 0) return null;
            }
            self.cur_node = self.cur_node.next.?;
        }
        return self.cur_node;
    }
};

fn estimateLineCount(node: *Node, font: Font) f32 {
    const line_size = font.getScaledMetrics(node.font_size).line_advance;
    const text_size = node.text_rect.size();
    return text_size[1] / line_size;
}

fn largeInputOptimizationVisiblePartOfText(self: *UI, node: *Node) struct {
    string: []const u8,
    offset: f32,
} {
    const font = self.font_cache.getFont(node.font_type);
    const line_size = font.getScaledMetrics(node.font_size).line_advance;
    const text_size = node.text_rect.size();
    const num_lines: usize = @intFromFloat(@ceil(text_size[1] / line_size));

    // const top_of_text = node.rect.max[1] - padding[1];
    const top_of_text = node.rect.max[1];
    const top_extra = @max(0, top_of_text - node.clip_rect.max[1]);
    const top_extra_lines: usize = @intFromFloat(@divFloor(top_extra, line_size));

    // const btm_of_text = node.rect.min[1] + padding[1];
    const btm_of_text = node.rect.min[1];
    const btm_extra = @max(0, node.clip_rect.min[1] - btm_of_text);
    const btm_extra_lines: usize = @intFromFloat(@divFloor(btm_extra, line_size));

    const start_idx = if (indexOfNthScalar(node.display_string, '\n', top_extra_lines)) |idx| idx + 1 else 0;
    const rest_of_string = node.display_string[start_idx..];
    const visible_lines = num_lines - top_extra_lines - btm_extra_lines;
    const end_idx = indexOfNthScalar(rest_of_string, '\n', visible_lines) orelse rest_of_string.len;

    return .{
        .string = rest_of_string[0..end_idx],
        .offset = top_extra,
    };
}
