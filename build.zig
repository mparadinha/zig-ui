const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;

    const glfw_dep = b.dependency("mach_glfw", .{ .target = target, .optimize = .ReleaseSafe });
    const glfw_mod = glfw_dep.module("mach-glfw");

    const options = b.addOptions();
    const this_dir = comptime std.fs.path.dirname(@src().file) orelse ".";
    options.addOption([]const u8, "resource_dir", this_dir ++ "/resources");
    const opts_mod = options.createModule();

    _ = b.addModule("zig-ui", .{
        .source_file = .{ .path = "src/main.zig" },
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
    stb_lib.addIncludePath(.{ .path = "src" });
    b.installArtifact(stb_lib);

    step.linkLibrary(stb_lib);
}
