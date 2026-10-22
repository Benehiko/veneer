const std = @import("std");

pub const Platform = enum { windows, linux };

pub const Source = enum { steam, manual };

pub const Steam = struct {
    app_id: []const u8,
    root: []const u8,
    steamapps: []const u8,
    compat_tool: ?[]const u8 = null,
};

pub const Game = struct {
    id: []const u8,
    name: []const u8,
    source: Source,
    platform: Platform,
    install_dir: []const u8,
    exe: ?[]const u8 = null,
    args: []const u8 = "",
    workdir: ?[]const u8 = null,
    art: ?[]const u8 = null,
    steam: ?Steam = null,

    pub fn lessThan(_: void, a: Game, b: Game) bool {
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }
};
