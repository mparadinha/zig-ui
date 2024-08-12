const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;

    const glfw_dep = b.dependency("mach_glfw", .{ .target = target, .optimize = .ReleaseSafe });
    const glfw_mod = glfw_dep.module("mach-glfw");

    const stb_lib = b.addStaticLibrary(.{
        .name = "stb-lib",
        .target = target,
        .optimize = .ReleaseSafe,
    });
    stb_lib.addCSourceFile(.{ .file = b.path("src/stb_impls.c") });
    stb_lib.linkLibC();
    stb_lib.addIncludePath(b.path("src"));

    const options = b.addOptions();
    options.addOption([]const u8, "resource_dir", b.path("resources").getPath(b));
    const opts_mod = options.createModule();

    const zig_ui_mod = b.addModule("zig-ui", .{
        .root_source_file = .{ .path = "zig_ui.zig" },
        .imports = &.{
            .{ .name = "mach-glfw", .module = glfw_mod },
            .{ .name = "build_opts", .module = opts_mod },
        },
    });
    zig_ui_mod.addIncludePath(b.path("src"));
    zig_ui_mod.linkLibrary(stb_lib);

    const demo = create_demo_exe_step(b, zig_ui_mod);
    const build_demo_step = b.step("demo", "Build demo program");
    const build_demo_artifact = b.addInstallArtifact(demo, .{});
    build_demo_step.dependOn(&build_demo_artifact.step);
    const run_demo_step = b.step("run-demo", "Run demo program");
    const run_demo_artifact = b.addRunArtifact(demo);
    run_demo_step.dependOn(&run_demo_artifact.step);

    // check step (compile, but don't emit binary) used for ZLS
    const check_demo = create_demo_exe_step(b, zig_ui_mod);
    const check = b.step("check", "Check if demo compiles (usefull for ZLS integration)");
    check.dependOn(&check_demo.step);
}

pub fn create_demo_exe_step(b: *std.Build, zig_ui_mod: *std.Build.Module) *std.Build.Step.Compile {
    const demo = b.addExecutable(.{
        .name = "demo",
        .target = b.host,
        .root_source_file = .{ .path = "demo.zig" },
    });
    demo.linkLibC();
    demo.root_module.addImport("zig-ui", zig_ui_mod);
    return demo;
}
