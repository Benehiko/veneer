const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plan = @import("plan.zig");

pub const libraries = [_][]const u8{
    "ubuntu12_32/gameoverlayrenderer.so",
    "ubuntu12_64/gameoverlayrenderer.so",
};

pub const vulkan_layer_switch = "ENABLE_VK_LAYER_VALVE_steam_overlay_1";

pub fn preload(arena: Allocator, overlay_libs: []const []const u8, existing: ?[]const u8) Allocator.Error!?[]const u8 {
    if (overlay_libs.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    if (existing) |e| {
        var it = std.mem.tokenizeAny(u8, e, ": ");
        while (it.next()) |lib| {
            if (std.mem.endsWith(u8, lib, "gameoverlayrenderer.so")) continue;
            try out.appendSlice(arena, lib);
            try out.append(arena, ':');
        }
    }
    for (overlay_libs, 0..) |lib, i| {
        if (i > 0) try out.append(arena, ':');
        try out.appendSlice(arena, lib);
    }
    return out.items;
}

pub fn find(arena: Allocator, io: Io, steam_root: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (libraries) |rel| {
        const full = try std.fs.path.join(arena, &.{ steam_root, rel });
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        try out.append(arena, full);
    }
    return out.items;
}

pub fn vars(arena: Allocator, io: Io, steam_root: []const u8, app_id: []const u8, existing_preload: ?[]const u8) Allocator.Error![]const plan.EnvVar {
    const libs = try find(arena, io, steam_root);
    const value = (try preload(arena, libs, existing_preload)) orelse return &.{};
    return arena.dupe(plan.EnvVar, &.{
        .{ .name = "LD_PRELOAD", .value = value },
        .{ .name = "SteamOverlayGameId", .value = app_id },
        .{ .name = vulkan_layer_switch, .value = "1" },
    });
}

const testing = std.testing;

test "the overlay joins an existing preload once, after the player's own libraries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const libs = [_][]const u8{ "/s/ubuntu12_32/gameoverlayrenderer.so", "/s/ubuntu12_64/gameoverlayrenderer.so" };

    try testing.expectEqualStrings("/s/ubuntu12_32/gameoverlayrenderer.so:/s/ubuntu12_64/gameoverlayrenderer.so", (try preload(a, &libs, null)).?);
    try testing.expectEqualStrings(
        "/usr/lib/libmangohud.so:/s/ubuntu12_32/gameoverlayrenderer.so:/s/ubuntu12_64/gameoverlayrenderer.so",
        (try preload(a, &libs, "/usr/lib/libmangohud.so /old/ubuntu12_64/gameoverlayrenderer.so")).?,
    );
    try testing.expect(try preload(a, &.{}, "/usr/lib/x.so") == null);
}
