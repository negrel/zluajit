const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lua = b.option([]const u8, "lua", "Lua library to link");

    const module = b.addModule("zlua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (lua != null)
        module.linkSystemLibrary(lua.?, .{});

    const lib = b.addStaticLibrary(.{
        .name = "zlua",
        .root_module = module,
    });

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = module,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
