const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Kind = enum { bsdtar, @"7zz", @"7z" };

pub const search_order = [_]Kind{ .bsdtar, .@"7zz", .@"7z" };

pub const Tool = struct {
    kind: Kind,
    path: []const u8,
};

pub fn find(arena: Allocator, io: Io, env: *const Environ.Map) !?Tool {
    const path_var = env.get("PATH") orelse return null;
    for (search_order) |kind| {
        var dirs = std.mem.splitScalar(u8, path_var, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
            const full = try std.fs.path.join(arena, &.{ dir, @tagName(kind) });
            Io.Dir.cwd().access(io, full, .{ .execute = true }) catch continue;
            return .{ .kind = kind, .path = full };
        }
    }
    return null;
}

pub fn listArgv(arena: Allocator, tool: Tool, archive: []const u8) Allocator.Error![]const []const u8 {
    return switch (tool.kind) {
        .bsdtar => arena.dupe([]const u8, &.{ tool.path, "-tf", archive }),
        .@"7zz", .@"7z" => arena.dupe([]const u8, &.{ tool.path, "l", "-ba", "-slt", archive }),
    };
}

pub fn extractArgv(arena: Allocator, tool: Tool, archive: []const u8, dest: []const u8) Allocator.Error![]const []const u8 {
    return switch (tool.kind) {
        .bsdtar => arena.dupe([]const u8, &.{ tool.path, "-xf", archive, "-C", dest }),
        .@"7zz", .@"7z" => arena.dupe([]const u8, &.{
            tool.path,                                       "x",     "-y", "-bso0", "-bsp0",
            try std.fmt.allocPrint(arena, "-o{s}", .{dest}), archive,
        }),
    };
}

pub fn listedPaths(arena: Allocator, kind: Kind, output: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        switch (kind) {
            .bsdtar => if (line.len > 0) try out.append(arena, line),
            .@"7zz", .@"7z" => if (std.mem.startsWith(u8, line, "Path = ")) try out.append(arena, line["Path = ".len..]),
        }
    }
    return out.items;
}

pub fn unsafePath(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '/' or name[0] == '\\') return true;
    if (name.len >= 2 and name[1] == ':') return true;
    var parts = std.mem.tokenizeAny(u8, name, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

pub fn checkListing(paths: []const []const u8) error{ UnsafeArchive, EmptyArchive }!void {
    if (paths.len == 0) return error.EmptyArchive;
    for (paths) |p| {
        if (unsafePath(p)) return error.UnsafeArchive;
    }
}

pub fn childEnv(gpa: Allocator, parent: *const Environ.Map) !Environ.Map {
    var env = Environ.Map.init(gpa);
    errdefer env.deinit();
    var it = parent.iterator();
    while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    try env.put("LC_ALL", "C");
    return env;
}

pub fn releaseDir(arena: Allocator, io: Io, root: []const u8, marker: []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    try walk(arena, io, root, marker, 0, &found);
    return found orelse error.NotAnOptiScalerRelease;
}

fn walk(arena: Allocator, io: Io, path: []const u8, marker: []const u8, depth: usize, found: *?[]const u8) !void {
    if (depth > 16) return error.ArchiveTooDeep;
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .sym_link => return error.UnsafeArchive,
            .directory => try walk(arena, io, try std.fs.path.join(arena, &.{ path, entry.name }), marker, depth + 1, found),
            else => if (found.* == null and depth <= 2 and std.ascii.eqlIgnoreCase(entry.name, marker)) {
                found.* = try arena.dupe(u8, path);
            },
        }
    }
}

const testing = std.testing;

test "paths that leave the target are refused, whatever the separator" {
    try testing.expect(unsafePath("/etc/passwd"));
    try testing.expect(unsafePath("a/../../b"));
    try testing.expect(unsafePath("..\\x.dll"));
    try testing.expect(unsafePath("C:\\Windows\\x.dll"));
    try testing.expect(!unsafePath("OptiScaler/OptiScaler.dll"));
    try testing.expect(!unsafePath("D3D12_Optiscaler/..hidden"));
    try testing.expectError(error.UnsafeArchive, checkListing(&.{ "ok.dll", "../evil.dll" }));
    try testing.expectError(error.EmptyArchive, checkListing(&.{}));
}

test "listings from bsdtar and 7-Zip yield the same entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try listedPaths(a, .bsdtar, "OptiScaler.dll\nLicenses/\nLicenses/MIT.txt\n");
    const sz = try listedPaths(a, .@"7zz",
        \\Path = OptiScaler.dll
        \\Size = 1024
        \\Attributes = A
        \\
        \\Path = Licenses
        \\Folder = +
        \\
        \\Path = Licenses/MIT.txt
        \\
    );
    try testing.expectEqual(@as(usize, 3), tar.len);
    try testing.expectEqual(@as(usize, 3), sz.len);
    try testing.expectEqualStrings("Licenses/MIT.txt", sz[2]);
}

test "argv for each tool lists or unpacks into the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar: Tool = .{ .kind = .bsdtar, .path = "/usr/bin/bsdtar" };
    const sz: Tool = .{ .kind = .@"7zz", .path = "/usr/bin/7zz" };
    const x = try extractArgv(a, tar, "/d/a.7z", "/d/out");
    try testing.expectEqualStrings("/d/out", x[x.len - 1]);
    const y = try extractArgv(a, sz, "/d/a.7z", "/d/out");
    try testing.expectEqualStrings("-o/d/out", y[5]);
    try testing.expectEqualStrings("/d/a.7z", (try listArgv(a, sz, "/d/a.7z"))[4]);
}

test "the release folder is where the DLL is; symlinks fail the whole archive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    var d = try tmp.dir.createDirPathOpen(testing.io, "out/Optiscaler_0.9/Licenses", .{});
    d.close(testing.io);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "out/Optiscaler_0.9/OptiScaler.dll", .data = "MZ" });
    const dir = try releaseDir(a, testing.io, try std.fs.path.join(a, &.{ root, "out" }), "OptiScaler.dll");
    try testing.expect(std.mem.endsWith(u8, dir, "out/Optiscaler_0.9"));

    try testing.expectError(error.NotAnOptiScalerRelease, releaseDir(a, testing.io, try std.fs.path.join(a, &.{ root, "out/Optiscaler_0.9/Licenses" }), "OptiScaler.dll"));

    try tmp.dir.symLink(testing.io, "/etc", "out/Optiscaler_0.9/Licenses/escape", .{ .is_directory = true });
    try testing.expectError(error.UnsafeArchive, releaseDir(a, testing.io, try std.fs.path.join(a, &.{ root, "out" }), "OptiScaler.dll"));
}
