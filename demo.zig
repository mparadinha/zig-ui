const std = @import("std");
const Allocator = std.mem.Allocator;
const zig_ui = @import("zig-ui");
const vec2 = zig_ui.vec2; // just `@Vector(2, f32)`, exported for convience
const vec4 = zig_ui.vec4;
const uvec2 = zig_ui.uvec2;
const gl = zig_ui.gl; // we also export our loaded gl functions if you want to use them
const gfx = zig_ui.gfx;
const glfw = zig_ui.glfw;
const Window = zig_ui.Window;
const UI = zig_ui.UI;

pub var prof = Profiler{};
const target_ms_per_frame: f32 = 1.0 / 60.0;

var gpa = std.heap.GeneralPurposeAllocator(.{
    // turning this on enables tracking of total allocation requests; the default
    // mem. limit is maxInt(usize), so we don't have to worry about that
    .enable_memory_limit = true,
}){};

pub fn main() !void {
    defer std.debug.assert(!gpa.detectLeaks());
    const allocator = gpa.allocator();

    var window = try Window.init(allocator, 1400, 800, "window title");
    window.finishSetup();
    defer window.deinit();

    var ui = try UI.init(allocator, .{});
    defer ui.deinit();
    // just an example. we can change these style variables at anytime
    ui.base_style.text_color = vec4{ 1, 1, 1, 1 };
    ui.base_style.border_thickness = 2;

    var dbg_ui_view = try UI.DebugView.init(allocator);
    defer dbg_ui_view.deinit();

    var text_input_backing_buffer: [1000]u8 = undefined;
    var demo = DemoState{
        .text_input = UI.TextInput.init(&text_input_backing_buffer, ""),
        .current_tabs = std.ArrayList(usize).init(allocator),
    };
    defer demo.current_tabs.deinit();
    var show_profiler = true;
    var profiler_graph_rect: UI.Rect = undefined;

    var last_time: f32 = @floatCast(glfw.getTime());
    while (!window.shouldClose()) {
        prof.markFrame();

        prof.startZoneN("main loop");
        defer prof.stopZone();

        var frame_arena_allocator = std.heap.ArenaAllocator.init(allocator);
        defer frame_arena_allocator.deinit();
        const frame_arena = frame_arena_allocator.allocator();

        glfw.swapInterval(if (demo.unlock_framerate) 0 else 1);

        // grab all window/input information we need for this frame
        const cur_time: f32 = @floatCast(glfw.getTime());
        const dt = cur_time - last_time;
        last_time = cur_time;
        const mouse_pos = window.getMousePos();
        const fbsize = window.getFramebufferSize();

        try ui.startBuild(fbsize[0], fbsize[1], mouse_pos, &window.event_queue, &window);
        try showDemo(allocator, &ui, mouse_pos, &window.event_queue, dt, &demo);
        if (show_profiler) profiler_graph_rect = showProfilerInfo(&ui, &prof);
        ui.endBuild(dt);

        if (window.event_queue.searchAndRemove(.KeyDown, .{
            .mods = .{ .control = true, .shift = true },
            .key = .d,
        })) dbg_ui_view.active = !dbg_ui_view.active;

        if (window.event_queue.searchAndRemove(.KeyDown, .{
            .mods = .{ .control = true, .shift = true },
            .key = .p,
        })) show_profiler = !show_profiler;

        window.clear(demo.clear_color);
        // <do whatever other rendering you want below the UI here>
        try ui.render();
        if (dbg_ui_view.active) try dbg_ui_view.show(&ui, fbsize[0], fbsize[1], mouse_pos, &window.event_queue, &window, dt);
        if (demo.show_zoom) try renderZoomDisplay(allocator, demo, fbsize);
        if (show_profiler) try renderProfilerGraph(allocator, &prof, profiler_graph_rect, fbsize);

        // @debug: print info about Node directly under cursor
        if (window.event_queue.searchAndRemove(.KeyDown, .{
            .mods = .{ .control = true, .shift = true },
            .key = .q,
        })) {
            var node_roots = std.ArrayList(*UI.Node).init(frame_arena);
            { // order copied from `UI.startBuild`
                if (ui.tooltip_root) |node| try node_roots.append(node);
                if (ui.ctx_menu_root) |node| try node_roots.append(node);
                var windows_done: usize = 0;
                while (windows_done < ui.window_roots.items.len) : (windows_done += 1) {
                    const node = ui.window_roots.items[ui.window_roots.items.len - 1 - windows_done];
                    try node_roots.append(node);
                }
                if (ui.root) |node| try node_roots.append(node);
            }
            const node = blk: {
                for (node_roots.items) |root| {
                    var node_it = UI.InputOrderNodeIterator.init(root);
                    while (node_it.next()) |node| {
                        if (node.rect.contains(mouse_pos)) break :blk node;
                    }
                }
                unreachable;
            };
            UI.printNode(node);
        }

        window.update();
    }
}

const DemoState = struct {
    // selected_tab: Tabs = .Basics,
    selected_tab: Tabs = .@"Perf. testing",

    clear_color: vec4 = vec4{ 0, 0, 0, 0.9 },
    demo_window_bg_color: vec4 = vec4{ 0.2, 0.4, 0.5, 0.5 },
    listbox_idx: usize = 0,
    measuring_square_start: ?vec2 = null,
    show_window_test: bool = false,
    text_input: UI.TextInput,
    created_tab_count: usize = 0,
    selected_tab_idx: usize = 0,
    current_tabs: std.ArrayList(usize),

    zoom_selecting_region: bool = false,
    zoom_snap_to_pixel: bool = false,
    zoom_display: UI.Rect = UI.Rect{ .min = vec2{ 0, 0 }, .max = vec2{ 0, 0 } },
    zoom_region: UI.Rect = UI.Rect{ .min = vec2{ 0, 0 }, .max = vec2{ 0, 0 } },

    // perf. testing stuff
    dummy_labels: usize = 250,
    auto_scale_dummy_labels: bool = false,

    show_debug_stats: bool = true,
    show_zoom: bool = false,
    unlock_framerate: bool = false,

    const Tabs = enum {
        Basics,
        Styling,
        @"Live Node Editor",
        @"Custom Texture",
        @"Perf. testing",
        @"Demo Config",
    };
};

const use_child_size = UI.Size.children2(1, 1);

fn showDemo(
    _: std.mem.Allocator,
    ui: *UI,
    mouse_pos: vec2,
    event_q: *Window.EventQueue,
    dt: f32,
    state: *DemoState,
) !void {
    prof.startZoneN("showDemo");
    defer prof.stopZone();

    const demo_p = ui.addNode(.{
        .draw_background = true,
    }, "demo_window", .{
        .bg_color = state.demo_window_bg_color,
        .size = UI.Size.exact(.percent, 1, 1),
        .layout_axis = .y,
    });
    ui.pushParent(demo_p);
    defer ui.popParentAssert(demo_p);

    _ = ui.enumTabList(DemoState.Tabs, &state.selected_tab);

    ui.startScrollView(.{
        .draw_border = true,
    }, "demo_tab", .{
        .size = UI.Size.flexible(.percent, 1, 1),
        .layout_axis = .y,
    });
    defer _ = ui.endScrollView(.{
        .bg_color = ui.base_style.bg_color,
        .handle_color = ui.base_style.border_color,
    });

    switch (state.selected_tab) {
        .Basics => try showDemoTabBasics(ui, state),
        .@"Demo Config" => showDemoTabConfig(ui, state),
        .@"Perf. testing" => showDemoTabPerfTesting(ui, state),
        else => ui.label("TODO"),
    }

    // measuring square
    if (event_q.matchAndRemove(.MouseDown, .{ .button = .middle })) |_|
        state.measuring_square_start = mouse_pos;
    if (event_q.matchAndRemove(.MouseUp, .{ .button = .middle })) |_|
        state.measuring_square_start = null;
    if (state.measuring_square_start) |start_pos| {
        const rect = UI.Rect{
            .min = @min(start_pos, mouse_pos),
            .max = @max(start_pos, mouse_pos),
        };
        const size = rect.size();
        _ = ui.addNode(.{
            .draw_background = true,
            .floating_x = true,
            .floating_y = true,
            .no_id = true,
        }, "", .{
            .bg_color = vec4{ 1, 1, 1, 0.3 },
            .size = UI.Size.exact(.pixels, size[0], size[1]),
            .rel_pos = UI.RelativePlacement.simple(rect.min),
        });
        ui.startTooltip(null);
        ui.labelF("{d}x{d}", .{ size[0], size[1] });
        ui.endTooltip();
    }

    // TODO: zoom region stuff
    // [ ] when user turn zoom on show a rectangle selection for the zoomed parted
    // [ ] add a node in the place of the zoom display
    // [ ] ctrl+drag on zoom display to move the zoomed in region around
    // [ ] normal drag to move zoom display around the demo window?
    // [ ] scroll on zoom display to set display level
    // [ ] zoom in/out around where cursor is when scrolled
    // [ ] add a toggle to add show the pixel grid when zoomed in (and maybe show the pixel coords as well)
    // [ ] display as part of the zoom display a little box with the current zoom level
    // TODO: check that `UI.Rect.at` isn't bugged
    const os_window_size = ui.root.?.rect;
    if (state.show_zoom) {
        const zoom_widget = ui.startWindow(
            "zoom_widget",
            UI.Size.children2(1, 1),
            UI.RelativePlacement.offset(.btm_right, vec2{ -4, 4 }),
        );
        defer ui.endWindow(zoom_widget);
        // TODO: drag `zoom_widget` to move it to a different place in the OS window
        if (false) {
            const sig = zoom_widget.signal;
            ui.labelF("zoom_widget drag vector: {d}", .{sig.mouse_pos - sig.drag_start});
        }

        ui.pushTmpStyle(.{ .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) } });
        if (ui.button("Select zoom region (press <ESC> to cancel)").clicked) {
            // TODO: only replace the selected region when we start dragging
            state.zoom_region = std.mem.zeroes(UI.Rect);
            state.zoom_selecting_region = true;
        }

        ui.pushTmpStyle(.{ .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) } });
        if (ui.button("Square zoom region").clicked) {
            const size = state.zoom_region.size();
            const side_len = @max(size[0], size[1]);
            state.zoom_region.max = state.zoom_region.min + vec2{ side_len, side_len };
        }

        {
            const display_box_size = 400;

            const coord_label = (struct {
                pub fn func(_ui: *UI, _coords: vec2) void {
                    _ui.labelF("{d:>4.0},{d:>4.0}", .{ _coords[0], _coords[1] });
                }
            }).func;

            ui.startLine();
            ui.pushStyle(.{ .font_size = 16 });
            coord_label(ui, state.zoom_region.get(.top_left));
            ui.spacer(.x, UI.Size.pixels(display_box_size, 1));
            coord_label(ui, state.zoom_region.get(.top_right));
            _ = ui.popStyle();
            ui.endLine();

            const zoom_display_box = ui.addNode(.{
                .clickable = true,
                .scroll_children_y = true, // just so we receive scroll inputs for zooming in/out
            }, "zoom_display_box", .{
                .size = UI.Size.exact(.pixels, display_box_size, display_box_size),
                .alignment = .center,
                .scroll_multiplier = vec2{ 1, 1 },
            });
            state.zoom_display = zoom_display_box.rect;
            const display_sig = zoom_display_box.signal;
            if (@reduce(.And, state.zoom_region.size() != vec2{ 0, 0 })) {
                const display_drag = display_sig.dragOffset();

                // drag inside display box to move zoomed region around
                const px_scale = state.zoom_region.size() / zoom_display_box.rect.size();
                const px_drag = display_drag * px_scale;
                if (!state.zoom_snap_to_pixel or @abs(px_drag[0]) >= 1 or @abs(px_drag[1]) >= 1) {
                    state.zoom_region = state.zoom_region.offset(-px_drag);
                    zoom_display_box.signal.drag_start = zoom_display_box.signal.mouse_pos;
                }

                // scroll inside display box to zoom in/out, centered on mouse position
                const scale = 1 - 0.1 * display_sig.scroll_amount[1];
                state.zoom_region = state.zoom_region.scale(@splat(scale));
            }

            ui.startLine();
            ui.pushStyle(.{ .font_size = 16 });
            coord_label(ui, state.zoom_region.get(.btm_left));
            ui.spacer(.x, UI.Size.pixels(display_box_size, 1));
            coord_label(ui, state.zoom_region.get(.btm_right));
            _ = ui.popStyle();
            ui.endLine();
        }

        _ = ui.checkBox("Snap to pixel grid", &state.zoom_snap_to_pixel);

        state.zoom_region = state.zoom_region.clamp(os_window_size);
        if (state.zoom_snap_to_pixel) {
            state.zoom_region.min = @round(state.zoom_region.min);
            state.zoom_region.max = @round(state.zoom_region.max);
        }
    }
    if (state.zoom_selecting_region) {
        if (ui.events.searchAndRemove(.KeyDown, .{ .mods = .{}, .key = .escape }))
            state.zoom_selecting_region = false;

        const selection_window = ui.startWindow(
            "zoom_selection_window",
            UI.Size.exact(.percent, 1, 1),
            UI.RelativePlacement.match(.center),
        );
        defer ui.endWindow(selection_window);

        const selection_zone = ui.addNode(.{
            .draw_background = true,
            .clickable = true,
        }, "selection_zone", .{
            .bg_color = vec4{ 0, 0, 0, 0.2 },
            .size = UI.Size.exact(.percent, 1, 1),
        });
        ui.pushParent(selection_zone);
        defer ui.popParentAssert(selection_zone);
        const selected_rect = blk: {
            const rect = selection_zone.signal.dragRect();
            break :blk rect;
            // TODO: square the selection rectangle
            // const size = rect.size();
            // const max_size = @max(size[0], size[1]);
            // break :blk UI.Rect{ .min = rect.min, .max = rect.min + vec2{ max_size, max_size } };
        };

        const empty_selection = @reduce(.And, state.zoom_region.size() == vec2{ 0, 0 });
        if (!selection_zone.signal.held_down and !empty_selection) {
            state.zoom_selecting_region = false;
        } else {
            state.zoom_region = selected_rect.intersection(os_window_size);
            ui.box(state.zoom_region, .{
                .bg_color = vec4{ 1, 1, 1, 0.3 },
                .border_color = vec4{ 1, 1, 1, 0.8 },
            });
        }
    }

    // show at the end, to get more accurate stats for this frame
    if (state.show_debug_stats) {
        const stats_window = ui.startWindow(
            "debug stats window",
            UI.Size.fillByChildren(1, 1),
            UI.RelativePlacement.match(.top_right),
        );
        defer ui.endWindow(stats_window);
        ui.labelF("mouse_pos={d}", .{ui.mouse_pos});
        ui.labelF("frame_idx={d}", .{ui.frame_idx});
        ui.labelF("{d:4.2} fps", .{1 / dt});
        ui.labelF("# of nodes: {}", .{ui.node_table.count()});
        ui.labelF("build_arena capacity: {:.2}", .{
            std.fmt.fmtIntSizeBin(ui.build_arena.queryCapacity()),
        });
        ui.labelF("gpa.total_requested_bytes: {:.2}", .{
            std.fmt.fmtIntSizeBin(gpa.total_requested_bytes),
        });
        {
            var statm_file = try std.fs.openFileAbsolute("/proc/self/statm", .{});
            defer statm_file.close();
            var buf: [512]u8 = undefined;
            _ = try statm_file.readAll(&buf);
            var it = std.mem.tokenizeAny(u8, &buf, " \t\n");
            const total_page_count = try std.fmt.parseUnsigned(usize, it.next().?, 0);
            const resident_page_count = try std.fmt.parseUnsigned(usize, it.next().?, 0);
            const shared_page_count = try std.fmt.parseUnsigned(usize, it.next().?, 0);

            const page_size = 4 * 1024;
            ui.labelF("total mem.: {:.2}", .{std.fmt.fmtIntSizeBin(total_page_count * page_size)});
            ui.labelF("resident mem.: {:.2}", .{std.fmt.fmtIntSizeBin(resident_page_count * page_size)});
            ui.labelF("shared mem.: {:.2}", .{std.fmt.fmtIntSizeBin(shared_page_count * page_size)});
        }
    }
}

fn showDemoTabBasics(ui: *UI, state: *DemoState) !void {
    const separator_args = .{
        .bg_color = vec4{ 1, 1, 1, 1 },
        .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.pixels(4, 1) },
        .corner_radii = [4]f32{ 2, 2, 2, 2 },
        .outer_padding = vec2{ 10, 5 },
        .alignment = .center,
    };
    const section_title_style = .{
        .font_type = .bold,
        .alignment = .center,
    };

    ui.label("Labels are for blocks of text with no interactivity.");
    ui.labelBox("You can use `labelBox` instead, if you want a background/borders");
    ui.labelBox(
        \\If the label text has newlines ('\n') in it, like this:
        \\then it will take up the necessary vertical space.
    );

    ui.shape(separator_args);
    ui.pushTmpStyle(section_title_style);
    ui.label("Node alignment");
    {
        ui.label("Each node alignment can specify it's alignment relative to the parent:");

        const sides = ui.pushLayoutParent(.{ .no_id = true }, "", use_child_size, .x);
        defer ui.popParentAssert(sides);

        inline for (@typeInfo(UI.Axis).Enum.fields) |axis_field| {
            const axis: UI.Axis = @enumFromInt(axis_field.value);

            const p = ui.pushLayoutParent(.{ .no_id = true }, "", UI.Size.fillByChildren(1, 1), .y);
            defer ui.popParentAssert(p);

            ui.labelF("when the parent's `layout_axis` is `UI.Axis.{s}`:", .{axis_field.name});
            const align_p_size = switch (axis) {
                .x => [2]UI.Size{ UI.Size.children(1), UI.Size.pixels(100, 0) },
                .y => [2]UI.Size{ UI.Size.pixels(300, 0), UI.Size.children(1) },
            };
            const align_p = ui.pushLayoutParent(.{ .draw_border = true, .no_id = true }, "", align_p_size, axis);
            defer ui.popParentAssert(align_p);

            inline for (@typeInfo(UI.Alignment).Enum.fields) |alignment_field| {
                const alignment: UI.Alignment = @enumFromInt(alignment_field.value);
                ui.pushTmpStyle(.{ .alignment = alignment });
                ui.labelBoxF("UI.Alignment.{s}", .{alignment_field.name});
            }
        }
    }

    ui.shape(separator_args);
    ui.pushTmpStyle(section_title_style);
    ui.label("Text truncation");
    {
        const sides = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{
            UI.Size.percent(1, 0), UI.Size.children(1),
        }, .x);
        defer ui.popParentAssert(sides);
        for ([2]bool{ true, false }) |disable_truncation| {
            const p = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{
                UI.Size.percent(0.5, 0), UI.Size.children(1),
            }, .y);
            defer ui.popParentAssert(p);
            ui.labelF("with `.flags.disable_text_truncation = {s}`", .{if (disable_truncation) "true" else "false"});
            for ([_]f32{ 100, 200, 300, 400 }) |width| {
                _ = ui.addNode(.{
                    .draw_text = true,
                    .draw_border = true,
                    .no_id = true,
                    .clip_children = true,
                    .disable_text_truncation = disable_truncation,
                }, "The quick brown fox jumps over the lazy dog.", .{
                    .size = [2]UI.Size{ UI.Size.pixels(width, 1), UI.Size.text(1) },
                });
            }
        }
    }

    if (ui.toggleButton("Color pickers:", true).toggled) {
        const sides = ui.pushLayoutParent(.{ .no_id = true, .draw_border = true }, "", use_child_size, .x);
        defer ui.popParentAssert(sides);
        {
            const p = ui.pushLayoutParent(.{ .no_id = true }, "", use_child_size, .y);
            defer ui.popParentAssert(p);
            ui.label("demo background color");
            ui.colorPicker("demo bg color", &state.demo_window_bg_color);
        }
        ui.spacer(.x, UI.Size.pixels(10, 1));
        {
            const p = ui.pushLayoutParent(.{ .no_id = true }, "", use_child_size, .y);
            defer ui.popParentAssert(p);
            ui.label("screen clear color");
            ui.colorPicker("clear color", &state.clear_color);
        }
    }

    const choices = [_][]const u8{ "Choice A", "Choice B", "Choice C", "Choice D", "Choice E", "Choice F" };
    ui.labelF("Current choice: {s}", .{choices[state.listbox_idx]});
    _ = ui.stringsListBox("listbox_test", UI.Size.exact(.pixels, 200, 100), &choices, &state.listbox_idx);
    ui.label("Drop down list:");
    _ = ui.dropDownList("dropdownlist_test", .{ UI.Size.children(1), UI.Size.pixels(80, 1) }, &choices, &state.listbox_idx);

    if (ui.text("Some text with a tooltip").hovering) {
        ui.startTooltip(null);
        ui.label("Tooltip text");
        ui.endTooltip();
    }

    {
        ui.startLine();
        defer ui.endLine();
        ui.label("Multiple widgets on a single line:");
        _ = ui.button("A useless button");
        ui.iconLabel(UI.Icons.cog);
        _ = ui.button("Another button");
    }

    ui.label("Valid unicode, but not present in default font (should render the `missing char` box): \u{1b83}");

    if (state.show_window_test) {
        const window_root = ui.startWindow(
            "test_window",
            UI.Size.exact(.pixels, 500, 500),
            UI.RelativePlacement{ .target = .center, .anchor = .center },
        );
        defer ui.endWindow(window_root);
        if (ui.button("Close test window").clicked) state.show_window_test = false;
    } else {
        if (ui.button("Open test window").clicked) state.show_window_test = true;
    }

    if (ui.button("Dump root node tree to `ui_main_tree.dot`").clicked) {
        const path = "ui_main_tree.dot";
        const dump_file = try std.fs.cwd().createFile(path, .{});
        defer dump_file.close();
        try ui.dumpNodeTreeGraph(ui.root.?, dump_file);
    }

    {
        const p = ui.pushLayoutParent(.{}, "text_input_p", [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.children(1) }, .x);
        defer ui.popParentAssert(p);
        ui.labelBoxF("A text input box (length of input: {:3>}):", .{state.text_input.bufpos});
        ui.pushTmpStyle(.{ .bg_color = vec4{ 0.75, 0.75, 0.75, 1 } });
        _ = ui.lineInput("testing_text_input", &state.text_input, .{ .default_str = "<default string>" });
    }

    // tabbed content
    {
        const tabbed_panel_size = UI.Size.exact(.pixels, 300, 400); // includes tab list
        const tab_opts = UI.TabOptions{
            .active_tab_bg = UI.colorFromRGB(0x6f, 0x51, 0x35),
            .inactive_tab_bg = UI.colorFromRGB(0x2c, 0x33, 0x39),
            .tabbed_content_border = UI.colorFromRGB(0xc1, 0x80, 0x0b),
            .close_btn = true,
        };
        const tabbed_content_border = UI.colorFromRGB(0xc1, 0x80, 0x0b);

        const tabbed_panel_p = ui.addNode(.{}, "tabbed_panel", .{ .size = tabbed_panel_size });
        ui.pushParent(tabbed_panel_p);
        defer ui.popParentAssert(tabbed_panel_p);
        {
            // TODO: allow opt-out/in of the ctrl+{shift}+tab behavior of cycling through tabs
            ui.startTabList();

            var tab_idx_to_remove: ?usize = null;
            for (state.current_tabs.items, 0..) |tab_name, tab_idx| {
                const is_selected = (tab_idx == state.selected_tab_idx);
                const tab_sig = ui.tabButtonF("Tab #{} title", .{tab_name}, is_selected, tab_opts);
                if (tab_sig.tab.clicked) state.selected_tab_idx = tab_idx;
                if (tab_sig.close.clicked) tab_idx_to_remove = tab_idx;
            }
            // TODO: drop shadow on selected tab? must draw shadow on top of its siblings
            // TODO: when the tabs dont fit scroll & clip them so '+' button is always present
            if (ui.subtleIconButton(UI.Icons.plus_circled).clicked) {
                try state.current_tabs.append(state.created_tab_count);
                state.created_tab_count += 1;
            }
            ui.endTabList();

            if (tab_idx_to_remove) |tab_idx| {
                _ = state.current_tabs.orderedRemove(tab_idx);
                // TODO: this 'which tab gets selected when cur. selected tab is close'
                // behavior should be configurable by the user via some tab options
                if (tab_idx == state.selected_tab_idx) {
                    state.selected_tab_idx = if (tab_idx > 0) tab_idx - 1 else 0;
                }
            }
        }
        {
            const tabbed_panel_content_p = ui.addNode(.{
                .draw_border = true,
            }, "tab_content", .{
                .border_color = tabbed_content_border,
                .size = [2]UI.Size{ UI.Size.percent(1, 1), UI.Size.percent(1, 0) },
                .inner_padding = vec2{ 2, 2 },
            });
            ui.pushParent(tabbed_panel_content_p);
            defer ui.popParentAssert(tabbed_panel_content_p);

            ui.labelBox("TESTING");
            if (ui.subtleButton("Show tabbed_panel_p border").hovering) {
                tabbed_panel_p.flags.draw_border = true;
                tabbed_panel_p.border_thickness = 1;
                tabbed_panel_p.border_color = vec4{ 1, 0, 0.2, 1 };
            }
        }
    }
}

fn showDemoTabConfig(ui: *UI, state: *DemoState) void {
    _ = ui.checkBox("Toggle debug stats in the corner", &state.show_debug_stats);
    _ = ui.checkBox("Hot-reload UI shaders", &UI.hot_reload_shaders);
    _ = ui.checkBox("Show zoom display", &state.show_zoom);
    _ = ui.checkBox("Unlock framerate", &state.unlock_framerate);
}

fn showDemoTabPerfTesting(ui: *UI, state: *DemoState) void {
    _ = ui.checkBox("Scale dummy label count to target 60fps", &state.auto_scale_dummy_labels);
    if (state.auto_scale_dummy_labels) {
        if (prof.frame_idx > 0) {
            const dt_diff = prof.frame_times[prof.frame_idx - 1] - target_ms_per_frame;
            if (dt_diff > 0.001) state.dummy_labels -= 1;
            if (dt_diff < -0.001) state.dummy_labels += 1;
        }
    } else {
        ui.startLine();
        defer ui.endLine();
        ui.labelF("{: >4}", .{state.dummy_labels});
        const slider_size = [2]UI.Size{ UI.Size.em(50, 1), UI.Size.em(1, 1) };
        ui.slider(usize, "dummy_label_slider", slider_size, &state.dummy_labels, 0, 5000);
    }
    if (ui.toggleButton("Static labels", false).toggled) {
        for (0..state.dummy_labels) |idx| ui.labelF("label #{}", .{idx});
    }
    if (ui.toggleButton("Dynamic labels", true).toggled) {
        for (0..state.dummy_labels) |idx| ui.labelF("label #{}: frame_idx+label_idx={}", .{ idx, idx + ui.frame_idx });
    }
}

fn renderZoomDisplay(allocator: Allocator, demo: DemoState, fbsize: uvec2) !void {
    const save_screenshot = false;

    const bytes = try allocator.alloc(u8, 4 * fbsize[0] * fbsize[1]);
    defer allocator.free(bytes);
    gl.readPixels(0, 0, @intCast(fbsize[0]), @intCast(fbsize[1]), gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(bytes));

    blk: {
        const tex_quad_shader = gfx.Shader.from_files(allocator, "textured_quad", .{
            .vertex = "test_zoom.vert",
            .fragment = "test_zoom.frag",
        }) catch break :blk;
        // const tex_quad_shader = try gfx.Shader.from_srcs(allocator, "textured_quad", .{
        //     .vertex =
        //     \\#version 330 core
        //     \\layout (location = 0) in vec2 in_pos;
        //     \\uniform vec2 size;
        //     \\uniform vec2 btm_left;
        //     \\uniform vec2 uv_size;
        //     \\uniform vec2 uv_btm_left;
        //     \\out vec2 pass_uv;
        //     \\void main() {
        //     \\    gl_Position = vec4((in_pos * size) + btm_left, 0, 1);
        //     \\    pass_uv = (in_pos * uv_size) + uv_btm_left;
        //     \\}
        //     ,
        //     .fragment =
        //     \\#version 330 core
        //     \\in vec2 pass_uv;
        //     \\uniform sampler2D img;
        //     \\out vec4 color;
        //     \\void main() { color = vec4(texture(img, pass_uv).rgb, 1); }
        //     ,
        // });
        defer tex_quad_shader.deinit();
        // TODO: just recreate mesh every frame and use the vert data instead of all those uniforms
        const tex_quad_mesh = gfx.Mesh.init(
            &.{ 0, 0, 1, 0, 1, 1, 0, 1 },
            &.{ 0, 1, 2, 0, 2, 3 },
            &.{.{ .n_elems = 2 }},
        );
        defer tex_quad_mesh.deinit();

        var tex_quad_tex = gfx.Texture.init(fbsize[0], fbsize[1], gl.RGBA, bytes, gl.TEXTURE_2D, &.{
            .{ .name = gl.TEXTURE_MIN_FILTER, .value = gl.LINEAR },
            .{ .name = gl.TEXTURE_MAG_FILTER, .value = gl.NEAREST },
        });
        defer tex_quad_tex.deinit();
        tex_quad_shader.bind();
        const window_size: vec2 = @floatFromInt(fbsize);
        tex_quad_shader.set("total_size", window_size);
        tex_quad_shader.set("region_size", demo.zoom_region.size());
        tex_quad_shader.set("region_btm_left", demo.zoom_region.min);
        tex_quad_shader.set("display_size", demo.zoom_display.size());
        tex_quad_shader.set("display_btm_left", demo.zoom_display.min);
        tex_quad_shader.set("img", @as(i32, 0));
        tex_quad_tex.bind(0);
        tex_quad_mesh.draw();
    }

    if (save_screenshot) {
        const file = try std.fs.cwd().createFile("screenshot.ppm", .{});
        defer file.close();
        const writer = file.writer();
        try writer.print("P6\n{} {}\n255\n", .{ fbsize[0], fbsize[1] });
        const ppm_bytes = try allocator.alloc(u8, 3 * fbsize[0] * fbsize[1]);
        defer allocator.free(ppm_bytes);
        var i: usize = 0;
        for (0..fbsize[1]) |row| {
            const rowsize = 4 * fbsize[0];
            const rowbytes = bytes[(fbsize[1] - 1 - row) * rowsize ..][0..rowsize];
            for (rowbytes, 0..) |byte, idx| {
                if (idx % 4 == 3) continue;
                ppm_bytes[i] = byte;
                i += 1;
            }
        }
        _ = try file.write(ppm_bytes);
        std.debug.print("saved screenshot to 'screenshot.ppm'\n", .{});
    }
}

const StaticHashTable = zig_ui.utils.StaticHashTable;
const reduceSlice = zig_ui.utils.reduceSlice;
const binOpSlices = zig_ui.utils.binOpSlices;

pub const Profiler = struct {
    zone_table: ZoneTable = .{},
    zone_stack: std.BoundedArray(*Zone, max_zone_nesting) = .{},
    frame_times: [Zone.number_of_samples]f32 = [_]f32{0} ** Zone.number_of_samples,
    frame_start: Zone.Timestamp = 0,
    frame_idx: usize = 0,
    self_zone: Zone = .{ .name = "Profiler", .color = defaultColor("Profiler") },

    const ZoneTable = StaticHashTable([]const u8, Zone, bucket_count, bucket_entries);
    pub const bucket_count = 32;
    pub const bucket_entries = 5;
    pub const max_zone_nesting = 32;

    pub fn markFrame(self: *Profiler) void {
        self.self_zone.start();
        defer _ = self.self_zone.stop();

        // don't count start up as 1st frame
        if (self.frame_start == 0) {
            self.frame_start = Zone.timestamp();
            return;
        }

        var zone_iter = self.zoneIterator(true, false);
        while (zone_iter.next()) |zone| zone.commit();

        const new_frame_start = Zone.timestamp();
        const elapsed_ns: f32 = @floatFromInt(new_frame_start - self.frame_start);
        self.frame_start = new_frame_start;

        const frame_slice_idx = (self.frame_idx % self.frame_times.len);
        self.frame_times[frame_slice_idx] = elapsed_ns / std.time.ns_per_s;
        self.frame_idx += 1;
    }

    fn defaultColor(name: []const u8) vec4 {
        const hash = ZoneTable.hashFromKey(name);
        return UI.colorFromRGB(
            @intCast((hash >> 0) & 0xff),
            @intCast((hash >> 8) & 0xff),
            @intCast((hash >> 16) & 0xff),
        );
    }

    pub fn startZoneN(self: *Profiler, comptime name: []const u8) void {
        self.self_zone.start();
        defer _ = self.self_zone.stop();

        const hash = comptime ZoneTable.hashFromKey(name);
        const gop = self.zone_table.getOrPutHash(hash) catch @panic("OOM");
        const zone = gop.value;
        if (!gop.found_existing) {
            zone.* = .{ .name = name, .color = comptime defaultColor(name) };
        }
        zone.start();
        self.zone_stack.append(zone) catch @panic("OOM");
    }

    pub fn stopZone(self: *Profiler) void {
        self.self_zone.start();
        defer _ = self.self_zone.stop();

        const zone = self.zone_stack.pop();
        const zone_time = zone.elapsed();
        if (zone.stop() and self.zone_stack.len > 0) {
            const parent = self.zone_stack.slice()[self.zone_stack.len - 1];
            parent.acc_child_sample += zone_time;
        }
    }

    pub const ZoneIterator = struct {
        profiler: *Profiler,
        include_profiler: bool,
        only_displayed_zones: bool,
        zone_it: ZoneTable.Iterator,
        returned_profiler_zone: bool = false,

        pub fn next(self: *ZoneIterator) ?*Zone {
            if (self.include_profiler and !self.returned_profiler_zone) {
                self.returned_profiler_zone = true;
                if (!self.only_displayed_zones or self.profiler.self_zone.display)
                    return &self.profiler.self_zone;
            }
            var entry = self.zone_it.next() orelse return null;
            if (self.only_displayed_zones) {
                while (!entry.value.display) entry = self.zone_it.next() orelse return null;
            }
            return entry.value;
        }
    };

    pub fn zoneIterator(self: *Profiler, include_profiler: bool, only_displayed_zones: bool) ZoneIterator {
        return .{
            .profiler = self,
            .include_profiler = include_profiler,
            .only_displayed_zones = only_displayed_zones,
            .zone_it = self.zone_table.iterator(),
        };
    }
};

pub const Zone = struct {
    samples: [number_of_samples]f32 = [_]f32{0} ** number_of_samples,
    sample_counter: [number_of_samples]u32 = [_]u32{0} ** number_of_samples,
    child_samples: [number_of_samples]f32 = [_]f32{0} ** number_of_samples,
    idx: usize = 0,

    start_timestamp: ?Timestamp = null,
    recursion_level: u8 = 0,
    acc_sample: Timestamp = 0,
    acc_counter: u32 = 0,
    acc_child_sample: Timestamp = 0,

    name: []const u8,
    color: vec4,
    display: bool = true,

    pub const Timestamp = i128;
    // in testing locally I observed that `std.time.nanoTimestamp` took
    // around 38ns/call (20ns/call in release mode) while using `std.time.Timer`
    // took around 71ns/call (24ns/call in release mode)
    pub const timestamp = std.time.nanoTimestamp;

    const number_of_samples = 1024;

    pub fn start(self: *Zone) void {
        // for recursing functions we ignore the nested starts/stops
        if (self.start_timestamp) |_| {
            self.recursion_level += 1;
        } else {
            self.start_timestamp = timestamp();
        }
    }

    pub fn elapsed(self: *Zone) Timestamp {
        return timestamp() - self.start_timestamp.?;
    }

    /// Returns `false` when we are stopping inside a recursion
    pub fn stop(self: *Zone) bool {
        // for recursing functions we ignore the nested starts/stops time
        // but keep the call counter
        self.acc_counter += 1;
        if (self.recursion_level == 0) {
            self.acc_sample += self.elapsed();
            self.start_timestamp = null;
            return true;
        } else {
            self.recursion_level -= 1;
            return false;
        }
    }

    pub fn commit(self: *Zone) void {
        self.samples[self.idx] = @as(f32, @floatFromInt(self.acc_sample)) / std.time.ns_per_s;
        self.sample_counter[self.idx] = self.acc_counter;
        self.child_samples[self.idx] = @as(f32, @floatFromInt(self.acc_child_sample)) / std.time.ns_per_s;
        self.acc_sample = 0;
        self.acc_counter = 0;
        self.acc_child_sample = 0;
        self.idx += 1;
        self.idx %= number_of_samples;
    }
};

const ProfilerDisplay = struct {
    mode: Mode = .sample_time,
    max_y: f32 = target_ms_per_frame * max_y_leeway_multiplier,
    include_children: bool = true,

    pub const Mode = enum { sample_time, call_count };

    pub const max_y_leeway_multiplier = 1.05;
};
var profiler_display = ProfilerDisplay{};

fn helperShowNodeTableHist(ui: *UI) void {
    prof.startZoneN("helperShowNodeTableHist");
    defer prof.stopZone();

    ui.pushStyle(.{ .font_size = 14 });
    defer _ = ui.popStyle();
    _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.children(1) }, .x);
    defer _ = ui.popParent();
    const max_bar_height = 100; // in px
    var max_count: usize = 0;
    for (ui.node_table.buckets) |bucket| {
        max_count = @max(max_count, bucket.count());
    }
    for (ui.node_table.buckets, 0..) |bucket, idx| {
        _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.children(1) }, .y);
        defer _ = ui.popParent();
        _ = ui.addNodeF(.{
            .draw_text = true,
            .draw_background = true,
            .draw_border = true,
            .no_id = true,
            .disable_text_truncation = true,
        }, "{:0>2}", .{idx}, .{
            .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) },
            .text_align = .center,
        });
        const count = bucket.count();
        _ = ui.addNodeF(.{
            .draw_text = true,
            .no_id = true,
            .disable_text_truncation = true,
        }, "{:0>2}", .{count}, .{
            .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) },
            .text_align = .center,
        });
        const bar_size = max_bar_height * @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(max_count));
        _ = ui.addNode(.{
            .draw_border = true,
            .draw_background = true,
            .no_id = true,
        }, "", .{ .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.pixels(bar_size, 1) } });
    }
}
const ColInfo = struct {
    name: []const u8,
    size: f32, // in pixels
};
fn showTableHeader(ui: *UI, cols: []ColInfo, sorted_col: *usize, reverse: *bool) void {
    ui.startLine();
    defer ui.endLine();
    for (cols, 0..) |col, col_idx| {
        var flags = UI.button_flags;
        flags.draw_text = false;
        flags.draw_background = false;
        const btn = ui.addNodeF(flags, "###{}_header", .{col_idx}, .{
            .size = [2]UI.Size{ UI.Size.pixels(col.size, 1), UI.Size.children(1) },
            .cursor_type = .pointing_hand,
            .layout_axis = .x,
        });
        {
            ui.pushParent(btn);
            ui.label(col.name);
            ui.spacer(.x, UI.Size.percent(1, 0));
            if (sorted_col.* == col_idx) {
                ui.iconLabel(if (reverse.*) UI.Icons.down_open else UI.Icons.up_open);
            }
            _ = ui.popParent();
        }
        if (btn.signal.clicked) {
            if (sorted_col.* == col_idx) reverse.* = !reverse.*;
            sorted_col.* = col_idx;
        }
    }
}
fn startColEntry(ui: *UI, cols: []ColInfo, col_idx: *usize) void {
    const col_entry_p = ui.addNode(.{
        .draw_border = true,
        .no_id = true,
    }, "", .{
        .size = [2]UI.Size{ UI.Size.pixels(cols[col_idx.*].size, 1), UI.Size.children(1) },
        .layout_axis = .x,
    });
    ui.pushParent(col_entry_p);
}
fn endColEntry(ui: *UI, _: []ColInfo, col_idx: *usize) void {
    _ = ui.popParent(); // col_entry_p
    col_idx.* += 1;
}
var zone_table_cols = [_]ColInfo{
    .{ .name = "zone", .size = 275 },
    .{ .name = "% of frame", .size = 125 },
    .{ .name = "ms/frame", .size = 100 },
    .{ .name = "calls/frame", .size = 125 },
    .{ .name = "μs/call", .size = 100 },
};
var zone_table_sorted_col: usize = 1;
var zone_table_sorted_col_reverse: bool = true;
fn helperShowZoneTable(ui: *UI, profiler: *Profiler) void {
    prof.startZoneN("helperShowZoneTable");
    defer prof.stopZone();

    _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.children(1), UI.Size.percent(1, 0) }, .y);
    defer _ = ui.popParent();

    const n_samples = @min(Zone.number_of_samples, profiler.frame_idx);
    const frame_times = profiler.frame_times[0..n_samples];

    const TableEntry = struct {
        zone: *Zone,
        avg_pct_of_frame: f32,
        avg_s_per_frame: f32,
        avg_calls_per_frame: f32,
        avg_s_per_call: f32,

        pub fn fromZone(zone: *Zone, frame_samples: []const f32, used_samples: usize, include_children: bool) @This() {
            std.debug.assert(used_samples == frame_samples.len);
            const samples = zone.samples[0..used_samples];
            const child_samples = zone.child_samples[0..used_samples];
            const sample_counter = zone.sample_counter[0..used_samples];
            const total_pct_of_frame: f32 = sum: {
                var tmp_buf: [Zone.number_of_samples]f32 = undefined;
                const tmp = tmp_buf[0..used_samples];
                @memcpy(tmp, samples);
                if (!include_children) binOpSlices(f32, .Sub, tmp, tmp, child_samples);
                binOpSlices(f32, .Div, tmp, tmp, frame_samples);
                break :sum reduceSlice(f32, .Add, tmp);
            };
            const total_time = if (include_children)
                reduceSlice(f32, .Add, samples)
            else
                reduceSlice(f32, .Add, samples) - reduceSlice(f32, .Add, child_samples);
            const total_calls: f32 = @floatFromInt(reduceSlice(u32, .Add, sample_counter));
            const total_s_per_call = sum: {
                var tmp_buf: [Zone.number_of_samples]f32 = undefined;
                const tmp = tmp_buf[0..used_samples];
                @memcpy(tmp, samples);
                if (!include_children) binOpSlices(f32, .Sub, tmp, tmp, child_samples);
                var tmp_counter_buf: [Zone.number_of_samples]f32 = undefined;
                const tmp_counter = tmp_counter_buf[0..used_samples];
                for (tmp_counter, 0..) |*v, idx| v.* = @floatFromInt(@max(sample_counter[idx], 1));
                binOpSlices(f32, .Div, tmp, tmp, tmp_counter);
                break :sum reduceSlice(f32, .Add, tmp);
            };
            const n_samples_f: f32 = @floatFromInt(used_samples);
            return .{
                .zone = zone,
                .avg_pct_of_frame = total_pct_of_frame / n_samples_f,
                .avg_s_per_frame = total_time / n_samples_f,
                .avg_calls_per_frame = total_calls / n_samples_f,
                .avg_s_per_call = total_s_per_call / n_samples_f,
            };
        }
    };
    const table_lines = blk: {
        const line_count = (Profiler.bucket_count * Profiler.bucket_entries) + 1;
        var array = std.BoundedArray(TableEntry, line_count){};

        var zone_it = profiler.zoneIterator(true, false);
        while (zone_it.next()) |zone| {
            array.append(TableEntry.fromZone(zone, frame_times, n_samples, profiler_display.include_children)) catch unreachable;
        }

        prof.startZoneN("sort table entries");
        const SortCtx = struct { sort_col_idx: usize, reverse: bool };
        std.sort.insertion(TableEntry, array.slice(), SortCtx{
            .sort_col_idx = zone_table_sorted_col,
            .reverse = zone_table_sorted_col_reverse,
        }, (struct {
            pub fn func(ctx: SortCtx, lhs: TableEntry, rhs: TableEntry) bool {
                const less_than = switch (ctx.sort_col_idx) {
                    0 => blk: {
                        var idx: usize = 0;
                        while (idx < @min(lhs.zone.name.len, rhs.zone.name.len)) : (idx += 1) {
                            if (lhs.zone.name[idx] != rhs.zone.name[idx])
                                break :blk lhs.zone.name[idx] < rhs.zone.name[idx];
                        }
                        break :blk false;
                    },
                    1 => lhs.avg_pct_of_frame < rhs.avg_pct_of_frame,
                    2 => lhs.avg_s_per_frame < rhs.avg_s_per_frame,
                    3 => lhs.avg_calls_per_frame < rhs.avg_calls_per_frame,
                    4 => lhs.avg_s_per_call < rhs.avg_s_per_call,
                    else => unreachable,
                };
                return if (ctx.reverse) !less_than else less_than;
            }
        }).func);
        prof.stopZone();

        break :blk array;
    };

    showTableHeader(ui, &zone_table_cols, &zone_table_sorted_col, &zone_table_sorted_col_reverse);

    const table_lines_p = ui.pushLayoutParent(.{
        .clip_children = true,
        .scroll_children_y = true,
    }, "table_lines_p", [2]UI.Size{ UI.Size.children(1), UI.Size.percent(1, 0) }, .y);
    defer ui.popParentAssert(table_lines_p);

    for (table_lines.slice(), 0..) |entry, zone_idx| {
        const zone = entry.zone;

        ui.startLine();
        defer ui.endLine();
        var col_idx: usize = 0;
        { // 'zone' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);

            ui.spacer(.x, UI.Size.em(0.2, 1));
            // TODO: turn this into a button that opens a color picker
            _ = ui.addNode(.{
                .draw_background = true,
                .no_id = true,
                .floating_y = true,
            }, "", .{
                .size = UI.Size.exact(.em, 1, 1),
                .bg_color = zone.color,
                .rel_pos = UI.RelativePlacement.match(.center),
            });
            ui.spacer(.x, UI.Size.em(0.1, 1));
            const checkmark = ui.addNodeF(.{
                .clickable = true,
                .draw_text = true,
                .draw_border = true,
                .draw_background = zone.display,
                .draw_hot_effects = true,
                .floating_y = true,
            }, "{s}###{}_zone_toggle", .{ UI.Icons.ok, zone_idx }, .{
                .cursor_type = .pointing_hand,
                .font_type = .icon,
                .font_size = ui.topStyle().font_size * 0.75,
                .rel_pos = UI.RelativePlacement.match(.center),
            });
            if (!zone.display) checkmark.flags.draw_text = false; // TODO: shouldn't have to do it like this (this is because we check 'flags.draw_text' inside addNode to call 'calcTextRect'
            if (checkmark.signal.clicked) zone.display = !zone.display;
            ui.spacer(.x, UI.Size.em(0.1, 1));
            const name_node = ui.addNodeF(.{
                .draw_text = true,
            }, "{s}###{}_name", .{ zone.name, zone_idx }, .{
                .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.text(1) },
            });
            if (name_node.text_truncated and name_node.signal.hovering) {
                ui.startTooltip(null);
                ui.label(zone.name);
                ui.endTooltip();
            }
        }
        { // '% of frame' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:2.1}", .{100 * entry.avg_pct_of_frame});
        }
        { // 'ms/frame' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:3.2}", .{entry.avg_s_per_frame * std.time.ms_per_s});
        }
        { // 'calls/frame' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:2.1}", .{entry.avg_calls_per_frame});
        }
        { // 'μs/call' column
            startColEntry(ui, &zone_table_cols, &col_idx);
            defer endColEntry(ui, &zone_table_cols, &col_idx);
            ui.labelF("{d:.1}", .{entry.avg_s_per_call * std.time.us_per_s});
        }
    }
}
fn showProfilerInfo(ui: *UI, profiler: *Profiler) UI.Rect {
    const w = ui.startWindow("profiler_window", UI.Size.exact(.percent, 1, 1), UI.RelativePlacement.simple(vec2{ 0, 0 }));
    defer ui.endWindow(w);
    helperShowNodeTableHist(ui);
    {
        ui.startLine();
        defer ui.endLine();
        _ = ui.checkBox("Include children in zone time", &profiler_display.include_children);
        if (ui.button("Enable all zones").clicked) {
            var zone_it = profiler.zoneIterator(true, false);
            while (zone_it.next()) |zone| zone.display = true;
        }
        if (ui.button("Disable all zones").clicked) {
            var zone_it = profiler.zoneIterator(true, false);
            while (zone_it.next()) |zone| zone.display = false;
        }
        {
            const other_mode: ProfilerDisplay.Mode = switch (profiler_display.mode) {
                .sample_time => .call_count,
                .call_count => .sample_time,
            };
            if (ui.buttonF("Switch graph to {s}", .{switch (other_mode) {
                .sample_time => "sample time",
                .call_count => "call counter",
            }}).clicked)
                profiler_display.mode = other_mode;
        }
    }
    {
        _ = ui.pushLayoutParent(.{ .no_id = true }, "", UI.Size.flexible(.percent, 1, 1), .x);
        defer _ = ui.popParent();

        helperShowZoneTable(ui, profiler);

        const profiler_graph_node = ui.addNode(.{
            .draw_border = true,
        }, "profiler_graph_node", .{
            .size = UI.Size.flexible(.percent, 1, 1),
        });

        { // graph y-axis scale
            _ = ui.pushLayoutParent(.{ .no_id = true }, "", [2]UI.Size{ UI.Size.children(1), UI.Size.percent(1, 0) }, .y);
            defer _ = ui.popParent();

            const order_of_mag = std.math.pow(f32, 10, @ceil(std.math.log10(@abs(profiler_display.max_y))));
            const min_divisions = 5;
            const max_divisions = 10;
            var step = (order_of_mag / 10);
            while (profiler_display.max_y / step < min_divisions + 2) step /= 2;
            while (profiler_display.max_y / step > max_divisions - 2) step *= 2;
            const graph_px_height = profiler_graph_node.rect.size()[1];
            var value: f32 = step;
            while (value < profiler_display.max_y) : (value += step) {
                const pct = value / profiler_display.max_y;
                const px_pos = pct * graph_px_height;
                const str = switch (profiler_display.mode) {
                    .sample_time => ui.fmtTmpString("{d:.0}ms", .{value * std.time.ms_per_s}),
                    .call_count => ui.fmtTmpString("{d}", .{value}),
                };
                _ = ui.addNode(.{
                    .draw_text = true,
                    .floating_y = true,
                    .no_id = true,
                }, str, .{
                    .rel_pos = UI.RelativePlacement.absolute(.{ .center = vec2{ 0, px_pos } }),
                });
            }
        }

        return profiler_graph_node.rect;
    }
}

fn renderProfilerGraph(allocator: Allocator, profiler: *Profiler, rect: UI.Rect, fbsize: uvec2) !void {
    prof.startZoneN("renderProfilerGraph");
    defer prof.stopZone();
    // TODO: change UI render backend to operate on primitives (lines, dots, triangles, rects)
    // instead of only supporting our special rects

    // TODO: don't recreate this every time, save it as part of profiler maybe?
    const shader = try gfx.Shader.from_srcs(allocator, "profiler_graph", .{
        .vertex =
        \\#version 330 core
        \\in float sample;
        \\uniform bool sample_is_uint;
        \\uniform uint sample_count;
        \\uniform float max_y;
        \\uniform vec2 btmleft;
        \\uniform vec2 size;
        \\uniform vec2 screen_size;
        \\out float pass_value;
        \\void main() {
        \\    float value = sample_is_uint ? float(floatBitsToInt(sample)) : sample;
        \\    vec2 pos_graph = vec2(gl_VertexID / float(max(1, sample_count) - 1), value / max_y);
        \\    vec2 pos_px = (pos_graph * size) + btmleft;
        \\    vec2 pos = (pos_px / screen_size) * 2 - vec2(1);
        \\    gl_Position = vec4(pos, 0, 1);
        \\    pass_value = value;
        \\}
        ,
        .fragment =
        \\#version 330 core
        \\in float pass_value;
        \\uniform float max_y;
        \\uniform vec4 color;
        \\out vec4 FragColor;
        \\void main() {
        \\    if (pass_value > max_y) discard;
        \\    FragColor = color;
        \\}
        ,
    });
    defer shader.deinit();

    // auto-size graph
    {
        profiler_display.max_y = 0;
        var zone_it = profiler.zoneIterator(true, true);
        while (zone_it.next()) |zone| {
            const max_sample = switch (profiler_display.mode) {
                .sample_time => blk: {
                    if (profiler_display.include_children) {
                        break :blk reduceSlice(f32, .Max, &zone.samples);
                    } else {
                        var tmp: [Zone.number_of_samples]f32 = undefined;
                        binOpSlices(f32, .Sub, &tmp, &zone.samples, &zone.child_samples);
                        break :blk reduceSlice(f32, .Max, &tmp);
                    }
                },
                .call_count => blk: {
                    const max_sample = reduceSlice(u32, .Max, &zone.sample_counter);
                    break :blk @as(f32, @floatFromInt(max_sample));
                },
            };
            profiler_display.max_y = @max(profiler_display.max_y, max_sample * 1.05);
        }
    }

    shader.bind();
    shader.set("btmleft", rect.min);
    shader.set("size", rect.size());
    shader.set("screen_size", @as(vec2, @floatFromInt(fbsize)));
    shader.set("max_y", profiler_display.max_y);
    var zone_it = profiler.zoneIterator(true, true);
    while (zone_it.next()) |zone| {
        const n_samples = Zone.number_of_samples;
        // TODO: don't create these buffers every time. create/alloc once then just update data
        const vert_buf = VertexBuffer.init(&.{.{ .type = gl.FLOAT, .len = 1 }}, n_samples);
        defer vert_buf.deinit();
        switch (profiler_display.mode) {
            .sample_time => {
                if (profiler_display.include_children) {
                    vert_buf.update(sliceAsBytes(f32, &zone.samples));
                } else {
                    var tmp: [Zone.number_of_samples]f32 = undefined;
                    binOpSlices(f32, .Sub, &tmp, &zone.samples, &zone.child_samples);
                    vert_buf.update(sliceAsBytes(f32, &tmp));
                }
            },
            .call_count => {
                vert_buf.update(sliceAsBytes(u32, &zone.sample_counter));
            },
        }
        shader.set("sample_is_uint", profiler_display.mode == .call_count);
        shader.set("sample_count", @as(u32, @intCast(n_samples)));
        shader.set("color", zone.color);
        vert_buf.draw(gl.LINE_STRIP);
    }
    // draw 60fps line
    if (profiler_display.mode == .sample_time) {
        const samples = &[_]f32{ target_ms_per_frame, target_ms_per_frame };

        const vert_buf = VertexBuffer.init(&.{.{ .type = gl.FLOAT, .len = 1 }}, samples.len);
        defer vert_buf.deinit();
        vert_buf.update(sliceAsBytes(f32, samples));
        shader.set("sample_is_uint", false);
        shader.set("sample_count", @as(u32, @intCast(samples.len)));
        shader.set("color", vec4{ 0, 0.9, 0, 1 });
        vert_buf.draw(gl.LINE_STRIP);
    }
}

fn sliceAsBytes(comptime T: type, slice: []const T) []const u8 {
    var bytes: []const u8 = undefined;
    bytes.ptr = @ptrCast(slice.ptr);
    bytes.len = slice.len * @sizeOf(T);
    return bytes;
}

/// Generic GPU geometry buffer.
pub const VertexBuffer = struct {
    vao: u32,
    vbo: u32,
    // TODO: support index/element buffer
    elem_size: usize,
    n_elems: usize,
    // TODO: support keeping around a copy of the GPU data inside this data structure
    // instead of outside of it; may be helpfull in some cases.

    pub const Attrib = struct {
        /// gl.FLOAT, etc.
        type: gl.GLenum,
        /// e.g. len=2 for vec2
        len: usize,

        pub fn size(self: Attrib) usize {
            return sizeOfGLType(self.type) * self.len;
        }
    };

    /// Initialize and allocate GPU side buffer
    pub fn init(
        attribs: []const Attrib,
        n_elems: usize,
        // TODO: support multiple vbos?
    ) VertexBuffer {
        const elem_size = blk: {
            var sum: usize = 0;
            // TODO: don't assume element attribs are tighly packed?
            for (attribs) |attrib| sum += attrib.size();
            break :blk sum;
        };

        var vao: u32 = 0;
        gl.genVertexArrays(1, &vao);
        gl.bindVertexArray(vao);

        var vbo: u32 = 0;
        gl.genBuffers(1, &vbo);
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        var offset: usize = 0;
        for (attribs, 0..) |attrib, i| {
            const index: u32 = @intCast(i);
            const attrib_offset: ?*const anyopaque = if (offset == 0) null else @ptrFromInt(offset);
            // TODO: don't assume elements are tighly packed?
            gl.vertexAttribPointer(index, @intCast(attrib.len), attrib.type, gl.FALSE, @intCast(elem_size), attrib_offset);
            gl.enableVertexAttribArray(index);
            // TODO: don't assume element attribs are tighly packed?
            offset += attrib.size();
        }
        // TODO: support gl.STATIC_DRAW as well
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(n_elems * elem_size), null, gl.DYNAMIC_DRAW);

        return .{
            .vao = vao,
            .vbo = vbo,
            .elem_size = elem_size,
            .n_elems = n_elems,
        };
    }

    pub fn deinit(self: VertexBuffer) void {
        gl.deleteBuffers(1, &self.vbo);
        gl.deleteVertexArrays(1, &self.vao);
    }

    /// Update buffer data, sync with GPU
    pub fn update(self: VertexBuffer, data: []const u8) void {
        std.debug.assert(data.len == self.elem_size * self.n_elems);
        // TODO: support gl.STATIC_DRAW as well
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(data.len), @ptrCast(data.ptr), gl.DYNAMIC_DRAW);
    }

    pub fn draw(
        self: VertexBuffer,
        /// gl.LINE_STRIP, gl.TRIANGLES, etc.
        mode: gl.GLenum,
    ) void {
        gl.bindVertexArray(self.vao);
        gl.drawArrays(mode, 0, @intCast(self.n_elems));
    }

    fn sizeOfGLType(gl_type: gl.GLenum) usize {
        return switch (gl_type) {
            gl.UNSIGNED_BYTE => @sizeOf(u8),
            gl.UNSIGNED_SHORT => @sizeOf(u16),
            gl.UNSIGNED_INT => @sizeOf(u32),
            gl.FLOAT => @sizeOf(f32),
            gl.DOUBLE => @sizeOf(f64),
            else => |todo| std.debug.panic("'type: gl.GLenum = {}' not suppported", .{todo}),
        };
    }
};
