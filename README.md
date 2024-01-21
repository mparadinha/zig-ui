# An immediate mode style GUI, writen fully in zig
**Heavily** inspired by
[Dear ImGui](https://github.com/ocornut/imgui),
[Ryan Fleury's UI series](https://www.rfleury.com/p/ui-series-table-of-contents),
and [Hasen Judi's UI series](https://hasen.substack.com/s/gpu-ui)

## Install & Build
Requires [zig-0.11.0](https://ziglang.org/download) compiler.

Add it your `build.zig.zon` file:
```zig
.{
    ...
    .dependencies = .{
        .zig_ui = .{
            .url = "https://github.com/mparadinha/zig-ui/archive/<commit_sha256>.tar.gz",
        },
    },
}
```
Then in your `build.zig` do:
```zig
pub fn build(b: *std.build.Builder) void {
    const exe = b.addExecutable(.{ ... });
    ...
    const zig_ui_dep = b.dependency("zig_ui", .{ .target = target, .optimize = optimize });
    const zig_ui_mod = zig_ui_dep.module("zig-ui");
    exe.linkLibC();
    exe.addModule("zig-ui", zig_ui_mod);
    @import("zig_ui").link(zig_ui_dep.builder, exe);
    ...
}
```

## Usage
```zig
const std = @import("std");
const zig_ui = @import("zig-ui");
const vec4 = zig_ui.vec4; // just `@Vector(4, f32)`, exported for convience
const gl = zig_ui.gl; // we also export our loaded gl functions if you want to use them
const glfw = zig_ui.glfw;
const Window = zig_ui.Window;
const UI = zig_ui.UI;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var width: u32 = 800;
    var height: u32 = 450;
    var window = try Window.init(allocator, width, height, "Window Title");
    window.finishSetup();
    defer window.deinit();
    const clear_color = vec4{ 0, 0, 0, 1 };

    var ui = try UI.init(allocator, .{});
    defer ui.deinit();
    // just an example. we can change these style variables at anytime
    ui.base_style.text_color = vec4{ 1, 1, 1, 1 };

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
        if (ui.button("Zig!").held_down) ui.label("For great justice!");
        ui.endBuild(dt);

        window.clear(clear_color);
        // do whatever other rendering you want here
        try ui.render();

        window.update();
    }
}
```
(see `src/widgets.zig` and `demo.zig` for more information)
