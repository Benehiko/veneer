const std = @import("std");
const Allocator = std.mem.Allocator;
const Platform = @import("../library/game.zig").Platform;
const gamescope = @import("../launch/gamescope.zig");
const plan = @import("../launch/plan.zig");

pub const display_labels = [_][]const u8{ "Normal window", "Gamescope, fullscreen" };

pub const upscaling_labels = [_][]const u8{ "Off", "FSR 1 in gamescope", "NIS in gamescope", "OptiScaler" };

pub const scale_labels = [_][]const u8{ "100% (native)", "77% (quality)", "67% (balanced)", "59% (performance)", "50% (ultra performance)" };

pub fn sizeText(buf: []u8, done: u64, total: u64) []const u8 {
    const mib = 1024.0 * 1024.0;
    const d = @as(f64, @floatFromInt(done)) / mib;
    if (total == 0) return std.fmt.bufPrint(buf, "{d:.1} MB", .{d}) catch "";
    const t = @as(f64, @floatFromInt(total)) / mib;
    const pct = @min(100, done * 100 / total);
    return std.fmt.bufPrint(buf, "{d:.1} of {d:.1} MB, {d}%", .{ d, t, pct }) catch "";
}

pub fn fileUrl(arena: Allocator, path: []const u8) Allocator.Error![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "file://");
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-_.~", c) != null) {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSliceSentinel(arena, 0);
}

pub fn scaleIndex(scale: u8) usize {
    var best: usize = 0;
    var best_gap: u8 = 255;
    for (gamescope.scales, 0..) |s, i| {
        const gap = if (s > scale) s - scale else scale - s;
        if (gap < best_gap) {
            best = i;
            best_gap = gap;
        }
    }
    return best;
}

pub fn matches(name: []const u8, query: []const u8) bool {
    const q = std.mem.trim(u8, query, " \t");
    return q.len == 0 or std.ascii.findIgnoreCase(name, q) != null;
}

pub const RunnerMenu = struct {
    labels: []const []const u8,
    values: []const []const u8,

    pub fn indexOf(self: RunnerMenu, runner: []const u8) ?usize {
        const want = if (runner.len == 0) "auto" else runner;
        for (self.values, 0..) |v, i| {
            if (std.mem.eql(u8, v, want)) return i;
        }
        return null;
    }
};

pub fn runnerMenu(arena: Allocator, tools: []const []const u8, current: []const u8, platform: Platform) Allocator.Error!RunnerMenu {
    var labels: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    try labels.append(arena, "Automatic");
    try values.append(arena, "auto");
    if (platform == .linux) {
        try labels.append(arena, "Native");
        try values.append(arena, "native");
    }
    for (tools) |t| {
        try labels.append(arena, t);
        try values.append(arena, t);
    }
    const menu: RunnerMenu = .{ .labels = labels.items, .values = values.items };
    if (menu.indexOf(current) == null) {
        const label = if (std.mem.indexOfScalar(u8, current, '/') != null)
            try std.fmt.allocPrint(arena, "Wine: {s}", .{current})
        else
            try std.fmt.allocPrint(arena, "{s} (not installed)", .{current});
        try labels.append(arena, label);
        try values.append(arena, current);
    }
    return .{ .labels = labels.items, .values = values.items };
}

pub fn envLine(arena: Allocator, env: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (env, 0..) |assignment, i| {
        if (i > 0) try out.append(arena, ' ');
        const plain = assignment.len > 0 and std.mem.indexOfAny(u8, assignment, " \t\"'\\") == null;
        if (plain) {
            try out.appendSlice(arena, assignment);
            continue;
        }
        try out.append(arena, '"');
        for (assignment) |c| {
            if (c == '"' or c == '\\') try out.append(arena, '\\');
            try out.append(arena, c);
        }
        try out.append(arena, '"');
    }
    return out.items;
}

pub fn envList(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    return plan.splitArgs(arena, line);
}

const testing = std.testing;

test "the render scale snaps to the nearest offered step" {
    try testing.expectEqual(@as(usize, 0), scaleIndex(100));
    try testing.expectEqual(@as(usize, 2), scaleIndex(67));
    try testing.expectEqual(@as(usize, 2), scaleIndex(65));
    try testing.expectEqual(@as(usize, 4), scaleIndex(25));
}

test "a file URL escapes spaces and other characters a URL cannot hold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("file:///home/p/.local/state/veneer/logs", try fileUrl(arena.allocator(), "/home/p/.local/state/veneer/logs"));
    try testing.expectEqualStrings("file:///home/my%20name/a%23b%25", try fileUrl(arena.allocator(), "/home/my name/a#b%"));
}

test "search matches any part of a name, ignoring case and stray spaces" {
    try testing.expect(matches("ELDEN RING", "elden"));
    try testing.expect(matches("ELDEN RING", "  "));
    try testing.expect(matches("Sekiro™: Shadows Die Twice", "shadows"));
    try testing.expect(!matches("Trine", "elden"));
}

test "the runner menu offers native only for Linux games and keeps an unknown choice visible" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = [_][]const u8{ "Proton 10.0", "Proton - Experimental" };

    const win = try runnerMenu(a, &tools, "auto", .windows);
    try testing.expectEqual(@as(usize, 3), win.labels.len);
    try testing.expectEqual(@as(usize, 0), win.indexOf("auto").?);
    try testing.expectEqual(@as(usize, 1), win.indexOf("Proton 10.0").?);
    try testing.expect(win.indexOf("native") == null);

    const lin = try runnerMenu(a, &tools, "native", .linux);
    try testing.expectEqual(@as(usize, 1), lin.indexOf("native").?);

    const wine = try runnerMenu(a, &tools, "/opt/wine/bin/wine", .windows);
    const k = wine.indexOf("/opt/wine/bin/wine").?;
    try testing.expectEqualStrings("Wine: /opt/wine/bin/wine", wine.labels[k]);

    const gone = try runnerMenu(a, &tools, "GE-Proton9-20", .windows);
    try testing.expectEqualStrings("GE-Proton9-20 (not installed)", gone.labels[gone.indexOf("GE-Proton9-20").?]);
}

test "environment assignments survive the one-line text field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = [_][]const u8{ "DXVK_HUD=fps", "MSG=two words", "Q=it's", "P=C:\\x \"y\"" };
    const line = try envLine(a, &env);
    const back = try envList(a, line);
    try testing.expectEqual(env.len, back.len);
    for (env, back) |want, got| try testing.expectEqualStrings(want, got);
}

test "sizes read in megabytes, with the percentage when the total is known" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("12.5 of 50.0 MB, 25%", sizeText(&buf, 12.5 * 1024 * 1024, 50 * 1024 * 1024));
    try testing.expectEqualStrings("3.0 MB", sizeText(&buf, 3 * 1024 * 1024, 0));
    try testing.expectEqualStrings("2.0 of 1.0 MB, 100%", sizeText(&buf, 2 * 1024 * 1024, 1024 * 1024));
}
