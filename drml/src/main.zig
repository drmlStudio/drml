const std = @import("std");
const package_checker = @import("package_checker.zig");
const package_manager = @import("package_manager.zig");

fn printUsage() void {
    std.debug.print("drml - a Zig package manager\n\n" ++
        "Usage:\n" ++
        "  drml init [directory]  Create a minimal package.json\n" ++
        "  drml build             Run the package.json build script\n" ++
        "  drml run <script>      Run a package.json script\n" ++
        "  drml exec <command>    Run a command directly\n" ++
        "  drml add <packages...> Add dependencies; --dev switches to devDependencies\n" ++
        "  drml install           Read package.json and write drml-lock.json\n" ++
        "  drml install --lockfile-only  Only generate drml-lock.json\n" ++
        "  drml install --include-optional-peers  Install optional peer dependencies\n" ++
        "  drml install --omit-dev  Skip root/workspace devDependencies\n" ++
        "  drml install --run-scripts  Run dependency lifecycle scripts (default: ignore)\n" ++
        "  drml check             Find imports missing from package.json\n" ++
        "  --verbose             Show resolver progress\n" ++
        "  --json                Emit machine-readable output\n" ++
        "  drml --help            Show this help\n" ++
        "  drml --version         Show the CLI version\n\n" ++
        "Exact versions and common semver ranges are supported. Existing npm-family\n" ++
        "lockfiles are ignored; lifecycle scripts run only with --run-scripts.\n", .{});
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        std.fs.File.stdout().deprecatedWriter().print("0.1.0-beta.2\n", .{}) catch return error.WriteFailed;
        return;
    }

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
        try package_manager.runScript(allocator, "build", if (args.len > 2) args[2..] else &.{});
        return;
    }

    if (std.mem.eql(u8, args[1], "run")) {
        if (args.len < 3) return error.InvalidArguments;
        try package_manager.runScript(allocator, args[2], if (args.len > 3) args[3..] else &.{});
        return;
    }

    if (std.mem.eql(u8, args[1], "exec")) {
        if (args.len < 3) return error.InvalidArguments;
        try package_manager.execCommand(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, args[1], "add")) {
        var regular = std.ArrayList([]const u8){};
        defer regular.deinit(allocator);
        var development = std.ArrayList([]const u8){};
        defer development.deinit(allocator);
        var dev_mode = false;
        var json = false;
        var verbose = false;
        var index: usize = 2;
        if (index < args.len and std.mem.eql(u8, args[index], "dev")) {
            dev_mode = true;
            index += 1;
        }
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--dev")) {
                dev_mode = true;
            } else if (std.mem.eql(u8, args[index], "--json")) {
                json = true;
            } else if (std.mem.eql(u8, args[index], "--verbose")) {
                verbose = true;
            } else if (dev_mode) {
                try development.append(allocator, args[index]);
            } else {
                try regular.append(allocator, args[index]);
            }
        }
        if (regular.items.len == 0 and development.items.len == 0) return error.InvalidArguments;
        try package_manager.addDependencies(allocator, regular.items, development.items);
        var manager = package_manager.PackageManager.init(allocator);
        const count = try manager.installWithOptions(.{ .verbose = verbose, .json = json });
        package_manager.finishProgress();
        if (json) {
            std.fs.File.stdout().deprecatedWriter().print("{{\"command\":\"add\",\"ok\":true,\"installed\":{d},\"dependencies\":{d},\"devDependencies\":{d},\"verbose\":{s}}}\n", .{
                count, regular.items.len, development.items.len, if (verbose) "true" else "false",
            }) catch return error.WriteFailed;
        } else {
            std.debug.print("\x1b[32m✓\x1b[0m added {d} package{s} ({d} dependencies, {d} devDependencies)\n", .{
                regular.items.len + development.items.len,
                if (regular.items.len + development.items.len == 1) "" else "s",
                regular.items.len,
                development.items.len,
            });
        }
        return;
    }

    if (!std.mem.eql(u8, args[1], "install")) {
        package_manager.runScript(allocator, args[1], if (args.len > 2) args[2..] else &.{}) catch |err| switch (err) {
            error.ScriptNotFound => {
                printUsage();
                return error.UnknownCommand;
            },
            else => return err,
        };
        return;
    }

    var manager = package_manager.PackageManager.init(allocator);
    var options = package_manager.InstallOptions{};
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--lockfile-only")) options.lockfile_only = true else if (std.mem.eql(u8, args[index], "--run-scripts")) options.run_scripts = true else if (std.mem.eql(u8, args[index], "--include-dev")) options.include_dev = true else if (std.mem.eql(u8, args[index], "--omit-dev")) options.include_dev = false else if (std.mem.eql(u8, args[index], "--include-optional-peers")) options.include_optional_peers = true else if (std.mem.eql(u8, args[index], "--verbose")) options.verbose = true else if (std.mem.eql(u8, args[index], "--json")) options.json = true else return error.InvalidArguments;
    }
    const count = try manager.installWithOptions(options);
    package_manager.finishProgress();
    if (options.json) {
        std.fs.File.stdout().deprecatedWriter().print("{{\"command\":\"install\",\"ok\":true,\"packages\":{d},\"verbose\":{s}}}\n", .{ count, if (options.verbose) "true" else "false" }) catch return error.WriteFailed;
    } else {
        std.debug.print("\x1b[32m✓\x1b[0m wrote drml-lock.json with {d} packages\n", .{count});
    }
}
