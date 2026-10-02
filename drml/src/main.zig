const std = @import("std");
const package_checker = @import("package_checker.zig");
const package_manager = @import("package_manager.zig");

fn printUsage() void {
    std.debug.print("drml - a Zig package manager\n\n" ++
        "Usage:\n" ++
        "  drml init [directory]  Create a minimal package.json\n" ++
        "  drml build             Run the package.json build script\n" ++
        "  drml install           Read package.json and write drml-lock.json\n" ++
        "  drml install --lockfile-only  Only generate drml-lock.json\n" ++
        "  drml install --include-optional-peers  Install optional peer dependencies\n" ++
        "  drml install --omit-dev  Skip root/workspace devDependencies\n" ++
        "  drml install --run-scripts  Run dependency lifecycle scripts (default: ignore)\n" ++
        "  drml check             Find imports missing from package.json\n" ++
        "  drml --help            Show this help\n\n" ++
        "Exact versions are required. Lifecycle scripts are ignored unless\n" ++
        "--run-scripts is explicitly supplied.\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        if (args.len > 2) return error.InvalidArguments;
        printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "init")) {
        if (args.len > 3) return error.InvalidArguments;
        try package_manager.initProject(if (args.len >= 3) args[2] else ".");
        return;
    }

    if (std.mem.eql(u8, args[1], "check")) {
        if (args.len > 2) return error.InvalidArguments;
        var checker = package_checker.PackageChecker.init(allocator);
        _ = try checker.check();
        std.debug.print("drml check: no undeclared packages found\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "build")) {
        if (args.len > 2) return error.InvalidArguments;
        try package_manager.runScript(allocator, "build");
        return;
    }

    if (!std.mem.eql(u8, args[1], "install")) {
        printUsage();
        return error.UnknownCommand;
    }

    var manager = package_manager.PackageManager.init(allocator);
    var options = package_manager.InstallOptions{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--lockfile-only")) options.lockfile_only = true else if (std.mem.eql(u8, args[index], "--run-scripts")) options.run_scripts = true else if (std.mem.eql(u8, args[index], "--include-dev")) options.include_dev = true else if (std.mem.eql(u8, args[index], "--omit-dev")) options.include_dev = false else if (std.mem.eql(u8, args[index], "--include-optional-peers")) options.include_optional_peers = true else return error.InvalidArguments;
    }
    const count = try manager.installWithOptions(options);
    std.debug.print("wrote drml-lock.json with {d} direct entries\n", .{count});
}
