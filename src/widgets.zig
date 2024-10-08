// there's no need to manually include this file, it's already provided by UI.zig

const std = @import("std");
const clamp = std.math.clamp;
const zig_ui = @import("../zig_ui.zig");
const vec2 = zig_ui.vec2;
const vec3 = zig_ui.vec3;
const vec4 = zig_ui.vec4;
const glfw = zig_ui.glfw;
const UI = @import("UI.zig");
const Node = UI.Node;
const Flags = UI.Flags;
const Signal = UI.Signal;
const Rect = UI.Rect;
const Size = UI.Size;
const Axis = UI.Axis;
const FontType = UI.FontType;
const Placement = UI.Placement;
const RelativePlacement = UI.RelativePlacement;
const Icons = UI.Icons;
const text_ops = @import("text_ops.zig");
const TextAction = text_ops.TextAction;
const utils = @import("utils.zig");

pub fn spacer(ui: *UI, axis: Axis, size: Size) void {
    const sizes = switch (axis) {
        .x => [2]Size{ size, Size.percent(0, 0) },
        .y => [2]Size{ Size.percent(0, 0), size },
    };
    _ = ui.addNode(.{ .no_id = true }, "", .{ .size = sizes });
}

pub fn shape(ui: *UI, init_args: anytype) void {
    _ = ui.addNode(.{
        .draw_background = true,
        .draw_border = @hasField(@TypeOf(init_args), "border_color"),
        .no_id = true,
    }, "", init_args);
}

pub fn box(ui: *UI, rect: UI.Rect, init_args: anytype) void {
    const node = ui.addNode(.{
        .draw_background = true,
        .draw_border = @hasField(@TypeOf(init_args), "border_color"),
        .floating_x = true,
        .floating_y = true,
        .no_id = true,
    }, "", init_args);
    if (@hasField(@TypeOf(init_args), "size"))
        @compileError("redundant `size` field in `init_args`. use `rect` argument instead");
    if (@hasField(@TypeOf(init_args), "rel_pos"))
        @compileError("redundant `rel_pos` field in `init_args`. use `rect` argument instead");
    const size = rect.size();
    node.size = UI.Size.exact(.pixels, size[0], size[1]);
    node.rel_pos = UI.RelativePlacement.simple(rect.min);
}

pub const label_flags = Flags{
    .no_id = true,
    .ignore_hash_sep = true,
    .draw_text = true,
};
pub fn label(ui: *UI, str: []const u8) void {
    _ = ui.addNode(label_flags, str, .{});
}

pub fn labelBox(ui: *UI, str: []const u8) void {
    _ = ui.addNode(.{
        .no_id = true,
        .ignore_hash_sep = true,
        .draw_text = true,
        .draw_background = true,
        .draw_border = true,
    }, str, .{});
}

pub fn text(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(.{
        .draw_text = true,
    }, str, .{});
    return node.signal;
}

pub fn textBox(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(.{
        .draw_text = true,
        .draw_border = true,
        .draw_background = true,
    }, str, .{});
    return node.signal;
}

pub const button_flags = Flags{
    .clickable = true,
    .draw_text = true,
    .draw_border = true,
    .draw_background = true,
    .draw_hot_effects = true,
    .draw_active_effects = true,
};
pub fn button(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(button_flags, str, .{
        .cursor_type = .pointing_hand,
    });
    return node.signal;
}

pub const subtle_button_flags = Flags{
    .clickable = true,
    .draw_text = true,
    .draw_active_effects = true,
};
pub fn subtleButton(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(subtle_button_flags, str, .{
        .cursor_type = .pointing_hand,
    });
    return node.signal;
}

pub fn iconLabel(ui: *UI, str: []const u8) void {
    _ = ui.addNode(.{
        .no_id = true,
        .ignore_hash_sep = true,
        .draw_text = true,
    }, str, .{
        .font_type = .icon,
    });
}

pub fn iconButton(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(.{
        .clickable = true,
        .draw_text = true,
        .draw_border = true,
        .draw_background = true,
        .draw_hot_effects = true,
        .draw_active_effects = true,
    }, str, .{
        .cursor_type = .pointing_hand,
        .font_type = .icon,
    });
    return node.signal;
}

pub fn subtleIconButton(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(.{
        .clickable = true,
        .draw_text = true,
        .draw_active_effects = true,
    }, str, .{
        .cursor_type = .pointing_hand,
        .font_type = .icon,
    });
    return node.signal;
}

pub fn slider(
    ui: *UI,
    comptime T: type,
    hash: []const u8,
    size: [2]Size,
    value_ptr: *T,
    min: T,
    max: T,
) void {
    // TODO: generalizing this to y-axis slider so it can be used for scroll bars and stuff like volume sliders
    // TODO: maybe add a more generic slider functions like `sliderOptions` or `sliderExtra` or `sliderOpts` or `sliderEx`
    // or just add an `options: SliderOptions` argument, following the convention of zig stdlib
    value_ptr.* = clamp(value_ptr.*, min, max);

    const style = ui.topStyle();

    const scroll_zone = ui.pushLayoutParentF(.{
        .clickable = true,
    }, "{s}_slider", .{hash}, size, .x);
    defer ui.popParentAssert(scroll_zone);

    const scroll_size = scroll_zone.rect.size();

    const handle_percent: f32 = switch (@typeInfo(T)) {
        .Float => @as(f32, @floatCast(value_ptr.* - min)) / @as(f32, @floatCast(max - min)),
        .Int => @as(f32, @floatFromInt(value_ptr.* - min)) / @as(f32, @floatFromInt(max - min)),
        else => @panic("TODO: add support for '" ++ @typeName(T) ++ "' sliders"),
    };
    const handle_radius = 0.3 * scroll_size[1];
    var handle_pos = handle_percent * scroll_size[0];
    // I'm not using `std.math.clamp` here on purpose, because of the 0 size on the 1st frame
    if (handle_pos < handle_radius) handle_pos = handle_radius;
    if (handle_pos > scroll_size[0] - handle_radius) handle_pos = scroll_size[0] - handle_radius;

    _ = ui.addNode(.{
        .draw_background = true,
        .floating_y = true,
        .no_id = true,
    }, "", .{
        .bg_color = vec4{ 0, 0, 0, 1 },
        .size = Size.flexible(.percent, 1, 0.2),
        .rel_pos = RelativePlacement.match(.center),
    });

    const handle = ui.addNode(.{
        .draw_background = true,
        .floating_x = true,
        .floating_y = true,
        .no_id = true,
    }, "", .{
        .bg_color = style.text_color,
        .size = Size.flexible(.pixels, handle_radius * 2, handle_radius * 2),
        .corner_radii = @as(vec4, @splat(handle_radius)),
        .rel_pos = RelativePlacement{
            .target = .center,
            .anchor = .middle_left,
            .diff = vec2{ handle_pos, 0 },
        },
    });

    if (scroll_zone.signal.held_down) {
        handle.rel_pos.diff[0] = clamp(
            scroll_zone.signal.mouse_pos[0],
            handle_radius,
            @max(handle_radius, scroll_zone.rect.size()[0] - handle_radius),
        );
        const scroll_zone_size = scroll_zone.rect.size()[0] - 2 * handle_radius;
        const scroll_zone_pos = scroll_zone.signal.mouse_pos[0] - handle_radius;
        const percentage = clamp(scroll_zone_pos / scroll_zone_size, 0, 1);
        value_ptr.* = switch (@typeInfo(T)) {
            .Float => min + (max - min) * @as(T, @floatCast(percentage)),
            .Int => min + @as(T, @intFromFloat(@round(@as(f32, @floatFromInt(max - min)) * percentage))),
            else => @panic("TODO: add support for '" ++ @typeName(T) ++ "' sliders"),
        };
    }

    value_ptr.* = clamp(value_ptr.*, min, max);
}

pub fn namedSlider(
    ui: *UI,
    comptime T: type,
    str: []const u8,
    size: [2]Size,
    value_ptr: *T,
    min: T,
    max: T,
) void {
    _ = ui;
    _ = str;
    _ = size;
    _ = value_ptr;
    _ = min;
    _ = max;
    @compileError("TODO");
}

pub fn checkBox(ui: *UI, hash: []const u8, value: *bool) Signal {
    const sig = ui.iconButtonF("{s}###{s}", .{ Icons.ok, hash });
    const node = sig.node.?;
    if (!value.*) node.flags.draw_text = false;
    if (sig.clicked) value.* = !value.*;
    return sig;
}

pub fn namedCheckBox(ui: *UI, str: []const u8, value: *bool) Signal {
    const hash_str = UI.hashPartOfString(str);
    const disp_str = UI.displayPartOfString(str);

    _ = ui.pushLayoutParentF(.{}, "###{s}", .{hash_str}, UI.Size.children2(1, 1), .x);
    defer _ = ui.popParent();

    ui.pushTmpStyle(.{
        .font_size = 0.7 * ui.topStyle().font_size,
        .alignment = .center,
    });
    const sig = ui.checkBox(hash_str, value);

    ui.label(disp_str);

    return sig;
}

pub fn toggleButton(ui: *UI, str: []const u8, start_open: bool) Signal {
    const hash_str = UI.hashPartOfString(str);
    const disp_str = UI.displayPartOfString(str);

    const click_region = ui.pushLayoutParentF(.{
        .toggleable = true,
    }, "{s}_click_region", .{hash_str}, Size.fillByChildren(1, 1), .x);
    defer ui.popParentAssert(click_region);
    click_region.cursor_type = .pointing_hand;
    if (click_region.first_time) click_region.toggled = start_open;
    const signal = click_region.signal;

    const arrow = if (signal.toggled) Icons.down_open else Icons.right_open;
    ui.iconLabel(arrow);
    ui.label(disp_str);

    return signal;
}

pub fn startListBox(ui: *UI, name: []const u8, size: [2]Size) void {
    ui.startScrollView(.{
        .draw_background = true, // TODO: get this from a parameter
    }, name, .{ .size = size });
}

pub fn endListBox(ui: *UI, opts: ScrollbarOptions) void {
    _ = ui.endScrollView(opts);
}

pub fn enumListBox() void {
    @compileError("TODO");
}

pub fn stringsListBox(
    ui: *UI,
    name: []const u8,
    size: [2]Size,
    choices: []const []const u8,
    chosen_idx: *usize,
) Signal {
    // TODO: scroll bar options
    ui.startListBox(name, size);
    defer ui.endListBox(.{
        .bg_color = UI.colorFromRGB(0x1c, 0x23, 0x29),
        .handle_color = vec4{ 0.85, 0.85, 0.85, 1 },
    });

    for (choices, 0..) |str, idx| {
        const btn_sig = ui.button(str);
        btn_sig.node.?.size[0] = Size.percent(1, 0);
        if (btn_sig.pressed) chosen_idx.* = idx;
    }

    // TODO: return correct click signals
    return Signal{ .node = null };
}

// TODO: create the other helper variants for like we have for listBox
pub fn dropDownList(
    ui: *UI,
    hash: []const u8,
    size: [2]Size,
    choices: []const []const u8,
    chosen_idx: *usize,
) Signal {
    // TODO: button(current choice displayed + down-arrow)
    const click_region = ui.pushLayoutParentF(.{
        .toggleable = true,
    }, "{s}_btn", .{hash}, Size.fillByChildren(1, 1), .x);
    {
        ui.label(choices[chosen_idx.*]);
        ui.iconLabel(Icons.down_open);
    }
    ui.popParentAssert(click_region);

    // TODO: new window with a listbox inside
    if (click_region.signal.toggled) {
        // const window_pos = RelativePlacement.simple(click_region.rect.min);
        const window_pos = RelativePlacement{
            .target = .top_right,
            .anchor = .btm_left,
            .diff = click_region.rect.get(.btm_right),
        };
        const list_window = ui.startWindow(hash, size, window_pos);
        defer ui.endWindow(list_window);
        _ = ui.stringsListBox(hash, size, choices, chosen_idx);
    }

    // TODO: combine click+listbox signals
    return click_region.signal;
}

pub const TabOptions = struct {
    active_tab_bg: vec4 = UI.colorFromRGB(0x6f, 0x51, 0x35),
    inactive_tab_bg: vec4 = UI.colorFromRGB(0x2c, 0x33, 0x39),
    tabbed_content_border: vec4 = UI.colorFromRGB(0xc1, 0x80, 0x0b),
    close_btn: bool = false,
};
pub fn startTabList(ui: *UI) void {
    // TODO: this `tab_list_p` could be a 'named {start,end}Line' maybe?
    const tab_list_p = ui.addNode(.{
        .scroll_children_x = true,
        .clip_children = true,
    }, "tab_list", .{
        .layout_axis = .x,
        .size = [2]UI.Size{ UI.Size.percent(1, 1), UI.Size.children(1) },
    });
    ui.pushParent(tab_list_p);
}
pub fn endTabList(ui: *UI) void {
    _ = ui.popParent(); // tab_list_p
}
pub const TabSignal = struct {
    tab: Signal,
    close: Signal,
};
pub fn tabButton(
    ui: *UI,
    name: []const u8,
    selected: bool,
    opts: TabOptions,
) TabSignal {
    ui.pushStyle(.{
        .bg_color = if (selected) opts.active_tab_bg else opts.inactive_tab_bg,
        .border_color = @as(vec4, @splat(0.5)),
        .corner_radii = [4]f32{ 8, 8, 0, 0 },
    });
    defer _ = ui.popStyle();

    const tab_idx = ui.topParent().child_count;
    // TODO: maybe render tabs without bottom border when selected?
    const tab_p = ui.addNodeF(.{
        .draw_border = true,
        .draw_background = true,
    }, "tab_{}", .{tab_idx}, .{
        .layout_axis = .x,
        .size = UI.Size.children2(1, 1),
    });
    ui.pushParent(tab_p);
    defer ui.popParentAssert(tab_p);

    const tab_sig = ui.subtleButtonF("{s}###title", .{name});

    const close_sig = if (opts.close_btn) ui.iconButton(UI.Icons.cancel) else std.mem.zeroes(Signal);
    if (close_sig.node) |node| node.corner_radii[0] = 0;

    return .{ .tab = tab_sig, .close = close_sig };
}

pub fn enumTabList(ui: *UI, comptime T: type, selected_tab: *T) struct {
    sig: Signal,
    tab_value: T,
} {
    ui.startTabList();
    defer ui.endTabList();

    var sig = Signal{ .node = null, .mouse_pos = undefined };
    var tab_value: T = undefined;

    inline for (@typeInfo(T).Enum.fields) |field| {
        const enum_val: T = @enumFromInt(field.value);
        const is_selected = (selected_tab.* == enum_val);
        const tab_sig = ui.tabButton(field.name, is_selected, .{ .close_btn = false });
        if (tab_sig.tab.clicked) selected_tab.* = enum_val;
        if (tab_sig.tab.hovering) {
            sig = tab_sig.tab;
            tab_value = enum_val;
        }
    }

    return .{ .sig = sig, .tab_value = tab_value };
}

/// pushes a new node as parent that is meant only for layout purposes
// TODO: delete this, use `addParent` instead
pub fn pushLayoutParent(
    ui: *UI,
    flags: Flags,
    hash: []const u8,
    size: [2]Size,
    layout_axis: Axis,
) *Node {
    const node = ui.addNodeStrings(flags, "", hash, .{
        .size = size,
        .layout_axis = layout_axis,
    });
    ui.pushParent(node);
    return node;
}

pub fn startLine(ui: *UI) void {
    const size = UI.Size.fillByChildren(0, 1);
    _ = ui.pushLayoutParent(.{ .no_id = true }, "", size, .x);
}

pub fn endLine(ui: *UI) void {
    _ = ui.popParent();
}

pub fn startCtxMenu(ui: *UI, pos: ?RelativePlacement) void {
    const root = ui.addNodeAsRoot(.{
        .clip_children = true,
        .draw_border = true,
        .draw_background = true,
        .floating_x = true,
        .floating_y = true,
    }, "INTERNAL_CTX_MENU_ROOT", .{
        .size = [2]Size{ Size.children(1), Size.children(1) },
        .bg_color = vec4{ 0, 0, 0, 0.75 },
        .corner_radii = vec4{ 4, 4, 4, 4 },
    });
    if (pos) |p|
        root.rel_pos = p
    else if (root.first_frame_touched == ui.frame_idx)
        root.rel_pos = RelativePlacement.absolute(.{ .top_left = ui.mouse_pos });

    ui.pushParent(root);
    ui.ctx_menu_root = root;
}

pub fn endCtxMenu(ui: *UI) void {
    ui.popParentAssert(ui.ctx_menu_root.?);
}

pub fn startTooltip(ui: *UI, pos: ?RelativePlacement) void {
    // TODO: the cursor hot-stop (i.e. the true cursor position)
    // is only on the top-left of the cursor image for the default
    // arrow cursor. is there no way to get the cursor size from glfw?
    const cursor_btm_right = ui.mouse_pos + vec2{ 16, -16 };
    const default_pos = RelativePlacement.absolute(.{ .top_left = cursor_btm_right });
    const root = ui.addNodeAsRoot(.{
        .clip_children = true,
        .draw_border = true,
        .draw_background = true,
        .floating_x = true,
        .floating_y = true,
    }, "INTERNAL_TOOLTIP_ROOT", .{
        .size = [2]Size{ Size.children(1), Size.children(1) },
        .bg_color = vec4{ 0, 0, 0, 0.75 },
        .corner_radii = vec4{ 4, 4, 4, 4 },
        .rel_pos = pos orelse default_pos,
    });
    ui.pushParent(root);
    ui.tooltip_root = root;
}

pub fn endTooltip(ui: *UI) void {
    ui.popParentAssert(ui.tooltip_root.?);
}

/// `pos` is relative to actual the full screen, not any other Node
pub fn startWindow(
    ui: *UI,
    hash: []const u8,
    size: [2]Size,
    pos: RelativePlacement,
) *Node {
    const window_root = ui.addNodeAsRoot(.{
        // set this interaction flag to consume inputs that would go *through* the window
        // and into nodes that are underneath the window
        .clickable = true,

        .clip_children = true,
        .draw_border = true,
        .draw_background = true,
        .floating_x = true,
        .floating_y = true,
    }, hash, .{
        .size = size,
        .rel_pos = pos,
        .bg_color = vec4{ 0, 0, 0, 0.75 },
    });
    ui.pushParent(window_root);

    ui.window_roots.append(window_root) catch |e|
        ui.setErrorInfo(@errorReturnTrace(), @errorName(e));

    return window_root;
}

pub fn endWindow(ui: *UI, window_root: *Node) void {
    ui.popParentAssert(window_root);
}

pub const ScrollViewSignal = struct {
    view: Signal,
    vbar: Signal,
    hbar: Signal,
};
pub const ScrollViewOptions = struct {};

pub fn startScrollView(
    ui: *UI,
    flags: Flags,
    name: []const u8,
    init_args: anytype,
) void {
    const InitArgs = @TypeOf(init_args);
    // TODO: put these checks into an error buffer that we report all at once at end of build
    std.debug.assert(@hasField(InitArgs, "size"));
    std.debug.assert(@TypeOf(init_args.size) == [2]UI.Size);
    for (init_args.size) |size| std.debug.assert(size == .pixels or size == .percent);

    const view_p = ui.addNode(flags, name, init_args);
    view_p.layout_axis = .x;
    ui.pushParent(view_p);

    const hbar_p = ui.addNode(.{}, "hbar_p", .{
        .layout_axis = .y,
        .size = UI.Size.flexible(.percent, 1, 1),
    });
    ui.pushParent(hbar_p);

    const scroll_content_p = ui.addNode(.{
        .scroll_children_x = true,
        .scroll_children_y = true,
        .clip_children = true,
    }, "scroll_content_p", .{
        .size = UI.Size.flexible(.percent, 1, 1),
    });
    if (@hasField(InitArgs, "layout_axis")) scroll_content_p.layout_axis = init_args.layout_axis;
    ui.pushParent(scroll_content_p);
}
pub fn endScrollView(ui: *UI, opts: ScrollbarOptions) ScrollViewSignal {
    const scroll_content_p = ui.popParent();
    const content_size = scroll_content_p.children_size;

    // TODO: use `child_calc_size` together with `inner_padding` as well

    // horizontal scroll bar
    ui.scrollbar("h_scroll_bar", .x, content_size[0], scroll_content_p, opts);

    _ = ui.popParent(); // hbar_p

    // vertical scroll bar
    ui.scrollbar("v_scroll_bar", .y, content_size[1], scroll_content_p, opts);

    _ = ui.popParent(); // view_p

    return std.mem.zeroes(ScrollViewSignal);
}

pub const ScrollbarOptions = struct {
    bg_color: vec4,
    handle_color: vec4,
    handle_border_color: ?vec4 = null,
    handle_corner_radius: f32 = 0,
    always_show: bool = true, // display bar even when content fully fit the parent
    size: UI.Size = UI.Size.em(0.7, 1),
};
pub fn scrollbar(
    ui: *UI,
    name: []const u8,
    axis: Axis,
    content_size: f32,
    scroll_view_parent: *Node,
    opts: ScrollbarOptions,
) void {
    const axis_idx: usize = @intFromEnum(axis);
    const off_axis_idx = 1 - axis_idx;

    const scroll_offset: *f32 = &scroll_view_parent.scroll_offset[axis_idx];

    const scroll_view_size = scroll_view_parent.rect.size()[axis_idx];
    const scroll_max = content_size - scroll_view_size;
    const view_pct_of_whole = std.math.clamp(scroll_view_size / content_size, 0, 1);
    if (view_pct_of_whole >= 1 and !opts.always_show) return;

    // parent for the arrow buttons, scroll bar, and scroll handle
    const scroll_region_p = ui.addNodeF(.{}, "{s}_scroll_p", .{name}, .{
        .layout_axis = axis,
        .size = switch (axis) {
            .x => [2]UI.Size{ UI.Size.pixels(scroll_view_size, 1), opts.size },
            .y => [2]UI.Size{ opts.size, UI.Size.pixels(scroll_view_size, 1) },
        },
    });
    ui.pushParent(scroll_region_p);
    defer ui.popParentAssert(scroll_region_p);

    // get the size of the arrow buttons so we can scale them down to fit
    // nicely into the bar
    const font_size = ui.topStyle().font_size;
    const arrow_icon_rect = ui.font_cache.textRect(UI.Icons.up_open, .icon, font_size) catch @panic("TODO");
    const arrow_icon_size = (arrow_icon_rect.max - arrow_icon_rect.min)[off_axis_idx];
    const off_axis_size = scroll_region_p.rect.size()[off_axis_idx];
    const scaled_icon_font_size = font_size / (arrow_icon_size / off_axis_size);

    // TODO: fix size of arrow buttons here, they're way too tiny!
    _ = scaled_icon_font_size;
    // ui.pushStyle(.{ .font_size = scaled_icon_font_size });
    ui.pushStyle(.{ .font_size = font_size / 2 }); // TODO: what?
    defer _ = ui.popStyle();
    // TODO: UI.Icons should be an enum that we then use to grab codepoints out
    // of a runtime user-customizable icon font map
    switch (axis) {
        .x => _ = ui.iconButton(UI.Icons.left_open),
        .y => _ = ui.iconButton(UI.Icons.up_open),
    }
    defer switch (axis) {
        .x => _ = ui.iconButton(UI.Icons.right_open),
        .y => _ = ui.iconButton(UI.Icons.down_open),
    };

    const scroll_bar = ui.addNodeF(.{
        .clickable = true,
        .draw_background = true,
    }, "{s}_bar", .{name}, .{
        .bg_color = opts.bg_color,
        .size = UI.Size.flexible(.percent, 1, 1),
    });
    ui.pushParent(scroll_bar);
    defer ui.popParentAssert(scroll_bar);

    const mouse_pos = scroll_bar.signal.mouse_pos[axis_idx];
    const bar_size = scroll_bar.rect.size()[axis_idx];
    const handle_size = view_pct_of_whole * bar_size;
    const half_handle = handle_size / 2;
    // TODO: instead of calculating these position values can we use some spacers instead?
    // that way this @max for 1st frame wouldn't be necessary
    const bar_scroll_size = @max(bar_size - handle_size, 0); // 1st frame bar_size is 0
    const mouse_scroll_pct =
        if (mouse_pos < half_handle)
        0
    else if (mouse_pos > (bar_size - half_handle))
        1
    else
        (mouse_pos - half_handle) / bar_scroll_size;
    var scroll_pct = std.math.clamp(mouse_scroll_pct, 0, 1);
    if (axis == .y) scroll_pct = 1 - scroll_pct;

    if (scroll_bar.signal.held_down) {
        scroll_offset.* = switch (axis) {
            .x => -scroll_max * scroll_pct,
            .y => scroll_max * scroll_pct,
        };
    } else {
        scroll_pct = switch (axis) {
            .x => -scroll_offset.* / scroll_max,
            .y => scroll_offset.* / scroll_max,
        };
    }

    const handle_pct = switch (axis) {
        .x => scroll_pct,
        .y => 1 - scroll_pct,
    };
    const handle_center_pos = half_handle + handle_pct * bar_scroll_size;
    const handle_pos = std.math.clamp(handle_center_pos - half_handle, 0, bar_scroll_size);

    const scroll_handle = ui.addNodeF(.{
        // TODO: .clickable = true,
        .draw_background = true,
        .floating_x = (axis == .x),
        .floating_y = (axis == .y),
    }, "{s}_handle", .{name}, .{
        .bg_color = opts.handle_color,
        .size = switch (axis) {
            .x => [2]UI.Size{ UI.Size.pixels(handle_size, 1), UI.Size.percent(1, 1) },
            .y => [2]UI.Size{ UI.Size.percent(1, 1), UI.Size.pixels(handle_size, 1) },
        },
        .corner_radii = @as(vec4, @splat(opts.handle_corner_radius)),
        .rel_pos = UI.RelativePlacement.simple(switch (axis) {
            .x => vec2{ handle_pos, 0 },
            .y => vec2{ 0, handle_pos },
        }),
    });
    if (opts.handle_border_color) |border_color| {
        scroll_handle.flags.draw_border = true;
        scroll_handle.border_color = border_color;
    }
    // TODO: clicking on scroll bar is page up/down, current behavior belongs to scroll_handle
}

pub const TextInput = struct {
    buffer: []u8,
    bufpos: usize,
    // the cursor/mark is in bytes into buffer
    cursor: usize,
    mark: usize,

    pub fn init(backing_buffer: []u8, str: []const u8) TextInput {
        var input_data = TextInput{
            .buffer = backing_buffer,
            .bufpos = str.len,
            .cursor = 0,
            .mark = 0,
        };
        @memcpy(input_data.buffer[0..str.len], str);
        return input_data;
    }

    pub fn slice(self: TextInput) []u8 {
        return self.buffer[0..self.bufpos];
    }
};

pub const LineInputOptions = struct {
    size: Size = Size.percent(1, 0),
    /// shown when the input is empty and the users has not interacted with the text box yet
    default_str: []const u8 = "",
};
pub fn lineInput(
    ui: *UI,
    name: []const u8,
    input: *TextInput,
    opts: LineInputOptions,
) Signal {
    return textInputRaw(ui, name, input, .{
        .size = [2]Size{ opts.size, Size.children(1) },
        .default_str = opts.default_str,
    }) catch |e| blk: {
        ui.setErrorInfo(@errorReturnTrace(), @errorName(e));
        break :blk std.mem.zeroes(Signal);
    };
}

// TODO: multi-line input support:
// [ ] need option for <ENTER> behavior: input newline or should that need shift-enter?
pub const TextInputOptions = struct {
    size: [2]Size = Size.flexible(.percent, 1, 1),
    /// shown when the input is empty and the users has not interacted with the text box yet
    default_str: []const u8 = "",
};
pub fn textInputRaw(
    ui: *UI,
    name: []const u8,
    input: *TextInput,
    opts: TextInputOptions,
) !Signal {
    const buffer = input.buffer;
    const buf_len = &input.bufpos;

    const widget_node = ui.addNodeF(.{
        .clickable = true,
        .selectable = true,
        .clip_children = true,
        .draw_background = true,
        .draw_border = true,
    }, "###{s}", .{name}, .{
        .layout_axis = .x,
        .cursor_type = .ibeam,
        .size = opts.size,
    });
    ui.pushParent(widget_node);
    defer ui.popParentAssert(widget_node);
    const sig = widget_node.signal;

    // make input box darker when not in focus
    if (!sig.focused) widget_node.bg_color = widget_node.bg_color * @as(vec4, @splat(0.85));

    const show_default_str = (input.slice().len == 0 and !sig.focused);
    const display_str = if (show_default_str) opts.default_str else input.slice();

    // we can't use a simple label because the position of text_node needs to be saved across frames
    // (we can't just rely on the cursor for this information; imagine doing `End` + `LeftArrow`, for example)
    const text_node = ui.addNode(.{
        .draw_text = true,
        .disable_text_truncation = true,
        .floating_x = true,
        .ignore_hash_sep = true,
    }, display_str, .{
        .font_type = if (show_default_str) FontType.italic else FontType.regular,
    });
    // slightly darken text color when showing the default text
    if (show_default_str) {
        for (0..3) |i| text_node.text_color[i] *= 0.8;
    }

    const font_pixel_size = ui.topStyle().font_size;
    const text_padd = ui.text_padding;

    const rect_before_cursor = try ui.font_cache.textRect(buffer[0..input.cursor], .regular, font_pixel_size);
    const rect_before_mark = try ui.font_cache.textRect(buffer[0..input.mark], .regular, font_pixel_size);

    const font_metrics = ui.font_cache.getFont(.regular).getScaledMetrics(font_pixel_size);
    const cursor_height = font_metrics.line_advance - text_padd[1];
    const cursor_rel_pos = vec2{ rect_before_cursor.max[0], 0 } + text_padd;
    const selection_size = @abs(rect_before_mark.max[0] - rect_before_cursor.max[0]);
    const selection_start = @min(rect_before_mark.max[0], rect_before_cursor.max[0]);
    const selection_rel_pos = vec2{ selection_start, 0 } + text_padd;

    const filled_rect_flags = Flags{
        .no_id = true,
        .draw_background = true,
        .floating_x = true,
        .floating_y = true,
    };
    const cursor_node = ui.addNode(filled_rect_flags, "", .{
        .bg_color = vec4{ 0, 0, 0, 1 },
        .size = Size.exact(.pixels, 1, cursor_height),
        .rel_pos = RelativePlacement.simple(text_node.rel_pos.diff + cursor_rel_pos),
    });
    _ = ui.addNode(filled_rect_flags, "", .{ // selection rectangle
        .bg_color = vec4{ 0, 0, 1, 0.25 },
        .size = Size.exact(.pixels, selection_size, cursor_height),
        .rel_pos = RelativePlacement.simple(text_node.rel_pos.diff + selection_rel_pos),
    });

    // scroll text to keep cursor in view
    if (!widget_node.first_time) {
        const cursor_valid_range = vec2{ text_padd[0], widget_node.rect.size()[0] - text_padd[0] };
        const cursor_pos = cursor_node.rel_pos.diff[0];
        if (cursor_pos < cursor_valid_range[0])
            text_node.rel_pos.diff[0] += cursor_valid_range[0] - cursor_pos
        else if (cursor_pos > cursor_valid_range[1])
            text_node.rel_pos.diff[0] -= cursor_pos - cursor_valid_range[1];
    }

    if (!sig.focused) return sig;

    var text_actions = try std.BoundedArray(TextAction, 100).init(0);

    // triple click is the same as ctrl+a (which is the same as `Home` followed by `shift+End`)
    if (sig.triple_clicked) {
        try text_actions.append(.{ .flags = .{}, .delta = std.math.minInt(isize) });
        try text_actions.append(.{ .flags = .{ .keep_mark = true }, .delta = std.math.maxInt(isize) });
    }
    // double click selects the current word
    else if (sig.double_clicked) {
        // for a double click to happen a click must happened before, placing the cursor over some word;
        // and so 'select current word' is the same as `ctrl+Left` followed by `ctrl+shift+Right`
        try text_actions.append(.{ .flags = .{ .word_scan = true }, .delta = -1 });
        try text_actions.append(.{ .flags = .{ .word_scan = true, .keep_mark = true }, .delta = 1 });
    }
    // use mouse press to select cursor position
    else if (sig.pressed or sig.held_down) {
        // find the index where the mouse is
        var idx: usize = 0;
        while (idx < buf_len.*) {
            const codepoint_len = try std.unicode.utf8ByteSequenceLength(display_str[idx]);
            const partial_text_buf = display_str[0 .. idx + codepoint_len];
            const partial_rect = try ui.font_cache.textRect(partial_text_buf, .regular, font_pixel_size);
            if (partial_rect.max[0] + text_padd[0] > sig.mouse_pos[0]) break;
            idx += codepoint_len;
        }

        if (sig.held_down) input.cursor = idx;
        if (sig.pressed) input.mark = idx;
    }
    // TODO: doing a click followed by press and drag in the same timing as a double-click
    // does a selection but using the same "word scan" as the double click code path
    // TODO: pressing escape to unselect currently selected text range

    while (ui.events.next()) |event| {
        const has_selection = input.cursor != input.mark;
        var ev_was_used = true;
        switch (event) {
            .KeyDown, .KeyRepeat => |ev| {
                const actions = text_ops.textActionsFromKeyEvent(
                    ev.key,
                    has_selection,
                    ev.mods.shift,
                    ev.mods.control,
                );
                for (actions.slice()) |action| try text_actions.append(action);
                if (actions.len == 0) ev_was_used = false;
            },
            .Char => |codepoint| {
                const add_codepoint_action = TextAction{
                    .flags = .{},
                    .delta = 0,
                    .codepoint = @intCast(codepoint),
                };
                try text_actions.append(add_codepoint_action);
            },
            else => ev_was_used = false,
        }
        if (ev_was_used) ui.events.removeCurrent();
    }

    for (text_actions.slice()) |action| {
        var unicode_buf: [4]u8 = undefined;
        const cur_buf = buffer[0..buf_len.*];
        const text_op = try text_ops.textOpFromAction(action, input.cursor, input.mark, &unicode_buf, cur_buf);

        text_ops.replaceRange(buffer, buf_len, .{ .start = text_op.range.start, .end = text_op.range.end }, text_op.replace_str);
        if (text_op.copy_str.len > 0) {
            const c_str = try ui.allocator.dupeZ(u8, text_op.copy_str);
            defer ui.allocator.free(c_str);
            glfw.setClipboardString(c_str);
        }
        input.cursor = text_op.byte_cursor;
        input.mark = text_op.byte_mark;
    }

    return sig;
}

const color_picker_cursor_radius = 10;
pub fn colorPicker(ui: *UI, hash: []const u8, color: *vec4) void {
    const square_px_size = 225; // 225/6 = 37.5 which is nice to avoid gaps in the hue bar nodes
    const square_size = Size.exact(.pixels, square_px_size, square_px_size);
    const hue_bar_size = Size.exact(.pixels, square_px_size / 10, square_px_size);

    var hsv = utils.RGBtoHSV(color.*);

    const background_node = ui.addNodeStrings(.{
        .draw_border = true,
        .draw_background = true,
        .no_id = true,
    }, "", hash, .{
        .size = Size.fillByChildren(1, 1),
        .layout_axis = .x,
        .inner_padding = @as(vec2, @splat(color_picker_cursor_radius)),
    });
    ui.pushParent(background_node);
    defer ui.popParentAssert(background_node);

    const color_square = ui.addNodeF(.{ .clickable = true }, "{s}_square", .{hash}, .{
        .size = square_size,
        .custom_draw_fn = (struct {
            pub fn draw(_: *UI, shader_inputs: *std.ArrayList(UI.ShaderInput), node: *UI.Node) error{OutOfMemory}!void {
                const hue = @as(*align(1) const vec4, @ptrCast(node.custom_draw_ctx_as_bytes.?.ptr)).*;
                const hue_color = utils.HSVtoRGB(vec4{ hue[0], 1, 1, 1 });
                var rect = UI.ShaderInput.fromNode(node);
                rect.edge_softness = 0;
                rect.border_thickness = vec4{ -1, -1, -1, -1 };
                rect.top_left_color = vec4{ 1, 1, 1, 1 };
                rect.btm_left_color = vec4{ 1, 1, 1, 1 };
                rect.top_right_color = hue_color;
                rect.btm_right_color = hue_color;
                try shader_inputs.append(rect);
                rect.top_left_color = vec4{ 0, 0, 0, 0 };
                rect.btm_left_color = vec4{ 0, 0, 0, 1 };
                rect.top_right_color = vec4{ 0, 0, 0, 0 };
                rect.btm_right_color = vec4{ 0, 0, 0, 1 };
                try shader_inputs.append(rect);
                { // circle cursor
                    const center = node.rect.min + vec2{ hue[1], hue[2] } * node.rect.size();
                    const radius: f32 = color_picker_cursor_radius;
                    const radius_vec: vec2 = @splat(radius);
                    rect.top_left_color = @as(vec4, @splat(1));
                    rect.btm_left_color = @as(vec4, @splat(1));
                    rect.top_right_color = @as(vec4, @splat(1));
                    rect.btm_right_color = @as(vec4, @splat(1));
                    rect.btm_left_pos = center - radius_vec;
                    rect.top_right_pos = center + radius_vec;
                    rect.corner_radii = [4]f32{ radius, radius, radius, radius };
                    rect.edge_softness = 1;
                    rect.border_thickness = vec4{ 2, 2, 2, 2 };
                    try shader_inputs.append(rect);
                }
            }
        }).draw,
        .custom_draw_ctx_as_bytes = std.mem.asBytes(&hsv),
    });
    if (color_square.signal.held_down) {
        const norm = color_square.signal.mouse_pos / color_square.rect.size();
        hsv[1] = clamp(norm[0], 0, 1);
        hsv[2] = clamp(norm[1], 0, 1);
    }

    ui.spacer(.x, Size.pixels(3, 1));

    const hue_bar = ui.addNodeF(.{ .clickable = true, .draw_background = true }, "{s}_hue_bar", .{hash}, .{
        .size = hue_bar_size,
        .custom_draw_fn = (struct {
            pub fn draw(_: *UI, shader_inputs: *std.ArrayList(UI.ShaderInput), node: *UI.Node) error{OutOfMemory}!void {
                var rect = UI.ShaderInput.fromNode(node);
                rect.edge_softness = 0;
                rect.border_thickness = vec4{ -1, -1, -1, -1 };
                const hue_colors = [_]vec4{
                    vec4{ 1, 0, 0, 1 },
                    vec4{ 1, 1, 0, 1 },
                    vec4{ 0, 1, 0, 1 },
                    vec4{ 0, 1, 1, 1 },
                    vec4{ 0, 0, 1, 1 },
                    vec4{ 1, 0, 1, 1 },
                };
                const segment_height = node.rect.size()[1] / hue_colors.len;
                rect.btm_left_pos[1] = rect.top_right_pos[1] - segment_height;
                for (hue_colors, 0..) |rect_color, idx| {
                    const next_color = hue_colors[(idx + 1) % hue_colors.len];
                    rect.top_left_color = rect_color;
                    rect.btm_left_color = next_color;
                    rect.top_right_color = rect_color;
                    rect.btm_right_color = next_color;
                    try shader_inputs.append(rect);
                    rect.top_right_pos[1] = rect.btm_left_pos[1];
                    rect.btm_left_pos[1] = rect.top_right_pos[1] - segment_height;
                }

                rect.top_left_color = @as(vec4, @splat(1));
                rect.btm_left_color = @as(vec4, @splat(1));
                rect.top_right_color = @as(vec4, @splat(1));
                rect.btm_right_color = @as(vec4, @splat(1));
                rect.edge_softness = 1;
                rect.border_thickness = vec4{ 2, 2, 2, 2 };
                rect.corner_radii = [4]f32{ 2, 2, 2, 2 };
                const hsv0 = @as(*align(1) const f32, @ptrCast(node.custom_draw_ctx_as_bytes)).*;
                const bar_size: f32 = 10;
                const center_y = blk: {
                    const center = node.rect.max[1] - node.rect.size()[1] * hsv0;
                    break :blk clamp(
                        center,
                        node.rect.min[1] + bar_size / 2,
                        node.rect.max[1] - bar_size / 2,
                    );
                };
                rect.btm_left_pos[1] = center_y - bar_size / 2;
                rect.top_right_pos[1] = center_y + bar_size / 2;
                try shader_inputs.append(rect);
            }
        }).draw,
        .custom_draw_ctx_as_bytes = std.mem.asBytes(&hsv[0]),
    });
    if (hue_bar.signal.held_down) {
        const norm = hue_bar.signal.mouse_pos / hue_bar.rect.size();
        hsv[0] = clamp(1 - norm[1], 0, 1);
    }

    ui.spacer(.x, Size.pixels(3, 1));

    color.* = utils.HSVtoRGB(hsv);

    // TODO: allow switching between representations for the sliders (RGBA, HSVA, OKLAB)

    const value_parent = ui.pushLayoutParentF(.{}, "{s}_values_parent", .{hash}, square_size, .y);
    defer ui.popParentAssert(value_parent);
    const components = [_][]const u8{ "R", "G", "B", "A" };
    const color_ptr = color;
    for (components, 0..) |comp, idx| {
        const size = [2]Size{ Size.percent(1, 0), Size.children(0) };
        const p = ui.pushLayoutParentF(.{}, "{s}_slider_{s}", .{ hash, comp }, size, .x);
        defer ui.popParentAssert(p);
        const slider_size = [2]Size{ Size.percent(1, 0), Size.text(1) };
        const slider_name = ui.fmtTmpString("{s}_comp_{s}", .{ hash, comp });
        ui.slider(f32, slider_name, slider_size, &color_ptr[idx], 0, 1);
        ui.labelF("{s} {d:1.3}", .{ comp, color_ptr[idx] });
    }
}

pub fn labelF(ui: *UI, comptime fmt: []const u8, args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    ui.label(str);
}

pub fn labelBoxF(ui: *UI, comptime fmt: []const u8, args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    ui.labelBox(str);
}

pub fn textF(ui: *UI, comptime fmt: []const u8, args: anytype) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.text(str);
}

pub fn textBoxF(ui: *UI, comptime fmt: []const u8, args: anytype) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.textBox(str);
}

pub fn buttonF(ui: *UI, comptime fmt: []const u8, args: anytype) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.button(str);
}

pub fn subtleButtonF(ui: *UI, comptime fmt: []const u8, args: anytype) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.subtleButton(str);
}

pub fn iconLabelF(ui: *UI, comptime fmt: []const u8, args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.iconLabel(str);
}

pub fn iconButtonF(ui: *UI, comptime fmt: []const u8, args: anytype) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.iconButton(str);
}

pub fn subtleIconButtonF(ui: *UI, comptime fmt: []const u8, args: anytype) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.subtleIconButton(str);
}

pub fn sliderF(ui: *UI, comptime T: type, comptime fmt: []const u8, args: anytype, size: [2]Size, value_ptr: *T, min: T, max: T) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.slider(T, str, size, value_ptr, min, max);
}

pub fn namedSliderF(ui: *UI, comptime T: type, comptime fmt: []const u8, args: anytype, size: [2]Size, value_ptr: *T, min: T, max: T) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.namedSlider(T, str, size, value_ptr, min, max);
}

pub fn checkBoxF(ui: *UI, comptime fmt: []const u8, args: anytype, value: *bool) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.checkBox(str, value);
}

pub fn namedCheckBoxF(ui: *UI, comptime fmt: []const u8, args: anytype, value: *bool) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.namedCheckBox(str, value);
}

pub fn toggleButtonF(ui: *UI, comptime fmt: []const u8, args: anytype, start_open: bool) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.toggleButton(str, start_open);
}

pub fn startListBoxButtonF(ui: *UI, comptime fmt: []const u8, args: anytype, layout_axis: Axis) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.startListBoxButton(str, layout_axis);
}

pub fn startListBoxF(ui: *UI, comptime fmt: []const u8, args: anytype, size: [2]Size) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.startListBoxButton(str, size);
}

pub fn stringsListBoxF(ui: *UI, comptime fmt: []const u8, args: anytype, size: [2]Size, choices: []const []const u8, chosen_idx: *usize) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return stringsListBox(str, size, choices, chosen_idx);
}

pub fn dropDownListF(ui: *UI, comptime fmt: []const u8, args: anytype, size: [2]Size, choices: []const []const u8, chosen_idx: *usize) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.dropDownList(str, size, choices, chosen_idx);
}

pub fn tabButtonF(ui: *UI, comptime fmt: []const u8, args: anytype, selected: bool, opts: TabOptions) TabSignal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.tabButton(str, selected, opts);
}

pub fn startWindowF(ui: *UI, comptime fmt: []const u8, args: anytype, size: [2]Size, pos: RelativePlacement) *Node {
    const str = ui.fmtTmpString(fmt, args);
    return ui.startWindow(str, size, pos);
}

pub fn startScrollViewF(ui: *UI, flags: Flags, comptime fmt: []const u8, args: anytype, init_args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.startScrollView(flags, str, init_args);
}

pub fn scrollbarF(ui: *UI, comptime fmt: []const u8, args: anytype, axis: Axis, content_size: f32, scroll_view_parent: *Node, opts: ScrollbarOptions) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.scrollbar(str, axis, content_size, scroll_view_parent, opts);
}

pub fn lineInputF(ui: *UI, comptime fmt: []const u8, args: anytype, input: *TextInput, opts: LineInputOptions) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.lineInput(str, input, opts);
}

pub fn textInputRawF(ui: *UI, comptime fmt: []const u8, args: anytype, input: *TextInput, opts: TextInputOptions) !Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.textInputRaw(str, input, opts);
}

pub fn colorPickerF(ui: *UI, comptime fmt: []const u8, args: anytype, color: *vec4) void {
    const str = ui.fmtTmpString(fmt, args);
    return ui.colorPicker(str, color);
}

pub fn pushLayoutParentF(ui: *UI, flags: Flags, comptime fmt: []const u8, args: anytype, size: [2]Size, layout_axis: Axis) *Node {
    const str = ui.fmtTmpString(fmt, args);
    return ui.pushLayoutParent(flags, str, size, layout_axis);
}

// make sure we don't forget to write the format string version of all the
// functions that have a '[]const u8' string parameter
comptime {
    const decls = @typeInfo(@This()).Struct.decls;
    for (decls) |decl| {
        const Decl = @TypeOf(@field(@This(), decl.name));
        if (@typeInfo(Decl) != .Fn) continue;
        if (decl.name[decl.name.len - 1] == 'F') continue;
        const str_param_idx: usize = idx: {
            for (@typeInfo(Decl).Fn.params, 0..) |param, p_idx| {
                if (param.type == []const u8) break :idx p_idx;
            }
            continue;
        };

        const fmt_fn_name = decl.name ++ "F";
        if (!@hasDecl(@This(), fmt_fn_name)) {
            @compileError("Missing format version of '" ++ decl.name ++ "'");
        }
        const fmt_params = @typeInfo(@TypeOf(@field(@This(), fmt_fn_name))).Fn.params;
        std.debug.assert(fmt_params[str_param_idx].type == []const u8);
        std.debug.assert(fmt_params[str_param_idx + 1].type == null);
    }
}
