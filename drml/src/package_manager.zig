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
        if (options.lockfile_only) {
            for (packages.items) |*package| {
                if (!package.git and !isExactVersion(package.version)) try resolvePackage(self.allocator, package);
            }
        }
        if (!options.lockfile_only) {
            if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
            try appendTransitivePackages(self.allocator, &packages, &package_indexes);
            try installPackages(self.allocator, packages.items, options.run_scripts);
            try linkWorkspacePackages(self.allocator, manifest.workspace_paths.items);
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
    git: bool = false,
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
fn isExactPrerelease(spec: []const u8) bool {
    return std.mem.indexOfScalar(u8, spec, '-') != null and
        !std.mem.startsWith(u8, spec, "^") and !std.mem.startsWith(u8, spec, "~") and
        !std.mem.startsWith(u8, spec, ">") and !std.mem.startsWith(u8, spec, "<") and
        !std.mem.startsWith(u8, spec, "=");
}

fn validateSpec(name: []const u8, spec: []const u8) !void {
    if (std.mem.startsWith(u8, spec, "workspace:")) return error.UnsupportedWorkspaceProtocol;
    if (isGitSpec(spec)) return;
    if (std.mem.indexOf(u8, spec, "://") != null) return error.UnsupportedDependencyProtocol;
    if (spec.len == 0) {
        std.debug.print("drml: {s}: empty dependency specification\n", .{name});
        return error.UnsupportedVersionRange;
    }
}

fn isGitSpec(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "git+") or
        std.mem.startsWith(u8, spec, "git://") or
        std.mem.startsWith(u8, spec, "github:");
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
            // A package can be listed in several manifest sections. Keep the
            // first request (root dependencies take precedence over dev,
            // optional, and peer entries) and merge the section markers. This
            // matches npm's one-package installation model and avoids
            // rejecting harmless repeats such as ^22.15.3 and 22.15.3.
            existing.dev = existing.dev and dev;
            existing.optional = existing.optional or optional;
            existing.peer = existing.peer or peer;
            continue;
        }
        const git = isGitSpec(entry.value_ptr.*);
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .requested = entry.value_ptr.*,
            .version = entry.value_ptr.*,
            .source = if (git)
                try allocator.dupe(u8, entry.value_ptr.*)
            else
                try std.fmt.allocPrint(allocator, "https://registry.npmjs.org/{s}/-/{s}-{s}.tgz", .{ entry.key_ptr.*, packageBasename(entry.key_ptr.*), entry.value_ptr.* }),
            .dev = dev,
            .optional = optional,
            .peer = peer,
            .git = git,
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
    var file = try std.fs.cwd().createFile("drml-lock.json.tmp", .{ .truncate = true });
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
    try std.fs.cwd().rename("drml-lock.json.tmp", "drml-lock.json");
    _ = allocator;
}

fn fetchRegistryMetadata(allocator: Allocator, name: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
    return fetchRegistryMetadataNative(allocator, name);
}

fn fetchRegistryMetadataNative(allocator: Allocator, name: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(allocator, "https://registry.npmjs.org/{s}", .{name});
    defer allocator.free(url);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.PackageNotFound;
    return try allocator.dupe(u8, body.writer.buffer[0..body.writer.end]);
}

const Version = struct { major: u64, minor: u64, patch: u64 };
const PartialVersion = struct { version: Version, components: u8 };

fn parsePartialVersion(value: []const u8) ?PartialVersion {
    var prerelease_parts = std.mem.splitScalar(u8, std.mem.trim(u8, value, " \t"), '-');
    const without_prerelease = prerelease_parts.next() orelse return null;
    var parts = std.mem.splitScalar(u8, without_prerelease, '.');
    var numbers: [3]u64 = .{ 0, 0, 0 };
    var count: u8 = 0;
    while (parts.next()) |part| {
        if (count == 3 or part.len == 0 or (part.len > 1 and part[0] == '0')) return null;
        numbers[count] = std.fmt.parseInt(u64, part, 10) catch return null;
        count += 1;
    }
    if (count == 0) return null;
    return .{ .version = .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] }, .components = count };
}

fn parseVersion(value: []const u8) ?Version {
    var prerelease_parts = std.mem.splitScalar(u8, value, '-');
    const without_prerelease = prerelease_parts.next() orelse return null;
    var parts = std.mem.splitScalar(u8, without_prerelease, '.');
    const major = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const patch_part = parts.next() orelse return null;
    if (std.mem.indexOfScalar(u8, patch_part, '-') != null) return null;
    const patch = std.fmt.parseInt(u64, patch_part, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn compareVersion(left: Version, right: Version) std.math.Order {
    if (left.major != right.major) return std.math.order(left.major, right.major);
    if (left.minor != right.minor) return std.math.order(left.minor, right.minor);
    return std.math.order(left.patch, right.patch);
}

fn satisfiesComparator(version: Version, comparator: []const u8) bool {
    const spec = std.mem.trim(u8, comparator, " \t");
    if (spec.len > 1 and spec[0] == '=') return satisfiesComparator(version, spec[1..]);
    if (spec.len == 0 or std.mem.eql(u8, spec, "*") or std.mem.eql(u8, spec, "x") or std.mem.eql(u8, spec, "X")) return true;
    if (std.mem.startsWith(u8, spec, "^")) {
        const partial = parsePartialVersion(spec[1..]) orelse return false;
        const base = partial.version;
        if (compareVersion(version, base) == .lt) return false;
        if (partial.components == 1) return version.major == base.major;
        if (base.major > 0) return version.major == base.major;
        if (base.minor > 0) return version.major == 0 and version.minor == base.minor;
        if (partial.components == 2) return version.major == 0 and version.minor == 0;
        return version.major == 0 and version.minor == 0 and version.patch == base.patch;
    }
    if (std.mem.startsWith(u8, spec, "~")) {
        const partial = parsePartialVersion(spec[1..]) orelse return false;
        const base = partial.version;
        if (compareVersion(version, base) == .lt or version.major != base.major) return false;
        return partial.components == 1 or version.minor == base.minor;
    }
    if (std.mem.startsWith(u8, spec, ">=")) {
        const base = (parsePartialVersion(spec[2..]) orelse return false).version;
        return compareVersion(version, base) != .lt;
    }
    if (std.mem.startsWith(u8, spec, ">")) {
        const base = (parsePartialVersion(spec[1..]) orelse return false).version;
        return compareVersion(version, base) == .gt;
    }
    if (std.mem.startsWith(u8, spec, "<=")) {
        const base = (parsePartialVersion(spec[2..]) orelse return false).version;
        return compareVersion(version, base) != .gt;
    }
    if (std.mem.startsWith(u8, spec, "<")) {
        const base = (parsePartialVersion(spec[1..]) orelse return false).version;
        return compareVersion(version, base) == .lt;
    }
    if (std.mem.indexOf(u8, spec, "||")) |separator| {
        return satisfiesRange(version, spec[0..separator]) or satisfiesRange(version, spec[separator + 2 ..]);
    }
    if (std.mem.endsWith(u8, spec, ".x") or std.mem.endsWith(u8, spec, ".*")) {
        const prefix = spec[0 .. spec.len - 2];
        var parts = std.mem.splitScalar(u8, prefix, '.');
        const major = std.fmt.parseInt(u64, parts.next() orelse return false, 10) catch return false;
        if (parts.next()) |minor_text| {
            const minor = std.fmt.parseInt(u64, minor_text, 10) catch return false;
            return version.major == major and version.minor == minor;
        }
        return version.major == major;
    }
    if (parseVersion(spec)) |exact| return compareVersion(version, exact) == .eq;
    if (parsePartialVersion(spec)) |partial| {
        if (partial.components == 1) return version.major == partial.version.major;
        if (partial.components == 2) return version.major == partial.version.major and version.minor == partial.version.minor;
    }
    return false;
}

fn satisfiesRange(version: Version, requested: []const u8) bool {
    const spec = std.mem.trim(u8, requested, " \t");
    if (std.mem.eql(u8, spec, "latest")) return true;
    var alternatives = std.mem.splitSequence(u8, spec, "||");
    while (alternatives.next()) |alternative| {
        var comparators = std.mem.tokenizeAny(u8, alternative, " \t");
        var matches = true;
        while (comparators.next()) |comparator| {
            if (!satisfiesComparator(version, comparator)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn selectVersion(allocator: Allocator, versions: std.json.ObjectMap, requested: []const u8) ![]const u8 {
    var selected: ?[]const u8 = null;
    var selected_version: ?Version = null;
    var it = versions.iterator();
    while (it.next()) |entry| {
        const version = parseVersion(entry.key_ptr.*) orelse continue;
        if (!satisfiesRange(version, requested)) continue;
        if (selected_version == null or compareVersion(version, selected_version.?) == .gt) {
            selected = entry.key_ptr.*;
            selected_version = version;
        }
    }
    return try allocator.dupe(u8, selected orelse return error.UnsupportedVersionRange);
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
    if (!isExactVersion(package.version)) {
        if (isExactPrerelease(package.requested) and versions.get(package.requested) != null) {
            package.version = try allocator.dupe(u8, package.requested);
        } else {
            const selected = try selectVersion(allocator, versions, package.requested);
            package.version = selected;
        }
    }
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

fn appendTransitivePackages(allocator: Allocator, packages: *std.ArrayList(LockedPackage), indexes: *std.StringHashMap(usize)) !void {
    var index: usize = 0;
    while (index < packages.items.len) : (index += 1) {
        const package = &packages.items[index];
        if (package.git) continue;
        resolvePackage(allocator, package) catch |err| {
            std.debug.print("drml: unable to resolve transitive {s}@{s}: {s}\n", .{ package.name, package.requested, @errorName(err) });
            return err;
        };
        const metadata_source = try fetchRegistryMetadata(allocator, package.name);
        defer allocator.free(metadata_source);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata_source, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidRegistryMetadata,
        };
        const versions = switch (root.get("versions") orelse return error.InvalidRegistryMetadata) {
            .object => |object| object,
            else => return error.InvalidRegistryMetadata,
        };
        const version_value = versions.get(package.version) orelse {
            std.debug.print("drml: metadata for {s}@{s} did not contain the selected version\n", .{ package.name, package.version });
            return error.PackageVersionNotFound;
        };
        const version_object = switch (version_value) {
            .object => |object| object,
            else => return error.InvalidRegistryMetadata,
        };
        for ([_][]const u8{ "dependencies", "optionalDependencies" }) |section| {
            const value = version_object.get(section) orelse continue;
            if (value != .object) return error.InvalidDependencySpec;
            var dependencies = try readObjectMap(allocator, value);
            defer dependencies.deinit();
            try appendPackages(allocator, packages, indexes, &dependencies, false, std.mem.eql(u8, section, "optionalDependencies"), false, true);
        }
    }
}

fn downloadPackage(allocator: Allocator, package: *const LockedPackage) ![]u8 {
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
    return downloadPackageNative(allocator, package);
}

fn downloadPackageNative(allocator: Allocator, package: *const LockedPackage) ![]u8 {
    try std.fs.cwd().makePath(".drml-cache");
    const cache_key = std.hash.Wyhash.hash(0, package.name);
    const archive = try std.fmt.allocPrint(allocator, ".drml-cache/{x}-{s}.tgz", .{ cache_key, package.version });
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{archive});
    defer allocator.free(temporary);
    const file = try std.fs.cwd().createFile(temporary, .{ .truncate = true });
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const result = client.fetch(.{
        .location = .{ .url = package.source },
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .response_writer = &writer.interface,
    }) catch |err| {
        file.close();
        std.fs.cwd().deleteFile(temporary) catch {};
        return err;
    };
    writer.interface.flush() catch |err| {
        file.close();
        std.fs.cwd().deleteFile(temporary) catch {};
        return err;
    };
    file.close();
    if (result.status != .ok) {
        std.fs.cwd().deleteFile(temporary) catch {};
        return error.PackageDownloadFailed;
    }
    verifyPackageIntegrity(allocator, temporary, package.integrity) catch |err| {
        std.fs.cwd().deleteFile(temporary) catch {};
        return err;
    };
    std.fs.cwd().rename(temporary, archive) catch |err| {
        std.fs.cwd().deleteFile(temporary) catch {};
        return err;
    };
    return archive;
}

fn verifyPackageIntegrity(allocator: Allocator, path: []const u8, integrity: ?[]const u8) !void {
    const expected = integrity orelse return;
    if (!std.mem.startsWith(u8, expected, "sha512-")) return error.UnsupportedIntegrity;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    defer allocator.free(contents);
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(contents, &digest, .{});
    var encoded: [88]u8 = undefined;
    const actual = std.base64.standard.Encoder.encode(&encoded, &digest);
    if (!std.mem.eql(u8, expected[7..], actual)) return error.PackageIntegrityMismatch;
}

fn extractPackage(allocator: Allocator, package: *const LockedPackage, archive: []const u8) !void {
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
    return extractPackageNative(allocator, package, archive);
}

fn extractPackageNative(allocator: Allocator, package: *const LockedPackage, archive: []const u8) !void {
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
        if (package.git) {
            try installGitPackage(allocator, package);
            if (run_scripts) try runPackageLifecycle(allocator, package);
            continue;
        }
        try resolvePackage(allocator, package);
        const archive = try downloadPackage(allocator, package);
        defer allocator.free(archive);
        try extractPackage(allocator, package, archive);
        if (run_scripts) try runPackageLifecycle(allocator, package);
        std.debug.print("drml: installed {s}@{s}\n", .{ package.name, package.version });
    }
}

fn installGitPackage(allocator: Allocator, package: *const LockedPackage) !void {
    try std.fs.cwd().makePath(".drml-cache");
    const cache_path = try std.fmt.allocPrint(allocator, ".drml-cache/git-{x}", .{std.hash.Wyhash.hash(0, package.source)});
    defer allocator.free(cache_path);
    try std.fs.cwd().deleteTree(cache_path);
    var allocated_source: ?[]const u8 = null;
    const source = if (std.mem.startsWith(u8, package.source, "git+")) package.source[4..] else if (std.mem.startsWith(u8, package.source, "github:")) blk: {
        allocated_source = try std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{package.source[7..]});
        break :blk allocated_source.?;
    } else package.source;
    defer if (allocated_source) |value| allocator.free(value);
    const clone_argv = [_][]const u8{ "git", "clone", "--depth", "1", source, cache_path };
    try runProcess(allocator, &clone_argv, null);
    const package_path = try std.fs.path.join(allocator, &.{ "node_modules", package.name });
    defer allocator.free(package_path);
    try std.fs.cwd().deleteTree(package_path);
    try std.fs.cwd().makePath(package_path);
    const copy_argv = [_][]const u8{ "cp", "-R", "-T", cache_path, package_path };
    try runProcess(allocator, &copy_argv, null);
    try linkPackageBinaries(allocator, package);
    std.debug.print("drml: installed {s} from {s}\n", .{ package.name, package.source });
}

fn packageNameAt(allocator: Allocator, manifest_path: []const u8) !?[]const u8 {
    const file = try std.fs.cwd().openFile(manifest_path, .{});
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    const name = root.get("name") orelse return null;
    const value = jsonString(name) orelse return error.InvalidManifest;
    return try allocator.dupe(u8, value);
}

fn linkWorkspacePackages(allocator: Allocator, manifests: []const []const u8) !void {
    try std.fs.cwd().makePath("node_modules");
    for (manifests) |manifest_path| {
        const name = (try packageNameAt(allocator, manifest_path)) orelse continue;
        defer allocator.free(name);
        const workspace_dir = std.fs.path.dirname(manifest_path) orelse continue;
        const target = try std.fs.cwd().realpathAlloc(allocator, workspace_dir);
        defer allocator.free(target);
        const link_path = try std.fs.path.join(allocator, &.{ "node_modules", name });
        defer allocator.free(link_path);
        if (std.fs.path.dirname(link_path)) |parent| try std.fs.cwd().makePath(parent);
        // A workspace can also appear as a normal dependency of another
        // workspace. In that case installation has already created a real
        // directory at this path; deleteFile only handles symlinks/files and
        // makes the subsequent symlink creation fail with PathAlreadyExists.
        std.fs.cwd().deleteTree(link_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try std.fs.cwd().symLink(target, link_path, .{});
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

fn runProcess(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    if (comptime builtin.os.tag == .wasi) return error.UnsupportedInstallerTarget;
    return runProcessNative(allocator, argv, cwd);
}

fn runProcessNative(allocator: Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    const local_bin = if (cwd) |directory|
        try std.fs.path.join(allocator, &.{ directory, "node_modules", ".bin" })
    else
        try allocator.dupe(u8, "node_modules/.bin");
    defer allocator.free(local_bin);
    const root_bin = if (cwd) |directory|
        try std.fs.path.join(allocator, &.{ directory, "..", ".bin" })
    else
        try allocator.dupe(u8, "node_modules/.bin");
    defer allocator.free(root_bin);
    const inherited_path = env.get("PATH") orelse "";
    const path = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ local_bin, root_bin, inherited_path });
    defer allocator.free(path);
    try env.put("PATH", path);
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .cwd = cwd, .env_map = &env, .max_output_bytes = 256 * 1024 });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ScriptFailed,
        else => return error.ScriptFailed,
    }
}

fn runCommand(allocator: Allocator, command: []const u8, cwd: ?[]const u8) !void {
    const argv = [_][]const u8{ "sh", "-c", command };
    try runProcess(allocator, &argv, cwd);
}

pub fn runScript(allocator: Allocator, script_name: []const u8, args: []const []const u8) !void {
    const pre_name = try std.fmt.allocPrint(allocator, "pre{s}", .{script_name});
    defer allocator.free(pre_name);
    if (try packageJsonScript(allocator, "package.json", pre_name)) |pre_command| {
        defer allocator.free(pre_command);
        try runCommand(allocator, pre_command, null);
    }
    const command = (try packageJsonScript(allocator, "package.json", script_name)) orelse return error.ScriptNotFound;
    defer allocator.free(command);
    try runScriptCommand(allocator, command, args, null);
    const post_name = try std.fmt.allocPrint(allocator, "post{s}", .{script_name});
    defer allocator.free(post_name);
    if (try packageJsonScript(allocator, "package.json", post_name)) |post_command| {
        defer allocator.free(post_command);
        try runCommand(allocator, post_command, null);
    }
}
fn runScriptCommand(allocator: Allocator, command: []const u8, args: []const []const u8, cwd: ?[]const u8) !void {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "sh", "-c", command, "drml-run" });
    try argv.appendSlice(allocator, args);
    try runProcess(allocator, argv.items, cwd);
}

pub fn execCommand(allocator: Allocator, argv: []const []const u8) !void {
    try runProcess(allocator, argv, null);
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

test "common semver ranges are accepted" {
    try std.testing.expect(satisfiesRange(.{ .major = 22, .minor = 16, .patch = 0 }, "^22.15.3"));
    try std.testing.expect(satisfiesRange(.{ .major = 4, .minor = 0, .patch = 0 }, "^4.0.0-rc.1"));
    try std.testing.expect(satisfiesRange(.{ .major = 0, .minor = 133, .patch = 0 }, "=0.133.0"));
    try std.testing.expect(satisfiesRange(.{ .major = 1, .minor = 3, .patch = 7 }, ">=1.0.0 <2.0.0"));
    try std.testing.expect(satisfiesRange(.{ .major = 2, .minor = 0, .patch = 0 }, "^1.0.0 || ^2.0.0"));
    try std.testing.expect(!satisfiesRange(.{ .major = 23, .minor = 0, .patch = 0 }, "^22.15.3"));
    try std.testing.expect(satisfiesRange(.{ .major = 1, .minor = 4, .patch = 9 }, "^1.2"));
    try std.testing.expect(satisfiesRange(.{ .major = 1, .minor = 2, .patch = 9 }, "~1.2"));
    try std.testing.expect(!satisfiesRange(.{ .major = 1, .minor = 3, .patch = 0 }, "~1.2"));
    try std.testing.expect(satisfiesRange(.{ .major = 3, .minor = 9, .patch = 0 }, "3"));
    try std.testing.expect(satisfiesRange(.{ .major = 0, .minor = 0, .patch = 9 }, "^0.0"));
}
