const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("drml/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (target.result.os.tag == .macos) {
        // Zig's macOS libc shims (dispatch, sysctl, realpath, and friends)
        // are provided by libSystem. Link it explicitly so both the native
        // executable and `zig build test` work with Xcode SDK toolchains.
        module.linkSystemLibrary("System", .{});
    }

    const exe = b.addExecutable(.{
        .name = "drml",
        .root_module = module,
    });

    b.installFile("drml/package.json", "package.json");
    b.installArtifact(exe);
    b.installFile("README.md", "README.md");
    b.installFile("drml/LICENSE", "LICENSE");
    b.installFile("drml/index.js", "index.js");
    b.installFile("drml/native.js", "native.js");
    b.installFile("drml/install.js", "install.js");

    const package_step = b.step("package", "Build a distributable npm package in zig-out");
    package_step.dependOn(b.getInstallStep());

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run drml");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = module,
    });
    if (target.result.os.tag == .macos) {
        // Keep the test link explicit as well; Zig does not always propagate
        // system libraries from a shared root module into addTest artifacts.
        tests.linkSystemLibrary("System");
    }
    const test_step = b.step("test", "Run drml tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
