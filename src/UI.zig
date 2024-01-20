const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl_4v3.zig");
const gfx = @import("graphics.zig");
const vec2 = @Vector(2, f32);
const vec3 = @Vector(3, f32);
const vec4 = @Vector(4, f32);
const Font = @import("Font.zig");
const Window = @import("Window.zig");

const glfw = @import("mach-glfw");

const build_opts = @import("build_opts");

const UI = @This();
pub usingnamespace @import("widgets.zig");

const Cursor = Window.Cursor;

allocator: Allocator,
generic_shader: gfx.Shader,
font: Font,
font_bold: Font,
icon_font: Font,
build_arena: std.heap.ArenaAllocator,
node_table: NodeTable,
prng: PRNG,

// if we accidentally create two nodes with the same hash in the frame this
// might lead to the node tree having cycles (which hangs whenever we traverse it)
// this is cleared every frame
node_keys_this_frame: std.ArrayList(NodeKey),

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
root_node: ?*Node,
ctx_menu_root_node: ?*Node,
tooltip_root_node: ?*Node,
window_roots: std.ArrayList(*Node),
screen_size: vec2,
mouse_pos: vec2, // in pixels
events: *Window.EventQueue,

// cross-frame data
frame_idx: usize,
hot_node_key: ?NodeKey,
active_node_key: ?NodeKey,
focused_node_key: ?NodeKey,

const NodeKey = NodeTable.Hash;

pub const FontOptions = struct {
    font_path: []const u8 = build_opts.resource_dir ++ "/VictorMono-Regular.ttf",
    bold_font_path: []const u8 = build_opts.resource_dir ++ "/VictorMono-Bold.ttf",
    icon_font_path: []const u8 = build_opts.resource_dir ++ "/icons.ttf",
};
// icon font (and this mapping) was generated using fontello.com
pub const Icons = struct {
    // zig fmt: off
    pub const cancel        = utf8LitFromCodepoint(59392);
    pub const th_list       = utf8LitFromCodepoint(59393);
    pub const search        = utf8LitFromCodepoint(59394);
    pub const plus_circled  = utf8LitFromCodepoint(59395);
    pub const cog           = utf8LitFromCodepoint(59396);
    pub const ok            = utf8LitFromCodepoint(59397);
    pub const circle        = utf8LitFromCodepoint(61713);
    pub const up_open       = utf8LitFromCodepoint(59398);
    pub const right_open    = utf8LitFromCodepoint(59399);
    pub const left_open     = utf8LitFromCodepoint(59400);
    pub const down_open     = utf8LitFromCodepoint(59401);
    pub const plus_squared  = utf8LitFromCodepoint(61694);
    pub const minus_squared = utf8LitFromCodepoint(61766);
    pub const plus          = utf8LitFromCodepoint(59402);
    // zig fmt: on

    fn utf8Len(comptime codepoint: u21) u3 {
        return std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
    }
    fn utf8LitFromCodepoint(comptime codepoint: u21) *const [utf8Len(codepoint):0]u8 {
        comptime {
            var buf: [utf8Len(codepoint):0]u8 = undefined;
            _ = std.unicode.utf8Encode(codepoint, &buf) catch unreachable;
            buf[buf.len] = 0;
            return &buf;
        }
    }
};

// call `deinit` to cleanup resources
pub fn init(allocator: Allocator, font_opts: FontOptions) !UI {
    return UI{
        .allocator = allocator,
        .generic_shader = gfx.Shader.from_srcs(allocator, "ui_generic", .{
            .vertex = @embedFile("ui/shader.vert"),
            .geometry = @embedFile("ui/shader.geom"),
            .fragment = @embedFile("ui/shader.frag"),
        }),
        .font = try Font.from_ttf(allocator, font_opts.font_path),
        .font_bold = try Font.from_ttf(allocator, font_opts.bold_font_path),
        .icon_font = try Font.from_ttf(allocator, font_opts.icon_font_path),
        .build_arena = std.heap.ArenaAllocator.init(allocator),
        .node_table = NodeTable.init(allocator),
        .prng = PRNG.init(0),

        .node_keys_this_frame = std.ArrayList(NodeKey).init(allocator),

        .first_error_trace = null,
        .first_error_name = "",
        .first_error_stack_trace = undefined,

        .base_style = Style{},

        .parent_stack = Stack(*Node).init(allocator),
        .style_stack = Stack(Style).init(allocator),
        .auto_pop_style = false,
        .root_node = null,
        .tooltip_root_node = null,
        .ctx_menu_root_node = null,
        .window_roots = std.ArrayList(*Node).init(allocator),
        .screen_size = undefined,
        .mouse_pos = undefined,
        .events = undefined,

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
    self.icon_font.deinit();
    self.generic_shader.deinit();
    self.window_roots.deinit();
    self.node_keys_this_frame.deinit();
}

pub const Flags = packed struct {
    clickable: bool = false,
    selectable: bool = false, // maintains focus when clicked
    scroll_children_x: bool = false,
    scroll_children_y: bool = false,

    clip_children: bool = false,
    draw_text: bool = false,
    draw_border: bool = false,
    draw_background: bool = false,
    draw_hot_effects: bool = false,
    draw_active_effects: bool = false,

    // node is not taken into account in the normal layout
    floating_x: bool = false,
    floating_y: bool = false,

    no_id: bool = false,
    ignore_hash_sep: bool = false,

    pub fn interactive(self: Flags) bool {
        return self.clickable or
            self.selectable or
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
    hash_string: []const u8,
    bg_color: vec4,
    border_color: vec4,
    text_color: vec4,
    corner_radii: [4]f32, // order is left-to-right, top-to-bottom
    edge_softness: f32,
    border_thickness: f32,
    pref_size: [2]Size,
    child_layout_axis: Axis,
    cursor_type: Cursor,
    font_type: FontType,
    font_size: f32,
    text_align: TextAlign,
    custom_draw_fn: ?CustomDrawFn,
    custom_draw_ctx_as_bytes: ?[]const u8, // gets copied during `addNode`
    scroll_multiplier: vec2,
    padding: vec2, // only applies to node with no display_string; padding for those is calculated in `textPadding`

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

    // persists across frames (but gets updated every frame)
    signal: Signal,

    // persistent cross-frame state
    hot_trans: f32,
    active_trans: f32,
    first_frame_touched: usize,
    last_frame_touched: usize,

    // cross-frame state for specific features
    rel_pos: RelativePlacement, // relative to parent
    cursor: usize, // used for text input
    mark: usize, // used for text input
    last_click_time: f32, // used for double click checks
    last_double_click_time: f32, // used for triple click checks
    scroll_offset: vec2,
};

pub const CustomDrawFn = *const fn (
    ui: *UI,
    shader_inputs: *std.ArrayList(ShaderInput),
    node: *Node,
) error{OutOfMemory}!void;

pub const Axis = enum { x, y };
pub const FontType = enum { text, text_bold, icon };
pub const TextAlign = enum { left, center, right };

pub const Style = struct {
    bg_color: vec4 = vec4{ 0, 0, 0, 1 },
    border_color: vec4 = vec4{ 0.5, 0.5, 0.5, 0.75 },
    text_color: vec4 = vec4{ 1, 1, 1, 1 },
    corner_radii: [4]f32 = [4]f32{ 0, 0, 0, 0 },
    edge_softness: f32 = 0,
    border_thickness: f32 = 0,
    pref_size: [2]Size = .{ Size.text_dim(1), Size.text_dim(1) },
    child_layout_axis: Axis = .y,
    cursor_type: Cursor = .arrow,
    font_type: FontType = .text,
    font_size: f32 = 18,
    text_align: TextAlign = .left,
    custom_draw_fn: ?CustomDrawFn = null,
    custom_draw_ctx_as_bytes: ?[]const u8 = null,
    scroll_multiplier: vec2 = @splat(18 * 2),
    padding: vec2 = vec2{ 0, 0 },
};

pub const Size = union(enum) {
    pixels: struct { value: f32, strictness: f32 },
    text_dim: struct { strictness: f32 },
    percent: struct { value: f32, strictness: f32 },
    by_children: struct { strictness: f32 },

    pub fn pixels(value: f32, strictness: f32) Size {
        return Size{ .pixels = .{ .value = value, .strictness = strictness } };
    }
    pub fn text_dim(strictness: f32) Size {
        return Size{ .text_dim = .{ .strictness = strictness } };
    }
    pub fn percent(value: f32, strictness: f32) Size {
        return Size{ .percent = .{ .value = value, .strictness = strictness } };
    }
    pub fn by_children(strictness: f32) Size {
        return Size{ .by_children = .{ .strictness = strictness } };
    }

    pub fn getStrictness(self: Size) f32 {
        return switch (self) {
            inline else => |v| v.strictness,
        };
    }

    const Tag = std.meta.Tag(Size);

    pub fn exact(tag: Tag, x: f32, y: f32) [2]Size {
        return switch (tag) {
            .pixels => [2]Size{ Size.pixels(x, 1), Size.pixels(y, 1) },
            .percent => [2]Size{ Size.percent(x, 1), Size.percent(y, 1) },
            else => @panic(""),
        };
    }

    pub fn flexible(tag: Tag, x: f32, y: f32) [2]Size {
        return switch (tag) {
            .pixels => [2]Size{ Size.pixels(x, 0), Size.pixels(y, 0) },
            .percent => [2]Size{ Size.percent(x, 0), Size.percent(y, 0) },
            else => @panic(""),
        };
    }

    pub fn fillByChildren(x_strictness: f32, y_strictness: f32) [2]Size {
        return [2]Size{ Size.by_children(x_strictness), Size.by_children(y_strictness) };
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
            .text_dim => |v| try writer.print("text_dim({d})", .{v.strictness}),
            .percent => |v| try writer.print("percent({d}, {d})", .{ v.value, v.strictness }),
            .by_children => |v| try writer.print("by_children({d})", .{v.strictness}),
        }
    }
};

pub const Rect = struct {
    min: vec2,
    max: vec2,

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
    clicked: bool,
    pressed: bool,
    released: bool,
    double_clicked: bool,
    triple_clicked: bool,
    hovering: bool,
    held_down: bool,
    enter_pressed: bool,
    mouse_pos: vec2, // these are relative to bottom-left corner of node
    // mouse_drag: ?Rect, // relative coordinates, just like `Signal.mouse_pos`
    scroll_amount: vec2, // positive means scrolling up/left
    focused: bool,
};

pub fn addNode(self: *UI, flags: Flags, string: []const u8, init_args: anytype) *Node {
    const node = self.addNodeRaw(flags, string, init_args) catch |e| blk: {
        self.setErrorInfo(@errorReturnTrace(), @errorName(e));
        break :blk self.root_node.?;
    };
    return node;
}

pub fn addNodeF(self: *UI, flags: Flags, comptime fmt: []const u8, args: anytype, init_args: anytype) *Node {
    const str = self.fmtTmpString(fmt, args);
    return self.addNode(flags, str, init_args);
}

pub fn addNodeStrings(self: *UI, flags: Flags, display_string: []const u8, hash_string: []const u8, init_args: anytype) *Node {
    const node = self.addNodeRawStrings(flags, display_string, hash_string, init_args) catch |e| blk: {
        self.setErrorInfo(@errorReturnTrace(), @errorName(e));
        break :blk self.root_node.?;
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
    const arena = self.build_arena.allocator();

    const display_string = if (flags.ignore_hash_sep) string else displayPartOfString(string);
    const hash_string = if (flags.no_id) blk: {
        // for `no_id` nodes we use a random number as the hash string, so they don't clobber each other
        break :blk &randomString(&self.prng);
    } else blk: {
        // to allow for nodes with different parents to have the same name we
        // combine the node's hash string with the hash string of the first parent
        // to have a stable one (i.e. *not* `no-id`).
        const parent_hash_str = parent_str: {
            var parent = self.parent_stack.top() orelse break :parent_str "";
            while (parent.flags.no_id) parent = parent.parent orelse
                @panic("at some point the root should have a stable name");
            break :parent_str parent.hash_string;
        };
        const hash_part = if (flags.ignore_hash_sep) string else hashPartOfString(string);
        break :blk try std.fmt.allocPrint(arena, "{s}::{s}", .{ parent_hash_str, hash_part });
    };

    return self.addNodeRawStrings(flags, display_string, hash_string, init_args);
}

pub fn addNodeRawStrings(self: *UI, flags: Flags, display_string_in: []const u8, hash_string_in: []const u8, init_args: anytype) !*Node {
    const arena = self.build_arena.allocator();
    const display_string = try arena.dupe(u8, display_string_in);
    const hash_string = try arena.dupe(u8, hash_string_in);

    const node_key = self.node_table.ctx.hash(hash_string);
    if (std.mem.indexOfScalar(NodeKey, self.node_keys_this_frame.items, node_key)) |_| {
        std.debug.panic("hash_string='{s}' has collision\n", .{hash_string});
    } else try self.node_keys_this_frame.append(node_key);

    // if a node already exists that matches this one we just use that one
    // this way the persistant cross-frame data is possible
    const lookup_result = try self.node_table.getOrPut(hash_string);
    var node = lookup_result.value_ptr;

    // link node into the tree
    var parent = self.parent_stack.top();
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
    node.display_string = display_string;
    node.hash_string = hash_string;
    const style = self.style_stack.top().?;
    inline for (@typeInfo(Style).Struct.fields) |field_type_info| {
        const field_name = field_type_info.name;
        @field(node, field_name) = @field(style, field_name);
    }
    // padding for nodes with text is done with `textPadding`
    // TODO: this should probably be an error
    if (node.display_string.len != 0) node.padding = vec2{ 0, 0 };

    node.first_time = !lookup_result.found_existing;

    // reset layout data (but not the final screen rect which we need for signal stuff)
    node.calc_size = vec2{ 0, 0 };
    node.calc_rel_pos = vec2{ 0, 0 };

    // update cross-frame (persistant) data
    node.last_frame_touched = self.frame_idx;
    if (!lookup_result.found_existing) {
        node.signal = try self.computeNodeSignal(node);
        node.first_frame_touched = self.frame_idx;
        node.rel_pos = RelativePlacement.match(.btm_left);
        node.last_click_time = 0;
        node.last_double_click_time = 0;
        node.scroll_offset = vec2{ 0, 0 };
    }

    // user overrides of node data
    inline for (@typeInfo(@TypeOf(init_args)).Struct.fields) |field_type_info| {
        const field_name = field_type_info.name;
        @field(node, field_name) = @field(init_args, field_name);
    }

    // for large inputs calculating the text size is too expensive to do multiple times per frame
    node.text_rect = try self.calcTextRect(node, display_string);

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
    if (self.tooltip_root_node) |node| try self.computeSignalsForTree(node);
    if (self.ctx_menu_root_node) |node| try self.computeSignalsForTree(node);
    for (self.window_roots.items) |node| try self.computeSignalsForTree(node);
    if (self.root_node) |node| try self.computeSignalsForTree(node);

    // clear out the whole arena
    self.build_arena.deinit();
    self.build_arena = std.heap.ArenaAllocator.init(self.allocator);

    self.node_keys_this_frame.clearRetainingCapacity();

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

    self.root_node = try self.addNodeRaw(.{ .clip_children = true }, "###INTERNAL_ROOT_NODE", .{
        .pref_size = Size.exact(.pixels, screen_size[0], screen_size[1]),
        .rect = Rect{ .min = vec2{ 0, 0 }, .max = screen_size },
    });
    try self.parent_stack.push(self.root_node.?);

    self.window_roots.clearRetainingCapacity();
    self.ctx_menu_root_node = null;
    self.tooltip_root_node = null;

    self.first_error_trace = null;

    var mouse_cursor: Cursor = .arrow;
    for ([_]?NodeKey{
        self.focused_node_key,
        self.hot_node_key,
        self.active_node_key,
    }) |node_key| {
        if (node_key) |key| mouse_cursor = self.node_table.getFromHash(key).?.cursor_type;
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
    if (parent != self.root_node.?)
        std.debug.panic("parent_stack should be empty but '#{s}' was left behind\n", .{parent.hash_string});

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
    self.layoutTree(self.root_node.?);
    for (self.window_roots.items) |node| self.layoutTree(node);
    if (self.ctx_menu_root_node) |node| self.layoutTree(node);
    if (self.tooltip_root_node) |node| self.layoutTree(node);

    self.frame_idx += 1;
}

fn layoutTree(self: *UI, root: *Node) void {
    self.solveIndependentSizes(root);
    self.solveDownwardDependent(root);
    self.solveUpwardDependent(root);
    self.solveViolations(root);
    self.solveFinalPos(root);
}

fn computeSignalsForTree(self: *UI, root: *Node) !void {
    var node_iterator = ReverseRenderOrderNodeIterator.init(root);
    while (node_iterator.next()) |node| {
        node.signal = try self.computeNodeSignal(node);
    }
}

pub fn computeNodeSignal(self: *UI, node: *Node) !Signal {
    var signal = Signal{
        .clicked = false,
        .pressed = false,
        .released = false,
        .double_clicked = false,
        .triple_clicked = false,
        .hovering = false,
        .held_down = false,
        .enter_pressed = false,
        .mouse_pos = self.mouse_pos - node.rect.min,
        // .mouse_drag = null,
        .scroll_amount = vec2{ 0, 0 },
        .focused = false,
    };

    if (!node.flags.interactive()) return signal;

    const mouse_is_over = node.rect.contains(self.mouse_pos);
    const node_key = self.keyFromNode(node);

    const hot_key_matches = if (self.hot_node_key) |key| key == node_key else false;
    const active_key_matches = if (self.active_node_key) |key| key == node_key else false;
    const focused_key_matches = if (self.focused_node_key) |key| key == node_key else false;

    var is_hot = mouse_is_over;
    var is_active = active_key_matches;
    var is_focused = focused_key_matches;

    const mouse_down_ev = self.events.match(.MouseDown, .{ .button = .left });
    var used_mouse_down_ev = false;
    const mouse_up_ev = self.events.match(.MouseUp, .{ .button = .left });
    var used_mouse_up_ev = false;
    const enter_down_ev = self.events.match(.KeyDown, .{ .key = .enter });
    var used_enter_down_ev = false;
    const enter_up_ev = self.events.match(.KeyUp, .{ .key = .enter });
    var used_enter_up_ev = false;

    signal.hovering = is_hot;

    if (node.flags.clickable) {
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

            // support x-scrolling by holding shift
            if (scroll[0] == 0 and ev.mods.shift) std.mem.swap(f32, &scroll[0], &scroll[1]);

            if (!node.flags.scroll_children_x) scroll[0] = 0;
            if (!node.flags.scroll_children_y) scroll[1] = 0;

            signal.scroll_amount = scroll;
            node.scroll_offset += vec2{ 1, -1 } * scroll;
        }
    }

    signal.focused = is_focused;

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

    return signal;
}

pub fn render(self: *UI) !void {
    var shader_inputs = std.ArrayList(ShaderInput).init(self.allocator);
    defer shader_inputs.deinit();

    try self.setupTreeForRender(&shader_inputs, self.root_node.?);
    for (self.window_roots.items) |node| try self.setupTreeForRender(&shader_inputs, node);
    if (self.ctx_menu_root_node) |node| try self.setupTreeForRender(&shader_inputs, node);
    if (self.tooltip_root_node) |node| try self.setupTreeForRender(&shader_inputs, node);

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

    self.generic_shader.bind();
    self.generic_shader.set("screen_size", self.screen_size);
    self.generic_shader.set("text_atlas", @as(i32, 0));
    self.font.texture.bind(0);
    self.generic_shader.set("text_bold_atlas", @as(i32, 1));
    self.font_bold.texture.bind(1);
    self.generic_shader.set("icon_atlas", @as(i32, 2));
    self.icon_font.texture.bind(2);
    gl.bindVertexArray(inputs_vao);
    gl.drawArrays(gl.POINTS, 0, @intCast(shader_inputs.items.len));
}

fn setupTreeForRender(self: *UI, shader_inputs: *std.ArrayList(ShaderInput), root: *Node) !void {
    var node_iterator = DepthFirstNodeIterator{ .cur_node = root };
    while (node_iterator.next()) |node| {
        try self.addShaderInputsForNode(shader_inputs, node);
    }
}

// turn a UI.Node into Shader quads
fn addShaderInputsForNode(self: *UI, shader_inputs: *std.ArrayList(ShaderInput), node: *Node) !void {
    if (node.custom_draw_fn) |draw_fn| return draw_fn(self, shader_inputs, node);

    const base_rect = ShaderInput.fromNode(node);

    // draw background
    if (node.flags.draw_background) {
        var rect = base_rect;
        rect.top_left_color = node.bg_color;
        rect.btm_left_color = node.bg_color;
        rect.top_right_color = node.bg_color;
        rect.btm_right_color = node.bg_color;
        rect.border_thickness = 0;
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
    if (node.flags.draw_text) {
        const font = switch (node.font_type) {
            .text => &self.font,
            .text_bold => &self.font_bold,
            .icon => &self.icon_font,
        };

        var text_base = self.textPosFromNode(node);
        if (node.flags.draw_active_effects)
            text_base[1] -= (self.textPadding(node)[1] / 2) * node.active_trans;

        const display_text = if (estimateLineCount(node, font.*) < 100)
            node.display_string
        else blk: {
            const res = self.largeInputOptimizationVisiblePartOfText(node);
            text_base[1] -= res.offset;
            break :blk res.string;
        };

        const quads = try font.buildQuads(self.allocator, display_text, node.font_size);
        defer self.allocator.free(quads);
        for (quads) |quad| {
            const quad_rect = Rect{ .min = quad.points[0].pos, .max = quad.points[2].pos };
            var rect = base_rect;
            rect.btm_left_pos = text_base + quad_rect.min;
            rect.top_right_pos = text_base + quad_rect.max;
            rect.btm_left_uv = quad.points[0].uv;
            rect.top_right_uv = quad.points[2].uv;
            rect.top_left_color = node.text_color;
            rect.btm_left_color = node.text_color;
            rect.top_right_color = node.text_color;
            rect.btm_right_color = node.text_color;
            rect.corner_radii = [4]f32{ 0, 0, 0, 0 };
            rect.edge_softness = 0;
            rect.border_thickness = 0;
            try shader_inputs.append(rect);
        }
    }
}

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
    border_thickness: f32,
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
            .border_thickness = node.border_thickness,
            .clip_rect_min = node.clip_rect.min,
            .clip_rect_max = node.clip_rect.max,
            .which_font = @intFromEnum(node.font_type),
        };
        return rect;
    }
};

fn solveIndependentSizes(self: *UI, node: *Node) void {
    const work_fn = solveIndependentSizesWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveDownwardDependent(self: *UI, node: *Node) void {
    const work_fn = solveDownwardDependentWorkFn;
    layoutRecurseHelperPost(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPost(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveUpwardDependent(self: *UI, node: *Node) void {
    const work_fn = solveUpwardDependentWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveViolations(self: *UI, node: *Node) void {
    const work_fn = solveViolationsWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveFinalPos(self: *UI, node: *Node) void {
    const work_fn = solveFinalPosWorkFn;
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .x });
    layoutRecurseHelperPre(work_fn, .{ .self = self, .node = node, .axis = .y });
}

fn solveIndependentSizesWorkFn(self: *UI, node: *Node, axis: Axis) void {
    const axis_idx: usize = @intFromEnum(axis);
    switch (node.pref_size[axis_idx]) {
        .pixels => |pixels| node.calc_size[axis_idx] = pixels.value,
        // this is wrong for percent (the correct one is calculated later) but this gives
        // and upper bound on the size, which might be needed for "downward dependent" nodes
        // which have children with `Size.percent`
        .percent,
        .text_dim,
        => {
            const text_size = node.text_rect.size();
            const text_padding = self.textPadding(node)[axis_idx];
            node.calc_size[axis_idx] = text_size[axis_idx] + 2 * text_padding;
        },
        else => {},
    }
}

fn solveDownwardDependentWorkFn(self: *UI, node: *Node, axis: Axis) void {
    _ = self;

    const axis_idx: usize = @intFromEnum(axis);
    const is_layout_axis = (axis == node.child_layout_axis);

    const child_funcs = struct {
        pub fn sumChildrenSizes(parent: *Node, idx: usize) f32 {
            var sum: f32 = 0;
            var child = parent.first;
            while (child) |child_node| : (child = child_node.next) {
                sum += child_node.calc_size[idx];
            }
            return sum;
        }
        pub fn maxChildrenSizes(parent: *Node, idx: usize) f32 {
            var max_so_far: f32 = 0;
            var child = parent.first;
            while (child) |child_node| : (child = child_node.next) {
                const child_size = switch (child_node.pref_size[idx]) {
                    .percent => blk: {
                        if (@intFromEnum(child_node.child_layout_axis) == idx) {
                            break :blk sumChildrenSizes(child_node, idx);
                        } else {
                            break :blk sumChildrenSizes(child_node, idx);
                        }
                    },
                    else => child_node.calc_size[idx],
                };
                max_so_far = @max(max_so_far, child_size);
            }
            return max_so_far;
        }
    };

    switch (node.pref_size[axis_idx]) {
        .by_children => {
            if (is_layout_axis) {
                node.calc_size[axis_idx] = child_funcs.sumChildrenSizes(node, axis_idx);
            } else {
                node.calc_size[axis_idx] = child_funcs.maxChildrenSizes(node, axis_idx);
            }
            node.calc_size[axis_idx] += 2 * node.padding[axis_idx];
        },
        else => {},
    }
}

fn solveUpwardDependentWorkFn(self: *UI, node: *Node, axis: Axis) void {
    const axis_idx: usize = @intFromEnum(axis);
    switch (node.pref_size[axis_idx]) {
        .percent => |percent| {
            const parent_size = if (node.parent) |p|
                p.calc_size - math.times(p.padding, 2)
            else
                self.screen_size;
            node.calc_size[axis_idx] = parent_size[axis_idx] * percent.value;
        },
        else => {},
    }
}

fn solveViolationsWorkFn(self: *UI, node: *Node, axis: Axis) void {
    _ = self;
    if (node.child_count == 0) return;

    const axis_idx: usize = @intFromEnum(axis);
    const is_layout_axis = (axis == node.child_layout_axis);

    const available_size = node.calc_size - math.times(node.padding, 2);

    // collect sizing information about children
    var total_children_size: f32 = 0;
    var max_child_size: f32 = 0;
    var zero_strict_take_budget: f32 = 0;
    var other_children_leeway: f32 = 0;
    var zero_strict_children = std.BoundedArray(*Node, 1000).init(0) catch unreachable;
    var other_children = std.BoundedArray(*Node, 1000).init(0) catch unreachable;
    var child = node.first;
    while (child) |child_node| : (child = child_node.next) {
        if (switch (axis) {
            .x => child_node.flags.floating_x,
            .y => child_node.flags.floating_y,
        }) continue;

        const strictness = child_node.pref_size[axis_idx].getStrictness();
        const child_size = child_node.calc_size[axis_idx];

        total_children_size += child_size;
        max_child_size = @max(max_child_size, child_size);
        if (strictness == 0) {
            zero_strict_take_budget += child_size;
            zero_strict_children.append(child_node) catch unreachable;
        } else {
            other_children_leeway += (1 - strictness);
            other_children.append(child_node) catch unreachable;
        }
    }

    const total_size = if (is_layout_axis) total_children_size else max_child_size;
    var overflow = @max(0, total_size - available_size[axis_idx]);

    // shrink zero strictness children as much as we can (to 0 size if needed) before
    // trying to shrink other children with strictness > 0
    const zero_strict_remove_amount = @min(overflow, zero_strict_take_budget);
    for (zero_strict_children.slice()) |z_child| {
        if (is_layout_axis) {
            const z_child_percent = z_child.calc_size[axis_idx] / zero_strict_take_budget;
            z_child.calc_size[axis_idx] -= zero_strict_remove_amount * z_child_percent;
        } else {
            const extra_size = z_child.calc_size[axis_idx] - available_size[axis_idx];
            z_child.calc_size[axis_idx] -= @max(0, extra_size);
        }
    }
    overflow -= zero_strict_remove_amount;

    // if there's still overflow, shrink the other children as much as we can
    // (proportionally to their strictness values, i.e least strict shrinks the most)
    if (overflow > 0) {
        var removed_amount: f32 = 0;
        for (other_children.slice()) |child_node| {
            const strictness = child_node.pref_size[axis_idx].getStrictness();
            if (strictness == 1) continue;
            const child_size = child_node.calc_size[axis_idx];
            const child_take_budget = child_size * strictness;
            const leeway_percent = (1 - strictness) / other_children_leeway;
            const desired_remove_amount = if (is_layout_axis)
                overflow * leeway_percent
            else
                @max(0, child_size - available_size[axis_idx]);
            const true_remove_amount = @min(child_take_budget, desired_remove_amount);
            child_node.calc_size[axis_idx] -= true_remove_amount;
            removed_amount += true_remove_amount;
        }
        overflow -= removed_amount;
        std.debug.assert(overflow >= 0); // if overflow is negative we removed too much somewhere
    }

    // constrain scrolling to children size, i.e. don't scroll more than is possible
    node.scroll_offset[axis_idx] = switch (axis) {
        .x => std.math.clamp(node.scroll_offset[axis_idx], -overflow, 0),
        .y => std.math.clamp(node.scroll_offset[axis_idx], 0, overflow),
    };
}

fn solveFinalPosWorkFn(self: *UI, node: *Node, axis: Axis) void {
    const axis_idx: usize = @intFromEnum(axis);
    const is_layout_axis = (axis == node.child_layout_axis);
    const is_scrollable_axis = switch (axis) {
        .x => node.flags.scroll_children_x,
        .y => node.flags.scroll_children_y,
    };

    // window root nodes need a position too!
    if (node.parent == null) {
        const calc_rel_pos = node.rel_pos.calcRelativePos(node.calc_size, self.screen_size);
        node.calc_rel_pos[axis_idx] = calc_rel_pos[axis_idx];
        node.rect.min[axis_idx] = node.calc_rel_pos[axis_idx];
        node.rect.max[axis_idx] = node.calc_rel_pos[axis_idx] + node.calc_size[axis_idx];
        node.clip_rect = node.rect;
    }

    if (node.child_count == 0) return;

    // start layout at the top left
    var start_rel_pos: f32 = switch (axis) {
        .x => node.padding[0],
        .y => node.calc_size[1] - node.padding[1],
    };
    // when `scroll_children` is enabled start layout at an offset
    if (is_scrollable_axis) start_rel_pos += node.scroll_offset[axis_idx];

    // position all the children
    var rel_pos: f32 = start_rel_pos;
    var child = node.first;
    while (child) |child_node| : (child = child_node.next) {
        const is_floating = switch (axis) {
            .x => child_node.flags.floating_x,
            .y => child_node.flags.floating_y,
        };
        if (is_floating) {
            const calc_rel_pos = child_node.rel_pos.calcRelativePos(child_node.calc_size, node.calc_size);
            child_node.calc_rel_pos[axis_idx] = calc_rel_pos[axis_idx];
            continue;
        }

        if (is_layout_axis) {
            const rel_pos_advance = child_node.calc_size[axis_idx];
            switch (axis) {
                .x => {
                    child_node.calc_rel_pos[axis_idx] = rel_pos;
                    rel_pos += rel_pos_advance;
                },
                .y => {
                    rel_pos -= rel_pos_advance;
                    child_node.calc_rel_pos[axis_idx] = rel_pos;
                },
            }
        } else {
            switch (axis) {
                .x => child_node.calc_rel_pos[axis_idx] = start_rel_pos,
                .y => child_node.calc_rel_pos[axis_idx] = start_rel_pos - child_node.calc_size[axis_idx],
            }
        }
    }

    // calculate the final screen pixel rect
    child = node.first;
    while (child) |child_node| : (child = child_node.next) {
        child_node.rect.min[axis_idx] = node.rect.min[axis_idx] + child_node.calc_rel_pos[axis_idx];
        child_node.rect.max[axis_idx] = child_node.rect.min[axis_idx] + child_node.calc_size[axis_idx];
        // propagate the clipping to children
        child_node.clip_rect = if (node.flags.clip_children) node.rect else node.clip_rect;
    }
}

const LayoutWorkFn = fn (*UI, *Node, Axis) void;
const LayoutWorkFnArgs = struct { self: *UI, node: *Node, axis: Axis };
/// do the work before recursing
fn layoutRecurseHelperPre(comptime work_fn: LayoutWorkFn, args: LayoutWorkFnArgs) void {
    work_fn(args.self, args.node, args.axis);
    var child = args.node.first;
    while (child) |child_node| : (child = child_node.next) {
        layoutRecurseHelperPre(work_fn, .{ .self = args.self, .node = child_node, .axis = args.axis });
    }
}
/// do the work after recursing
fn layoutRecurseHelperPost(comptime work_fn: LayoutWorkFn, args: LayoutWorkFnArgs) void {
    var child = args.node.first;
    while (child) |child_node| : (child = child_node.next) {
        layoutRecurseHelperPost(work_fn, .{ .self = args.self, .node = child_node, .axis = args.axis });
    }
    work_fn(args.self, args.node, args.axis);
}

pub fn textPadding(_: *UI, node: *Node) vec2 {
    // TODO: I'm not sure the `@round` should be here. I think this is same problem
    //       as the text appearing fuzzy on certain specific window resolutions
    return @splat(@round(node.font_size * 0.2));
}

/// calculate the origin of a node's text box in absolute coordinates
pub fn textPosFromNode(self: *UI, node: *Node) vec2 {
    const node_size = node.rect.size();
    const text_rect = node.text_rect;
    const text_size = text_rect.size();
    const text_padd = self.textPadding(node);

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
        .icon => &self.icon_font,
    };

    const text_line_info = findTextLineInfo(string);
    const num_lines = text_line_info.line_count;
    const longest_line = text_line_info.longest_line;
    if (num_lines == 0 or num_lines == 1) {
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

fn findTextLineInfo(str: []const u8) struct {
    line_count: usize,
    longest_line: []const u8,
} {
    if (str.len == 0) return .{ .line_count = 0, .longest_line = str[0..0] };

    const vec_size = comptime std.simd.suggestVectorSize(u8) orelse 128 / 8;
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

fn estimateLineCount(node: *Node, font: Font) f32 {
    const line_size = font.getScaledMetrics(node.font_size).line_advance;
    const text_size = node.text_rect.size();
    return text_size[1] / line_size;
}

fn largeInputOptimizationVisiblePartOfText(self: *UI, node: *Node) struct {
    string: []const u8,
    offset: f32,
} {
    const font: *Font = switch (node.font_type) {
        .text => &self.font,
        .text_bold => &self.font_bold,
        .icon => &self.icon_font,
    };
    const line_size = font.getScaledMetrics(node.font_size).line_advance;
    const text_size = node.text_rect.size();
    const num_lines: usize = @intFromFloat(@ceil(text_size[1] / line_size));
    // const padding = self.textPadding(node);

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

/// find the index of the `nth` occurence of `scalar` in `slice`
fn indexOfNthScalar(slice: []const u8, scalar: u8, nth: usize) ?usize {
    if (nth == 0) return null;

    const vec_size = comptime std.simd.suggestVectorSize(u8) orelse 128 / 8;
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

pub fn keyFromNode(self: UI, node: *Node) NodeKey {
    return self.node_table.ctx.hash(hashPartOfString(node.hash_string));
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

pub const DepthFirstNodeIterator = struct {
    cur_node: *Node,
    first_iteration: bool = true,
    parent_level: usize = 0, // how many times have we gone down the hierarchy

    pub fn next(self: *DepthFirstNodeIterator) ?*Node {
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

//  render order:  |  event consumption order:
//       0         |       6
//    ┌──┴──┐      |    ┌──┴──┐
//    1     4      |    5     2
//   ┌┴┐   ┌┴┐     |   ┌┴┐   ┌┴┐
//   2 3   5 6     |   4 3   1 0
pub const ReverseRenderOrderNodeIterator = struct {
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

        var cur_node = self.cur_node;
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
    ctx: HashContext,

    key_mappings: KeyMap,

    const K = []const u8;
    const V = Node;
    const Hash = u64;

    // note: this makes lookups O(n). if that starts to become a problem
    // we can just switch this ArrayList to a HashMap and NodeTable becomes
    // essentially a wrapper around std.HashMap
    const KeyMap = std.ArrayList(struct { key_hash: Hash, value_ptr: *V });

    const HashContext = struct {
        pub fn hash(self: @This(), key: K) u64 {
            _ = self;
            return std.hash_map.hashString(key);
        }
        pub fn eql(self: @This(), key_a: K, key_b: K) bool {
            _ = self;
            return std.mem.eql(u8, key_a, key_b);
        }
    };

    pub fn init(allocator: Allocator) NodeTable {
        return .{
            .allocator = allocator,
            .ctx = HashContext{},
            .key_mappings = KeyMap.init(allocator),
        };
    }

    pub fn deinit(self: *NodeTable) void {
        for (self.key_mappings.items) |map| self.allocator.destroy(map.value_ptr);
        self.key_mappings.deinit();
    }

    pub const GetOrPutResult = struct { found_existing: bool, value_ptr: *V };

    pub fn getOrPut(self: *NodeTable, key: K) !GetOrPutResult {
        const key_hash = self.ctx.hash(key);
        for (self.key_mappings.items) |key_map| {
            if (key_map.key_hash == key_hash) {
                return GetOrPutResult{ .found_existing = true, .value_ptr = key_map.value_ptr };
            }
        }

        const value_ptr = try self.allocator.create(V);
        try self.key_mappings.append(.{ .key_hash = key_hash, .value_ptr = value_ptr });

        return GetOrPutResult{ .found_existing = false, .value_ptr = value_ptr };
    }

    pub fn getFromHash(self: *NodeTable, hash: Hash) ?*V {
        for (self.key_mappings.items) |key_map| {
            if (key_map.key_hash == hash) {
                return key_map.value_ptr;
            }
        }
        return null;
    }

    /// does nothing if the key doesn't exist
    pub fn remove(self: *NodeTable, key: K) void {
        const key_hash = self.ctx.hash(key);
        for (self.key_mappings.items, 0..) |key_map, i| {
            if (key_map.key_hash == key_hash) {
                self.allocator.destroy(key_map.value_ptr);
                _ = self.key_mappings.swapRemove(i);
                return;
            }
        }
    }

    pub fn hasKey(self: *NodeTable, key: K) bool {
        return self.hasKeyHash(self.ctx.hash(key));
    }

    pub fn hasKeyHash(self: *NodeTable, hash: Hash) bool {
        for (self.key_mappings.items) |key_map| {
            if (key_map.key_hash == hash) return true;
        }
        return false;
    }

    pub fn valueIterator(self: *NodeTable) ValueIterator {
        return ValueIterator{ .table = self, .iter_idx = null };
    }

    pub const ValueIterator = struct {
        table: *NodeTable,
        iter_idx: ?usize, // non-null while iterating

        pub fn next(self: *ValueIterator) ?*V {
            const idx = if (self.iter_idx) |idx| idx else blk: {
                self.iter_idx = 0;
                break :blk 0;
            };
            self.iter_idx.? += 1;

            if (idx >= self.table.key_mappings.items.len) return null;

            return self.table.key_mappings.items[idx].value_ptr;
        }

        pub const RemoveError = error{NotIterating};

        /// remove the thing that was last return by `next` from the table
        /// sets the removed entry to undefined memory
        pub fn removeCurrent(self: *ValueIterator) RemoveError!void {
            const idx = if (self.iter_idx) |idx| idx else return RemoveError.NotIterating;
            if (idx > self.table.key_mappings.items.len) return RemoveError.NotIterating;

            self.table.allocator.destroy(self.table.key_mappings.items[idx - 1].value_ptr);
            _ = self.table.key_mappings.swapRemove(idx - 1);
            self.iter_idx.? -= 1;
        }
    };
};

pub const PRNG = struct {
    state: u64,

    pub fn init(seed: u64) PRNG {
        return .{ .state = seed };
    }

    pub fn next(self: *PRNG) u64 {
        // 3 random primes I generated online
        self.state = ((self.state *% 2676693499) +% 5223158351) ^ 4150081079;
        return self.state;
    }
};

pub fn randomString(prng: *PRNG) [32]u8 {
    var buf: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>16}{x:0>16}", .{ prng.next(), prng.next() }) catch unreachable;
    return buf;
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

pub fn dumpNodeTreeGraph(self: *UI, root: *Node, save_path: []const u8) !void {
    const savefile = try std.fs.cwd().createFile(save_path, .{});
    defer savefile.close();
    var writer = savefile.writer();

    _ = try writer.write("digraph {\n");
    _ = try writer.write("  overlap=true;\n");
    _ = try writer.write("  ranksep=2;\n");

    var node_iter = self.node_table.valueIterator();
    while (node_iter.next()) |node| {
        try writer.print("  Node_0x{x} [label=\"", .{@intFromPtr(node)});
        try writer.print("{s}\n", .{std.fmt.fmtSliceEscapeLower(node.hash_string)});
        try writer.print("{any}\n", .{node.pref_size});
        try writer.print("{d}\n", .{node.rect});
        if (node.child_count > 0) try writer.print("child_layout={}\n", .{node.child_layout_axis});
        inline for (@typeInfo(Flags).Struct.fields) |field| {
            if (@field(node.flags, field.name)) _ = try writer.write(field.name ++ ",");
        }
        try writer.print("\"];\n", .{});
        if (node.parent) |other| try writer.print("    Node_0x{x} -> Node_0x{x} [label=\"parent\"];\n", .{ @intFromPtr(node), @intFromPtr(other) });
        if (node.first) |other| try writer.print("    Node_0x{x} -> Node_0x{x} [label=\"first\"];\n", .{ @intFromPtr(node), @intFromPtr(other) });
        if (node.last) |other| try writer.print("    Node_0x{x} -> Node_0x{x} [label=\"last\"];\n", .{ @intFromPtr(node), @intFromPtr(other) });
        if (node.next) |other| try writer.print("    Node_0x{x} -> Node_0x{x} [label=\"next\"];\n", .{ @intFromPtr(node), @intFromPtr(other) });
        if (node.prev) |other| try writer.print("    Node_0x{x} -> Node_0x{x} [label=\"prev\"];\n", .{ @intFromPtr(node), @intFromPtr(other) });
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

    _ = root;
}

pub const DebugView = struct {
    allocator: Allocator,
    ui: UI,
    active: bool,
    node_list_idx: usize,
    node_query_pos: ?vec2,
    anchor_right: bool,
    show_help: bool,

    pub fn init(allocator: Allocator) !DebugView {
        return DebugView{
            .allocator = allocator,
            .ui = try UI.init(allocator, .{}),
            .active = false,
            .node_list_idx = 0,
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
        // scroll up/down to change the highlighted node in the list
        if (events.fetchAndRemove(.MouseScroll, null)) |scroll_ev| {
            if (scroll_ev.y < 0) self.node_list_idx += 1;
            if (scroll_ev.y > 0) {
                if (self.node_list_idx > 0) self.node_list_idx -= 1;
            }
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

        self.node_list_idx = std.math.clamp(self.node_list_idx, 0, selected_nodes.items.len - 1);
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
                .pref_size = Size.fromRect(node.rect),
            });
        }
        // green border for the node selected from the list (separated so it always draws on top)
        _ = self.ui.addNode(border_node_flags, "", .{
            .border_color = vec4{ 0, 1, 0, 0.5 },
            .rel_pos = RelativePlacement.simple(active_node.rect.min),
            .pref_size = Size.fromRect(active_node.rect),
        });
        // blue border to show the padding
        if (@reduce(.And, active_node.padding != vec2{ 0, 0 })) {
            _ = self.ui.addNode(border_node_flags, "", .{
                .border_color = vec4{ 0, 0, 1, 0.5 },
                .rel_pos = RelativePlacement.simple(active_node.rect.min + active_node.padding),
                .pref_size = size: {
                    const size = active_node.rect.size() - math.times(active_node.padding, 2);
                    break :size Size.exact(.pixels, size[0], size[1]);
                },
            });
        }
        _ = self.ui.popStyle();

        self.ui.pushStyle(.{ .font_size = 16, .bg_color = vec4{ 0, 0, 0, 0.75 } });
        defer _ = self.ui.popStyle();
        self.ui.root_node.?.child_layout_axis = .x;
        if (self.anchor_right) self.ui.spacer(.x, Size.percent(1, 0));
        {
            const left_bg_node = self.ui.addNode(.{
                .no_id = true,
                .draw_background = true,
                .clip_children = true,
            }, "", .{
                .child_layout_axis = .y,
                .pref_size = [2]Size{ Size.by_children(0.5), Size.by_children(1) },
            });
            self.ui.pushParent(left_bg_node);
            defer self.ui.popParentAssert(left_bg_node);

            if (self.node_query_pos) |pos| self.ui.labelF("node_query_pos: {d}\n", .{pos});

            for (selected_nodes.items, 0..) |node, idx| {
                if (idx == self.node_list_idx) {
                    self.ui.labelBoxF("hash=\"{s}\"", .{node.hash_string});
                } else {
                    self.ui.labelF("hash=\"{s}\"", .{node.hash_string});
                }
            }
        }
        {
            const right_bg_node = self.ui.addNode(.{
                .no_id = true,
                .draw_background = true,
                .clip_children = true,
            }, "", .{
                .child_layout_axis = .y,
                .pref_size = [2]Size{ Size.by_children(1), Size.by_children(1) },
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
                        self.ui.labelF("{s}.hash_string=\"{s}\"", .{ name, link.hash_string });
                    },
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
                        inline for (@typeInfo(Signal).Struct.fields) |signal_field| {
                            if (signal_field.type == bool and @field(value, signal_field.name)) {
                                _ = try buf.writer().write(signal_field.name ++ ", ");
                            }
                        }
                        self.ui.labelF("{s}={{{s}.mouse_pos={d}, .scroll_amount={d}}}", .{
                            name, buf.slice(), value.mouse_pos, value.scroll_amount,
                        });
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
                .child_layout_axis = .y,
                .pref_size = [2]Size{ Size.by_children(1), Size.by_children(1) },
            });
            self.ui.pushParent(help_bg_node);
            defer self.ui.popParentAssert(help_bg_node);

            self.ui.label("Ctrl+Shift+H            -> toggle this help menu");
            self.ui.label("Ctrl+Shift+D            -> toggle dbg UI");
            self.ui.label("scroll up/down          -> choose highlighed node");
            self.ui.label("Ctrl+Shift+ScrollClick  -> freeze mouse position");
            self.ui.label("Ctrl+Shift+Left/Right   -> anchor left/right");
        }

        self.ui.endBuild(dt);
        try self.ui.render();
    }
};
