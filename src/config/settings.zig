const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const paths = @import("../paths.zig");
const zonfile = @import("zonfile.zig");

pub const Settings = struct {
    optiscaler_dir: []const u8 = "",
};

pub fn path(arena: Allocator, env: *const Environ.Map) ![]const u8 {
    return std.fs.path.join(arena, &.{ try paths.dir(arena, env, .config), "settings.zon" });
}

pub fn load(arena: Allocator, io: Io, env: *const Environ.Map) !Settings {
    return zonfile.load(Settings, arena, io, try path(arena, env));
}

pub fn save(gpa: Allocator, io: Io, env: *const Environ.Map, s: Settings) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return zonfile.save(gpa, io, try path(arena.allocator(), env), s);
}
