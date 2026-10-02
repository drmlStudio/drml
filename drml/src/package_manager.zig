const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const InstallOptions = struct {
    lockfile_only: bool = false,
    run_scripts: bool = false,
    include_dev: bool = true,
    include_optional_peers: bool = false,
};

pub const PackageManager = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) PackageManager {
        return .{ .allocator = allocator };
    }

    pub fn install(self: *PackageManager) !usize {
        return self.installWithOptions(.{});
    }

    pub fn installWithOptions(self: *PackageManager, options: InstallOptions) !usize {
        if (findForeignLockfile()) |lockfile| {
            std.debug.print("drml: found {s}; import support is not enabled yet, refusing to ignore it\n", .{lockfile});
            return error.ForeignLockfilePresent;
        }

        var manifest = try readManifest(self.allocator, "package.json");
        var packages = std.ArrayList(LockedPackage){};
        var package_indexes = std.StringHashMap(usize).init(self.allocator);
        try appendPackages(self.allocator, &packages, &package_indexes, &manifest.dependencies, false, false, false, manifest.has_workspaces);
        if (options.include_dev) try appendPackages(self.allocator, &packages, &package_indexes, &manifest.dev_dependencies, true, false, false, manifest.has_workspaces);
        try appendPackages(self.allocator, &packages, &package_indexes, &manifest.optional_dependencies, false, true, false, manifest.has_workspaces);
        try appendPeerPackages(self.allocator, &packages, &package_indexes, &manifest, false, manifest.has_workspaces);
        if (options.include_optional_peers) try appendPeerPackages(self.allocator, &packages, &package_indexes, &manifest, true, manifest.has_workspaces);
        for (manifest.workspace_paths.items) |workspace_manifest_path| {
            var workspace = try readManifest(self.allocator, workspace_manifest_path);
            try appendPackages(self.allocator, &packages, &package_indexes, &workspace.dependencies, false, false, false, true);
            if (options.include_dev) try appendPackages(self.allocator, &packages, &package_indexes, &workspace.dev_dependencies, true, false, false, true);
            try appendPackages(self.allocator, &packages, &package_indexes, &workspace.optional_dependencies, false, true, false, true);
            try appendPeerPackages(self.allocator, &packages, &package_indexes, &workspace, false, true);
            if (options.include_optional_peers) try appendPeerPackages(self.allocator, &packages, &package_indexes, &workspace, true, true);
        }
        if (!options.lockfile_only) {
            if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
            try installPackages(self.allocator, packages.items, options.run_scripts);
        }
        try writeLockfile(self.allocator, &manifest, packages.items);
        return packages.items.len;
    }
};

const Manifest = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    dependencies: std.StringHashMap([]const u8),
    dev_dependencies: std.StringHashMap([]const u8),
    optional_dependencies: std.StringHashMap([]const u8),
    peer_dependencies: std.StringHashMap([]const u8),
    optional_peers: std.StringHashMap(bool),
    package_manager: ?[]const u8 = null,
    has_workspaces: bool = false,
    workspace_paths: std.ArrayList([]const u8),
};

const LockedPackage = struct {
    name: []const u8,
    requested: []const u8,
    version: []const u8,
    source: []const u8,
    integrity: ?[]const u8 = null,
    dev: bool,
    optional: bool,
    peer: bool,
};

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn readObjectMap(allocator: Allocator, root: ?std.json.Value) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(allocator);
    if (root == null) return result;
    switch (root.?) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const value = jsonString(entry.value_ptr.*) orelse return error.InvalidDependencySpec;
                try result.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, value));
            }
        },
        else => return error.InvalidDependencySpec,
    }
    return result;
}

fn collectWorkspacePaths(allocator: Allocator, paths: *std.ArrayList([]const u8), pattern: []const u8) !void {
    const wildcard = std.mem.indexOfAny(u8, pattern, "*") orelse {
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{pattern});
        if (std.fs.cwd().access(manifest_path, .{})) |_| try paths.append(allocator, manifest_path) else |_| allocator.free(manifest_path);
        return;
    };
    const slash = std.mem.lastIndexOfScalar(u8, pattern[0..wildcard], '/') orelse 0;
    const base = if (slash == 0) "." else pattern[0..slash];
    var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return;
    defer dir.close();
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        const child = if (slash == 0) entry.name else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name });
        defer if (slash != 0) allocator.free(child);
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{child});
        if (std.fs.cwd().access(manifest_path, .{})) |_| try paths.append(allocator, manifest_path) else |_| allocator.free(manifest_path);
    }
}

fn readManifest(allocator: Allocator, path: []const u8) !Manifest {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };

    var manifest = Manifest{
        .dependencies = try readObjectMap(allocator, root.get("dependencies")),
        .dev_dependencies = try readObjectMap(allocator, root.get("devDependencies")),
        .optional_dependencies = try readObjectMap(allocator, root.get("optionalDependencies")),
        .peer_dependencies = try readObjectMap(allocator, root.get("peerDependencies")),
        .optional_peers = std.StringHashMap(bool).init(allocator),
        .workspace_paths = std.ArrayList([]const u8){},
    };
    if (root.get("name")) |value| {
        if (jsonString(value)) |name| manifest.name = try allocator.dupe(u8, name);
    }
    if (root.get("version")) |value| {
        if (jsonString(value)) |version| manifest.version = try allocator.dupe(u8, version);
    }
    if (root.get("packageManager")) |value| {
        if (jsonString(value)) |package_manager| {
            manifest.package_manager = try allocator.dupe(u8, package_manager);
        } else return error.InvalidPackageManager;
    }
    if (root.get("workspaces")) |value| {
        switch (value) {
            .array => |items| {
                manifest.has_workspaces = true;
                for (items.items) |item| {
                    const pattern = jsonString(item) orelse return error.InvalidWorkspaces;
                    try collectWorkspacePaths(allocator, &manifest.workspace_paths, pattern);
                }
            },
            .object => |object| {
                manifest.has_workspaces = true;
                const packages = object.get("packages") orelse return error.InvalidWorkspaces;
                const items = switch (packages) {
                    .array => |array| array,
                    else => return error.InvalidWorkspaces,
                };
                for (items.items) |item| {
                    const pattern = jsonString(item) orelse return error.InvalidWorkspaces;
                    try collectWorkspacePaths(allocator, &manifest.workspace_paths, pattern);
                }
            },
            else => return error.InvalidWorkspaces,
        }
    }
    if (root.get("peerDependenciesMeta")) |meta_value| switch (meta_value) {
        .object => |meta| {
            var it = meta.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.object.get("optional")) |optional| {
                        if (optional == .bool and optional.bool) {
                            try manifest.optional_peers.put(try allocator.dupe(u8, entry.key_ptr.*), true);
                        }
                    }
                }
            }
        },
        else => return error.InvalidDependencySpec,
    };
    return manifest;
}

fn isExactVersion(spec: []const u8) bool {
    var parts = std.mem.splitScalar(u8, spec, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (part.len == 0 or (part.len > 1 and part[0] == '0')) return false;
        for (part) |character| if (character < '0' or character > '9') return false;
    }
    return count == 3;
}

fn validateSpec(name: []const u8, spec: []const u8) !void {
    if (std.mem.startsWith(u8, spec, "workspace:")) return error.UnsupportedWorkspaceProtocol;
    if (std.mem.indexOf(u8, spec, "://") != null or std.mem.startsWith(u8, spec, "git")) {
        return error.UnsupportedDependencyProtocol;
    }
    if (!isExactVersion(spec)) {
        std.debug.print("drml: {s}@{s}: only exact x.y.z versions are supported in this milestone\n", .{ name, spec });
        return error.UnsupportedVersionRange;
    }
}

fn appendPackages(allocator: Allocator, list: *std.ArrayList(LockedPackage), indexes: *std.StringHashMap(usize), map: *std.StringHashMap([]const u8), dev: bool, optional: bool, peer: bool, allow_workspace_protocol: bool) !void {
    var it = map.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.value_ptr.*, "workspace:")) {
            if (!allow_workspace_protocol) return error.UnsupportedWorkspaceProtocol;
            continue;
        }
        try validateSpec(entry.key_ptr.*, entry.value_ptr.*);
        if (indexes.get(entry.key_ptr.*)) |existing_index| {
            const existing = &list.items[existing_index];
            if (!std.mem.eql(u8, existing.requested, entry.value_ptr.*)) return error.ConflictingDependencySpec;
            existing.dev = existing.dev and dev;
            existing.optional = existing.optional or optional;
            existing.peer = existing.peer or peer;
            continue;
        }
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .requested = entry.value_ptr.*,
            .version = entry.value_ptr.*,
            .source = try std.fmt.allocPrint(allocator, "https://registry.npmjs.org/{s}/-/{s}-{s}.tgz", .{ entry.key_ptr.*, packageBasename(entry.key_ptr.*), entry.value_ptr.* }),
            .dev = dev,
            .optional = optional,
            .peer = peer,
        });
        try indexes.put(try allocator.dupe(u8, entry.key_ptr.*), list.items.len - 1);
    }
}

fn packageBasename(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name[slash + 1 ..] else name;
}

fn appendPeerPackages(allocator: Allocator, list: *std.ArrayList(LockedPackage), indexes: *std.StringHashMap(usize), manifest: *Manifest, optional_only: bool, allow_workspace_protocol: bool) !void {
    var it = manifest.peer_dependencies.iterator();
    while (it.next()) |entry| {
        const is_optional = manifest.optional_peers.contains(entry.key_ptr.*);
        if (is_optional != optional_only) continue;
        var one = std.StringHashMap([]const u8).init(allocator);
        defer one.deinit();
        try one.put(entry.key_ptr.*, entry.value_ptr.*);
        try appendPackages(allocator, list, indexes, &one, false, false, true, allow_workspace_protocol);
    }
}

fn writeLockfile(allocator: Allocator, manifest: *Manifest, packages: []LockedPackage) !void {
    var file = try std.fs.cwd().createFile("drml-lock.json", .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.writeAll("{\n  \"lockfileVersion\": 1,\n  \"name\": ");
    try writer.interface.print("{f}", .{std.json.fmt(manifest.name orelse "", .{})});
    try writer.interface.writeAll(",\n  \"packageManager\": ");
    if (manifest.package_manager) |package_manager| {
        try writer.interface.print("{f}", .{std.json.fmt(package_manager, .{})});
    } else {
        try writer.interface.writeAll("null");
    }
    try writer.interface.writeAll(",\n  \"packages\": {\n");
    for (packages, 0..) |package, index| {
        if (index != 0) try writer.interface.writeAll(",\n");
        try writer.interface.writeAll("    ");
        try writer.interface.print("{f}", .{std.json.fmt(package.name, .{})});
        try writer.interface.writeAll(": {");
        try writer.interface.writeAll("\"requested\":");
        try writer.interface.print("{f}", .{std.json.fmt(package.requested, .{})});
        try writer.interface.writeAll(",\"version\":");
        try writer.interface.print("{f}", .{std.json.fmt(package.version, .{})});
        try writer.interface.writeAll(",\"source\":");
        try writer.interface.print("{f}", .{std.json.fmt(package.source, .{})});
        try writer.interface.writeAll(",\"integrity\":");
        if (package.integrity) |integrity| {
            try writer.interface.print("{f}", .{std.json.fmt(integrity, .{})});
        } else {
            try writer.interface.writeAll("null");
        }
        try writer.interface.print(",\"dev\":{s},\"optional\":{s},\"peer\":{s}}}", .{
            if (package.dev) "true" else "false",
            if (package.optional) "true" else "false",
            if (package.peer) "true" else "false",
        });
    }
    try writer.interface.writeAll("\n  }\n}\n");
    try writer.interface.flush();
    _ = allocator;
}

fn fetchRegistryMetadata(allocator: Allocator, name: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://registry.npmjs.org/{s}", .{name});
    defer allocator.free(url);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.PackageNotFound;
    return try allocator.dupe(u8, body.writer.buffer[0..body.writer.end]);
}

fn resolvePackage(allocator: Allocator, package: *LockedPackage) !void {
    const metadata_source = try fetchRegistryMetadata(allocator, package.name);
    defer allocator.free(metadata_source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata_source, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidRegistryMetadata,
    };
    const versions_value = root.get("versions") orelse return error.InvalidRegistryMetadata;
    const versions = switch (versions_value) {
        .object => |object| object,
        else => return error.InvalidRegistryMetadata,
    };
    const version_value = versions.get(package.version) orelse return error.PackageVersionNotFound;
    const version_object = switch (version_value) {
        .object => |object| object,
        else => return error.InvalidRegistryMetadata,
    };
    const dist_value = version_object.get("dist") orelse return error.InvalidRegistryMetadata;
    const dist = switch (dist_value) {
        .object => |object| object,
        else => return error.InvalidRegistryMetadata,
    };
    const tarball = jsonString(dist.get("tarball") orelse return error.InvalidRegistryMetadata) orelse return error.InvalidRegistryMetadata;
    package.source = try allocator.dupe(u8, tarball);
    if (dist.get("integrity")) |integrity_value| {
        if (jsonString(integrity_value)) |integrity| package.integrity = try allocator.dupe(u8, integrity);
    }
}

fn downloadPackage(allocator: Allocator, package: *const LockedPackage) ![]u8 {
    try std.fs.cwd().makePath(".drml-cache");
    const cache_key = std.hash.Wyhash.hash(0, package.name);
    const archive = try std.fmt.allocPrint(allocator, ".drml-cache/{x}-{s}.tgz", .{ cache_key, package.version });
    const file = try std.fs.cwd().createFile(archive, .{});
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const result = client.fetch(.{
        .location = .{ .url = package.source },
        .response_writer = &writer.interface,
    }) catch |err| {
        file.close();
        return err;
    };
    try writer.interface.flush();
    file.close();
    if (result.status != .ok) return error.PackageDownloadFailed;
    return archive;
}

fn extractPackage(allocator: Allocator, package: *const LockedPackage, archive: []const u8) !void {
    const package_path = try std.fs.path.join(allocator, &.{ "node_modules", package.name });
    defer allocator.free(package_path);
    try std.fs.cwd().deleteTree(package_path);
    try std.fs.cwd().makePath(package_path);
    const argv = [_][]const u8{ "tar", "-xzf", archive, "-C", package_path, "--strip-components=1", "--no-same-owner", "--no-same-permissions" };
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = &argv, .max_output_bytes = 64 * 1024 });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.TarExtractionFailed,
        else => return error.TarExtractionFailed,
    }
    try linkPackageBinaries(allocator, package);
}

fn linkPackageBinaries(allocator: Allocator, package: *const LockedPackage) !void {
    const package_path = try std.fs.path.join(allocator, &.{ "node_modules", package.name, "package.json" });
    defer allocator.free(package_path);
    const file = std.fs.cwd().openFile(package_path, .{}) catch return;
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const bin = root.get("bin") orelse return;
    try std.fs.cwd().makePath("node_modules/.bin");
    switch (bin) {
        .string => |target| try linkOneBinary(allocator, package, packageBasename(package.name), target),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const target = jsonString(entry.value_ptr.*) orelse continue;
                try linkOneBinary(allocator, package, entry.key_ptr.*, target);
            }
        },
        else => {},
    }
}

fn linkOneBinary(allocator: Allocator, package: *const LockedPackage, name: []const u8, target: []const u8) !void {
    const link_path = try std.fs.path.join(allocator, &.{ "node_modules", ".bin", name });
    defer allocator.free(link_path);
    const target_path = try std.fmt.allocPrint(allocator, "../{s}/{s}", .{ package.name, target });
    defer allocator.free(target_path);
    if (std.fs.cwd().access(link_path, .{})) |_| {
        try std.fs.cwd().deleteFile(link_path);
    } else |_| {}
    try std.fs.cwd().symLink(target_path, link_path, .{});
}

fn installPackages(allocator: Allocator, packages: []LockedPackage, run_scripts: bool) !void {
    for (packages) |*package| {
        std.debug.print("drml: resolving {s}@{s}\n", .{ package.name, package.version });
        try resolvePackage(allocator, package);
        const archive = try downloadPackage(allocator, package);
        defer allocator.free(archive);
        try extractPackage(allocator, package, archive);
        if (run_scripts) try runPackageLifecycle(allocator, package);
        std.debug.print("drml: installed {s}@{s}\n", .{ package.name, package.version });
    }
}

fn packageJsonScript(allocator: Allocator, path: []const u8, script_name: []const u8) !?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| return err;
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    const scripts = root.get("scripts") orelse return null;
    const object = switch (scripts) {
        .object => |value| value,
        else => return error.InvalidScripts,
    };
    const command = object.get(script_name) orelse return null;
    const value = jsonString(command) orelse return error.InvalidScripts;
    return try allocator.dupe(u8, value);
}

fn runCommand(allocator: Allocator, command: []const u8, cwd: ?[]const u8) !void {
    const argv = [_][]const u8{ "sh", "-c", command };
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = &argv, .cwd = cwd, .max_output_bytes = 256 * 1024 });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ScriptFailed,
        else => return error.ScriptFailed,
    }
}

pub fn runScript(allocator: Allocator, script_name: []const u8) !void {
    const command = (try packageJsonScript(allocator, "package.json", script_name)) orelse return error.ScriptNotFound;
    defer allocator.free(command);
    try runCommand(allocator, command, null);
}

fn runPackageLifecycle(allocator: Allocator, package: *const LockedPackage) !void {
    const package_path = try std.fs.path.join(allocator, &.{ "node_modules", package.name });
    defer allocator.free(package_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ package_path, "package.json" });
    defer allocator.free(manifest_path);
    const lifecycle = [_][]const u8{ "preinstall", "install", "postinstall" };
    for (lifecycle) |name| {
        const command = (try packageJsonScript(allocator, manifest_path, name)) orelse continue;
        defer allocator.free(command);
        std.debug.print("drml: running {s} for {s}\n", .{ name, package.name });
        try runCommand(allocator, command, package_path);
    }
}

fn findForeignLockfile() ?[]const u8 {
    const candidates = [_][]const u8{ "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb" };
    for (candidates) |candidate| {
        if (std.fs.cwd().access(candidate, .{})) |_| return candidate else |_| {}
    }
    return null;
}

pub fn initProject(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
    const full = try std.fs.path.join(std.heap.page_allocator, &.{ path, "package.json" });
    defer std.heap.page_allocator.free(full);
    var file = try std.fs.cwd().createFile(full, .{ .exclusive = true });
    defer file.close();
    try file.writeAll("{\n  \"name\": \"drml-project\",\n  \"version\": \"0.1.0\",\n  \"private\": true,\n  \"dependencies\": {}\n}\n");
    std.debug.print("created {s}\n", .{full});
}

test "exact versions are accepted" {
    try validateSpec("demo", "1.2.3");
    try std.testing.expect(isExactVersion("1.2.3"));
    try std.testing.expect(!isExactVersion("^1.2.3"));
}
