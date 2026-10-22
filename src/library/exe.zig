const std = @import("std");
const Io = std.Io;
const Platform = @import("game.zig").Platform;

pub fn classify(header: []const u8) ?Platform {
    if (std.mem.startsWith(u8, header, "MZ")) return .windows;
    if (std.mem.startsWith(u8, header, "\x7fELF")) return .linux;
    if (std.mem.startsWith(u8, header, "#!")) return .linux;
    return null;
}

pub fn classifyFile(io: Io, path: []const u8) ?Platform {
    var buf: [4]u8 = undefined;
    const header = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    return classify(header);
}

const testing = std.testing;

test "the header, not the file name, decides the platform" {
    try testing.expectEqual(Platform.windows, classify("MZ\x90\x00").?);
    try testing.expectEqual(Platform.linux, classify("\x7fELF").?);
    try testing.expectEqual(Platform.linux, classify("#!/bin/sh").?);
    try testing.expect(classify("PK\x03\x04") == null);
    try testing.expect(classify("M") == null);
}
