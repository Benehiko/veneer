const std = @import("std");
const Io = std.Io;
const Mode = @import("gamescope.zig").Mode;

pub const drm_dir = "/sys/class/drm";

pub fn parseMode(line: []const u8) ?Mode {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const x = std.mem.indexOfScalar(u8, trimmed, 'x') orelse return null;
    var end = x + 1;
    while (end < trimmed.len and std.ascii.isDigit(trimmed[end])) end += 1;
    const w = std.fmt.parseInt(u32, trimmed[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, trimmed[x + 1 .. end], 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

pub fn largest(modes: []const Mode) ?Mode {
    var best: ?Mode = null;
    for (modes) |m| {
        if (best == null or @as(u64, m.width) * m.height > @as(u64, best.?.width) * best.?.height) best = m;
    }
    return best;
}

pub fn nativeMode(io: Io) ?Mode {
    var dir = Io.Dir.cwd().openDir(io, drm_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var found: [16]Mode = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (n == found.len) break;
        if (!std.mem.startsWith(u8, entry.name, "card") or std.mem.indexOfScalar(u8, entry.name, '-') == null) continue;
        var buf: [64]u8 = undefined;
        var path_buf: [256]u8 = undefined;
        const status_path = std.fmt.bufPrint(&path_buf, "{s}/status", .{entry.name}) catch continue;
        const status = dir.readFile(io, status_path, &buf) catch continue;
        if (!std.mem.startsWith(u8, status, "connected")) continue;
        var modes_buf: [512]u8 = undefined;
        const modes_path = std.fmt.bufPrint(&path_buf, "{s}/modes", .{entry.name}) catch continue;
        const modes = dir.readFile(io, modes_path, &modes_buf) catch continue;
        var lines = std.mem.tokenizeScalar(u8, modes, '\n');
        if (parseMode(lines.next() orelse continue)) |m| {
            found[n] = m;
            n += 1;
        }
    }
    return largest(found[0..n]);
}

const testing = std.testing;

test "a DRM mode line yields its size, interlace marks and all" {
    try testing.expectEqual(Mode{ .width = 2560, .height = 1440 }, parseMode("2560x1440\n").?);
    try testing.expectEqual(Mode{ .width = 1920, .height = 1080 }, parseMode("1920x1080i").?);
    try testing.expect(parseMode("") == null);
    try testing.expect(parseMode("0x1080") == null);
    try testing.expect(parseMode("garbage") == null);
}

test "the largest connected output is the one to fill" {
    const modes = [_]Mode{ .{ .width = 1920, .height = 1080 }, .{ .width = 3440, .height = 1440 }, .{ .width = 2560, .height = 1440 } };
    try testing.expectEqual(Mode{ .width = 3440, .height = 1440 }, largest(&modes).?);
    try testing.expect(largest(&.{}) == null);
}
