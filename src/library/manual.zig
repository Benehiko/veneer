const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const exe = @import("exe.zig");
const Game = @import("game.zig").Game;

pub const file_name = "library.zon";

pub const Entry = struct {
    name: []const u8,
    exe: []const u8,
    args: []const u8 = "",
};

pub const File = struct {
    games: []const Entry = &.{},
};

pub fn load(arena: Allocator, io: Io, config_dir: []const u8) !File {
    const path = try std.fs.path.join(arena, &.{ config_dir, file_name });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

pub fn parse(arena: Allocator, text: []const u8) !File {
    const source = try arena.dupeSentinel(u8, text, 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(File, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.BadLibraryFile,
    };
}

pub fn save(gpa: Allocator, io: Io, config_dir: []const u8, file: File) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(file, .{}, &out.writer);
    try out.writer.writeByte('\n');

    try Io.Dir.cwd().createDirPath(io, config_dir);
    var dir = try Io.Dir.cwd().openDir(io, config_dir, .{});
    defer dir.close(io);
    const tmp_name = file_name ++ ".tmp";
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = out.written() });
    try Io.Dir.rename(dir, tmp_name, dir, file_name, io);
}

pub fn withAdded(arena: Allocator, file: File, entry: Entry) Allocator.Error!File {
    var games: std.ArrayList(Entry) = .empty;
    var replaced = false;
    for (file.games) |g| {
        if (std.mem.eql(u8, g.exe, entry.exe)) {
            try games.append(arena, entry);
            replaced = true;
        } else try games.append(arena, g);
    }
    if (!replaced) try games.append(arena, entry);
    return .{ .games = games.items };
}

pub fn withRemoved(arena: Allocator, file: File, id: []const u8) Allocator.Error!?File {
    var games: std.ArrayList(Entry) = .empty;
    var removed = false;
    for (file.games) |g| {
        if (std.mem.eql(u8, try idFor(arena, g.exe), id)) {
            removed = true;
        } else try games.append(arena, g);
    }
    return if (removed) .{ .games = games.items } else null;
}

pub fn idFor(arena: Allocator, exe_path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "manual:{x:0>16}", .{std.hash.Wyhash.hash(0, exe_path)});
}

pub fn toGame(arena: Allocator, io: Io, entry: Entry) Allocator.Error!Game {
    return .{
        .id = try idFor(arena, entry.exe),
        .name = entry.name,
        .source = .manual,
        .platform = exe.classifyFile(io, entry.exe) orelse .windows,
        .install_dir = std.fs.path.dirname(entry.exe) orelse "/",
        .exe = entry.exe,
        .args = entry.args,
    };
}

const testing = std.testing;

test "the library file survives a save and load" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(testing.io, ".", a), "veneer" });

    try testing.expectEqual(@as(usize, 0), (try load(a, testing.io, dir)).games.len);

    const file: File = .{ .games = &.{
        .{ .name = "Quote \"Game\"", .exe = "/games/q/q.exe", .args = "-windowed" },
        .{ .name = "Native", .exe = "/games/n/run.sh" },
    } };
    try save(testing.allocator, testing.io, dir, file);
    const back = try load(a, testing.io, dir);
    try testing.expectEqual(@as(usize, 2), back.games.len);
    try testing.expectEqualStrings("Quote \"Game\"", back.games[0].name);
    try testing.expectEqualStrings("-windowed", back.games[0].args);
    try testing.expectEqualStrings("", back.games[1].args);
}

test "adding the same executable twice replaces the entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: File = .{};
    file = try withAdded(a, file, .{ .name = "Old", .exe = "/g/a.exe" });
    file = try withAdded(a, file, .{ .name = "Other", .exe = "/g/b.exe" });
    file = try withAdded(a, file, .{ .name = "New", .exe = "/g/a.exe" });
    try testing.expectEqual(@as(usize, 2), file.games.len);
    try testing.expectEqualStrings("New", file.games[0].name);
}

test "removing by id drops only that game, and an unknown id changes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: File = .{ .games = &.{
        .{ .name = "A", .exe = "/g/a.exe" },
        .{ .name = "B", .exe = "/g/b.exe" },
    } };
    const after = (try withRemoved(a, file, try idFor(a, "/g/a.exe"))).?;
    try testing.expectEqual(@as(usize, 1), after.games.len);
    try testing.expectEqualStrings("B", after.games[0].name);
    try testing.expect(try withRemoved(a, file, "manual:0000000000000000") == null);
}

test "ids are stable for a path and differ between paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(try idFor(a, "/x.exe"), try idFor(a, "/x.exe"));
    try testing.expect(!std.mem.eql(u8, try idFor(a, "/x.exe"), try idFor(a, "/y.exe")));
}
