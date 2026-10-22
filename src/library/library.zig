const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const paths = @import("../paths.zig");
const steam = @import("steam.zig");
const manual = @import("manual.zig");
pub const Game = @import("game.zig").Game;

pub fn scan(arena: Allocator, io: Io, env: *const Environ.Map) ![]Game {
    var games: std.ArrayList(Game) = .empty;
    if (env.get("HOME")) |home| try steam.scan(arena, io, home, &games);

    const config_dir = try paths.dir(arena, env, .config);
    const file = manual.load(arena, io, config_dir) catch |err| blk: {
        std.log.warn("could not read {s}/{s}: {s}", .{ config_dir, manual.file_name, @errorName(err) });
        break :blk manual.File{};
    };
    for (file.games) |entry| try games.append(arena, try manual.toGame(arena, io, entry));

    std.mem.sort(Game, games.items, {}, Game.lessThan);
    return games.items;
}

pub const Lookup = union(enum) {
    one: Game,
    none,
    many: usize,
};

pub fn find(games: []const Game, query: []const u8) Lookup {
    for (games) |g| {
        if (std.mem.eql(u8, g.id, query)) return .{ .one = g };
        if (g.steam) |s| {
            if (std.mem.eql(u8, s.app_id, query)) return .{ .one = g };
        }
    }
    for (games) |g| {
        if (std.ascii.eqlIgnoreCase(g.name, query)) return .{ .one = g };
    }
    var hit: ?Game = null;
    var count: usize = 0;
    for (games) |g| {
        if (std.ascii.findIgnoreCase(g.name, query) != null) {
            hit = g;
            count += 1;
        }
    }
    return switch (count) {
        0 => .none,
        1 => .{ .one = hit.? },
        else => .{ .many = count },
    };
}

const testing = std.testing;

test "lookup tries id, app id, exact name, then a unique name fragment" {
    const games = [_]Game{
        .{ .id = "steam:1245620", .name = "ELDEN RING", .source = .steam, .platform = .windows, .install_dir = "/a", .steam = .{ .app_id = "1245620", .root = "/s", .steamapps = "/s/steamapps" } },
        .{ .id = "steam:2", .name = "Elden Ring Nightreign", .source = .steam, .platform = .windows, .install_dir = "/b" },
        .{ .id = "manual:00", .name = "Hades", .source = .manual, .platform = .windows, .install_dir = "/c" },
    };
    try testing.expectEqualStrings("Hades", find(&games, "manual:00").one.name);
    try testing.expectEqualStrings("ELDEN RING", find(&games, "1245620").one.name);
    try testing.expectEqualStrings("ELDEN RING", find(&games, "elden ring").one.name);
    try testing.expectEqualStrings("Elden Ring Nightreign", find(&games, "night").one.name);
    try testing.expectEqual(@as(usize, 2), find(&games, "elden").many);
    try testing.expect(find(&games, "zelda") == .none);
}

test {
    _ = steam;
    _ = manual;
}
