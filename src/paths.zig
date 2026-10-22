const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Base = enum { config, data, cache, state };

pub const app = "veneer";

pub fn dir(gpa: Allocator, env: *const Environ.Map, base: Base) error{ OutOfMemory, NoHome }![]u8 {
    const var_name, const fallback = switch (base) {
        .config => .{ "XDG_CONFIG_HOME", ".config" },
        .data => .{ "XDG_DATA_HOME", ".local/share" },
        .cache => .{ "XDG_CACHE_HOME", ".cache" },
        .state => .{ "XDG_STATE_HOME", ".local/state" },
    };
    if (env.get(var_name)) |value| {
        if (std.fs.path.isAbsolute(value)) return std.fs.path.join(gpa, &.{ value, app });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, fallback, app });
}

const testing = std.testing;

test "an absolute XDG variable wins; a relative one is ignored as the spec requires" {
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/p");

    const fallback = try dir(testing.allocator, &env, .state);
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("/home/p/.local/state/veneer", fallback);

    try env.put("XDG_CONFIG_HOME", "/cfg");
    const set = try dir(testing.allocator, &env, .config);
    defer testing.allocator.free(set);
    try testing.expectEqualStrings("/cfg/veneer", set);

    try env.put("XDG_CACHE_HOME", "relative/cache");
    const relative = try dir(testing.allocator, &env, .cache);
    defer testing.allocator.free(relative);
    try testing.expectEqualStrings("/home/p/.cache/veneer", relative);
}

test "no HOME and no XDG variable is an error" {
    var env = Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.NoHome, dir(testing.allocator, &env, .data));
}
