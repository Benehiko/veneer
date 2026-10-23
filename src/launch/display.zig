const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Mode = @import("gamescope.zig").Mode;

pub const drm_dir = "/sys/class/drm";

pub const Output = struct {
    name: []const u8,
    modes: []const Mode,

    pub fn preferred(self: Output) ?Mode {
        return if (self.modes.len > 0) self.modes[0] else null;
    }
};

pub fn isAuto(value: []const u8) bool {
    return value.len == 0 or std.mem.eql(u8, value, "auto");
}

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

fn same(a: Mode, b: Mode) bool {
    return a.width == b.width and a.height == b.height;
}

pub fn parseModes(arena: Allocator, text: []const u8) Allocator.Error![]const Mode {
    var list: std.ArrayList(Mode) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    next: while (lines.next()) |line| {
        const m = parseMode(line) orelse continue;
        for (list.items) |seen| if (same(seen, m)) continue :next;
        try list.append(arena, m);
    }
    return list.items;
}

pub fn connectorName(entry: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, entry, "card")) return null;
    const dash = std.mem.indexOfScalar(u8, entry, '-') orelse return null;
    if (dash + 1 == entry.len) return null;
    return entry[dash + 1 ..];
}

fn area(m: Mode) u64 {
    return @as(u64, m.width) * m.height;
}

pub fn largest(outs: []const Output) ?Output {
    var best: ?Output = null;
    for (outs) |o| {
        const m = o.preferred() orelse continue;
        if (best == null or area(m) > area(best.?.preferred().?)) best = o;
    }
    return best;
}

pub fn size(outs: []const Output, resolution: ?Mode) ?Mode {
    if (resolution) |r| return r;
    const base = largest(outs) orelse return null;
    return base.preferred();
}

fn byName(_: void, a: Output, b: Output) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn outputs(arena: Allocator, io: Io) Allocator.Error![]const Output {
    var dir = Io.Dir.cwd().openDir(io, drm_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var list: std.ArrayList(Output) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const name = connectorName(entry.name) orelse continue;
        var path_buf: [256]u8 = undefined;
        var status_buf: [64]u8 = undefined;
        const status_path = std.fmt.bufPrint(&path_buf, "{s}/status", .{entry.name}) catch continue;
        const status = dir.readFile(io, status_path, &status_buf) catch continue;
        if (!std.mem.startsWith(u8, status, "connected")) continue;
        var modes_buf: [8192]u8 = undefined;
        const modes_path = std.fmt.bufPrint(&path_buf, "{s}/modes", .{entry.name}) catch continue;
        var text = dir.readFile(io, modes_path, &modes_buf) catch continue;
        if (text.len == modes_buf.len) text = text[0 .. std.mem.lastIndexOfScalar(u8, text, '\n') orelse 0];
        const modes = try parseModes(arena, text);
        if (modes.len == 0) continue;
        try list.append(arena, .{ .name = try arena.dupe(u8, name), .modes = modes });
    }
    std.mem.sort(Output, list.items, {}, byName);
    return list.items;
}

const testing = std.testing;

test "a DRM mode line yields its size, interlace marks and all" {
    try testing.expectEqual(Mode{ .width = 2560, .height = 1440 }, parseMode("2560x1440\n").?);
    try testing.expectEqual(Mode{ .width = 1920, .height = 1080 }, parseMode("1920x1080i").?);
    try testing.expect(parseMode("") == null);
    try testing.expect(parseMode("0x1080") == null);
    try testing.expect(parseMode("garbage") == null);
}

test "a modes file lists each size once, preferred first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const modes = try parseModes(arena.allocator(), "2560x1440\n1920x1080\n1920x1080i\n2560x1440\n1280x720\n");
    const want = [_]Mode{ .{ .width = 2560, .height = 1440 }, .{ .width = 1920, .height = 1080 }, .{ .width = 1280, .height = 720 } };
    try testing.expectEqualSlices(Mode, &want, modes);
}

test "connector names drop the card prefix" {
    try testing.expectEqualStrings("DP-1", connectorName("card1-DP-1").?);
    try testing.expectEqualStrings("HDMI-A-2", connectorName("card0-HDMI-A-2").?);
    try testing.expect(connectorName("card1") == null);
    try testing.expect(connectorName("renderD128") == null);
}

const outs_fixture = [_]Output{
    .{ .name = "DP-1", .modes = &.{ .{ .width = 2560, .height = 1440 }, .{ .width = 1920, .height = 1080 } } },
    .{ .name = "DP-2", .modes = &.{.{ .width = 3440, .height = 1440 }} },
    .{ .name = "HDMI-A-1", .modes = &.{.{ .width = 1920, .height = 1080 }} },
};

test "the largest connected output is the one to fill" {
    try testing.expectEqualStrings("DP-2", largest(&outs_fixture).?.name);
    try testing.expect(largest(&.{}) == null);
}

test "the size is the chosen resolution, else the largest output's own" {
    try testing.expectEqual(Mode{ .width = 3440, .height = 1440 }, size(&outs_fixture, null).?);
    try testing.expectEqual(Mode{ .width = 1920, .height = 1080 }, size(&outs_fixture, .{ .width = 1920, .height = 1080 }).?);
    try testing.expect(size(&.{}, null) == null);
}
