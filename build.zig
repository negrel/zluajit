const std = @import("std");

const luajit = @import("build/luajit.zig");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build shared library instead of static") orelse false;
    const lua52_compat = b.option(bool, "lua52-compat", "Enable Lua 5.2 compatibility layer") orelse false;

    const luajitLib = luajit.configure(
        b,
        target,
        optimize,
        b.dependency("luajit", .{}),
        shared,
        lua52_compat,
    );

    const module = b.addModule("zlua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .unwind_tables = .sync,
    });

    const lib = b.addStaticLibrary(.{
        .name = "zlua",
        .root_module = module,
    });
    lib.linkLibrary(luajitLib);

    b.installArtifact(lib);
    b.installArtifact(luajitLib);

    const lib_unit_tests = b.addTest(.{
        .root_module = module,
    });
    const install_lib_unit_tests = b.addInstallArtifact(lib_unit_tests, .{});
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&install_lib_unit_tests.step);
}
