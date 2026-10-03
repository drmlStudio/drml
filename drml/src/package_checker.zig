const std = @import("std");

const Allocator = std.mem.Allocator;

pub const PackageChecker = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) PackageChecker {
        return .{ .allocator = allocator };
    }

    pub fn check(self: *PackageChecker) !usize {
        var declared = try readDeclaredPackages(self.allocator);
        var root = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer root.close();
        const violations = try scanDirectory(self.allocator, root, "", &declared);

        if (violations != 0) return error.UndeclaredPackages;
        return 0;
    }
};

fn scanDirectory(allocator: Allocator, dir: std.fs.Dir, prefix: []const u8, declared: *std.StringHashMap(void)) !usize {
    var iterator = dir.iterate();
    var violations: usize = 0;
    while (try iterator.next()) |entry| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(path);

        if (entry.kind == .directory) {
            if (isIgnoredDirectory(entry.name)) continue;
            var child = try dir.openDir(entry.name, .{ .iterate = true });
            violations += try scanDirectory(allocator, child, path, declared);
            child.close();
        } else if (entry.kind == .file and isSourceFile(path) and !isIgnoredPath(path)) {
            violations += try checkFile(allocator, dir, entry.name, path, declared);
        }
    }
    return violations;
}

fn checkFile(allocator: Allocator, dir: std.fs.Dir, basename: []const u8, path: []const u8, declared: *std.StringHashMap(void)) !usize {
    const file = try dir.openFile(basename, .{});
    const source = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    file.close();
    defer allocator.free(source);

    var imports = std.StringHashMap(void).init(allocator);
    defer imports.deinit();
    try collectImports(allocator, source, &imports);

    var violations: usize = 0;
    var it = imports.keyIterator();
    while (it.next()) |specifier| {
        const package_name = packageName(specifier.*) orelse continue;
        if (!declared.contains(package_name)) {
            std.debug.print("drml check: {s}: imported package '{s}' is not declared in package.json\n", .{ path, package_name });
            violations += 1;
        }
    }
    return violations;
}

fn readDeclaredPackages(allocator: Allocator) !std.StringHashMap(void) {
    const file = try std.fs.cwd().openFile("package.json", .{});
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();

    var declared = std.StringHashMap(void).init(allocator);
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidManifest,
    };
    const sections = [_][]const u8{ "dependencies", "devDependencies", "optionalDependencies", "peerDependencies" };
    for (sections) |section| {
        if (root.get(section)) |value| {
            switch (value) {
                .object => |object| {
                    var it = object.iterator();
                    while (it.next()) |entry| try declared.put(try allocator.dupe(u8, entry.key_ptr.*), {});
                },
                else => return error.InvalidDependencySpec,
            }
        }
    }
    return declared;
}

fn isSourceFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".jsx") or
        std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".tsx") or
        std.mem.endsWith(u8, path, ".mjs") or
        std.mem.endsWith(u8, path, ".cjs") or
        std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts");
}

fn isIgnoredPath(path: []const u8) bool {
    const ignored = [_][]const u8{ "node_modules/", ".git/", "dist/", "build/", ".next/", ".turbo/", "coverage/", ".cache/" };
    for (ignored) |segment| if (std.mem.indexOf(u8, path, segment) != null) return true;
    return false;
}

fn isIgnoredDirectory(name: []const u8) bool {
    const ignored = [_][]const u8{ "node_modules", ".git", "dist", "build", ".next", ".turbo", "coverage", ".cache" };
    for (ignored) |segment| if (std.mem.eql(u8, name, segment)) return true;
    return false;
}

fn packageName(specifier: []const u8) ?[]const u8 {
    if (specifier.len == 0 or specifier[0] == '.' or specifier[0] == '/' or specifier[0] == '#') return null;
    if (std.mem.startsWith(u8, specifier, "node:")) return null;
    if (std.mem.eql(u8, specifier, "assert") or std.mem.eql(u8, specifier, "assert/strict") or
        std.mem.eql(u8, specifier, "async_hooks") or std.mem.eql(u8, specifier, "buffer") or
        std.mem.eql(u8, specifier, "child_process") or std.mem.eql(u8, specifier, "cluster") or
        std.mem.eql(u8, specifier, "console") or std.mem.eql(u8, specifier, "constants") or
        std.mem.eql(u8, specifier, "crypto") or std.mem.eql(u8, specifier, "dgram") or
        std.mem.eql(u8, specifier, "diagnostics_channel") or std.mem.eql(u8, specifier, "dns") or
        std.mem.eql(u8, specifier, "events") or std.mem.eql(u8, specifier, "fs") or
        std.mem.eql(u8, specifier, "fs/promises") or std.mem.eql(u8, specifier, "http") or
        std.mem.eql(u8, specifier, "https") or std.mem.eql(u8, specifier, "http2") or
        std.mem.eql(u8, specifier, "inspector") or std.mem.eql(u8, specifier, "module") or
        std.mem.eql(u8, specifier, "net") or std.mem.eql(u8, specifier, "os") or
        std.mem.eql(u8, specifier, "path") or std.mem.eql(u8, specifier, "perf_hooks") or
        std.mem.eql(u8, specifier, "process") or std.mem.eql(u8, specifier, "punycode") or
        std.mem.eql(u8, specifier, "querystring") or std.mem.eql(u8, specifier, "readline") or
        std.mem.eql(u8, specifier, "repl") or std.mem.eql(u8, specifier, "stream") or
        std.mem.eql(u8, specifier, "string_decoder") or std.mem.eql(u8, specifier, "timers") or
        std.mem.eql(u8, specifier, "test") or std.mem.eql(u8, specifier, "test/reporters") or
        std.mem.eql(u8, specifier, "timers/promises") or std.mem.eql(u8, specifier, "tls") or
        std.mem.eql(u8, specifier, "trace_events") or std.mem.eql(u8, specifier, "tty") or
        std.mem.eql(u8, specifier, "url") or std.mem.eql(u8, specifier, "util") or
        std.mem.eql(u8, specifier, "v8") or std.mem.eql(u8, specifier, "vm") or
        std.mem.eql(u8, specifier, "wasi") or std.mem.eql(u8, specifier, "worker_threads") or
        std.mem.eql(u8, specifier, "sqlite") or
        std.mem.eql(u8, specifier, "zlib")) return null;

    if (specifier[0] == '@') {
        const first = std.mem.indexOfScalar(u8, specifier, '/') orelse return specifier;
        const second = std.mem.indexOfScalarPos(u8, specifier, first + 1, '/') orelse return specifier;
        return specifier[0..second];
    }
    return if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| specifier[0..slash] else specifier;
}

fn skipTrivia(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len) {
        while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
        if (index + 1 < source.len and source[index] == '/' and source[index + 1] == '/') {
            index += 2;
            while (index < source.len and source[index] != '\n') : (index += 1) {}
            continue;
        }
        if (index + 1 < source.len and source[index] == '/' and source[index + 1] == '*') {
            index += 2;
            while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
            index = @min(index + 2, source.len);
            continue;
        }
        break;
    }
    return index;
}

fn skipRegex(source: []const u8, start: usize) usize {
    var index = start + 1;
    var in_class = false;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
        } else if (source[index] == '[') {
            in_class = true;
        } else if (source[index] == ']') {
            in_class = false;
        } else if (source[index] == '/' and !in_class) {
            index += 1;
            while (index < source.len and std.ascii.isAlphabetic(source[index])) : (index += 1) {}
            return index;
        }
    }
    return source.len;
}

fn isRegexStart(source: []const u8, index: usize) bool {
    if (index == 0) return true;
    var previous = index;
    while (previous > 0) {
        previous -= 1;
        if (!std.ascii.isWhitespace(source[previous])) break;
    }
    if (std.mem.indexOfScalar(u8, "=([{,:;!?&|", source[previous]) != null) return true;
    if (source[previous] == ')') return isControlParen(source, previous);

    const end = previous + 1;
    var start = end;
    while (start > 0 and (std.ascii.isAlphabetic(source[start - 1]) or source[start - 1] == '_')) : (start -= 1) {}
    if (start == end) return false;
    const word = source[start..end];
    const keywords = [_][]const u8{ "return", "throw", "case", "delete", "void", "typeof", "new", "yield", "await", "else", "do", "in", "of" };
    for (keywords) |keyword| if (std.mem.eql(u8, word, keyword)) return true;
    return false;
}

fn isControlParen(source: []const u8, close: usize) bool {
    var depth: usize = 1;
    var index = close;
    while (index > 0) {
        index -= 1;
        if (source[index] == ')') depth += 1;
        if (source[index] == '(') {
            depth -= 1;
            if (depth == 0) break;
        }
    }
    if (source[index] != '(') return false;
    var end = index;
    while (end > 0 and std.ascii.isWhitespace(source[end - 1])) : (end -= 1) {}
    var start = end;
    while (start > 0 and std.ascii.isAlphabetic(source[start - 1])) : (start -= 1) {}
    const word = source[start..end];
    return std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "while") or
        std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "with") or
        std.mem.eql(u8, word, "switch") or std.mem.eql(u8, word, "catch");
}

fn skipQuoted(source: []const u8, start: usize) usize {
    const quote = source[start];
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
        } else if (source[index] == quote) {
            return index + 1;
        }
    }
    return source.len;
}

fn quotedValue(source: []const u8, start: usize) ?struct { value: []const u8, end: usize } {
    if (start >= source.len or (source[start] != '\'' and source[start] != '"')) return null;
    const quote = source[start];
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
        } else if (source[index] == quote) {
            return .{ .value = source[start + 1 .. index], .end = index + 1 };
        }
    }
    return null;
}

fn wordAt(source: []const u8, start: usize, word: []const u8) bool {
    if (start + word.len > source.len or !std.mem.eql(u8, source[start .. start + word.len], word)) return false;
    const before_ok = start == 0 or !std.ascii.isAlphanumeric(source[start - 1]) and source[start - 1] != '_' and source[start - 1] != '$';
    const after = start + word.len;
    const after_ok = after == source.len or !std.ascii.isAlphanumeric(source[after]) and source[after] != '_' and source[after] != '$';
    return before_ok and after_ok;
}

fn collectImports(allocator: Allocator, source: []const u8, imports: *std.StringHashMap(void)) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\'' or source[index] == '"' or source[index] == '`') {
            index = skipQuoted(source, index);
            continue;
        }
        if (source[index] == '/' and (index + 1 >= source.len or (source[index + 1] != '/' and source[index + 1] != '*')) and isRegexStart(source, index)) {
            index = skipRegex(source, index);
            continue;
        }
        if (source[index] == '/' and index + 1 < source.len and source[index + 1] == '/') {
            index += 2;
            while (index < source.len and source[index] != '\n') : (index += 1) {}
            continue;
        }
        if (source[index] == '/' and index + 1 < source.len and source[index + 1] == '*') {
            index += 2;
            while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
            index = @min(index + 2, source.len);
            continue;
        }

        if (wordAt(source, index, "require")) {
            const open = skipTrivia(source, index + 7);
            if (open < source.len and source[open] == '(') {
                if (quotedValue(source, skipTrivia(source, open + 1))) |quoted| {
                    if (packageName(quoted.value)) |name| try imports.put(try allocator.dupe(u8, name), {});
                    index = quoted.end;
                    continue;
                }
            }
        } else if (wordAt(source, index, "import")) {
            const next = skipTrivia(source, index + 6);
            if (next < source.len and source[next] == '(') {
                if (quotedValue(source, skipTrivia(source, next + 1))) |quoted| {
                    if (packageName(quoted.value)) |name| try imports.put(try allocator.dupe(u8, name), {});
                    index = quoted.end;
                    continue;
                }
            } else if (quotedValue(source, next)) |quoted| {
                if (packageName(quoted.value)) |name| try imports.put(try allocator.dupe(u8, name), {});
                index = quoted.end;
                continue;
            } else {
                var scan = next;
                var braces: usize = 0;
                var found = false;
                while (scan < source.len) {
                    if (source[scan] == '/' and scan + 1 < source.len and (source[scan + 1] == '/' or source[scan + 1] == '*')) {
                        scan = skipTrivia(source, scan);
                        continue;
                    }
                    if (source[scan] == '\'' or source[scan] == '"' or source[scan] == '`') {
                        scan = skipQuoted(source, scan);
                        continue;
                    }
                    if (source[scan] == '{') braces += 1;
                    if (source[scan] == '}' and braces > 0) braces -= 1;
                    if (source[scan] == ';' and braces == 0) break;
                    if (wordAt(source, scan, "from")) {
                        const value_start = skipTrivia(source, scan + 4);
                        if (quotedValue(source, value_start)) |quoted| {
                            if (packageName(quoted.value)) |name| try imports.put(try allocator.dupe(u8, name), {});
                            index = quoted.end;
                            found = true;
                            break;
                        }
                    }
                    scan += 1;
                }
                if (found) continue;
            }
        } else if (wordAt(source, index, "export")) {
            var scan = skipTrivia(source, index + 6);
            var braces: usize = 0;
            while (scan < source.len) {
                if (source[scan] == '/' and scan + 1 < source.len and (source[scan + 1] == '/' or source[scan + 1] == '*')) {
                    scan = skipTrivia(source, scan);
                    continue;
                }
                if (source[scan] == '\'' or source[scan] == '"' or source[scan] == '`') {
                    scan = skipQuoted(source, scan);
                    continue;
                }
                if (source[scan] == '{') braces += 1;
                if (source[scan] == '}' and braces > 0) braces -= 1;
                if (source[scan] == ';' and braces == 0) break;
                if (wordAt(source, scan, "from")) {
                    const value_start = skipTrivia(source, scan + 4);
                    if (quotedValue(source, value_start)) |quoted| {
                        if (packageName(quoted.value)) |name| try imports.put(try allocator.dupe(u8, name), {});
                        index = quoted.end;
                        break;
                    }
                }
                scan += 1;
            }
        }
        index += 1;
    }
}

test "normalizes package names and ignores local and builtin imports" {
    try std.testing.expectEqualStrings("react", packageName("react/jsx-runtime").?);
    try std.testing.expectEqualStrings("@scope/pkg", packageName("@scope/pkg/subpath").?);
    try std.testing.expect(packageName("./local") == null);
    try std.testing.expect(packageName("node:fs") == null);
    try std.testing.expect(packageName("fs/promises") == null);
    try std.testing.expect(packageName("test") == null);
    try std.testing.expect(packageName("test/reporters") == null);
    try std.testing.expect(packageName("inspector") == null);
}
