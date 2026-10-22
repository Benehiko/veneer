const std = @import("std");
const Io = std.Io;

pub const markers = [_][]const u8{
    "EasyAntiCheat",
    "EasyAntiCheat_EOS",
    "start_protected_game.exe",
    "EasyAntiCheat_EOS_Setup.exe",
    "BattlEye",
    "BEService.exe",
    "BEService_x64.exe",
};

pub fn isMarker(name: []const u8) ?[]const u8 {
    for (markers) |m| {
        if (std.ascii.eqlIgnoreCase(name, m)) return m;
    }
    return null;
}

pub fn detect(io: Io, install_dir: []const u8) ?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, install_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (isMarker(entry.name)) |m| return m;
        if (entry.kind != .directory) continue;
        var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch null) |inner| {
            if (isMarker(inner.name)) |m| return m;
        }
    }
    return null;
}

const testing = std.testing;

test "anti-cheat markers match by whole name, in any case" {
    try testing.expectEqualStrings("EasyAntiCheat", isMarker("easyanticheat").?);
    try testing.expectEqualStrings("BattlEye", isMarker("BattlEye").?);
    try testing.expect(isMarker("EasyAntiCheatNotes.txt") == null);
}

test "a marker one directory down is found; a clean install is not flagged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var game = try tmp.dir.createDirPathOpen(testing.io, "Game/EasyAntiCheat", .{});
    game.close(testing.io);
    var clean = try tmp.dir.createDirPathOpen(testing.io, "Clean/bin", .{});
    clean.close(testing.io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(testing.io, ".", &buf);
    const root = buf[0..len];

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("EasyAntiCheat", detect(testing.io, try std.fmt.bufPrint(&path_buf, "{s}", .{root})).?);
    try testing.expect(detect(testing.io, try std.fmt.bufPrint(&path_buf, "{s}/Clean", .{root})) == null);
}
