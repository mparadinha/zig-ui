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
const utils = zig_ui.utils;

pub var prof = zig_ui.Profiler{};

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
    var show_profiler = false;
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
        if (show_profiler) profiler_graph_rect = zig_ui.profiler.showProfilerInfo(&ui, &prof);
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
        if (show_profiler) try zig_ui.profiler.renderProfilerGraph(allocator, &prof, profiler_graph_rect, fbsize, target_ms_per_frame);

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
    selected_tab: Tabs = .Debug,

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
        Debug,
    };
};

const use_child_size = UI.Size.children2(1, 1);

fn showDemo(
    allocator: std.mem.Allocator,
    ui: *UI,
    mouse_pos: vec2,
    event_q: *Window.EventQueue,
    dt: f32,
    state: *DemoState,
) !void {
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
        .Debug => try showDemoTabDebug(allocator, ui, state),
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

        _ = ui.namedCheckBox("Snap to pixel grid", &state.zoom_snap_to_pixel);

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
    _ = ui.namedCheckBox("Toggle debug stats in the corner", &state.show_debug_stats);
    _ = ui.namedCheckBox("Hot-reload UI shaders", &UI.hot_reload_shaders);
    _ = ui.namedCheckBox("Show zoom display", &state.show_zoom);
    _ = ui.namedCheckBox("Unlock framerate", &state.unlock_framerate);
}

fn showDemoTabPerfTesting(ui: *UI, state: *DemoState) void {
    {
        ui.startLine();
        defer ui.endLine();

        ui.labelF("{: >4}", .{state.dummy_labels});
        const slider_size = [2]UI.Size{ UI.Size.em(50, 1), UI.Size.em(1, 1) };
        ui.slider(usize, "dummy_label_slider", slider_size, &state.dummy_labels, 0, 5000);
    }
    if (ui.toggleButton("Static labels", false).toggled) {
        for (0..state.dummy_labels) |idx| ui.labelF("label #{}", .{idx});
    }
    if (ui.toggleButton("Dynamic labels", false).toggled) {
        for (0..state.dummy_labels) |idx| ui.labelF("label #{}: frame_idx+label_idx={}", .{ idx, idx + ui.frame_idx });
    }
    if (ui.toggleButton("Fill screen with random text", false).toggled) {
        var prng = UI.PRNG{ .state = ui.frame_idx };
        _ = prng.next();
        for (0..40) |_| {
            ui.startLine();
            for (0..15) |_| ui.labelF("{x:0>16}", .{prng.next()});
            ui.endLine();
        }
    }
}

fn showDemoTabDebug(allocator: std.mem.Allocator, ui: *UI, _: *DemoState) !void {
    const font = ui.font_cache.getFont(.regular);
    const str = "! !";
    ui.labelF("str: '{s}'", .{str});
    const quads = try font.buildText(allocator, str, 18);
    defer allocator.free(quads);
    for (quads, 0..) |quad, q_idx| {
        ui.labelF("quad for '{c}':", .{str[q_idx]});
        for (quad.points, 0..) |point, p_idx| ui.labelF("  points[{}]: pos={d}, uv={d}", .{ p_idx, point.pos, point.uv });
    }
    for (' '..'~' + 1) |char| {
        const glyph = try font.getGlyphRasterData(@intCast(char), 18);
        ui.labelF("'{c}' pos_bl={d}, pos_tr={d}, uv_bl={d}, uv_tr={d}, advance={d}", .{
            @as(u8, @intCast(char)),
            glyph.pos_btm_left,
            glyph.pos_top_right,
            glyph.uv_btm_left,
            glyph.uv_top_right,
            glyph.advance,
        });
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
        defer tex_quad_shader.deinit();
        // TODO: just recreate mesh every frame and use the vert data instead of all those uniforms

        const tex_quad_mesh_data = [_]f32{
            // 1st tri
            0, 0, // btm left
            1, 0, // btm right
            1, 1, // top right
            // 2nd tri
            0, 0, // btm left
            1, 1, // top right
            0, 1, // top left
        };
        const tex_quad_mesh = gfx.VertexBuffer.init(&.{
            .{ .type = gl.FLOAT, .len = 2 },
        }, 2);
        defer tex_quad_mesh.deinit();
        tex_quad_mesh.update(utils.sliceAsBytes(f32, &tex_quad_mesh_data));

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
        tex_quad_mesh.draw(gl.TRIANGLES);
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
