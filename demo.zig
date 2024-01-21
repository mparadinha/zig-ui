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
        try showDemo(allocator, &ui, &demo);
        ui.endBuild(dt);

        window.clear(demo.clear_color);
        // do whatever other rendering you want here
        try ui.render();

        window.update();
    }
}

const DemoState = struct {
    clear_color: vec4 = vec4{ 0, 0, 0, 1 },
    demo_window_bg_color: vec4 = vec4{ 0, 0, 0, 0 },
    debug_stats: bool = true,
};

fn showDemo(_: std.mem.Allocator, ui: *UI, state: *DemoState) !void {
    const p = ui.addNode(.{
        .draw_background = true,
        .scroll_children_y = true,
    }, "demo_window", .{
        .bg_color = state.demo_window_bg_color,
        .size = UI.Size.exact(.percent, 1, 1),
        .layout_axis = .y,
    });
    ui.pushParent(p);
    defer ui.popParentAssert(p);

    const use_child_size = Size.fillByChildren(1, 1);

    const pickers = ui.addNode(.{ .draw_text = true, .toggleable = true }, "Color pickers:", .{});
    if (pickers.first_time) pickers.toggled = true;
    if (pickers.signal.toggled) {
        const flags = UI.Flags{ .no_id = true };
        const sides = ui.addNode(flags, "", .{ .size = use_child_size, .layout_axis = .x });
        ui.pushParent(sides);
        defer ui.popParentAssert(sides);

        const left = ui.addNode(flags, "", .{ .size = use_child_size });
        {
            ui.pushParent(left);
            defer ui.popParentAssert(left);
            ui.label("screen clear color");
            ui.colorPicker("clear color", &state.clear_color);
        }
        ui.spacer(.x, Size.pixels(10, 1));
        const right = ui.addNode(flags, "", .{ .size = use_child_size });
        {
            ui.pushParent(right);
            defer ui.popParentAssert(right);
            ui.label("demo window background color");
            ui.colorPicker("demo bg color", &state.demo_window_bg_color);
        }
    }

    _ = ui.checkBox("Toggle debug stats in the corner", &state.debug_stats);

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
        ui.labelF("# of nodes: {}", .{ui.node_table.key_mappings.items.len});
        ui.labelF("build_arena capacity: {:.2}", .{
            std.fmt.fmtIntSizeBin(ui.build_arena.queryCapacity()),
        });
    }

    ui.label("Valid unicode, but not present in default font (should render the `missing char` box): \u{1b83}");

    if (ui.button("Dump root node tree to `ui_main_tree.dot`").clicked) {
        const path = "ui_main_tree.dot";
        const dump_file = try std.fs.cwd().createFile(path, .{});
        defer dump_file.close();
        try ui.dumpNodeTreeGraph(ui.root_node.?, dump_file);
    }
}
