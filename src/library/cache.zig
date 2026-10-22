const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const paths = @import("../paths.zig");
const zonfile = @import("../config/zonfile.zig");
const Game = @import("game.zig").Game;

pub const version = 1;

const File = struct {
    version: u32 = 0,
    games: []const Game = &.{},
};

pub fn path(arena: Allocator, env: *const Environ.Map) ![]const u8 {
    return std.fs.path.join(arena, &.{ try paths.dir(arena, env, .cache), "library.zon" });
}

pub fn load(arena: Allocator, io: Io, env: *const Environ.Map) ![]const Game {
    const file = zonfile.load(File, arena, io, try path(arena, env)) catch return &.{};
    return if (file.version == version) file.games else &.{};
}

pub fn save(gpa: Allocator, io: Io, env: *const Environ.Map, games: []const Game) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return zonfile.save(gpa, io, try path(arena.allocator(), env), File{ .version = version, .games = games });
}

const testing = std.testing;

test "the cached library comes back whole, and a stale format is ignored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CACHE_HOME", try tmp.dir.realPathFileAlloc(testing.io, ".", a));

    try testing.expectEqual(@as(usize, 0), (try load(a, testing.io, &env)).len);

    const games = [_]Game{
        .{ .id = "steam:10", .name = "Alpha", .source = .steam, .platform = .windows, .install_dir = "/l/Alpha", .exe = "/l/Alpha/a.exe", .steam = .{ .app_id = "10", .root = "/s", .steamapps = "/l", .compat_tool = "proton_10" } },
        .{ .id = "manual:00", .name = "Beta", .source = .manual, .platform = .linux, .install_dir = "/g" },
    };
    try save(testing.allocator, testing.io, &env, &games);
    const back = try load(a, testing.io, &env);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("proton_10", back[0].steam.?.compat_tool.?);
    try testing.expect(back[1].exe == null);

    const p = try path(a, &env);
    try zonfile.save(testing.allocator, testing.io, p, File{ .version = version + 1, .games = &games });
    try testing.expectEqual(@as(usize, 0), (try load(a, testing.io, &env)).len);
}
