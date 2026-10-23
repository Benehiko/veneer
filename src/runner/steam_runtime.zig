const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vdf = @import("../library/vdf.zig");
const steam = @import("../library/steam.zig");

pub const Manifest = struct {
    commandline: ?[]const u8 = null,
    require_tool_appid: ?[]const u8 = null,
};

pub const Runtime = struct {
    dir: []const u8,
    argv: []const []const u8,
};

pub const Lookup = union(enum) {
    none,
    missing: []const u8,
    found: Runtime,
};

pub fn parseManifest(arena: Allocator, text: []const u8) ?Manifest {
    const doc = vdf.parse(arena, text) catch return null;
    const m = doc.object("manifest") orelse return null;
    return .{ .commandline = m.string("commandline"), .require_tool_appid = m.string("require_tool_appid") };
}

fn readManifest(arena: Allocator, io: Io, tool_dir: []const u8) ?Manifest {
    const path = std.fs.path.join(arena, &.{ tool_dir, "toolmanifest.vdf" }) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 10)) catch return null;
    return parseManifest(arena, text);
}

pub fn expand(arena: Allocator, dir: []const u8, commandline: []const u8, verb: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, commandline, " \t");
    while (it.next()) |word| {
        const replaced = try std.mem.replaceOwned(u8, arena, word, "%verb%", verb);
        if (out.items.len == 0) {
            try out.append(arena, try std.fs.path.join(arena, &.{ dir, std.mem.trimStart(u8, replaced, "/") }));
        } else try out.append(arena, replaced);
    }
    return out.items;
}

fn installDir(arena: Allocator, io: Io, locations: []const steam.Location, app_id: []const u8) !?[]const u8 {
    const name = try std.fmt.allocPrint(arena, "appmanifest_{s}.acf", .{app_id});
    for (locations) |loc| {
        for (loc.libraries) |lib| {
            const path = try std.fs.path.join(arena, &.{ lib, "steamapps", name });
            const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
            const doc = vdf.parse(arena, text) catch continue;
            const state = doc.object("AppState") orelse continue;
            const dir_name = state.string("installdir") orelse continue;
            return try std.fs.path.join(arena, &.{ lib, "steamapps", "common", dir_name });
        }
    }
    return null;
}

pub fn forTool(arena: Allocator, io: Io, locations: []const steam.Location, tool_dir: []const u8, verb: []const u8) !Lookup {
    const tool = readManifest(arena, io, tool_dir) orelse return .none;
    const id = tool.require_tool_appid orelse return .none;
    const dir = try installDir(arena, io, locations, id) orelse return .{ .missing = id };
    const runtime = readManifest(arena, io, dir) orelse return .{ .missing = id };
    const commandline = runtime.commandline orelse return .{ .missing = id };
    const argv = try expand(arena, dir, commandline, verb);
    if (argv.len == 0) return .{ .missing = id };
    return .{ .found = .{ .dir = dir, .argv = argv } };
}

const testing = std.testing;

test "a Proton manifest names the runtime it needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const m = parseManifest(arena.allocator(),
        \\"manifest"
        \\{
        \\  "version" "2"
        \\  "commandline" "/proton %verb%"
        \\  "require_tool_appid" "1628350"
        \\  "use_sessions" "1"
        \\}
    ).?;
    try testing.expectEqualStrings("1628350", m.require_tool_appid.?);
    try testing.expectEqualStrings("/proton %verb%", m.commandline.?);
    try testing.expect(parseManifest(arena.allocator(), "\"other\" { }") == null);
}

test "the runtime's command line is rooted at its directory and takes the verb" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try expand(arena.allocator(), "/lib/steamapps/common/SteamLinuxRuntime_sniper", "/_v2-entry-point --verb=%verb% --", "waitforexitandrun");
    const want = [_][]const u8{ "/lib/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point", "--verb=waitforexitandrun", "--" };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, a| try testing.expectEqualStrings(w, a);
}

test "the runtime is found in whichever library holds it, and its absence is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "proton");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proton/toolmanifest.vdf", .data =
        \\"manifest" { "commandline" "/proton %verb%" "require_tool_appid" "1628350" }
    });
    try tmp.dir.createDirPath(testing.io, "plain");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plain/toolmanifest.vdf", .data =
        \\"manifest" { "commandline" "/proton %verb%" }
    });
    try tmp.dir.createDirPath(testing.io, "second/steamapps/common/SteamLinuxRuntime_sniper");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "second/steamapps/appmanifest_1628350.acf", .data =
        \\"AppState" { "appid" "1628350" "installdir" "SteamLinuxRuntime_sniper" }
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "second/steamapps/common/SteamLinuxRuntime_sniper/toolmanifest.vdf", .data =
        \\"manifest" { "commandline" "/_v2-entry-point --verb=%verb% --" }
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const proton_dir = try std.fs.path.join(a, &.{ root, "proton" });
    const plain_dir = try std.fs.path.join(a, &.{ root, "plain" });
    const first = try std.fs.path.join(a, &.{ root, "first" });
    const second = try std.fs.path.join(a, &.{ root, "second" });

    const both = [_]steam.Location{.{ .root = root, .libraries = &.{ first, second } }};
    const found = (try forTool(a, testing.io, &both, proton_dir, "waitforexitandrun")).found;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ second, "steamapps", "common", "SteamLinuxRuntime_sniper" }), found.dir);
    try testing.expectEqualStrings("--verb=waitforexitandrun", found.argv[1]);

    const only_first = [_]steam.Location{.{ .root = root, .libraries = &.{first} }};
    try testing.expectEqualStrings("1628350", (try forTool(a, testing.io, &only_first, proton_dir, "run")).missing);
    try testing.expect(try forTool(a, testing.io, &both, plain_dir, "run") == .none);
}
