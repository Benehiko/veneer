const std = @import("std");
const Allocator = std.mem.Allocator;
const vdf = @import("vdf.zig");
const Platform = @import("game.zig").Platform;

pub const Error = Allocator.Error || error{
    BadMagic,
    Truncated,
    UnknownType,
    BadStringIndex,
    TooDeep,
};

pub const Version = enum(u32) {
    v27 = 0x07564427,
    v28 = 0x07564428,
    v29 = 0x07564429,
};

pub const Reader = struct {
    bytes: []const u8,
    version: Version,
    strings: []const []const u8,
    first_entry: usize,

    pub fn init(arena: Allocator, bytes: []const u8) Error!Reader {
        if (bytes.len < 8) return error.Truncated;
        const version = std.enums.fromInt(Version, readInt(u32, bytes, 0)) orelse return error.BadMagic;
        var r: Reader = .{ .bytes = bytes, .version = version, .strings = &.{}, .first_entry = 8 };
        if (version == .v29) {
            if (bytes.len < 16) return error.Truncated;
            const table = std.math.cast(usize, readInt(i64, bytes, 8)) orelse return error.Truncated;
            r.first_entry = 16;
            r.strings = try readStringTable(arena, bytes, table);
        }
        return r;
    }

    pub fn find(self: Reader, arena: Allocator, app_id: u32) Error!?vdf.Object {
        var pos = self.first_entry;
        while (pos + 8 <= self.bytes.len) {
            const id = readInt(u32, self.bytes, pos);
            if (id == 0) return null;
            const size = readInt(u32, self.bytes, pos + 4);
            const body = pos + 8;
            const end = std.math.add(usize, body, size) catch return error.Truncated;
            if (end > self.bytes.len) return error.Truncated;
            if (id == app_id) {
                var at = body + self.headerLen();
                if (at > end) return error.Truncated;
                const root = try self.object(arena, &at, end, 0);
                return root.object("appinfo") orelse root;
            }
            pos = end;
        }
        return null;
    }

    fn headerLen(self: Reader) usize {
        return switch (self.version) {
            .v27 => 40,
            .v28, .v29 => 60,
        };
    }

    fn object(self: Reader, arena: Allocator, pos: *usize, end: usize, depth: usize) Error!vdf.Object {
        if (depth > vdf.max_depth) return error.TooDeep;
        var pairs: std.ArrayList(vdf.Pair) = .empty;
        while (true) {
            if (pos.* >= end) return error.Truncated;
            const kind = self.bytes[pos.*];
            pos.* += 1;
            if (kind == 0x08) break;
            const name = try self.key(pos, end);
            const value: vdf.Value = switch (kind) {
                0x00 => .{ .object = try self.object(arena, pos, end, depth + 1) },
                0x01 => .{ .string = try cString(self.bytes, pos, end) },
                0x02 => .{ .string = try self.number(arena, i32, pos, end) },
                0x03 => .{ .string = try self.float(arena, pos, end) },
                0x04, 0x06 => .{ .string = try self.number(arena, u32, pos, end) },
                0x07 => .{ .string = try self.number(arena, u64, pos, end) },
                0x0A => .{ .string = try self.number(arena, i64, pos, end) },
                else => return error.UnknownType,
            };
            try pairs.append(arena, .{ .key = name, .value = value });
        }
        return .{ .pairs = try pairs.toOwnedSlice(arena) };
    }

    fn key(self: Reader, pos: *usize, end: usize) Error![]const u8 {
        if (self.version != .v29) return cString(self.bytes, pos, end);
        if (pos.* + 4 > end) return error.Truncated;
        const index = readInt(u32, self.bytes, pos.*);
        pos.* += 4;
        if (index >= self.strings.len) return error.BadStringIndex;
        return self.strings[index];
    }

    fn number(self: Reader, arena: Allocator, T: type, pos: *usize, end: usize) Error![]const u8 {
        if (pos.* + @sizeOf(T) > end) return error.Truncated;
        const v = readInt(T, self.bytes, pos.*);
        pos.* += @sizeOf(T);
        return std.fmt.allocPrint(arena, "{d}", .{v});
    }

    fn float(self: Reader, arena: Allocator, pos: *usize, end: usize) Error![]const u8 {
        if (pos.* + 4 > end) return error.Truncated;
        const v: f32 = @bitCast(readInt(u32, self.bytes, pos.*));
        pos.* += 4;
        return std.fmt.allocPrint(arena, "{d}", .{v});
    }
};

fn readStringTable(arena: Allocator, bytes: []const u8, offset: usize) Error![]const []const u8 {
    if (offset + 4 > bytes.len) return error.Truncated;
    const count = readInt(u32, bytes, offset);
    if (count > bytes.len) return error.Truncated;
    const out = try arena.alloc([]const u8, count);
    var pos = offset + 4;
    for (out) |*s| s.* = try cString(bytes, &pos, bytes.len);
    return out;
}

fn cString(bytes: []const u8, pos: *usize, end: usize) Error![]const u8 {
    const rest = bytes[pos.*..end];
    const len = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Truncated;
    pos.* += len + 1;
    return rest[0..len];
}

fn readInt(T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

pub const Launch = struct {
    executable: []const u8,
    arguments: []const u8,
    workdir: ?[]const u8,
};

pub fn launchFor(info: vdf.Object, platform: Platform) ?Launch {
    const entries = info.path(&.{ "config", "launch" }) orelse return null;
    var best: ?Launch = null;
    var best_score: u8 = 0;
    for (entries.pairs) |pair| {
        const entry = switch (pair.value) {
            .object => |o| o,
            .string => continue,
        };
        const exe = entry.string("executable") orelse continue;
        if (exe.len == 0) continue;
        const config = entry.object("config") orelse vdf.Object{};
        if (config.string("BetaKey") != null) continue;

        var score: u8 = 1;
        if (config.string("oslist")) |oslist| {
            if (oslist.len > 0) {
                if (!listHas(oslist, @tagName(platform))) continue;
                score += 2;
            }
        }
        const kind = entry.string("type") orelse "default";
        if (std.ascii.eqlIgnoreCase(kind, "default")) score += 1;
        if (score > best_score) {
            best_score = score;
            best = .{
                .executable = exe,
                .arguments = entry.string("arguments") orelse "",
                .workdir = entry.string("workingdir"),
            };
        }
    }
    return best;
}

pub fn listHas(list: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, ", ");
    while (it.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item, word)) return true;
    }
    return false;
}

const testing = std.testing;

const Builder = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    v29: bool,

    fn int(b: *Builder, T: type, v: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        try b.out.appendSlice(b.a, &buf);
    }

    fn key(b: *Builder, k: []const u8) !void {
        if (!b.v29) {
            try b.out.appendSlice(b.a, k);
            return b.out.append(b.a, 0);
        }
        for (b.strings.items, 0..) |s, i| {
            if (std.mem.eql(u8, s, k)) return b.int(u32, @intCast(i));
        }
        try b.strings.append(b.a, k);
        try b.int(u32, @intCast(b.strings.items.len - 1));
    }

    fn open(b: *Builder, k: []const u8) !void {
        try b.out.append(b.a, 0x00);
        try b.key(k);
    }

    fn str(b: *Builder, k: []const u8, v: []const u8) !void {
        try b.out.append(b.a, 0x01);
        try b.key(k);
        try b.out.appendSlice(b.a, v);
        try b.out.append(b.a, 0);
    }

    fn close(b: *Builder) !void {
        try b.out.append(b.a, 0x08);
    }
};

fn sampleFile(a: Allocator, v29: bool) ![]const u8 {
    var kv: Builder = .{ .a = a, .v29 = v29 };
    try kv.open("appinfo");
    try kv.str("appid", "1245620");
    try kv.open("common");
    try kv.str("name", "ELDEN RING");
    try kv.str("type", "Game");
    try kv.out.append(a, 0x02);
    try kv.key("metacritic_score");
    try kv.int(i32, 90);
    try kv.close();
    try kv.open("config");
    try kv.open("launch");
    try kv.open("0");
    try kv.str("executable", "Game\\start_protected_game.exe");
    try kv.str("type", "default");
    try kv.open("config");
    try kv.str("oslist", "windows");
    try kv.close();
    try kv.close();
    try kv.close();
    try kv.close();
    try kv.close();
    try kv.close();

    var file: Builder = .{ .a = a, .v29 = false };
    try file.int(u32, if (v29) @backingInt(Version.v29) else @backingInt(Version.v28));
    try file.int(u32, 1);
    const table_at = file.out.items.len;
    if (v29) try file.int(i64, 0);

    try file.int(u32, 10);
    try file.int(u32, 60 + 1);
    try file.out.appendNTimes(a, 0, 60);
    try file.close();

    try file.int(u32, 1245620);
    try file.int(u32, @intCast(60 + kv.out.items.len));
    try file.out.appendNTimes(a, 0xAA, 60);
    try file.out.appendSlice(a, kv.out.items);
    try file.int(u32, 0);

    if (v29) {
        std.mem.writeInt(i64, file.out.items[table_at..][0..8], @intCast(file.out.items.len), .little);
        try file.int(u32, @intCast(kv.strings.items.len));
        for (kv.strings.items) |s| {
            try file.out.appendSlice(a, s);
            try file.out.append(a, 0);
        }
    }
    return file.out.items;
}

test "an app is found past other entries, in both key encodings" {
    for ([_]bool{ false, true }) |v29| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = try sampleFile(a, v29);
        const reader = try Reader.init(a, bytes);
        const info = (try reader.find(a, 1245620)).?;
        try testing.expectEqualStrings("ELDEN RING", info.object("common").?.string("name").?);
        try testing.expectEqualStrings("90", info.object("common").?.string("metacritic_score").?);
        try testing.expect(try reader.find(a, 570) == null);
    }
}

test "a truncated or foreign file is an error, never a read past the end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try sampleFile(a, true);
    try testing.expectError(error.BadMagic, Reader.init(a, "not appinfo at all"));
    const reader = try Reader.init(a, bytes);
    var cut = reader;
    for (16..bytes.len - 40) |len| {
        cut.bytes = bytes[0..len];
        if (cut.find(a, 1245620)) |found| {
            if (found) |info| try testing.expectEqualStrings("ELDEN RING", info.object("common").?.string("name").?);
        } else |_| {}
    }
}

test "the launch entry for the platform wins, beta entries never do" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const info = try vdf.parse(arena.allocator(),
        \\"config" { "launch" {
        \\  "0" { "executable" "beta.exe" "type" "default" "config" { "oslist" "windows" "BetaKey" "public_test" } }
        \\  "1" { "executable" "tool.exe" "type" "option1" }
        \\  "2" { "executable" "game.exe" "arguments" "-dx12" "type" "default" "config" { "oslist" "windows" } }
        \\  "3" { "executable" "game.sh" "type" "default" "config" { "oslist" "linux" } }
        \\} }
    );
    const win = launchFor(info, .windows).?;
    try testing.expectEqualStrings("game.exe", win.executable);
    try testing.expectEqualStrings("-dx12", win.arguments);
    try testing.expectEqualStrings("game.sh", launchFor(info, .linux).?.executable);
}

test "oslist matching is by whole word" {
    try testing.expect(listHas("windows,linux", "linux"));
    try testing.expect(listHas("windows, macos", "MACOS"));
    try testing.expect(!listHas("linuxish", "linux"));
}
