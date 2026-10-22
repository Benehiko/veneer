const std = @import("std");
const Allocator = std.mem.Allocator;

pub const builtin_table = @embedFile("optiscaler_releases");

pub const Release = struct {
    tag: []const u8,
    url: []const u8,
    sha256: [32]u8,

    pub fn fileName(self: Release) []const u8 {
        return std.fs.path.basename(self.url);
    }
};

pub fn parse(arena: Allocator, text: []const u8) (Allocator.Error || error{BadRelease})![]const Release {
    var out: std.ArrayList(Release) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const tag = cols.next() orelse return error.BadRelease;
        const url = cols.next() orelse return error.BadRelease;
        const hex = cols.next() orelse return error.BadRelease;
        if (cols.next() != null or tag.len == 0) return error.BadRelease;
        if (!std.mem.startsWith(u8, url, "https://") or !std.mem.endsWith(u8, url, ".7z")) return error.BadRelease;
        var r: Release = .{ .tag = tag, .url = url, .sha256 = undefined };
        if (hex.len != 64) return error.BadRelease;
        _ = std.fmt.hexToBytes(&r.sha256, hex) catch return error.BadRelease;
        for (out.items) |have| {
            if (std.mem.eql(u8, have.tag, tag)) return error.BadRelease;
        }
        try out.append(arena, r);
    }
    return out.items;
}

pub fn find(list: []const Release, tag: []const u8) ?Release {
    for (list) |r| {
        if (std.mem.eql(u8, r.tag, tag)) return r;
    }
    return null;
}

pub fn newest(list: []const Release) ?Release {
    return if (list.len > 0) list[0] else null;
}

const testing = std.testing;

test "the shipped table parses, newest first, every tag once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), builtin_table);
    try testing.expect(list.len > 0);
    try testing.expectEqualStrings(list[0].tag, newest(list).?.tag);
}

test "rows need a tag, an https .7z URL and a 64-digit hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ab8 = "abababab";
    const hash = ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8;
    const zz8 = "zzzzzzzz";
    const bad_hash = zz8 ++ zz8 ++ zz8 ++ zz8 ++ zz8 ++ zz8 ++ zz8 ++ zz8;
    const good = "v1\thttps://x/a.7z\t" ++ hash;
    const list = try parse(a, "# header\n" ++ good ++ "\n");
    try testing.expectEqual(@as(u8, 0xab), list[0].sha256[31]);
    try testing.expectEqualStrings("a.7z", list[0].fileName());
    try testing.expect(find(list, "v1") != null and find(list, "v2") == null);

    try testing.expectError(error.BadRelease, parse(a, "v1\thttp://x/a.7z\t" ++ hash));
    try testing.expectError(error.BadRelease, parse(a, "v1\thttps://x/a.zip\t" ++ hash));
    try testing.expectError(error.BadRelease, parse(a, "v1\thttps://x/a.7z\tabc"));
    try testing.expectError(error.BadRelease, parse(a, "v1\thttps://x/a.7z\t" ++ bad_hash));
    try testing.expectError(error.BadRelease, parse(a, good ++ "\n" ++ good));
}
