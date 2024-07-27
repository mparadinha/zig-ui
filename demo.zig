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

    var last_time: f32 = @floatCast(glfw.getTime());
    while (!window.shouldClose()) {
        // grab all window/input information we need for this frame
        const cur_time: f32 = @floatCast(glfw.getTime());
        const dt = cur_time - last_time;
        last_time = cur_time;
        const mouse_pos = window.getMousePos();
        const fbsize = window.getFramebufferSize();

        try ui.startBuild(fbsize[0], fbsize[1], mouse_pos, &window.event_queue, &window);
        try showDemo(allocator, &ui, mouse_pos, &window.event_queue, dt, &demo);
        ui.endBuild(dt);

        if (window.event_queue.searchAndRemove(.KeyUp, .{
            .mods = .{ .control = true, .shift = true },
            .key = .d,
        })) dbg_ui_view.active = !dbg_ui_view.active;

        window.clear(demo.clear_color);
        // do whatever other rendering you want below the UI here
        try ui.render();
        if (dbg_ui_view.active) {
            try dbg_ui_view.show(&ui, fbsize[0], fbsize[1], mouse_pos, &window.event_queue, &window, dt);
        }
        if (demo.show_zoom) try renderZoomDisplay(allocator, demo, fbsize);

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

    zoom_display: UI.Rect = UI.Rect{ .min = vec2{ 0, 0 }, .max = vec2{ 0, 0 } },
    zoom_region: UI.Rect = UI.Rect{ .min = vec2{ 0, 0 }, .max = vec2{ 0, 0 } },

    show_debug_stats: bool = true,
    show_zoom: bool = false,

    const Tabs = enum {
        Basics,
        Styling,
        @"Live Node Editor",
        @"Custom Texture",
        @"Demo Config",
    };
};

const use_child_size = UI.Size.fillByChildren(1, 1);

fn showDemo(
    _: std.mem.Allocator,
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

    ui.enumTabList(DemoState.Tabs, &state.selected_tab);

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
    if (state.show_zoom) {
        const root_size = ui.root.?.rect.size();

        state.zoom_display = UI.Rect{ .min = @splat(0), .max = root_size / vec2{ 2, 2 } };
        state.zoom_region = UI.Rect{
            .min = vec2{ 0, root_size[1] / 2 },
            .max = vec2{ root_size[0] / 2, root_size[1] },
        };
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
    ui.label("Labels are for blocks of text with no interactivity.");
    ui.labelBox("You can use `labelBox` instead, if you want a background/borders");
    ui.labelBox(
        \\If the label text has newlines ('\n') in it, like this:
        \\then it will take up the necessary vertical space.
    );

    ui.shape(.{
        .bg_color = vec4{ 1, 1, 1, 1 },
        .size = [2]UI.Size{ UI.Size.percent(1, 0), UI.Size.pixels(4, 1) },
        .corner_radii = [4]f32{ 2, 2, 2, 2 },
        .outer_padding = vec2{ 10, 5 },
        .alignment = .center,
    });

    ui.label("Each node alignment can specify it's alignment relative to the parent:");
    {
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
    _ = ui.listBox("listbox_test", .{ UI.Size.children(1), UI.Size.pixels(80, 1) }, &choices, &state.listbox_idx);
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
        _ = ui.lineInput(
            "testing_text_input",
            UI.Size.percent(1, 0),
            &state.text_input,
        );
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
}

fn renderZoomDisplay(allocator: Allocator, demo: DemoState, fbsize: uvec2) !void {
    const save_screenshot = false;

    const tex_quad_shader = try gfx.Shader.from_srcs(allocator, "textured_quad", .{
        .vertex =
        \\#version 330 core
        \\layout (location = 0) in vec2 in_pos;
        \\uniform vec2 size;
        \\uniform vec2 btm_left;
        \\uniform vec2 uv_size;
        \\uniform vec2 uv_btm_left;
        \\out vec2 pass_uv;
        \\void main() {
        \\    gl_Position = vec4((in_pos * size) + btm_left, 0, 1);
        \\    pass_uv = (in_pos * uv_size) + uv_btm_left;
        \\}
        ,
        .fragment =
        \\#version 330 core
        \\in vec2 pass_uv;
        \\uniform sampler2D img;
        \\out vec4 color;
        \\void main() { color = vec4(texture(img, pass_uv).rgb, 1); }
        ,
    });
    defer tex_quad_shader.deinit();
    // TODO: just recreate mesh every frame and use the vert data instead of all those uniforms
    const tex_quad_mesh = gfx.Mesh.init(
        &.{ 0, 0, 1, 0, 1, 1, 0, 1 },
        &.{ 0, 1, 2, 0, 2, 3 },
        &.{.{ .n_elems = 2 }},
    );
    defer tex_quad_mesh.deinit();
    const uv_size = vec2{ 1, 1 };
    const uv_btm_left = vec2{ 0, 0 };

    const bytes = try allocator.alloc(u8, 4 * fbsize[0] * fbsize[1]);
    defer allocator.free(bytes);
    gl.readPixels(0, 0, @intCast(fbsize[0]), @intCast(fbsize[1]), gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(bytes));

    if (save_screenshot) {
        const file = try std.fs.cwd().createFile("screenshot.ppm", .{});
        defer file.close();
        const writer = file.writer();
        try writer.print("P6\n{} {}\n255\n", .{ fbsize[0], fbsize[1] });
        const ppm_bytes = try allocator.alloc(u8, 4 * fbsize[0] * fbsize[1]);
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

    {
        var tex_quad_tex = gfx.Texture.init(fbsize[0], fbsize[1], gl.RGBA, bytes, gl.TEXTURE_2D, &.{
            .{ .name = gl.TEXTURE_MIN_FILTER, .value = gl.LINEAR },
            .{ .name = gl.TEXTURE_MAG_FILTER, .value = gl.NEAREST },
        });
        defer tex_quad_tex.deinit();
        tex_quad_shader.bind();
        const window_size: vec2 = @floatFromInt(fbsize);
        const quad_size = demo.zoom_display.size() / window_size;
        const btm_left = demo.zoom_display.min / window_size;
        const ndc_quad_size = vec2{ 2, 2 } * quad_size;
        const ndc_btm_left = vec2{ 2, 2 } * btm_left - vec2{ 1, 1 };
        tex_quad_shader.set("size", ndc_quad_size);
        tex_quad_shader.set("btm_left", ndc_btm_left);
        tex_quad_shader.set("uv_size", uv_size);
        tex_quad_shader.set("uv_btm_left", uv_btm_left);
        tex_quad_shader.set("img", @as(i32, 0));
        tex_quad_tex.bind(0);
        tex_quad_mesh.draw();
    }
}
