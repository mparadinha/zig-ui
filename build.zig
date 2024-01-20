const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;

    const glfw_dep = b.dependency("mach_glfw", .{ .target = target, .optimize = .ReleaseSafe });
    const glfw_mod = glfw_dep.module("mach-glfw");

    const options = b.addOptions();
    // TODO: don't use `@src` when updating to 0.12 build system
    const this_dir = comptime std.fs.path.dirname(@src().file) orelse ".";
    options.addOption([]const u8, "resource_dir", this_dir ++ "/resources");
    const opts_mod = options.createModule();

    _ = b.addModule("zig-ui", .{
        .source_file = .{ .path = "zig_ui.zig" },
        .dependencies = &.{
            .{ .name = "mach-glfw", .module = glfw_mod },
            .{ .name = "build_opts", .module = opts_mod },
        },
    });
}

pub fn link(b: *std.build.Builder, step: *std.Build.CompileStep) void {
    const glfw_dep = b.dependency("mach_glfw", .{
        .target = step.target,
        .optimize = .ReleaseSafe,
    });
    @import("mach_glfw").link(glfw_dep.builder, step);

    const stb_lib = b.addStaticLibrary(.{
        .name = "stb-lib",
        .root_source_file = .{ .path = "src/stb_impls.c" },
        .target = step.target,
        .optimize = .ReleaseSafe,
    });
    stb_lib.linkLibC();
    stb_lib.addIncludePath(.{ .path = "src" });
    b.installArtifact(stb_lib);

    step.linkLibrary(stb_lib);

    // needed so that Font.zig can include stb files
    // (which will get done on the user side?)
    // TODO: I think there's a correct way to do this but it's fine for now
    // I'll fix it when I update to the new 0.12 build system
    const this_dir = comptime std.fs.path.dirname(@src().file) orelse ".";
    step.addIncludePath(.{ .path = this_dir ++ "/src" });
}
