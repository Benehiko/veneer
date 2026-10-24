const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const fs_type = @import("../localfs/fs_type.zig");

pub const lib_name = "libveneer-localfs.so";

const arch_dirs = [_][]const u8{ "i386", "x86_64" };

pub fn libraries(arena: Allocator, io: Io, self_dir: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (arch_dirs) |arch| {
        const full = try std.fs.path.resolve(arena, &.{ self_dir, "..", "lib", "veneer", arch, lib_name });
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        try out.append(arena, full);
    }
    return out.items;
}

pub fn onNetwork(arena: Allocator, path: []const u8) Allocator.Error!bool {
    var at: ?[]const u8 = path;
    while (at) |p| : (at = std.fs.path.dirname(p)) {
        const f_type = typeOf(try arena.dupeSentinel(u8, p, 0)) orelse continue;
        return fs_type.isNetwork(f_type);
    }
    return false;
}

fn typeOf(path: [:0]const u8) ?usize {
    var buf: [16]usize align(8) = undefined;
    const rc = linux.syscall2(.statfs, @intFromPtr(path.ptr), @intFromPtr(&buf));
    if (linux.errno(rc) != .SUCCESS) return null;
    return buf[0];
}

pub fn preload(arena: Allocator, libs: []const []const u8, existing: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (libs) |lib| {
        if (out.items.len > 0) try out.append(arena, ':');
        try out.appendSlice(arena, lib);
    }
    if (existing) |e| {
        var it = std.mem.tokenizeAny(u8, e, ": ");
        while (it.next()) |lib| {
            if (std.mem.eql(u8, std.fs.path.basename(lib), lib_name)) continue;
            if (out.items.len > 0) try out.append(arena, ':');
            try out.appendSlice(arena, lib);
        }
    }
    return out.items;
}

const testing = std.testing;

test {
    _ = fs_type;
}

test "the shim goes first in the preload, once, before the player's libraries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const libs = [_][]const u8{ "/v/lib/veneer/i386/libveneer-localfs.so", "/v/lib/veneer/x86_64/libveneer-localfs.so" };

    try testing.expectEqualStrings(libs[0] ++ ":" ++ libs[1], try preload(a, &libs, null));
    try testing.expectEqualStrings(
        libs[0] ++ ":" ++ libs[1] ++ ":/usr/lib/libmangohud.so",
        try preload(a, &libs, "/old/x86_64/libveneer-localfs.so /usr/lib/libmangohud.so"),
    );
}

test "a path that does not exist yet is judged by its nearest existing parent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const parent = typeOf(try a.dupeSentinel(u8, root, 0)).?;
    const missing = try std.fs.path.join(a, &.{ root, "compatdata", "42" });
    try testing.expectEqual(fs_type.isNetwork(parent), try onNetwork(a, missing));
}
