const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vdf = @import("../library/vdf.zig");
const steam = @import("../library/steam.zig");

pub const system_tool_dirs = [_][]const u8{
    "/usr/share/steam/compatibilitytools.d",
    "/usr/local/share/steam/compatibilitytools.d",
};

pub const Tool = struct {
    name: []const u8,
    internal: ?[]const u8 = null,
    dir: []const u8,
    script: []const u8,
    official: bool,
};

pub const Version = struct {
    major: u16,
    minor: u16,

    fn greater(a: Version, b: Version) bool {
        return a.major > b.major or (a.major == b.major and a.minor > b.minor);
    }
};

pub fn discover(arena: Allocator, io: Io, locations: []const steam.Location) ![]const Tool {
    var tools: std.ArrayList(Tool) = .empty;
    for (locations) |loc| {
        try scanDir(arena, io, try std.fs.path.join(arena, &.{ loc.root, "compatibilitytools.d" }), false, &tools);
        for (loc.libraries) |lib| {
            try scanDir(arena, io, try std.fs.path.join(arena, &.{ lib, "steamapps", "common" }), true, &tools);
        }
    }
    for (system_tool_dirs) |dir| try scanDir(arena, io, dir, false, &tools);
    return tools.items;
}

fn scanDir(arena: Allocator, io: Io, path: []const u8, official: bool, tools: *std.ArrayList(Tool)) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const script_rel = try std.fs.path.join(arena, &.{ entry.name, "proton" });
        dir.access(io, script_rel, .{}) catch continue;
        const tool_dir = try std.fs.path.join(arena, &.{ path, entry.name });
        for (tools.items) |t| {
            if (std.mem.eql(u8, t.dir, tool_dir)) break;
        } else {
            const manifest = try std.fs.path.join(arena, &.{ entry.name, "compatibilitytool.vdf" });
            const internal: ?[]const u8 = if (dir.readFileAlloc(io, manifest, arena, .limited(64 << 10))) |text|
                internalName(arena, text)
            else |_|
                null;
            try tools.append(arena, .{
                .name = try arena.dupe(u8, entry.name),
                .internal = internal,
                .dir = tool_dir,
                .script = try std.fs.path.join(arena, &.{ tool_dir, "proton" }),
                .official = official,
            });
        }
    }
}

pub fn internalName(arena: Allocator, text: []const u8) ?[]const u8 {
    const doc = vdf.parse(arena, text) catch return null;
    const tools = doc.path(&.{ "compatibilitytools", "compat_tools" }) orelse return null;
    if (tools.pairs.len == 0) return null;
    return tools.pairs[0].key;
}

pub fn aliasVersion(alias: []const u8) ?Version {
    const prefix = "proton_";
    if (!std.mem.startsWith(u8, alias, prefix)) return null;
    const digits = alias[prefix.len..];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const value = std.fmt.parseInt(u16, digits, 10) catch return null;
    return switch (digits.len) {
        1 => .{ .major = value, .minor = 0 },
        2 => if (value >= 30) .{ .major = value / 10, .minor = value % 10 } else .{ .major = value, .minor = 0 },
        3 => .{ .major = value / 100, .minor = value % 100 },
        else => null,
    };
}

pub fn nameVersion(name: []const u8) ?Version {
    const prefix = "Proton ";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    const major = std.fmt.parseInt(u16, rest[0..dot], 10) catch return null;
    var end = dot + 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    const minor = std.fmt.parseInt(u16, rest[dot + 1 .. end], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

pub fn resolve(tools: []const Tool, wanted: []const u8) ?Tool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, wanted)) return t;
        if (t.internal) |i| {
            if (std.mem.eql(u8, i, wanted)) return t;
        }
    }
    const named: ?[]const u8 = if (std.mem.eql(u8, wanted, "proton_experimental"))
        "Proton - Experimental"
    else if (std.mem.eql(u8, wanted, "proton_hotfix"))
        "Proton Hotfix"
    else
        null;
    if (named) |n| {
        for (tools) |t| {
            if (std.mem.eql(u8, t.name, n)) return t;
        }
    }
    const want = aliasVersion(wanted) orelse return null;
    for (tools) |t| {
        const have = nameVersion(t.name) orelse continue;
        if (have.major == want.major and have.minor == want.minor) return t;
    }
    return null;
}

pub fn newest(tools: []const Tool) ?Tool {
    var best: ?Tool = null;
    var best_version: Version = .{ .major = 0, .minor = 0 };
    for (tools) |t| {
        if (!t.official) continue;
        const v = nameVersion(t.name) orelse continue;
        if (best == null or v.greater(best_version)) {
            best = t;
            best_version = v;
        }
    }
    if (best) |b| return b;
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, "Proton - Experimental")) return t;
    }
    return if (tools.len > 0) tools[0] else null;
}

pub fn forGame(tools: []const Tool, mapped: ?[]const u8) ?Tool {
    if (mapped) |m| {
        if (resolve(tools, m)) |t| return t;
    }
    return newest(tools);
}

const testing = std.testing;

const sample_tools = [_]Tool{
    .{ .name = "Proton 9.0 (Beta)", .dir = "/c/Proton 9.0 (Beta)", .script = "/c/Proton 9.0 (Beta)/proton", .official = true },
    .{ .name = "Proton 10.0", .dir = "/c/Proton 10.0", .script = "/c/Proton 10.0/proton", .official = true },
    .{ .name = "Proton - Experimental", .dir = "/c/Proton - Experimental", .script = "/c/x/proton", .official = true },
    .{ .name = "Proton EM-10.0-2D", .internal = "proton-EM-10.0-2D-proton", .dir = "/t/em", .script = "/t/em/proton", .official = false },
};

test "Steam's internal aliases decode to Proton versions" {
    try testing.expectEqual(Version{ .major = 9, .minor = 0 }, aliasVersion("proton_9").?);
    try testing.expectEqual(Version{ .major = 10, .minor = 0 }, aliasVersion("proton_10").?);
    try testing.expectEqual(Version{ .major = 6, .minor = 3 }, aliasVersion("proton_63").?);
    try testing.expectEqual(Version{ .major = 5, .minor = 13 }, aliasVersion("proton_513").?);
    try testing.expect(aliasVersion("proton_experimental") == null);
    try testing.expect(aliasVersion("GE-Proton9-20") == null);
}

test "directory names yield their version, suffixes and all" {
    try testing.expectEqual(Version{ .major = 9, .minor = 0 }, nameVersion("Proton 9.0 (Beta)").?);
    try testing.expectEqual(Version{ .major = 10, .minor = 0 }, nameVersion("Proton 10.0").?);
    try testing.expect(nameVersion("Proton - Experimental") == null);
    try testing.expect(nameVersion("Proton EM-10.0-2D") == null);
}

test "a mapping resolves by internal name, by alias, or by version" {
    try testing.expectEqualStrings("Proton EM-10.0-2D", resolve(&sample_tools, "proton-EM-10.0-2D-proton").?.name);
    try testing.expectEqualStrings("Proton - Experimental", resolve(&sample_tools, "proton_experimental").?.name);
    try testing.expectEqualStrings("Proton 9.0 (Beta)", resolve(&sample_tools, "proton_9").?.name);
    try testing.expect(resolve(&sample_tools, "proton_8") == null);
}

test "with no usable mapping the newest official numbered Proton wins" {
    try testing.expectEqualStrings("Proton 10.0", forGame(&sample_tools, null).?.name);
    try testing.expectEqualStrings("Proton 10.0", forGame(&sample_tools, "proton_8").?.name);
    try testing.expectEqualStrings("Proton - Experimental", newest(sample_tools[2..3]).?.name);
    try testing.expect(newest(&.{}) == null);
}

test "the internal name is the first key under compat_tools" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const name = internalName(arena.allocator(),
        \\"compatibilitytools" { "compat_tools" {
        \\  "GE-Proton9-20" // Internal name
        \\  { "install_path" "." "display_name" "GE-Proton9-20" }
        \\} }
    ).?;
    try testing.expectEqualStrings("GE-Proton9-20", name);
}
