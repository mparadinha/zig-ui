const std = @import("std");
const Allocator = std.mem.Allocator;
const clamp = std.math.clamp;
const zig_ui = @import("../zig_ui.zig");
const vec2 = zig_ui.vec2;
const vec3 = zig_ui.vec3;
const vec4 = zig_ui.vec4;
const glfw = zig_ui.glfw;
const Window = zig_ui.Window;
const Font = zig_ui.Font;
const gfx = @import("graphics.zig");
const utils = @import("utils.zig");

const build_opts = @import("build_opts");

const UI = @This();
pub usingnamespace @import("widgets.zig");
pub usingnamespace @import("layout.zig");
pub usingnamespace @import("rendering.zig");
pub usingnamespace @import("utils.zig");

const ShaderInput = @import("rendering.zig").ShaderInput;

const Cursor = Window.Cursor;

allocator: Allocator,
generic_shader: gfx.Shader,
font: Font,
font_bold: Font,
font_italic: Font,
icon_font: Font,
build_arena: std.heap.ArenaAllocator,
node_table: NodeTable,
prng: PRNG,

// if we accidentally create two nodes with the same hash in the frame this
// might lead to the node tree having cycles (which hangs whenever we traverse it)
// this is cleared every frame
node_keys_this_frame: std.AutoHashMap(NodeKey, void),

// to prevent having error return in all the functions, we ignore the errors during the
// ui building phase, and return one only at the end of the building phase.
// so we store the stack trace of the first error that occurred here
first_error_trace: ?std.builtin.StackTrace,
first_error_name: []const u8,
first_error_stack_trace: std.builtin.StackTrace,

base_style: Style,

// per-frame data
parent_stack: Stack(*Node),
style_stack: Stack(Style),
auto_pop_style: bool,
root: ?*Node,
ctx_menu_root: ?*Node,
tooltip_root: ?*Node,
window_roots: std.ArrayList(*Node),
screen_size: vec2,
mouse_pos: vec2, // in pixels
events: *Window.EventQueue,
// because the `hovered` signal is tied to an input event we can't remove it from
// the event queue to signify that some node consumed it.
some_node_is_hovered: bool,

// cross-frame data
frame_idx: usize,
hot_node_key: ?NodeKey,
active_node_key: ?NodeKey,
focused_node_key: ?NodeKey,

const NodeKey = NodeTable.Hash;

pub const FontOptions = struct {
    font_path: []const u8 = build_opts.resource_dir ++ "/VictorMono-Regular.ttf",
    bold_font_path: []const u8 = build_opts.resource_dir ++ "/VictorMono-Bold.ttf",
    italic_font_path: []const u8 = build_opts.resource_dir ++ "/VictorMono-Oblique.ttf",
    icon_font_path: []const u8 = build_opts.resource_dir ++ "/icons.ttf",
};
// icon font (and this mapping) was generated using fontello.com
pub const Icons = struct {
    // zig fmt: off
    pub const cancel =        "\u{e800}";
    pub const th_list =       "\u{e801}";
    pub const search =        "\u{e802}";
    pub const plus_circled =  "\u{e803}";
    pub const cog =           "\u{e804}";
    pub const ok =            "\u{e805}";
    pub const circle =        "\u{f111}";
    pub const up_open =       "\u{e806}";
    pub const right_open =    "\u{e807}";
    pub const left_open =     "\u{e808}";
    pub const down_open =     "\u{e809}";
    pub const plus_squared =  "\u{f0fe}";
    pub const minus_squared = "\u{f146}";
    pub const plus =          "\u{e80a}";
    // zig fmt: on
};

// call `deinit` to cleanup resources
pub fn init(allocator: Allocator, font_opts: FontOptions) !UI {
    return UI{
        .allocator = allocator,
        .generic_shader = gfx.Shader.from_srcs(allocator, "ui_generic", .{
            .vertex = @embedFile("shader.vert"),
            .geometry = @embedFile("shader.geom"),
            .fragment = @embedFile("shader.frag"),
        }) catch unreachable,
        .font = try Font.fromTTF(allocator, font_opts.font_path),
        .font_bold = try Font.fromTTF(allocator, font_opts.bold_font_path),
        .font_italic = try Font.fromTTF(allocator, font_opts.italic_font_path),
        .icon_font = try Font.fromTTF(allocator, font_opts.icon_font_path),
        .build_arena = std.heap.ArenaAllocator.init(allocator),
        .node_table = NodeTable.init(allocator),
        .prng = .{ .state = 0 },

        .node_keys_this_frame = std.AutoHashMap(NodeKey, void).init(allocator),

        .first_error_trace = null,
        .first_error_name = "",
        .first_error_stack_trace = undefined,

        .base_style = Style{},

        .parent_stack = Stack(*Node).init(allocator),
        .style_stack = Stack(Style).init(allocator),
        .auto_pop_style = false,
        .root = null,
        .tooltip_root = null,
        .ctx_menu_root = null,
        .window_roots = std.ArrayList(*Node).init(allocator),
        .screen_size = undefined,
        .mouse_pos = undefined,
        .events = undefined,
        .some_node_is_hovered = false,

        .frame_idx = 0,
        .hot_node_key = null,
        .active_node_key = null,
        .focused_node_key = null,
    };
}

pub fn deinit(self: *UI) void {
    self.style_stack.deinit();
    self.parent_stack.deinit();
    self.node_table.deinit();
    self.build_arena.deinit();
    self.font.deinit();
    self.font_bold.deinit();
    self.font_italic.deinit();
    self.icon_font.deinit();
    self.generic_shader.deinit();
    self.window_roots.deinit();
    self.node_keys_this_frame.deinit();
}

pub const Flags = packed struct {
    // interactivity flags
    clickable: bool = false,
    selectable: bool = false, // maintains focus when clicked
    toggleable: bool = false, // like `clickable` but `Signal.toggled` is also used
    scroll_children_x: bool = false,
    scroll_children_y: bool = false,

    // rendering flags
    clip_children: bool = false,
    draw_text: bool = false,
    draw_border: bool = false,
    draw_background: bool = false,
    draw_hot_effects: bool = false,
    draw_active_effects: bool = false,
    disable_text_truncation: bool = false,

    // node is not taken into account in the normal layout
    floating_x: bool = false,
    floating_y: bool = false,

    no_id: bool = false,
    ignore_hash_sep: bool = false,

    pub fn interactive(self: Flags) bool {
        return self.clickable or
            self.selectable or
            self.toggleable or
            self.scroll_children_x or
            self.scroll_children_y;
    }
};

pub const Node = struct {
    // tree links (updated every frame)
    first: ?*Node,
    last: ?*Node,
    next: ?*Node,
    prev: ?*Node,
    parent: ?*Node,
    child_count: usize,

    // per-frame params
    flags: Flags,
    display_string: []const u8,
    key: NodeKey,
    bg_color: vec4,
    border_color: vec4,
    text_color: vec4,
    corner_radii: [4]f32, // order is left-to-right, top-to-bottom
    edge_softness: f32,
    border_thickness: f32,
    size: [2]Size,
    alignment: Alignment,
    layout_axis: Axis,
    cursor_type: Cursor,
    font_type: FontType,
    font_size: f32,
    text_align: TextAlign,
    custom_draw_fn: ?CustomDrawFn,
    custom_draw_ctx_as_bytes: ?[]const u8, // gets copied during `addNode`
    scroll_multiplier: vec2,
    inner_padding: vec2,
    outer_padding: vec2,

    // per-frame additional info
    first_time: bool,

    // per-frame sizing information
    text_rect: Rect,

    // post-size-determination data
    calc_size: vec2,
    calc_rel_pos: vec2, // relative to bottom left (0, 0) corner of the parent

    // post-layout data
    rect: Rect,
    clip_rect: Rect,
    children_size: vec2,

    // persists across frames (but gets updated every frame)
    signal: Signal,

    // persistent cross-frame state
    hot_trans: f32,
    active_trans: f32,
    first_frame_touched: usize,
    last_frame_touched: usize,

    // cross-frame state for specific features
    rel_pos: RelativePlacement, // relative to parent
    last_click_time: f32, // used for double click checks
    last_double_click_time: f32, // used for triple click checks
    scroll_offset: vec2,
    toggled: bool, // used for collapsible tree node
};

pub const CustomDrawFn = *const fn (
    ui: *UI,
    shader_inputs: *std.ArrayList(ShaderInput),
    node: *Node,
) error{OutOfMemory}!void;

pub const Axis = enum { x, y };
pub const Alignment = enum { start, center, end };
pub const FontType = enum { text, text_bold, text_italic, icon }; // update `shader.frag` whenever this changes
pub const TextAlign = enum { left, center, right };

pub const Style = struct {
    bg_color: vec4 = vec4{ 0, 0, 0, 1 },
    border_color: vec4 = vec4{ 0.5, 0.5, 0.5, 0.75 },
    text_color: vec4 = vec4{ 1, 1, 1, 1 },
    corner_radii: [4]f32 = [4]f32{ 0, 0, 0, 0 },
    edge_softness: f32 = 0.5,
    border_thickness: f32 = -1,
    size: [2]Size = .{ Size.text(1), Size.text(1) },
    layout_axis: Axis = .y,
    alignment: Alignment = .start,
    cursor_type: Cursor = .arrow,
    font_type: FontType = .text,
    font_size: f32 = 18,
    text_align: TextAlign = .left,
    custom_draw_fn: ?CustomDrawFn = null,
    custom_draw_ctx_as_bytes: ?[]const u8 = null,
    scroll_multiplier: vec2 = @splat(18 * 2),
    inner_padding: vec2 = vec2{ 0, 0 },
    outer_padding: vec2 = vec2{ 0, 0 },
};

pub const Size = union(enum) {
    pixels: struct { value: f32, strictness: f32 },
    text: struct { strictness: f32 },
    em: struct { value: f32, strictness: f32 },
    percent: struct { value: f32, strictness: f32 },
    children: struct { strictness: f32 },

    const Tag = std.meta.Tag(Size);

    pub fn pixels(value: f32, strictness: f32) Size {
        return Size{ .pixels = .{ .value = value, .strictness = strictness } };
    }
    pub fn text(strictness: f32) Size {
        return Size{ .text = .{ .strictness = strictness } };
    }
    pub fn em(value: f32, strictness: f32) Size {
        return Size{ .em = .{ .value = value, .strictness = strictness } };
    }
    pub fn percent(value: f32, strictness: f32) Size {
        return Size{ .percent = .{ .value = value, .strictness = strictness } };
    }
    pub fn children(strictness: f32) Size {
        return Size{ .children = .{ .strictness = strictness } };
    }

    // TODO: `em` Size type as well? or just a UI helper that uses the top font?

    pub fn getStrictness(self: Size) f32 {
        return switch (self) {
            inline else => |v| v.strictness,
        };
    }

    pub const children2 = fillByChildren;

    pub fn exact(tag: Tag, x: f32, y: f32) [2]Size {
        return switch (tag) {
            .pixels => [2]Size{ Size.pixels(x, 1), Size.pixels(y, 1) },
            .em => [2]Size{ Size.em(x, 1), Size.em(y, 1) },
            .percent => [2]Size{ Size.percent(x, 1), Size.percent(y, 1) },
            else => @panic(""),
        };
    }

    pub fn flexible(tag: Tag, x: f32, y: f32) [2]Size {
        return switch (tag) {
            .pixels => [2]Size{ Size.pixels(x, 0), Size.pixels(y, 0) },
            .em => [2]Size{ Size.em(x, 0), Size.em(y, 0) },
            .percent => [2]Size{ Size.percent(x, 0), Size.percent(y, 0) },
            else => @panic(""),
        };
    }

    pub fn fillByChildren(x_strictness: f32, y_strictness: f32) [2]Size {
        return [2]Size{ Size.children(x_strictness), Size.children(y_strictness) };
    }

    pub fn fillAxis(axis: Axis, other_size: Size) [2]Size {
        return switch (axis) {
            .x => [2]Size{ Size.percent(1, 1), other_size },
            .y => [2]Size{ other_size, Size.percent(1, 1) },
        };
    }

    pub fn fromRect(rect: Rect) [2]Size {
        const size = rect.size();
        return Size.exact(.pixels, size[0], size[1]);
    }

    pub fn format(value: Size, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        switch (value) {
            .pixels => |v| try writer.print("pixels({d}, {d})", .{ v.value, v.strictness }),
            .em => |v| try writer.print("em({d}, {d})", .{ v.value, v.strictness }),
            .text => |v| try writer.print("text({d})", .{v.strictness}),
            .percent => |v| try writer.print("percent({d}, {d})", .{ v.value, v.strictness }),
            .children => |v| try writer.print("children({d})", .{v.strictness}),
        }
    }
};

pub const Rect = struct {
    min: vec2,
    max: vec2,

    pub fn at(placement: Placement, rect_size: vec2) Rect {
        const btm_left = placement.convertTo(.btm_left, rect_size).btm_left;
        return .{ .min = btm_left, .max = btm_left + rect_size };
    }

    pub fn size(self: Rect) vec2 {
        return self.max - self.min;
    }

    pub fn contains(self: Rect, pos: vec2) bool {
        return pos[0] < self.max[0] and pos[0] > self.min[0] and
            pos[1] < self.max[1] and pos[1] > self.min[1];
    }

    pub fn containsRect(self: Rect, other: Rect) bool {
        return self.contains(other.min) and self.contains(other.max);
    }

    pub fn snapped(self: Rect, placement: Placement) Rect {
        const calc_size = self.size();
        const bottom_left = placement.convertTo(.btm_left, calc_size);
        return .{ .min = bottom_left, .max = bottom_left + calc_size };
    }

    pub fn get(self: Rect, place: Placement.Tag) vec2 {
        return (Placement{ .btm_left = self.min }).convertTo(place, self.size()).value();
    }

    pub fn clamp(self: Rect, other: Rect) Rect {
        const max_overflow = @max(vec2{ 0, 0 }, self.max - other.max);
        var clamped = self.offset(-max_overflow);
        const min_overflow = @min(vec2{ 0, 0 }, self.min - other.min);
        clamped = clamped.offset(-min_overflow);
        return Rect.intersection(clamped, other);
    }

    pub fn offset(self: Rect, diff: vec2) Rect {
        return .{ .min = self.min + diff, .max = self.max + diff };
    }

    /// scale rect while keeping center in the same place
    pub fn scale(self: Rect, mult: vec2) Rect {
        return Rect.at(.{ .center = self.get(.center) }, self.size() * mult);
    }

    pub fn intersection(self: Rect, other: Rect) Rect {
        const highest_min = @max(self.min, other.min);
        const lowest_max = @min(self.max, other.max);
        if (@reduce(.Or, lowest_max < highest_min)) return .{ .min = @splat(0), .max = @splat(0) };
        return .{ .min = highest_min, .max = lowest_max };
    }

    pub fn format(v: Rect, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{{ .min={d:.2}, .max={d:.2} }}", .{ v.min, v.max });
    }
};

pub const Placement = union(enum) {
    top_left: vec2,
    btm_left: vec2,
    top_right: vec2,
    btm_right: vec2,
    center: vec2,
    middle_top: vec2,
    middle_btm: vec2,
    middle_left: vec2,
    middle_right: vec2,

    const Tag = std.meta.Tag(Placement);

    // `@unionInit` only works if the tag is comptime known
    pub fn init(tag: Tag, v: vec2) Placement {
        return switch (tag) {
            inline else => |t| @unionInit(Placement, @tagName(t), v),
        };
    }

    pub fn value(self: Placement) vec2 {
        return switch (self) {
            inline else => |v| v,
        };
    }

    pub fn convertTo(self: Placement, new_tag: Tag, rect_size: vec2) Placement {
        if (self == new_tag) return self;
        const center = self.getCenter(rect_size);
        const half_size = rect_size / vec2{ 2, 2 };
        return Placement.init(new_tag, switch (new_tag) {
            .top_left => center + vec2{ -half_size[0], half_size[1] },
            .btm_left => center - half_size,
            .top_right => center + half_size,
            .btm_right => center + vec2{ half_size[0], -half_size[1] },
            .center => center,
            .middle_top => center + vec2{ 0, half_size[1] },
            .middle_btm => center - vec2{ 0, half_size[1] },
            .middle_left => center - vec2{ half_size[0], 0 },
            .middle_right => center + vec2{ half_size[0], 0 },
        });
    }

    pub fn getCenter(self: Placement, rect_size: vec2) vec2 {
        const half_size = rect_size / vec2{ 2, 2 };
        return switch (self) {
            .top_left => |tl| tl + vec2{ half_size[0], -half_size[1] },
            .btm_left => |bl| bl + half_size,
            .top_right => |tr| tr - half_size,
            .btm_right => |br| br + vec2{ -half_size[0], half_size[1] },
            .center => |cntr| cntr,
            .middle_top => |mt| mt - vec2{ 0, half_size[1] },
            .middle_btm => |mb| mb + vec2{ 0, half_size[1] },
            .middle_left => |ml| ml + vec2{ half_size[0], 0 },
            .middle_right => |mr| mr - vec2{ half_size[0], 0 },
        };
    }
};

/// defines a placement such that `anchor` plus `diff` is `target`
/// `anchor` usually refers to some parent, and `target` to the thing we want to place
pub const RelativePlacement = struct {
    target: Placement.Tag,
    anchor: Placement.Tag,
    diff: vec2 = vec2{ 0, 0 },

    pub fn match(tag: Placement.Tag) RelativePlacement {
        return .{ .target = tag, .anchor = tag };
    }

    pub fn offset(tag: Placement.Tag, diff: vec2) RelativePlacement {
        return .{ .target = tag, .anchor = tag, .diff = diff };
    }

    pub fn simple(diff: vec2) RelativePlacement {
        return .{ .target = .btm_left, .anchor = .btm_left, .diff = diff };
    }

    pub fn absolute(placement: Placement) RelativePlacement {
        return .{ .target = std.meta.activeTag(placement), .anchor = .btm_left, .diff = placement.value() };
    }

    /// given the sizes of the two objects we can calculate their relative position
    pub fn calcRelativePos(rel_placement: RelativePlacement, target_size: vec2, anchor_size: vec2) vec2 {
        return Placement.init(rel_placement.target, rel_placement.diff)
            .convertTo(.btm_left, target_size)
            .convertTo(rel_placement.anchor, anchor_size)
            .value();
    }

    pub fn format(v: RelativePlacement, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{{ .target={s}, .anchor={s}, .diff={d:4.2} }}", .{
            @tagName(v.target), @tagName(v.anchor), v.diff,
        });
    }
};

pub const Signal = struct {
    node: ?*Node,

    clicked: bool = false,
    pressed: bool = false,
    released: bool = false,
    double_clicked: bool = false,
    triple_clicked: bool = false,
    hovering: bool = false,
    held_down: bool = false,
    enter_pressed: bool = false,
    scroll_amount: vec2 = vec2{ 0, 0 }, // positive means scrolling up/left
    focused: bool = false,
    toggled: bool = false,

    // these are relative to bottom-left corner of node
    mouse_pos: vec2 = vec2{ 0, 0 },
    drag_start: vec2 = vec2{ 0, 0 },

    pub fn dragRect(signal: Signal) Rect {
        return .{
            .min = @min(signal.drag_start, signal.mouse_pos),
            .max = @max(signal.drag_start, signal.mouse_pos),
        };
    }

    pub fn dragOffset(signal: Signal) vec2 {
        return signal.mouse_pos - signal.drag_start;
    }
};

pub fn addNode(self: *UI, flags: Flags, string: []const u8, init_args: anytype) *Node {
    const node = self.addNodeRaw(flags, string, init_args) catch |e| blk: {
        self.setErrorInfo(@errorReturnTrace(), @errorName(e));
        break :blk self.root.?;
    };
    return node;
}

pub fn addNodeF(self: *UI, flags: Flags, comptime fmt: []const u8, args: anytype, init_args: anytype) *Node {
    const str = self.fmtTmpString(fmt, args);
    return self.addNode(flags, str, init_args);
}

// TODO: remove this, use '###' instead?
pub fn addNodeStrings(self: *UI, flags: Flags, display_string: []const u8, hash_string: []const u8, init_args: anytype) *Node {
    const node = self.addNodeRawStrings(flags, display_string, hash_string, init_args) catch |e| blk: {
        self.setErrorInfo(@errorReturnTrace(), @errorName(e));
        break :blk self.root.?;
    };
    return node;
}

pub fn addNodeStringsF(
    self: *UI,
    flags: Flags,
    comptime display_fmt: []const u8,
    display_args: anytype,
    comptime hash_fmt: []const u8,
    hash_args: anytype,
    init_args: anytype,
) *Node {
    const display_str = self.fmtTmpString(display_fmt, display_args);
    const hash_str = self.fmtTmpString(hash_fmt, hash_args);
    return self.addNodeStrings(flags, display_str, hash_str, init_args);
}

pub fn addNodeRaw(self: *UI, flags: Flags, string: []const u8, init_args: anytype) !*Node {
    const display_string = if (flags.ignore_hash_sep) string else displayPartOfString(string);
    const hash_string = if (flags.ignore_hash_sep) string else hashPartOfString(string);
    return self.addNodeRawStrings(flags, display_string, hash_string, init_args);
}

pub fn addNodeRawStrings(
    self: *UI,
    flags: Flags,
    display_str_in: []const u8,
    hash_str_in: []const u8,
    init_args: anytype,
) !*Node {
    const arena = self.build_arena.allocator();

    const display_str = if (flags.draw_text) display_str_in else &[0]u8{};
    const hash_str = if (flags.no_id) blk: {
        // for `no_id` nodes we use a random number as the hash string, so they don't clobber each other
        break :blk &randomArray(&self.prng);
    } else if (self.parent_stack.top()) |stack_top| blk: {
        // to allow for nodes with different parents to have the same name we
        // combine the node's hash string with the hash string of the first parent
        // to have a stable one (i.e. *not* `no-id`).
        var parent = stack_top;
        while (parent.flags.no_id) parent = parent.parent orelse
            @panic("at some point the root should have a stable name");
        break :blk try std.fmt.allocPrint(arena, "{x:0>16}:{s}", .{ parent.key, hash_str_in });
    } else blk: {
        break :blk hash_str_in;
    };

    const node_key = self.node_table.getKeyHash(hash_str);
    if (try self.node_keys_this_frame.fetchPut(node_key, {})) |_| {
        // TODO: in the future this should not panic but instead save the error
        // for the user until the end of build; when we implement that we should
        // turn this node into a `no_id` and return it as if nothing happened.
        std.debug.panic("hash_string='{s}' has collision\n", .{hash_str});
    }

    // if a node already exists that matches this one we just use that one
    // this way the persistant cross-frame data is possible
    const lookup_result = try self.node_table.getOrPutHash(node_key);
    var node = lookup_result.value_ptr;

    // link node into the tree
    const parent = self.parent_stack.top();
    node.first = null;
    node.last = null;
    node.next = null;
    node.prev = if (parent) |parent_node| blk: {
        break :blk if (parent_node.last == node) null else parent_node.last;
    } else null;
    node.parent = parent;
    node.child_count = 0;
    if (node.prev) |prev| prev.next = node;
    if (parent) |parent_node| {
        if (parent_node.child_count == 0) parent_node.first = node;
        parent_node.child_count += 1;
        parent_node.last = node;
    }

    // set per-frame data
    if (flags.interactive() and flags.no_id)
        std.debug.panic("conflicting flags: `no_id` nodes can't be interacted with:\n{}\n", .{flags});
    node.flags = flags;
    node.display_string = try arena.dupe(u8, display_str);
    node.key = node_key;
    const style = self.style_stack.top().?;
    inline for (@typeInfo(Style).Struct.fields) |field_type_info| {
        const field_name = field_type_info.name;
        @field(node, field_name) = @field(style, field_name);
    }
    node.inner_padding = if (node.flags.draw_text) self.textPadding(node) else vec2{ 0, 0 };

    node.first_time = !lookup_result.found_existing;

    // reset layout data (but not the final screen rect which we need for signal stuff)
    node.calc_size = vec2{ 0, 0 };
    node.calc_rel_pos = vec2{ 0, 0 };

    // update cross-frame (persistant) data
    node.last_frame_touched = self.frame_idx;
    if (node.first_time) {
        node.signal = .{ .node = node, .mouse_pos = undefined };
        node.first_frame_touched = self.frame_idx;
        node.rel_pos = RelativePlacement.match(.btm_left);
        node.last_click_time = 0;
        node.last_double_click_time = 0;
        node.scroll_offset = vec2{ 0, 0 };
        node.toggled = false;
    }

    // user overrides of node data
    inline for (@typeInfo(@TypeOf(init_args)).Struct.fields) |field_type_info| {
        const field_name = field_type_info.name;
        @field(node, field_name) = @field(init_args, field_name);
    }

    // for large inputs calculating the text size is too expensive to do multiple times per frame
    node.text_rect = try self.calcTextRect(node, node.display_string);

    // save the custom draw context if needed
    if (node.custom_draw_ctx_as_bytes) |ctx_bytes|
        node.custom_draw_ctx_as_bytes = try arena.dupe(u8, ctx_bytes);

    if (self.auto_pop_style) {
        _ = self.popStyle();
        self.auto_pop_style = false;
    }

    return node;
}

/// make this new node a new root node (i.e. no parent and no siblings)
pub fn addNodeAsRoot(self: *UI, flags: Flags, string: []const u8, init_args: anytype) *Node {
    // the `addNode` function is gonna use whatever parent is at the top of the stack by default
    // so we have to trick it into thinking this is the root node
    const saved_stack_len = self.parent_stack.len();
    self.parent_stack.array_list.items.len = 0;
    defer self.parent_stack.array_list.items.len = saved_stack_len;

    const node = self.addNode(flags, string, init_args);
    return node;
}

pub fn pushParent(self: *UI, node: *Node) void {
    self.parent_stack.push(node) catch |e|
        self.setErrorInfo(@errorReturnTrace(), @errorName(e));
}
pub fn popParent(self: *UI) *Node {
    return self.parent_stack.pop().?;
}
pub fn popParentAssert(self: *UI, expected: *Node) void {
    std.debug.assert(self.popParent() == expected);
}
pub fn topParent(self: *UI) *Node {
    return self.parent_stack.top().?;
}

pub fn pushStyle(self: *UI, partial_style: anytype) void {
    var style = self.style_stack.top().?;
    inline for (@typeInfo(@TypeOf(partial_style)).Struct.fields) |field_type_info| {
        const field_name = field_type_info.name;
        if (!@hasField(Node, field_name)) {
            @compileError("Style does not have a field named '" ++ field_name ++ "'");
        }
        @field(style, field_name) = @field(partial_style, field_name);
    }
    self.style_stack.push(style) catch |e| {
        self.setErrorInfo(@errorReturnTrace(), @errorName(e));
    };
}
pub fn popStyle(self: *UI) Style {
    return self.style_stack.pop().?;
}
pub fn topStyle(self: *UI) Style {
    return self.style_stack.top().?;
}
/// same as `pushStyle` but the it gets auto-pop'd after the next `addNode`
pub fn pushTmpStyle(self: *UI, partial_style: anytype) void {
    self.pushStyle(partial_style);
    if (self.auto_pop_style) std.debug.panic("only one auto-pop'd style can be in the stack\n", .{});
    self.auto_pop_style = true;
}

pub fn setFocusedNode(self: *UI, node: *Node) void {
    self.focused_node_key = self.keyFromNode(node);
}

pub fn startBuild(
    self: *UI,
    screen_w: u32,
    screen_h: u32,
    mouse_pos: vec2,
    events: *Window.EventQueue,
    window: *Window,
) !void {
    self.hot_node_key = null;
    // get the signal in the reverse order that we render in (if a node is on top
    // of another, the top one should get the inputs, no the bottom one)
    if (self.tooltip_root) |node| try self.computeSignalsForTree(node);
    if (self.ctx_menu_root) |node| try self.computeSignalsForTree(node);
    for (self.window_roots.items) |node| try self.computeSignalsForTree(node);
    if (self.root) |node| try self.computeSignalsForTree(node);

    // clear out the whole arena
    _ = self.build_arena.reset(.free_all);

    self.node_keys_this_frame.clearRetainingCapacity();

    // the PRNG is only used for `no_id` hash generation.
    // by reseting it every frame we still get 'random' hashes in the same
    // frame, while maintaining *some* inter-frame consistency
    self.prng.state = 0;

    // remove the `no_id` nodes from the hash table before starting this new frame
    // TODO: is this necessary or just a memory saving thing? because if it's the
    //       latter, these nodes should get yetted on the next frame anyway...
    var node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node| {
        if (node.flags.no_id) try node_iter.removeCurrent();
    }

    const screen_size = vec2{ @as(f32, @floatFromInt(screen_w)), @as(f32, @floatFromInt(screen_h)) };
    self.screen_size = screen_size;
    self.mouse_pos = mouse_pos;
    self.events = events;

    std.debug.assert(self.parent_stack.len() == 0);

    self.style_stack.clear();
    try self.style_stack.push(self.base_style);

    self.root = try self.addNodeRaw(.{ .clip_children = true }, "###INTERNAL_ROOT", .{
        .size = Size.exact(.pixels, screen_size[0], screen_size[1]),
        .rect = Rect{ .min = vec2{ 0, 0 }, .max = screen_size },
    });
    try self.parent_stack.push(self.root.?);

    self.window_roots.clearRetainingCapacity();
    self.ctx_menu_root = null;
    self.tooltip_root = null;

    self.first_error_trace = null;

    self.some_node_is_hovered = false;

    var mouse_cursor: Cursor = .arrow;
    for ([_]?NodeKey{
        self.focused_node_key,
        self.hot_node_key,
        self.active_node_key,
    }) |node_key| {
        if (node_key) |key| mouse_cursor = self.nodeFromKey(key).?.cursor_type;
    }
    window.setCursor(mouse_cursor);
}

pub fn endBuild(self: *UI, dt: f32) void {
    if (self.first_error_trace) |error_trace| {
        std.debug.print("Error '{s}' occurred during the UI building phase with the following error trace:\n{}\n", .{
            self.first_error_name, error_trace,
        });
        std.debug.print("and the following stack trace:\n{}\n", .{self.first_error_stack_trace});
        @panic("An error occurred during the UI building phase");
    }

    _ = self.style_stack.pop().?;
    const parent = self.parent_stack.pop().?;
    if (parent != self.root.?)
        @panic("only the root node should remain in the parent_stack\n");

    std.debug.assert(self.parent_stack.len() == 0);

    // stale node pruning, or else they just keep taking up memory forever
    var node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node_ptr| {
        if (node_ptr.last_frame_touched < self.frame_idx) {
            node_iter.removeCurrent() catch unreachable;
        }
    }

    // in case the hot/active/focused node key is pointing to a stale node
    if (self.hot_node_key != null and !self.node_table.hasKeyHash(self.hot_node_key.?)) self.hot_node_key = null;
    if (self.active_node_key != null and !self.node_table.hasKeyHash(self.active_node_key.?)) self.active_node_key = null;
    if (self.focused_node_key != null and !self.node_table.hasKeyHash(self.focused_node_key.?)) self.focused_node_key = null;

    // update the transition/animation values
    const fast_rate = 1 - std.math.pow(f32, 2, -20.0 * dt);
    node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node_ptr| {
        const node_key = self.keyFromNode(node_ptr);
        const is_hot = (self.hot_node_key == node_key);
        const is_active = (self.active_node_key == node_key);
        const hot_target = if (is_hot) @as(f32, 1) else @as(f32, 0);
        const active_target = if (is_active) @as(f32, 1) else @as(f32, 0);
        node_ptr.hot_trans += (hot_target - node_ptr.hot_trans) * fast_rate;
        node_ptr.active_trans += (active_target - node_ptr.active_trans) * fast_rate;
    }

    // do all the layout
    self.layoutTree(self.root.?);
    for (self.window_roots.items) |node| self.layoutTree(node);
    if (self.ctx_menu_root) |node| self.layoutTree(node);
    if (self.tooltip_root) |node| self.layoutTree(node);

    self.frame_idx += 1;
}

fn computeSignalsForTree(self: *UI, root: *Node) !void {
    var node_iterator = InputOrderNodeIterator.init(root);
    while (node_iterator.next()) |node| {
        node.signal = try self.computeSignalFromNode(node);
    }
}

pub fn computeSignalFromNode(self: *UI, node: *Node) !Signal {
    var signal = Signal{
        .node = node,
        .mouse_pos = self.mouse_pos - node.rect.min,
    };

    const clipped_rect = Rect.intersection(node.clip_rect, node.rect);
    const mouse_is_over = clipped_rect.contains(self.mouse_pos);
    const node_key = self.keyFromNode(node);

    const hot_key_matches = if (self.hot_node_key) |key| key == node_key else false;
    const active_key_matches = if (self.active_node_key) |key| key == node_key else false;
    const focused_key_matches = if (self.focused_node_key) |key| key == node_key else false;

    const is_interactive = node.flags.interactive();
    const is_hot = mouse_is_over and is_interactive;
    var is_active = active_key_matches and is_interactive;
    var is_focused = focused_key_matches and is_interactive;

    const mouse_down_ev = self.events.match(.MouseDown, .{ .button = .left });
    var used_mouse_down_ev = false;
    const mouse_up_ev = self.events.match(.MouseUp, .{ .button = .left });
    var used_mouse_up_ev = false;
    const enter_down_ev = self.events.match(.KeyDown, .{ .key = .enter });
    const used_enter_down_ev = false;
    const enter_up_ev = self.events.match(.KeyUp, .{ .key = .enter });
    var used_enter_up_ev = false;

    if (mouse_is_over and !self.some_node_is_hovered) {
        signal.hovering = true;
        self.some_node_is_hovered = true;
    }

    if (node.flags.clickable or node.flags.toggleable) {
        // begin/end a click if there was a mouse down/up event on this node
        if (is_hot and !active_key_matches and mouse_down_ev != null) {
            signal.pressed = true;
            is_active = true;
            used_mouse_down_ev = true;
        } else if (is_hot and active_key_matches and mouse_up_ev != null) {
            signal.released = true;
            signal.clicked = true;
            is_active = false;
            used_mouse_up_ev = true;
        } else if (!is_hot and active_key_matches and mouse_up_ev != null) {
            is_active = false;
            used_mouse_up_ev = true;
        }

        signal.held_down = is_active;
    }

    if (node.flags.selectable) {
        if (mouse_down_ev != null) is_focused = is_hot;

        // selectables support recieving clicks when the mouse up event happens outside
        if (is_focused and active_key_matches and mouse_up_ev != null) {
            signal.released = true;
            signal.clicked = true;
            is_active = false;
            used_mouse_up_ev = true;
        }

        if (is_focused and enter_up_ev != null) {
            signal.enter_pressed = true;
            used_enter_up_ev = true;
            is_focused = false;
        }
    }

    const is_scrollable = node.flags.scroll_children_x or node.flags.scroll_children_y;
    if (is_scrollable and is_hot) {
        if (self.events.fetchAndRemove(.MouseScroll, null)) |ev| {
            var scroll = vec2{ ev.x, ev.y } * node.scroll_multiplier;
            // TODO: add support for Home/End, PageUp/Down

            // scroll along the child layout axis of the node
            // and shift+scroll swaps the scroll axis
            if ((scroll[0] == 0 and ev.mods.shift) or node.layout_axis == .x)
                std.mem.swap(f32, &scroll[0], &scroll[1]);

            if (!node.flags.scroll_children_x) scroll[0] = 0;
            if (!node.flags.scroll_children_y) scroll[1] = 0;

            signal.scroll_amount = scroll;
            node.scroll_offset += vec2{ 1, -1 } * scroll;
        }
    }

    signal.focused = is_focused;

    // mouse dragging
    signal.drag_start = signal.mouse_pos;
    if (signal.held_down or signal.released) {
        // TODO: maybe we should store this state in the node itself not the signal?
        signal.drag_start = node.signal.drag_start;
    }

    // set/reset the hot and active keys
    if (is_hot and self.hot_node_key == null) self.hot_node_key = node_key;
    if (!is_hot and hot_key_matches) self.hot_node_key = null;
    if (is_active and !active_key_matches) self.active_node_key = node_key;
    if (!is_active and active_key_matches) self.active_node_key = null;
    if (is_focused and !focused_key_matches) self.focused_node_key = node_key;
    if (!is_focused and focused_key_matches) self.focused_node_key = null;

    if (used_mouse_down_ev) _ = self.events.removeAt(mouse_down_ev.?);
    if (used_mouse_up_ev) _ = self.events.removeAt(mouse_up_ev.?);
    if (used_enter_down_ev) _ = self.events.removeAt(enter_down_ev.?);
    if (used_enter_up_ev) _ = self.events.removeAt(enter_up_ev.?);

    // double/triple click logic
    // TODO: expose this delay-time as a user-configurable thing
    //       as far as I can tell (from a limited web search) there is
    //       no way (on linux) to get some system-wide double-click delay
    const delay_time = 0.400; // (in seconds)
    const cur_time: f32 = @floatCast(glfw.getTime());
    // TODO: also keep track of click position and only register a click
    //       as a *double* click if it's within some boundary
    if (signal.clicked and node.last_click_time + delay_time > cur_time)
        signal.double_clicked = true;
    if (signal.double_clicked and node.last_double_click_time + delay_time > cur_time)
        signal.triple_clicked = true;
    if (signal.clicked) node.last_click_time = cur_time;
    if (signal.double_clicked) node.last_double_click_time = cur_time;

    // update/sync toggle info
    if (node.flags.toggleable) {
        if (signal.clicked) node.toggled = !node.toggled;
        signal.toggled = node.toggled;
    }

    return signal;
}

pub fn textPadding(_: *UI, node: *Node) vec2 {
    return @splat(node.font_size * 0.2);
}

/// calculate the origin of a node's text box in absolute coordinates
pub fn textPosFromNode(self: *UI, node: *Node) vec2 {
    _ = self;
    const node_size = node.rect.size();
    const text_rect = node.text_rect;
    const text_size = text_rect.size();
    const text_padd = node.inner_padding;

    // offset from left-side of node rect to start (i.e. left) of text box
    const rel_text_x = switch (node.text_align) {
        .left => text_padd[0],
        .center => (node_size[0] / 2) - (text_size[0] / 2),
        .right => node_size[0] - text_padd[0] - text_size[0],
    };

    // offset from the text's y=0 to middle of the whole text rect
    const text_to_center_y = text_rect.max[1] - (text_size[1] / 2);
    // offset from bottom of node rect to start (i.e. bottom) of text box
    const rel_text_y = (node_size[1] / 2) - text_to_center_y;

    return node.rect.min + vec2{ rel_text_x, rel_text_y };
}

fn calcTextRect(self: *UI, node: *Node, string: []const u8) !Rect {
    const font: *Font = switch (node.font_type) {
        .text => &self.font,
        .text_bold => &self.font_bold,
        .text_italic => &self.font_italic,
        .icon => &self.icon_font,
    };

    const text_line_info = findTextLineInfo(string);
    const num_lines = text_line_info.line_count;
    const longest_line = text_line_info.longest_line;
    if (num_lines <= 1) {
        const font_rect = try font.textRect(string, node.font_size);
        return .{ .min = font_rect.min, .max = font_rect.max };
    }

    const longest_line_width = blk: {
        const rect = try font.textRect(longest_line, node.font_size);
        break :blk rect.max[0] - rect.min[0];
    };

    const line_size = font.getScaledMetrics(node.font_size).line_advance;

    const first_line = string[0 .. indexOfNthScalar(string, '\n', 1) orelse string.len];
    const first_line_rect = try font.textRect(first_line, node.font_size);

    const last_newline = std.mem.lastIndexOfScalar(u8, string, '\n');
    const last_line = string[if (last_newline) |idx| idx + 1 else 0..];
    const last_line_rect = try font.textRect(last_line, node.font_size);

    const first_to_last_baseline = line_size * @as(f32, @floatFromInt(num_lines - 1));

    return .{
        .min = vec2{ 0, -(first_to_last_baseline - last_line_rect.min[1]) },
        .max = vec2{ longest_line_width, first_line_rect.max[1] },
    };
}

/// note that `longest_line` is the longest in *bytes*! which only serves
/// as a _heuristic_ for the longest display line.
/// to actually get the line with the largest display length we need to
/// do all the Font work, because line length depends on the sizes of the
/// glyphs, not amount of bytes. this is true even for ASCII only `str`s,
/// for e.g. with a non-monospaced font, a line of 100 'i's will be shorter
/// then a line of 50 'M's
fn findTextLineInfo(str: []const u8) struct {
    line_count: usize,
    longest_line: []const u8,
} {
    if (str.len == 0) return .{ .line_count = 0, .longest_line = str[0..0] };

    const vec_size = comptime std.simd.suggestVectorLength(u8) orelse 128 / 8;
    const V = @Vector(vec_size, u8);

    var line_count: usize = 1;
    var longest_line: []const u8 = str[0..0];
    var last_line_start: usize = 0;
    var chunk_start: usize = 0;
    while (chunk_start < str.len) {
        const rest_of_str = str[chunk_start..];

        const chunk: V = if (rest_of_str.len < vec_size) chunk: {
            var chunk: V = @splat(0);
            for (rest_of_str, 0..) |char, idx| chunk[idx] = char;
            break :chunk chunk;
        } else str[chunk_start..][0..vec_size].*;

        const cmp = chunk == @as(V, @splat('\n'));
        const one_if_true = @select(u8, cmp, @as(V, @splat(1)), @as(V, @splat(0)));
        const num_matches = @reduce(.Add, one_if_true);
        var advance: usize = vec_size;
        if (num_matches != 0) {
            const max_int: V = @splat(std.math.maxInt(u8));
            const indices = std.simd.iota(u8, vec_size);

            const true_or_max_indices = @select(u8, cmp, indices, max_int);
            const newline_idx = @reduce(.Min, true_or_max_indices);

            const next_line_in_chunk = @as(usize, newline_idx) + 1;
            const next_line_start = chunk_start + next_line_in_chunk;
            const line_len = next_line_start - last_line_start;
            if (line_len > longest_line.len)
                longest_line = str[last_line_start..][0..line_len];

            last_line_start = next_line_start;
            if (num_matches > 1) {
                const longest_possible_line_in_chunk = vec_size - newline_idx - (num_matches - 1);
                if (longest_line.len >= longest_possible_line_in_chunk) {
                    const min_int: V = @splat(std.math.minInt(u8));
                    const true_or_min_indices = @select(u8, cmp, indices, min_int);
                    const last_newline_idx = @reduce(.Max, true_or_min_indices);
                    const last_start_idx = chunk_start + @as(usize, last_newline_idx) + 1;
                    last_line_start = last_start_idx;
                } else {
                    advance = next_line_in_chunk;
                }
            }
        }

        chunk_start += advance;
        line_count += if (advance < vec_size) 1 else std.simd.countElementsWithValue(chunk, '\n');
    }

    if (str[str.len - 1] == '\n' and line_count > 1) line_count -= 1;
    if (longest_line.len == 0) longest_line = str;
    return .{ .line_count = line_count, .longest_line = longest_line };
}

/// find the index of the `nth` occurence of `scalar` in `slice`
pub fn indexOfNthScalar(slice: []const u8, scalar: u8, nth: usize) ?usize {
    if (nth == 0) return null;

    const vec_size = comptime std.simd.suggestVectorLength(u8) orelse 128 / 8;
    const V = @Vector(vec_size, u8);

    var running_count: usize = 0;

    for (0..slice.len / vec_size) |chunk_idx| {
        const start_idx = chunk_idx * vec_size;
        const chunk: V = slice[start_idx..][0..vec_size].*;
        const chunk_count = std.simd.countElementsWithValue(chunk, scalar);
        if (running_count + chunk_count >= nth) {
            for (0..vec_size) |elem_idx| {
                if (chunk[elem_idx] == scalar) running_count += 1;
                if (running_count == nth) return start_idx + elem_idx;
            }
        }
        running_count += chunk_count;
    }
    if (slice.len % vec_size != 0) {
        const start_idx = slice.len - (slice.len % vec_size);
        for (slice[start_idx..], 0..) |elem, elem_idx| {
            if (elem == scalar) running_count += 1;
            if (running_count == nth) return start_idx + elem_idx;
        }
    }

    return null;
}

pub fn fmtTmpString(ui: *UI, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(ui.build_arena.allocator(), fmt, args) catch |e| {
        ui.setErrorInfo(@errorReturnTrace(), @errorName(e));
        return "";
    };
}

pub fn setErrorInfo(self: *UI, error_trace: ?*std.builtin.StackTrace, name: []const u8) void {
    const allocator = self.build_arena.allocator();
    if (self.first_error_trace) |_| return;
    self.first_error_trace = if (error_trace) |trace| .{
        .index = trace.index,
        .instruction_addresses = allocator.dupe(usize, trace.instruction_addresses) catch @panic("OOM"),
    } else @panic("setErrorInfo called with a null stack trace");
    self.first_error_name = allocator.dupe(u8, name) catch @panic("OOM");
    self.first_error_stack_trace = .{
        .index = 0,
        .instruction_addresses = allocator.alloc(usize, 32) catch @panic("OOM"),
    };
    std.debug.captureStackTrace(@returnAddress(), &self.first_error_stack_trace);
}

pub fn nodeFromKey(self: UI, key: NodeKey) ?*Node {
    return self.node_table.getFromHash(key);
}

pub fn keyFromNode(_: UI, node: *Node) NodeKey {
    return node.key;
}

pub fn displayPartOfString(string: []const u8) []const u8 {
    if (std.mem.indexOf(u8, string, "###")) |idx| {
        return string[0..idx];
    } else return string;
}

pub fn hashPartOfString(string: []const u8) []const u8 {
    if (std.mem.indexOf(u8, string, "###")) |idx| {
        return string[idx + 3 ..];
    } else return string;
}

//  render order:  |  event consumption order:
//       0         |       6
//    ┌──┴──┐      |    ┌──┴──┐
//    1     4      |    5     2
//   ┌┴┐   ┌┴┐     |   ┌┴┐   ┌┴┐
//   2 3   5 6     |   4 3   1 0
pub const InputOrderNodeIterator = struct {
    cur_node: *Node,
    reached_top: bool,

    const Self = @This();

    pub fn init(root: *Node) Self {
        var self = Self{ .cur_node = root, .reached_top = false };
        while (self.cur_node.last) |last| self.cur_node = last;
        return self;
    }

    pub fn next(self: *Self) ?*Node {
        if (self.reached_top) return null;

        const cur_node = self.cur_node;
        var next_node = @as(?*Node, cur_node);

        if (cur_node.prev) |prev| {
            next_node = prev;
            while (next_node.?.last) |last| next_node = last;
        } else next_node = cur_node.parent;

        if (next_node) |node| {
            self.cur_node = node;
        } else self.reached_top = true;

        return cur_node;
    }
};

/// very small wrapper around std.ArrayList that provides push, pop, and top functions
pub fn Stack(comptime T: type) type {
    return struct {
        array_list: std.ArrayList(T),

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{ .array_list = std.ArrayList(T).init(allocator) };
        }

        pub fn deinit(self: Self) void {
            self.array_list.deinit();
        }

        pub fn push(self: *Self, item: T) !void {
            try self.array_list.append(item);
        }

        pub fn pop(self: *Self) ?T {
            return self.array_list.popOrNull();
        }

        pub fn top(self: Self) ?T {
            if (self.array_list.items.len == 0) return null;
            return self.array_list.items[self.array_list.items.len - 1];
        }

        pub fn len(self: Self) usize {
            return self.array_list.items.len;
        }

        pub fn clear(self: *Self) void {
            self.array_list.clearRetainingCapacity();
        }
    };
}

/// Hash map where pointers to entries remains stable when adding new ones.
/// Supports removing entries while iterating over them.
pub const NodeTable = struct {
    allocator: Allocator,
    ptr_map: PtrMap,

    const K = []const u8;
    const V = Node;
    const Hash = u64;
    const PtrMap = std.ArrayHashMap(Hash, *V, struct {
        pub fn hash(_: @This(), key: Hash) u32 {
            return @truncate(key);
        }
        pub fn eql(_: @This(), a: Hash, b: Hash, _: usize) bool {
            return a == b;
        }
    }, false);

    pub fn init(allocator: Allocator) NodeTable {
        return .{
            .allocator = allocator,
            .ptr_map = PtrMap.init(allocator),
        };
    }

    pub fn deinit(self: *NodeTable) void {
        var ptr_iter = self.ptr_map.iterator();
        while (ptr_iter.next()) |entry| self.allocator.destroy(entry.value_ptr.*);
        self.ptr_map.deinit();
    }

    pub const GetOrPutResult = struct { found_existing: bool, value_ptr: *V };

    pub fn getOrPut(self: *NodeTable, key: K) !GetOrPutResult {
        return self.getOrPutHash(self.getKeyHash(key));
    }

    pub fn getOrPutHash(self: *NodeTable, hash: Hash) !GetOrPutResult {
        const gop = try self.ptr_map.getOrPut(hash);
        if (!gop.found_existing) {
            const value_ptr = try self.allocator.create(V);
            gop.value_ptr.* = value_ptr;
        }
        return GetOrPutResult{
            .found_existing = gop.found_existing,
            .value_ptr = gop.value_ptr.*,
        };
    }

    pub fn getKeyHash(_: NodeTable, key: K) Hash {
        return std.hash_map.hashString(key);
    }

    pub fn getFromHash(self: NodeTable, hash: Hash) ?*V {
        return self.ptr_map.get(hash);
    }

    /// does nothing if the key doesn't exist
    pub fn remove(self: *NodeTable, key: K) void {
        const hash = self.getKeyHash(key);
        if (self.ptr_map.fetchSwapRemove(hash)) |pair| {
            self.allocator.destroy(pair.value.*);
        }
    }

    pub fn removeAt(self: *NodeTable, idx: usize) void {
        const node_ptr = self.ptr_map.values()[idx];
        self.allocator.destroy(node_ptr);
        self.ptr_map.swapRemoveAt(idx);
    }

    pub fn hasKey(self: *NodeTable, key: K) bool {
        return self.hasKeyHash(self.getKeyHash(key));
    }

    pub fn hasKeyHash(self: *NodeTable, hash: Hash) bool {
        return self.ptr_map.contains(hash);
    }

    pub fn count(self: NodeTable) usize {
        return self.ptr_map.count();
    }

    /// Any adding/removing to/from the table might invalidate this array
    pub fn values(self: *NodeTable) []*V {
        return self.ptr_map.values();
    }

    pub fn valueIterator(self: *NodeTable) ValueIterator {
        return ValueIterator{ .iter = self.ptr_map.iterator(), .table = self };
    }

    pub const ValueIterator = struct {
        iter: PtrMap.Iterator,
        table: *NodeTable,

        pub fn next(it: *ValueIterator) ?*V {
            const iter_next = it.iter.next();
            return if (iter_next) |entry| entry.value_ptr.* else null;
        }

        pub fn removeCurrent(it: *ValueIterator) !void {
            if (it.iter.index > 0) it.iter.index -= 1;
            it.table.removeAt(it.iter.index);
            it.iter.len -= 1;
        }
    };
};

pub const PRNG = struct {
    state: u64,

    pub fn next(self: *PRNG) u64 {
        // 3 random primes I generated online
        self.state = ((self.state *% 2676693499) +% 5223158351) ^ 4150081079;
        return self.state;
    }
};

pub fn randomArray(prng: *PRNG) [16]u8 {
    return @as([8]u8, @bitCast(prng.next())) ++ @as([8]u8, @bitCast(prng.next()));
}

pub fn dumpNodeTree(self: *UI) void {
    var node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node| {
        std.debug.print("{*} [{s}] :: first=0x{x:0>15}, last=0x{x:0>15}, next=0x{x:0>15}, prev=0x{x:0>15}, parent=0x{x:0>15}, child_count={}\n", .{
            node,
            node.hash_string,
            if (node.first) |ptr| @intFromPtr(ptr) else 0,
            if (node.last) |ptr| @intFromPtr(ptr) else 0,
            if (node.next) |ptr| @intFromPtr(ptr) else 0,
            if (node.prev) |ptr| @intFromPtr(ptr) else 0,
            if (node.parent) |ptr| @intFromPtr(ptr) else 0,
            node.child_count,
        });
    }
}

pub fn dumpNodeTreeGraph(self: *UI, root: *Node, file: std.fs.File) !void {
    _ = root;

    var writer = file.writer();

    _ = try writer.write("digraph {\n");
    _ = try writer.write("  overlap=true;\n");
    _ = try writer.write("  ranksep=2;\n");

    var node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node| {
        try writer.print("  Node_0x{x} [label=\"", .{@intFromPtr(node)});
        try writer.print("{any}\n", .{node.size});
        try writer.print("{d}\n", .{node.rect});
        if (node.child_count > 0) try writer.print("child_layout={}\n", .{node.layout_axis});
        inline for (@typeInfo(Flags).Struct.fields) |field| {
            if (@field(node.flags, field.name)) _ = try writer.write(field.name ++ ",");
        }
        try writer.print("\"];\n", .{});
        const tree_fields = &.{ "parent", "first", "last", "next", "prev" };
        inline for (tree_fields) |field| {
            if (@field(node, field)) |other|
                try writer.print("    Node_0x{x} -> Node_0x{x} [label=\"{s}\"];\n", .{ @intFromPtr(node), @intFromPtr(other), field });
        }
    }

    node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node| {
        if (node.child_count == 0) continue;

        _ = try writer.write("  subgraph {\n");
        _ = try writer.write("    rankdir=LR;\n");
        _ = try writer.write("    rank=same;\n");

        var child = node.first;
        while (child) |child_node| : (child = child_node.next) {
            try writer.print("    Node_0x{x};\n", .{@intFromPtr(child_node)});
        }

        _ = try writer.write("  }\n");
    }

    _ = try writer.write("}\n");
}

pub const DebugView = struct {
    allocator: Allocator,
    ui: UI,
    active: bool,
    node_list_idx: usize,
    node_list_len: usize,
    node_query_pos: ?vec2,
    anchor_right: bool,
    show_help: bool,

    pub fn init(allocator: Allocator) !DebugView {
        return DebugView{
            .allocator = allocator,
            .ui = try UI.init(allocator, .{}),
            .active = false,
            .node_list_idx = 0,
            .node_list_len = 0,
            .node_query_pos = null,
            .anchor_right = false,
            .show_help = true,
        };
    }

    pub fn deinit(self: *DebugView) void {
        self.ui.deinit();
    }

    pub fn show(
        self: *DebugView,
        ui: *UI,
        width: u32,
        height: u32,
        mouse_pos: vec2,
        events: *Window.EventQueue,
        window: *Window,
        dt: f32,
    ) !void {
        // ctrl+shift+h to toggle help menu
        const ctrl_shift = Window.InputEvent.Modifiers{ .shift = true, .control = true };
        if (events.searchAndRemove(.KeyDown, .{ .key = .h, .mods = ctrl_shift }))
            self.show_help = !self.show_help;
        // ctrl+shift+up/down to change the highlighted node in the list
        if (events.searchAndRemove(.KeyDown, .{ .key = .up, .mods = ctrl_shift })) {
            if (self.node_list_idx == 0) {
                self.node_list_idx = std.math.maxInt(usize);
            } else {
                self.node_list_idx -= 1;
            }
        }
        if (events.searchAndRemove(.KeyDown, .{ .key = .down, .mods = ctrl_shift })) {
            self.node_list_idx = (self.node_list_idx + 1) % self.node_list_len;
        }
        // ctrl+shift+scroll_click to freeze query position to current mouse_pos
        if (events.find(.MouseUp, .{ .button = .middle, .mods = ctrl_shift })) |ev_idx| blk: {
            const mods = window.getModifiers();
            if (!(mods.shift and mods.control)) break :blk;
            self.node_query_pos = if (self.node_query_pos) |_| null else mouse_pos;
            _ = events.removeAt(ev_idx);
        }
        // ctrl+shift+left/right to anchor left/right
        if (events.searchAndRemove(.KeyDown, .{ .key = .left, .mods = ctrl_shift }))
            self.anchor_right = false;
        if (events.searchAndRemove(.KeyDown, .{ .key = .right, .mods = ctrl_shift }))
            self.anchor_right = true;
        // TODO: change the top_left position for the dbg_ui_view?

        // grab a list of all the nodes that overlap with the query position
        const query_pos = if (self.node_query_pos) |pos| pos else mouse_pos;
        var selected_nodes = std.ArrayList(*UI.Node).init(self.allocator);
        defer selected_nodes.deinit();
        var node_iter = ui.node_table.valueIterator();
        while (node_iter.next()) |node| {
            if (node.rect.contains(query_pos)) try selected_nodes.append(node);
        }
        if (selected_nodes.items.len == 0) return;

        self.node_list_idx = clamp(self.node_list_idx, 0, selected_nodes.items.len - 1);
        self.node_list_len = selected_nodes.items.len;
        const active_node = selected_nodes.items[self.node_list_idx];

        try self.ui.startBuild(width, height, mouse_pos, events, window);

        // red border around the selected nodes
        const border_node_flags = Flags{
            .no_id = true,
            .draw_border = true,
            .floating_x = true,
            .floating_y = true,
        };
        self.ui.pushStyle(.{ .border_thickness = 2 });
        for (selected_nodes.items) |node| {
            _ = self.ui.addNode(border_node_flags, "", .{
                .border_color = vec4{ 1, 0, 0, 0.5 },
                .rel_pos = RelativePlacement.simple(node.rect.min),
                .size = Size.fromRect(node.rect),
            });
        }
        // green border for the node selected from the list (separated so it always draws on top)
        _ = self.ui.addNode(border_node_flags, "", .{
            .border_color = vec4{ 0, 1, 0, 0.5 },
            .rel_pos = RelativePlacement.simple(active_node.rect.min),
            .size = Size.fromRect(active_node.rect),
        });
        // blue border to show the padding
        // if (@reduce(.And, active_node.padding != vec2{ 0, 0 })) {
        //     _ = self.ui.addNode(border_node_flags, "", .{
        //         .border_color = vec4{ 0, 0, 1, 0.5 },
        //         .rel_pos = RelativePlacement.simple(active_node.rect.min + active_node.padding),
        //         .size = size: {
        //             const size = active_node.rect.size() - active_node.padding * vec2{ 2, 2 };
        //             break :size Size.exact(.pixels, size[0], size[1]);
        //         },
        //     });
        // }
        _ = self.ui.popStyle();

        self.ui.pushStyle(.{ .font_size = 16, .bg_color = vec4{ 0, 0, 0, 0.75 } });
        defer _ = self.ui.popStyle();
        self.ui.root.?.layout_axis = .x;
        if (self.anchor_right) self.ui.spacer(.x, Size.percent(1, 0));
        {
            const left_bg_node = self.ui.addNode(.{
                .no_id = true,
                .draw_background = true,
                .clip_children = true,
            }, "", .{
                .layout_axis = .y,
                .size = [2]Size{ Size.children(0.5), Size.children(1) },
            });
            self.ui.pushParent(left_bg_node);
            defer self.ui.popParentAssert(left_bg_node);

            if (self.node_query_pos) |pos| self.ui.labelF("node_query_pos: {d}\n", .{pos});

            for (selected_nodes.items, 0..) |node, idx| {
                if (idx == self.node_list_idx) {
                    self.ui.labelBoxF("key=0x{x}", .{node.key});
                } else {
                    self.ui.labelF("key=0x{x}", .{node.key});
                }
            }
        }
        {
            const right_bg_node = self.ui.addNode(.{
                .no_id = true,
                .draw_background = true,
                .clip_children = true,
            }, "", .{
                .layout_axis = .y,
                .size = [2]Size{ Size.children(1), Size.children(1) },
            });
            self.ui.pushParent(right_bg_node);
            defer self.ui.popParentAssert(right_bg_node);

            inline for (@typeInfo(Node).Struct.fields) |field| {
                const name = field.name;
                const value = @field(active_node, name);

                // const skips = [_][]const u8{};

                if (@typeInfo(field.type) == .Enum) {
                    self.ui.labelF("{s}=.{s}\n", .{ name, @tagName(value) });
                    continue;
                }
                switch (field.type) {
                    ?*Node => if (value) |link| {
                        self.ui.labelF("{s}.key=0x{x}", .{ name, link.key });
                    },
                    NodeKey => self.ui.labelF("{s}.key=0x{x}", .{ name, value }),
                    Flags => {
                        var buf = std.BoundedArray(u8, 1024){};
                        inline for (@typeInfo(Flags).Struct.fields) |flag_field| {
                            if (@field(value, flag_field.name)) {
                                _ = try buf.writer().write(flag_field.name ++ ", ");
                            }
                        }
                        self.ui.labelF("flags={s}", .{buf.slice()});
                    },
                    Signal => {
                        var buf = std.BoundedArray(u8, 1024){};
                        try buf.writer().print(".mouse_pos={d}, .scroll_amount={d:.1}", .{
                            value.mouse_pos, value.scroll_amount,
                        });
                        inline for (@typeInfo(Signal).Struct.fields) |signal_field| {
                            if (signal_field.type == bool and @field(value, signal_field.name)) {
                                _ = try buf.writer().write(", " ++ signal_field.name);
                            }
                        }
                        self.ui.labelF("{s}={{{s}}}", .{ name, buf.slice() });
                    },
                    []const u8 => {
                        self.ui.labelF("{s}=\"{s}\"", .{ name, value[0..@min(value.len, 35)] });
                    },
                    f32, [2]f32, [3]f32, [4]f32, vec2, vec3, vec4 => self.ui.labelF("{s}={d}", .{ name, value }),
                    else => self.ui.labelF("{s}={any}", .{ name, value }),
                }
            }
        }
        if (self.show_help) {
            const help_bg_node = self.ui.addNode(.{
                .draw_background = true,
                .clip_children = true,
            }, "#help_bg_node", .{
                .layout_axis = .y,
                .size = [2]Size{ Size.children(1), Size.children(1) },
            });
            self.ui.pushParent(help_bg_node);
            defer self.ui.popParentAssert(help_bg_node);

            self.ui.label("Ctrl+Shift+H            -> toggle this help menu");
            self.ui.label("Ctrl+Shift+D            -> toggle dbg UI");
            self.ui.label("Ctrl+Shift+Up/Down      -> choose highlighed node");
            self.ui.label("Ctrl+Shift+ScrollClick  -> freeze mouse position");
            self.ui.label("Ctrl+Shift+Left/Right   -> anchor left/right");
        }

        self.ui.endBuild(dt);
        try self.ui.render();
    }
};
