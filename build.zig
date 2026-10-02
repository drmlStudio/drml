const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("drml/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "drml",
        .root_module = module,
    });
    b.installArtifact(exe);
    b.installFile("README.md", "share/drml/README.md");
    b.installFile("LICENSE", "share/drml/LICENSE");

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run drml");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = module,
    });
    const test_step = b.step("test", "Run drml tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
