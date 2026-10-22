const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn load(comptime T: type, arena: Allocator, io: Io, path: []const u8) !T {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = arena,
        .arena = arena,
        .source = try arena.dupeSentinel(u8, text, 0),
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.BadZonFile,
    };
}

pub fn save(gpa: Allocator, io: Io, path: []const u8, value: anytype) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(value, .{ .emit_default_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');

    const dir_path = std.fs.path.dirname(path) orelse ".";
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const base = std.fs.path.basename(path);
    var tmp_buf: [std.fs.max_name_bytes + 8]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{base});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = out.written() });
    try Io.Dir.rename(dir, tmp, dir, base, io);
}

const testing = std.testing;

test "a value survives a save and load; a missing file loads as defaults" {
    const T = struct { name: []const u8 = "none", list: []const []const u8 = &.{}, n: ?u32 = null };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(testing.io, ".", a), "sub", "x.zon" });

    try testing.expectEqualStrings("none", (try load(T, a, testing.io, path)).name);
    try save(testing.allocator, testing.io, path, T{ .name = "set", .list = &.{ "a", "b" }, .n = 3 });
    const back = try load(T, a, testing.io, path);
    try testing.expectEqualStrings("set", back.name);
    try testing.expectEqualStrings("b", back.list[1]);
    try testing.expectEqual(@as(?u32, 3), back.n);
}
