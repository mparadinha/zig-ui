// there's no need to manually include this file, it's already provided by UI.zig

const std = @import("std");
const clamp = std.math.clamp;
const fabs = std.math.fabs;
const zig_ui = @import("../zig_ui.zig");
const vec2 = zig_ui.vec2;
const vec3 = zig_ui.vec3;
const vec4 = zig_ui.vec4;
const glfw = zig_ui.glfw;
const UI = @import("UI.zig");
const Node = UI.Node;
const Signal = UI.Signal;
const Rect = UI.Rect;
const Size = UI.Size;
const Axis = UI.Axis;
const Placement = UI.Placement;
const RelativePlacement = UI.RelativePlacement;
const Icons = UI.Icons;
const text_ops = @import("text_ops.zig");
const TextAction = text_ops.TextAction;

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

pub fn label(ui: *UI, str: []const u8) void {
    _ = ui.addNode(.{
        .no_id = true,
        .ignore_hash_sep = true,
        .draw_text = true,
    }, str, .{});
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

pub fn scrollableLabel(
    ui: *UI,
    hash: []const u8,
    size: [2]Size,
    str: []const u8,
) void {
    const p = ui.pushLayoutParent(.{
        .clip_children = true,
        .scroll_children_x = true,
        .scroll_children_y = true,
    }, hash, size, .y);
    defer ui.popParentAssert(p);
    ui.label(str);
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

pub fn button(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(.{
        .clickable = true,
        .draw_text = true,
        .draw_border = true,
        .draw_background = true,
        .draw_hot_effects = true,
        .draw_active_effects = true,
    }, str, .{
        .cursor_type = .pointing_hand,
    });
    return node.signal;
}

pub fn subtleButton(ui: *UI, str: []const u8) Signal {
    const node = ui.addNode(.{
        .clickable = true,
        .draw_text = true,
        .draw_active_effects = true,
    }, str, .{
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

pub fn slider(ui: *UI, name: []const u8, size: [2]Size, value_ptr: *f32, min: f32, max: f32) void {
    // TODO: also allow integer types for values
    // TODO: generalizing this to y-axis slider so it can be used for scroll bars and stuff like volume sliders
    // TODO: maybe add a more generic slider functions like `sliderOptions` or `sliderExtra` or `sliderOpts` or `sliderEx`

    value_ptr.* = clamp(value_ptr.*, min, max);

    const style = ui.topStyle();

    const scroll_zone = ui.pushLayoutParentF(.{
        .clickable = true,
    }, "{s}_slider", .{name}, size, .x);
    defer ui.popParentAssert(scroll_zone);

    const scroll_size = scroll_zone.rect.size();

    const handle_percent = (value_ptr.* - min) / (max - min);
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
        const percentage = clamp(scroll_zone.signal.mouse_pos[0] / scroll_zone.rect.size()[0], 0, 1);
        value_ptr.* = min + (max - min) * percentage;
    }

    value_ptr.* = clamp(value_ptr.*, min, max);
}

pub fn checkBox(ui: *UI, str: []const u8, value: *bool) Signal {
    const p_size = Size.fillByChildren(1, 1);
    const p = ui.pushLayoutParentF(.{ .draw_background = true }, "{s}_parent", .{str}, p_size, .x);
    defer ui.popParentAssert(p);

    const box_icon = if (value.*) Icons.ok else " ";
    const box_signal = ui.iconButtonF("{s}###{s}_button", .{ box_icon, str });
    if (box_signal.clicked) value.* = !value.*;

    ui.label(str);

    return box_signal;
}

pub fn toggleButton(ui: *UI, str: []const u8, start_open: bool) Signal {
    const click_region = ui.pushLayoutParentF(.{
        .toggleable = true,
    }, "{s}_click_region", .{str}, Size.fillByChildren(1, 1), .x);
    defer ui.popParentAssert(click_region);
    click_region.cursor_type = .pointing_hand;
    if (click_region.first_time) click_region.toggled = start_open;
    const signal = click_region.signal;

    const arrow = if (signal.toggled) Icons.down_open else Icons.right_open;
    ui.iconLabel(arrow);
    ui.label(str);

    return signal;
}

pub fn listBox(
    ui: *UI,
    hash: []const u8,
    size: [2]Size,
    choices: []const []const u8,
    chosen_idx: *usize,
) Signal {
    const scroll_region = ui.pushLayoutParent(.{
        .clip_children = true,
        .scroll_children_y = true,
    }, hash, size, .y);
    defer ui.popParentAssert(scroll_region);

    for (choices, 0..) |str, idx| {
        if (ui.button(str).pressed) chosen_idx.* = idx;
    }

    // TODO: scroll bar

    // TODO: return correct click signals
    return scroll_region.signal;
}

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
        _ = ui.listBox(hash, size, choices, chosen_idx);
    }

    // TODO: combine click+listbox signals
    return click_region.signal;
}

/// pushes a new node as parent that is meant only for layout purposes
pub fn pushLayoutParent(
    ui: *UI,
    flags: UI.Flags,
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

/// returns the new parent (which gets pushed on the parent stack) for this region
// TODO: scrolling in x direction as well
pub fn startScrollRegion(ui: *UI, hash: []const u8) *Node {
    const parent = ui.addNodeF(.{
        .scroll_children_y = true,
        .clip_children = true,
    }, "###{s}:scroll_region_parent", .{hash}, .{
        .layout_axis = .y,
    });
    ui.pushParent(parent);
    return parent;
}

pub fn endScrollRegion(ui: *UI, parent: *Node, start_scroll: f32, end_scroll: f32) void {
    const hash = parent.hash_string;

    const bar_node = ui.addNode(.{ .draw_background = true, .no_id = true, .floating_x = true }, "", .{});
    bar_node.layout_axis = .y;
    bar_node.size = [2]Size{ Size.children(1), Size.percent(1, 0) };
    bar_node.bg_color = vec4{ 0, 0, 0, 0.3 };
    bar_node.rel_pos = RelativePlacement.match(.top_right);
    {
        ui.pushParent(bar_node);
        defer std.debug.assert(ui.popParent() == bar_node);

        const up_btn = ui.subtleIconButtonF("{s}###{s}:up_scroll_btn", .{ Icons.up_open, hash });
        if (up_btn.held_down) parent.scroll_offset[1] += 50;

        const scroll_bar_region = ui.addNodeF(.{
            .clickable = true,
        }, "###{s}:scroll_bar_region", .{hash}, .{});
        scroll_bar_region.size = [2]Size{ Size.percent(1, 0), Size.percent(1, 0) };
        {
            ui.pushParent(scroll_bar_region);
            defer std.debug.assert(ui.popParent() == scroll_bar_region);

            const scroll_size = end_scroll - start_scroll;
            const bar_region_size = scroll_bar_region.rect.size()[1];
            const mouse_bar_pct = (scroll_bar_region.rect.max[1] - ui.mouse_pos[1]) / bar_region_size;
            const bar_pct = clamp(mouse_bar_pct, 0, 1);

            if (scroll_bar_region.signal.held_down) {
                parent.scroll_offset[1] = (scroll_size * bar_pct) + start_scroll;
            }

            const bar_icon_node = ui.addNodeF(.{
                .draw_text = true,
                .floating_y = true,
            }, "{s}###{s}:bar_btn", .{ Icons.circle, hash }, .{
                .font_type = .icon,
            });
            const icon_size = bar_icon_node.text_rect.size()[1];
            bar_icon_node.rel_pos = RelativePlacement.match(.top_left);
            bar_icon_node.rel_pos.diff[1] = if (bar_region_size > 0) blk: {
                const scroll_pct = clamp((parent.scroll_offset[1] - start_scroll) / scroll_size, 0, 1);
                break :blk -clamp(
                    (bar_region_size * scroll_pct) - (icon_size / 2),
                    0,
                    bar_region_size - icon_size,
                );
            } else 0;
        }

        const down_btn = ui.subtleIconButtonF("{s}###{s}:down_scroll_btn", .{ Icons.down_open, hash });
        if (down_btn.held_down) parent.scroll_offset[1] -= 50;
    }

    ui.popParentAssert(parent);
}

pub fn textInput(ui: *UI, hash: []const u8, buffer: []u8, buf_len: *usize) Signal {
    return textInputRaw(ui, hash, buffer, buf_len) catch |e| blk: {
        ui.setErrorInfo(@errorReturnTrace(), @errorName(e));
        break :blk std.mem.zeroes(Signal);
    };
}

pub fn textInputRaw(ui: *UI, hash: []const u8, buffer: []u8, buf_len: *usize) !Signal {
    const display_str = buffer[0..buf_len.*];
    // TODO: what is the point of writing this zero byte? the search/match code crashes when I remove it
    buffer[buf_len.*] = 0;

    // note: the node cursor/mark is in bytes into buffer

    const widget_node = ui.addNodeStringsF(.{
        .clickable = true,
        .selectable = true,
        .clip_children = true,
        .draw_background = true,
        .draw_border = true,
    }, "", .{}, "{s}", .{hash}, .{
        .layout_axis = .x,
        .cursor_type = .ibeam,
    });
    if (widget_node.first_time) {
        widget_node.cursor = buf_len.*;
        widget_node.mark = buf_len.*;
    }

    ui.pushParent(widget_node);
    defer ui.popParentAssert(widget_node);

    const sig = widget_node.signal;

    // make input box darker when not in focus
    if (!sig.focused) widget_node.bg_color = widget_node.bg_color * @as(vec4, @splat(0.85));

    // we can't use a simple label because the position of text_node needs to be saved across frames
    // (we can't just rely on the cursor for this information; imagine doing `End` + `LeftArrow`, for example)
    const text_node = ui.addNode(.{
        .draw_text = true,
        .floating_x = true,
        .ignore_hash_sep = true,
    }, display_str, .{
        .text_color = vec4{ 0, 0, 0, 1 },
    });

    const font_pixel_size = ui.topStyle().font_size;
    const text_padd = ui.textPadding(text_node);

    const rect_before_cursor = try ui.font.textRect(buffer[0..widget_node.cursor], font_pixel_size);
    const rect_before_mark = try ui.font.textRect(buffer[0..widget_node.mark], font_pixel_size);

    const cursor_height = ui.font.getScaledMetrics(font_pixel_size).line_advance - text_padd[1];
    const cursor_rel_pos = vec2{ rect_before_cursor.max[0], 0 } + text_padd;
    const selection_size = fabs(rect_before_mark.max[0] - rect_before_cursor.max[0]);
    const selection_start = @min(rect_before_mark.max[0], rect_before_cursor.max[0]);
    const selection_rel_pos = vec2{ selection_start, 0 } + text_padd;

    const filled_rect_flags = UI.Flags{
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
    _ = ui.addNode(filled_rect_flags, "", .{
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
            const partial_rect = try ui.font.textRect(partial_text_buf, font_pixel_size);
            if (partial_rect.max[0] + text_padd[0] > sig.mouse_pos[0]) break;
            idx += codepoint_len;
        }

        if (sig.held_down) widget_node.cursor = idx;
        if (sig.pressed) widget_node.mark = idx;
    }
    // TODO: doing a click followed by press and drag in the same timing as a double-click
    // does a selection but using the same "word scan" as the double click code path

    while (ui.events.next()) |event| {
        const has_selection = widget_node.cursor != widget_node.mark;
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
        const text_op = try text_ops.textOpFromAction(action, widget_node.cursor, widget_node.mark, &unicode_buf, cur_buf);

        text_ops.replaceRange(buffer, buf_len, .{ .start = text_op.range.start, .end = text_op.range.end }, text_op.replace_str);
        if (text_op.copy_str.len > 0) {
            const c_str = try ui.allocator.dupeZ(u8, text_op.copy_str);
            defer ui.allocator.free(c_str);
            glfw.setClipboardString(c_str);
        }
        widget_node.cursor = text_op.byte_cursor;
        widget_node.mark = text_op.byte_mark;
    }

    return sig;
}

const color_picker_cursor_radius = 10;
pub fn colorPicker(ui: *UI, hash: []const u8, color: *vec4) void {
    const square_px_size = 225; // 225/6 = 37.5 which is nice to avoid gaps in the hue bar nodes
    const square_size = Size.exact(.pixels, square_px_size, square_px_size);
    const hue_bar_size = Size.exact(.pixels, square_px_size / 10, square_px_size);

    var hsv = RGBtoHSV(color.*);

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
                const hue_color = HSVtoRGB(vec4{ hue[0], 1, 1, 1 });
                var rect = UI.ShaderInput.fromNode(node);
                rect.edge_softness = 0;
                rect.border_thickness = 0;
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
                    rect.border_thickness = 2;
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
                rect.border_thickness = 0;
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
                rect.border_thickness = 2;
                rect.corner_radii = [4]f32{ 2, 2, 2, 2 };
                const hsv0 = @as(*align(1) const f32, @ptrCast(node.custom_draw_ctx_as_bytes)).*;
                const bar_size: f32 = 10;
                const center_y = blk: {
                    var center = node.rect.max[1] - node.rect.size()[1] * hsv0;
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

    color.* = HSVtoRGB(hsv);

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
        ui.slider(slider_name, slider_size, &color_ptr[idx], 0, 1);
        ui.labelF("{s} {d:1.3}", .{ comp, color_ptr[idx] });
    }
}

fn RGBtoHSV(rgba: vec4) vec4 {
    const r = rgba[0];
    const g = rgba[1];
    const b = rgba[2];
    const x_max = @max(r, g, b);
    const x_min = @min(r, g, b);
    const V = x_max;
    const C = x_max - x_min;
    const H = if (C == 0)
        0
    else if (V == r)
        60 * @mod((g - b) / C, 6)
    else if (V == g)
        60 * (((b - r) / C) + 2)
    else if (V == b)
        60 * (((r - g) / C) + 4)
    else
        unreachable;
    const S_V = if (V == 0) 0 else C / V;

    return vec4{
        H / 360,
        S_V,
        V,
        rgba[3],
    };
}

fn HSVtoRGB(hsva: vec4) vec4 {
    const h = (hsva[0] * 360) / 60;
    const C = hsva[2] * hsva[1];
    const X = C * (1 - fabs(@mod(h, 2) - 1));
    const rgb_l = switch (@as(u32, @intFromFloat(@floor(h)))) {
        0 => vec3{ C, X, 0 },
        1 => vec3{ X, C, 0 },
        2 => vec3{ 0, C, X },
        3 => vec3{ 0, X, C },
        4 => vec3{ X, 0, C },
        else => vec3{ C, 0, X },
    };
    const m = hsva[2] - C;
    return vec4{
        rgb_l[0] + m,
        rgb_l[1] + m,
        rgb_l[2] + m,
        hsva[3],
    };
}

pub fn labelF(ui: *UI, comptime fmt: []const u8, args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    ui.label(str);
}

pub fn labelBoxF(ui: *UI, comptime fmt: []const u8, args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    ui.labelBox(str);
}

pub fn scrollableLabelF(ui: *UI, hash: []const u8, size: [2]Size, comptime fmt: []const u8, args: anytype) void {
    const str = ui.fmtTmpString(fmt, args);
    ui.scrollableLabel(hash, size, str);
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

pub fn checkBoxF(ui: *UI, comptime fmt: []const u8, args: anytype, value: *bool) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.checkBox(str, value);
}

pub fn toggleButtonF(ui: *UI, comptime fmt: []const u8, args: anytype, start_open: bool) Signal {
    const str = ui.fmtTmpString(fmt, args);
    return ui.toggleButton(str, start_open);
}

pub fn pushLayoutParentF(ui: *UI, flags: UI.Flags, comptime fmt: []const u8, args: anytype, size: [2]Size, layout_axis: Axis) *Node {
    const str = ui.fmtTmpString(fmt, args);
    return ui.pushLayoutParent(flags, str, size, layout_axis);
}
