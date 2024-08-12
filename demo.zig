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
const fps_value: f32 = 1.0 / 60.0;
var max_graph_y: f32 = fps_value * 1.5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var show_profiler_graph = false;

    var last_time: f32 = @floatCast(glfw.getTime());
    while (!window.shouldClose()) {
        prof.startZoneN("main loop");
        defer prof.stopZoneN("main loop");

        // grab all window/input information we need for this frame
        const cur_time: f32 = @floatCast(glfw.getTime());
        const dt = cur_time - last_time;
        last_time = cur_time;
        const mouse_pos = window.getMousePos();
        const fbsize = window.getFramebufferSize();

        glfw.swapInterval(if (demo.unlock_framerate) 0 else 1);

        try ui.startBuild(fbsize[0], fbsize[1], mouse_pos, &window.event_queue, &window);
        try showDemo(allocator, &ui, mouse_pos, &window.event_queue, dt, &demo);
        if (show_profiler_graph) showProfilerInfo(&ui);
        ui.endBuild(dt);

        if (window.event_queue.searchAndRemove(.KeyUp, .{
            .mods = .{ .control = true, .shift = true },
            .key = .d,
        })) dbg_ui_view.active = !dbg_ui_view.active;

        if (window.event_queue.searchAndRemove(.KeyUp, .{
            .mods = .{ .control = true, .shift = true },
            .key = .p,
        })) show_profiler_graph = !show_profiler_graph;

        window.clear(demo.clear_color);
        // <do whatever other rendering you want below the UI here>
        try ui.render();
        if (dbg_ui_view.active) try dbg_ui_view.show(&ui, fbsize[0], fbsize[1], mouse_pos, &window.event_queue, &window, dt);
        if (demo.show_zoom) try renderZoomDisplay(allocator, demo, fbsize);
        if (show_profiler_graph) try renderProfilerGraph(allocator, demo, prof, fbsize);

        window.update();
    }
}

const DemoState = struct {
    selected_tab: Tabs = .Basics,

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

    show_debug_stats: bool = true,
    show_zoom: bool = false,
    unlock_framerate: bool = false,

    const Tabs = enum {
        Basics,
        Styling,
        @"Live Node Editor",
        @"Custom Texture",
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
    defer prof.stopZoneN("showDemo");

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
        .font_type = .text_bold,
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
        for ([2]bool{ false, true }) |disable_truncation| {
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

pub const Profiler = struct {
    zone_buckets: [20]Bucket = [_]Bucket{.{}} ** 20,

    const Bucket = std.BoundedArray(Entry, 5);
    const Entry = struct { key: []const u8, hash: u64, zone: Zone };

    pub fn gopZoneN(self: *Profiler, comptime name: []const u8) struct {
        value_ptr: *Zone,
        found_existing: bool,
    } {
        const hash = comptime std.hash.Wyhash.hash(0, name);
        const bucket_idx = hash % self.zone_buckets.len;
        const bucket = &self.zone_buckets[bucket_idx];
        for (bucket.slice()) |*entry| {
            if (entry.hash == hash) return .{ .value_ptr = &entry.zone, .found_existing = true };
        }
        bucket.append(.{ .key = name, .hash = hash, .zone = undefined }) catch @panic("OOM");
        return .{ .value_ptr = &bucket.buffer[bucket.len - 1].zone, .found_existing = false };
    }

    pub fn startZoneN(self: *Profiler, comptime name: []const u8) void {
        const gop = self.gopZoneN(name);
        const zone = gop.value_ptr;
        if (!gop.found_existing) zone.* = .{ .samples = undefined };
        if (zone.start_timestamp != null) return;
        zone.start_timestamp = std.time.nanoTimestamp();
    }

    pub fn stopZoneN(self: *Profiler, comptime name: []const u8) void {
        const zone = self.gopZoneN(name).value_ptr;
        const timestamp = std.time.nanoTimestamp();
        const elapsed_ns: f32 = @floatFromInt(timestamp - zone.start_timestamp.?);
        zone.start_timestamp = null;
        zone.sample(elapsed_ns / std.time.ns_per_s);
    }
};
pub const Zone = struct {
    samples: [1000]f32,
    idx: usize = 0,
    color: ?vec4 = null,
    /// Non `null` when we are timing inside this zone
    start_timestamp: ?i128 = null,
    display: bool = true,

    /// Add new sample to ring buffer
    pub fn sample(self: *Zone, value: f32) void {
        self.samples[self.idx] = value;
        self.idx += 1;
        self.idx %= self.samples.len;
    }
};

fn showProfilerInfo(ui: *UI) void {
    const w = ui.startWindow("profiler_window", UI.Size.exact(.percent, 1, 1), UI.RelativePlacement.simple(vec2{ 0, 0 }));
    defer ui.endWindow(w);
    {
        ui.startLine();
        defer ui.endLine();
        ui.labelF("max_graph_y: {d: >4.1}", .{max_graph_y * 1000});
        ui.slider(f32, "max_graph_y", UI.Size.exact(.em, 50, 1), &max_graph_y, 0, 0.1);
        ui.topParent().last.?.flags.floating_y = true;
        ui.topParent().last.?.rel_pos = UI.RelativePlacement.match(.center);
    }
    for (&prof.zone_buckets) |*bucket| {
        for (bucket.slice()) |*entry| {
            const name = entry.key;
            const zone = &entry.zone;
            ui.startLine();
            defer ui.endLine();
            const color = blk: {
                const hash = std.mem.asBytes(&entry.hash);
                break :blk UI.colorFromRGB(hash[0], hash[1], hash[2]);
            };
            _ = ui.addNode(.{
                .draw_background = true,
                .no_id = true,
                .floating_y = true,
            }, "", .{
                .bg_color = color,
                .size = UI.Size.exact(.em, 1, 1),
                .rel_pos = UI.RelativePlacement.match(.center),
            });
            const zone_total_time = blk: {
                var sum: f32 = 0;
                for (zone.samples) |sample| sum += sample;
                break :blk sum;
            };
            const total_time = (@as(f32, @floatFromInt(zone.samples.len)) * fps_value);
            const avg_elapsed = zone_total_time / @as(f32, @floatFromInt(zone.samples.len));
            _ = ui.checkBoxF("###{s}", .{name}, &zone.display);
            ui.labelF("{s} (avg. {d:2.1}%, {d:3.2}ms)", .{
                name,
                100 * (zone_total_time / total_time),
                avg_elapsed * 1000,
            });
        }
    }
}

fn renderProfilerGraph(allocator: Allocator, demo: DemoState, profiler: Profiler, fbsize: uvec2) !void {
    prof.startZoneN("renderProfilerGraph");
    defer prof.stopZoneN("renderProfilerGraph");
    // TODO: change UI render backend to operate on primitives (lines, dots, triangles, rects)
    // instead of only supporting our special rects

    // TODO: don't recreate this every time, save it as part of profiler maybe?
    const shader = try gfx.Shader.from_srcs(allocator, "profiler_graph", .{
        .vertex =
        \\#version 330 core
        \\in float sample;
        \\uniform uint sample_count;
        \\uniform float max_y;
        \\void main() {
        \\    vec2 graph_pos = vec2(gl_VertexID / float(max(1, sample_count) - 1), sample / max_y);
        \\    vec2 pos = graph_pos * 2 - vec2(1);
        \\    gl_Position = vec4(pos, 0, 1);
        \\}
        ,
        .fragment =
        \\#version 330 core
        \\uniform vec4 color;
        \\out vec4 FragColor;
        \\void main() { FragColor = color; }
        ,
    });
    defer shader.deinit();

    _ = fbsize;
    _ = demo;
    shader.bind();
    // shader.set("screen_size", @as(vec2, @floatFromInt(fbsize)));
    shader.set("max_y", max_graph_y);
    for (profiler.zone_buckets) |bucket| {
        for (bucket.slice()) |entry| {
            const name_hash = entry.hash;
            const zone = entry.zone;
            if (!zone.display) continue;
            const color = blk: {
                const hash = std.mem.asBytes(&name_hash);
                break :blk UI.colorFromRGB(hash[0], hash[1], hash[2]);
            };
            // TODO: don't create these buffers every time. create/alloc once then just update data
            const vert_buf = VertexBuffer.init(&.{.{ .type = gl.FLOAT, .len = 1 }}, zone.samples.len);
            defer vert_buf.deinit();
            vert_buf.update(sliceAsBytes(f32, &zone.samples));
            shader.set("sample_count", @as(u32, @intCast(zone.samples.len)));
            shader.set("color", color);
            vert_buf.draw(gl.LINE_STRIP);
        }
    }

    { // draw 60fps line
        const samples = &[_]f32{ fps_value, fps_value };

        const vert_buf = VertexBuffer.init(&.{.{ .type = gl.FLOAT, .len = 1 }}, samples.len);
        defer vert_buf.deinit();
        vert_buf.update(sliceAsBytes(f32, samples));
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
