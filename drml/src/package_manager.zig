const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const PackageManager = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) PackageManager {
        return .{ .allocator = allocator };
    }

    pub fn install(self: *PackageManager) !usize {
        return self.installWithOptions(false);
    }

    pub fn installWithOptions(self: *PackageManager, lockfile_only: bool) !usize {
        if (findForeignLockfile()) |lockfile| {
            std.debug.print("drml: found {s}; import support is not enabled yet, refusing to ignore it\n", .{lockfile});
            return error.ForeignLockfilePresent;
        }

        var manifest = try readManifest(self.allocator, "package.json");
        if (manifest.has_workspaces) {
            std.debug.print("drml: workspaces detected; recursive monorepo resolution is not enabled yet\n", .{});
            return error.UnsupportedWorkspaces;
        }

        var packages = std.ArrayList(LockedPackage){};
        var package_indexes = std.StringHashMap(usize).init(self.allocator);
        try appendPackages(self.allocator, &packages, &package_indexes, &manifest.dependencies, false, false, false);
        try appendPackages(self.allocator, &packages, &package_indexes, &manifest.dev_dependencies, true, false, false);
        try appendPackages(self.allocator, &packages, &package_indexes, &manifest.optional_dependencies, false, true, false);
        try appendPackages(self.allocator, &packages, &package_indexes, &manifest.peer_dependencies, false, false, true);
        if (!lockfile_only) {
            if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
            try installPackages(self.allocator, packages.items);
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
            .array, .object => manifest.has_workspaces = true,
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

fn appendPackages(allocator: Allocator, list: *std.ArrayList(LockedPackage), indexes: *std.StringHashMap(usize), map: *std.StringHashMap([]const u8), dev: bool, optional: bool, peer: bool) !void {
    var it = map.iterator();
    while (it.next()) |entry| {
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

fn installPackages(allocator: Allocator, packages: []LockedPackage) !void {
    for (packages) |*package| {
        std.debug.print("drml: resolving {s}@{s}\n", .{ package.name, package.version });
        try resolvePackage(allocator, package);
        const archive = try downloadPackage(allocator, package);
        defer allocator.free(archive);
        try extractPackage(allocator, package, archive);
        std.debug.print("drml: installed {s}@{s}\n", .{ package.name, package.version });
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
