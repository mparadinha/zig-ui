const std = @import("std");
const zig_ui = @import("zig-ui");
const vec4 = zig_ui.vec4; // just `@Vector(4, f32)`, exported for convience
const gl = zig_ui.gl; // we also export our loaded gl functions if you want to use them
const glfw = zig_ui.glfw;
const Window = zig_ui.Window;
const UI = zig_ui.UI;
const Size = UI.Size;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var width: u32 = 1400;
    var height: u32 = 800;
    var window = try Window.init(allocator, width, height, "window title");
    window.finishSetup();
    defer window.deinit();

    var ui = try UI.init(allocator, .{});
    defer ui.deinit();
    // just an example. we can change these style variables at anytime
    ui.base_style.text_color = vec4{ 1, 1, 1, 1 };
    ui.base_style.border_thickness = 2;

    var demo = DemoState{};

    var last_time: f32 = @floatCast(glfw.getTime());
    while (!window.shouldClose()) {
        // grab all window/input information we need for this frame
        const framebuf_size = window.getFramebufferSize();
        width = framebuf_size[0];
        height = framebuf_size[1];
        const cur_time: f32 = @floatCast(glfw.getTime());
        const dt = cur_time - last_time;
        last_time = cur_time;
        const mouse_pos = window.getMousePos();

        try ui.startBuild(width, height, mouse_pos, &window.event_queue, &window);
        try showDemo(allocator, &ui, dt, &demo);
        ui.endBuild(dt);

        window.clear(demo.clear_color);
        // do whatever other rendering you want here
        try ui.render();

        window.update();
    }
}

const DemoState = struct {
    clear_color: vec4 = vec4{ 0, 0, 0, 0.9 },
    demo_window_bg_color: vec4 = vec4{ 0.2, 0.4, 0.5, 0.5 },
    debug_stats: bool = true,
    listbox_idx: usize = 0,
};

fn showDemo(
    _: std.mem.Allocator,
    ui: *UI,
    dt: f32,
    state: *DemoState,
) !void {
    const demo_p = ui.addNode(.{
        .draw_background = true,
        .scroll_children_y = true,
    }, "demo_window", .{
        .bg_color = state.demo_window_bg_color,
        .size = UI.Size.exact(.percent, 1, 1),
        .layout_axis = .y,
    });
    ui.pushParent(demo_p);
    defer ui.popParentAssert(demo_p);

    const use_child_size = Size.fillByChildren(1, 1);

    if (ui.toggleButton("Color pickers:", true).toggled) {
        const sides = ui.pushLayoutParent(.{ .no_id = true, .draw_border = true }, "", use_child_size, .x);
        defer ui.popParentAssert(sides);
        {
            const p = ui.pushLayoutParent(.{ .no_id = true }, "", use_child_size, .y);
            defer ui.popParentAssert(p);
            ui.label("demo background color");
            ui.colorPicker("demo bg color", &state.demo_window_bg_color);
        }
        ui.spacer(.x, Size.pixels(10, 1));
        {
            const p = ui.pushLayoutParent(.{ .no_id = true }, "", use_child_size, .y);
            defer ui.popParentAssert(p);
            ui.label("screen clear color");
            ui.colorPicker("clear color", &state.clear_color);
        }
    }

    _ = ui.checkBox("Toggle debug stats in the corner", &state.debug_stats);

    const choices = [_][]const u8{ "Choice A", "Choice B", "Choice C", "Choice D", "Choice E", "Choice F" };
    ui.labelF("Current choice: {s}", .{choices[state.listbox_idx]});
    _ = ui.listBox("listbox_test", .{ Size.children(1), Size.pixels(80, 1) }, &choices, &state.listbox_idx);
    ui.label("Drop down list:");
    _ = ui.dropDownList("dropdownlist_test", .{ Size.children(1), Size.pixels(80, 1) }, &choices, &state.listbox_idx);

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

    if (ui.button("Dump root node tree to `ui_main_tree.dot`").clicked) {
        const path = "ui_main_tree.dot";
        const dump_file = try std.fs.cwd().createFile(path, .{});
        defer dump_file.close();
        try ui.dumpNodeTreeGraph(ui.root_node.?, dump_file);
    }

    // show at the end, to get more accurate stats for this frame
    if (state.debug_stats) {
        const stats_window = ui.startWindow(
            "debug stats window",
            Size.fillByChildren(1, 1),
            UI.RelativePlacement.match(.top_right),
        );
        defer ui.endWindow(stats_window);
        ui.labelF("mouse_pos={d}", .{ui.mouse_pos});
        ui.labelF("frame_idx={d}", .{ui.frame_idx});
        ui.labelF("{d:4.2} fps", .{1 / dt});
        ui.labelF("# of nodes: {}", .{ui.node_table.key_mappings.items.len});
        ui.labelF("build_arena capacity: {:.2}", .{
            std.fmt.fmtIntSizeBin(ui.build_arena.queryCapacity()),
        });
    }
}
