const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const join = std.fs.path.join;

/// Build required sources, use tracy by importing "tracy.zig"
pub fn link(b: *Builder, step: *LibExeObjStep, opt_path: ?[]const u8) void {
    const step_options = b.addOptions();
    step.addOptions("build_options", step_options);
    step_options.addOption(bool, "tracy_enabled", opt_path != null);

    if (opt_path) |path| {
        const alloc = b.allocator;
        const public_path = join(alloc, &.{ path, "public" }) catch unreachable;
        const tracy_path = join(alloc, &.{ path, "public", "tracy" }) catch unreachable;
        const tracy_client_source_path = join(alloc, &.{ public_path, "TracyClient.cpp" }) catch unreachable;

        step.addIncludePath(.{ .path = public_path });
        step.addIncludePath(.{ .path = tracy_path });

        const tracy_lib = b.addStaticLibrary(.{
            .name = "tracy-lib",
            .target = step.target,
            .optimize = .ReleaseSafe,
        });
        tracy_lib.addCSourceFiles(&.{tracy_client_source_path}, &.{
            "-DTRACY_ENABLE",
            // MinGW doesn't have all the newfangled windows features,
            // so we need to pretend to have an older windows version.
            "-D_WIN32_WINNT=0x601",
            "-fno-sanitize=undefined",
        });
        tracy_lib.addIncludePath(.{ .path = public_path });
        tracy_lib.addIncludePath(.{ .path = tracy_path });
        tracy_lib.linkLibC();
        tracy_lib.linkSystemLibrary("c++");
        if (tracy_lib.target.isWindows()) {
            tracy_lib.linkSystemLibrary("Advapi32");
            tracy_lib.linkSystemLibrary("User32");
            tracy_lib.linkSystemLibrary("Ws2_32");
            tracy_lib.linkSystemLibrary("DbgHelp");
        }

        step.linkLibrary(tracy_lib);
    }
}
