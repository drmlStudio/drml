const std = @import("std");
const package_checker = @import("package_checker.zig");
const package_manager = @import("package_manager.zig");

fn printUsage() void {
    std.debug.print("drml - a Zig package manager\n\n" ++
        "Usage:\n" ++
        "  drml init [directory]  Create a minimal package.json\n" ++
        "  drml install           Read package.json and write drml-lock.json\n" ++
        "  drml install --lockfile-only  Only generate drml-lock.json\n" ++
        "  drml check             Find imports missing from package.json\n" ++
        "  drml --help            Show this help\n\n" ++
        "The first milestone is intentionally strict: exact versions and the\n" ++
        "standard dependency fields are accepted; unsupported protocols/ranges\n" ++
        "fail instead of silently producing a misleading lockfile.\n", .{});
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

    if (!std.mem.eql(u8, args[1], "install")) {
        printUsage();
        return error.UnknownCommand;
    }

    if (args.len > 3 or (args.len == 3 and !std.mem.eql(u8, args[2], "--lockfile-only"))) return error.InvalidArguments;

    var manager = package_manager.PackageManager.init(allocator);
    const count = try manager.installWithOptions(args.len == 3);
    std.debug.print("wrote drml-lock.json with {d} direct entries\n", .{count});
}
