const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vdf = @import("vdf.zig");
const appinfo = @import("appinfo.zig");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Platform = game_mod.Platform;

pub const root_candidates = [_][]const u8{
    ".local/share/Steam",
    ".steam/steam",
    ".var/app/com.valvesoftware.Steam/data/Steam",
};

const tool_name_prefixes = [_][]const u8{
    "Proton",
    "Steam Linux Runtime",
    "Steamworks Common Redistributables",
};

const playable_types = [_][]const u8{ "game", "application", "demo", "beta" };

pub const Manifest = struct {
    app_id: []const u8,
    name: []const u8,
    install_dir: []const u8,
    installed: bool,
};

pub fn parseManifest(arena: Allocator, text: []const u8) vdf.ParseError!?Manifest {
    const doc = try vdf.parse(arena, text);
    const state = doc.object("AppState") orelse return null;
    const app_id = state.string("appid") orelse return null;
    const install_dir = state.string("installdir") orelse return null;
    const flags = std.fmt.parseInt(u32, state.string("StateFlags") orelse "0", 10) catch 0;
    return .{
        .app_id = app_id,
        .name = state.string("name") orelse app_id,
        .install_dir = install_dir,
        .installed = flags & 4 != 0,
    };
}

pub fn libraryPaths(arena: Allocator, text: []const u8) vdf.ParseError![]const []const u8 {
    const doc = try vdf.parse(arena, text);
    const folders = doc.object("libraryfolders") orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (folders.pairs) |pair| {
        switch (pair.value) {
            .object => |o| if (o.string("path")) |p| try out.append(arena, p),
            .string => {},
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn compatTool(config: vdf.Object, app_id: []const u8) ?[]const u8 {
    const mapping = config.path(&.{ "InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping" }) orelse
        return null;
    const name = (mapping.object(app_id) orelse return null).string("name") orelse return null;
    return if (name.len == 0) null else name;
}

pub fn platformFor(explicit_tool: ?[]const u8, oslist: ?[]const u8) Platform {
    if (explicit_tool) |tool| {
        return if (std.mem.startsWith(u8, tool, "steamlinuxruntime")) .linux else .windows;
    }
    if (oslist) |list| {
        if (appinfo.listHas(list, "linux")) return .linux;
    }
    return .windows;
}

pub fn isPlayable(app_type: ?[]const u8, name: []const u8) bool {
    if (app_type) |t| {
        for (playable_types) |p| {
            if (std.ascii.eqlIgnoreCase(t, p)) return true;
        }
        return false;
    }
    for (tool_name_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    return true;
}

pub fn isLaunchUrl(executable: []const u8) bool {
    const colon = std.mem.indexOf(u8, executable, "://") orelse return false;
    if (colon < 2) return false;
    if (!std.ascii.isAlphabetic(executable[0])) return false;
    for (executable[1..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

pub fn joinGamePath(arena: Allocator, install_dir: []const u8, relative: []const u8) Allocator.Error![]const u8 {
    const rel = try arena.dupe(u8, relative);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    return std.fs.path.join(arena, &.{ install_dir, std.mem.trimStart(u8, rel, "/") });
}

const Root = struct {
    path: []const u8,
    config: vdf.Object,
    appinfo: ?appinfo.Reader,

    fn load(arena: Allocator, io: Io, path: []const u8) !Root {
        var root: Root = .{ .path = path, .config = .{}, .appinfo = null };
        const config_path = try std.fs.path.join(arena, &.{ path, "config", "config.vdf" });
        if (Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(16 << 20))) |text| {
            root.config = vdf.parse(arena, text) catch .{};
        } else |_| {}
        const info_path = try std.fs.path.join(arena, &.{ path, "appcache", "appinfo.vdf" });
        if (Io.Dir.cwd().readFileAlloc(io, info_path, arena, .limited(1 << 30))) |bytes| {
            root.appinfo = appinfo.Reader.init(arena, bytes) catch null;
        } else |_| {}
        return root;
    }
};

pub const Location = struct {
    root: []const u8,
    libraries: []const []const u8,
};

pub fn locate(arena: Allocator, io: Io, home: []const u8) ![]const Location {
    var libraries: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(Location) = .empty;

    for (root_candidates) |rel| {
        const root_path = try std.fs.path.join(arena, &.{ home, rel });
        const first_new = libraries.items.len;

        const index_path = try std.fs.path.join(arena, &.{ root_path, "steamapps", "libraryfolders.vdf" });
        const listed: []const []const u8 = if (Io.Dir.cwd().readFileAlloc(io, index_path, arena, .limited(4 << 20))) |text|
            libraryPaths(arena, text) catch &.{}
        else |_|
            &.{};
        for (listed) |lib| try appendUnique(arena, &libraries, lib);
        if (listed.len == 0) {
            var probe = Io.Dir.cwd().openDir(io, root_path, .{}) catch continue;
            probe.close(io);
            try appendUnique(arena, &libraries, root_path);
        }
        if (libraries.items.len == first_new) continue;
        try out.append(arena, .{ .root = root_path, .libraries = try arena.dupe([]const u8, libraries.items[first_new..]) });
    }
    return out.items;
}

pub fn scan(arena: Allocator, io: Io, home: []const u8, games: *std.ArrayList(Game)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try locate(arena, io, home)) |loc| {
        const root = try Root.load(arena, io, loc.root);
        for (loc.libraries) |lib| try scanLibrary(arena, io, root, lib, games, &seen);
    }
}

fn appendUnique(arena: Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    const trimmed = std.mem.trimEnd(u8, item, "/");
    for (list.items) |have| {
        if (std.mem.eql(u8, have, trimmed)) return;
    }
    try list.append(arena, trimmed);
}

fn scanLibrary(
    arena: Allocator,
    io: Io,
    root: Root,
    library: []const u8,
    games: *std.ArrayList(Game),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const steamapps = try std.fs.path.join(arena, &.{ library, "steamapps" });
    var dir = Io.Dir.cwd().openDir(io, steamapps, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "appmanifest_") or !std.mem.endsWith(u8, entry.name, ".acf")) continue;
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
        const m = (parseManifest(arena, text) catch continue) orelse continue;
        if (!m.installed or seen.contains(m.app_id)) continue;
        const app_num = std.fmt.parseInt(u32, m.app_id, 10) catch continue;

        const info: ?vdf.Object = if (root.appinfo) |r| (r.find(arena, app_num) catch null) else null;
        const common: vdf.Object = if (info) |i| i.object("common") orelse .{} else .{};
        if (!isPlayable(if (info != null) common.string("type") else null, m.name)) continue;

        const explicit = compatTool(root.config, m.app_id);
        const platform = platformFor(explicit, common.string("oslist"));
        const install_dir = try std.fs.path.join(arena, &.{ steamapps, "common", m.install_dir });

        var game: Game = .{
            .id = try std.fmt.allocPrint(arena, "steam:{s}", .{m.app_id}),
            .name = common.string("name") orelse m.name,
            .source = .steam,
            .platform = platform,
            .install_dir = install_dir,
            .art = try artPath(arena, io, root.path, m.app_id),
            .steam = .{
                .app_id = m.app_id,
                .root = root.path,
                .steamapps = steamapps,
                .compat_tool = explicit orelse compatTool(root.config, "0"),
            },
        };
        if (info) |i| {
            if (appinfo.launchFor(i, platform)) |launch| {
                game.exe = if (isLaunchUrl(launch.executable)) launch.executable else try joinGamePath(arena, install_dir, launch.executable);
                game.args = launch.arguments;
                if (launch.workdir) |w| {
                    if (w.len > 0) game.workdir = try joinGamePath(arena, install_dir, w);
                }
                if (game.workdir == null and isLaunchUrl(launch.executable)) game.workdir = install_dir;
            }
        }
        try seen.put(arena, m.app_id, {});
        try games.append(arena, game);
    }
}

const art_names = [_][]const u8{ "library_600x900.jpg", "library_capsule.jpg", "library_header.jpg", "header.jpg" };

fn artPath(arena: Allocator, io: Io, root: []const u8, app_id: []const u8) !?[]const u8 {
    const cache = try std.fs.path.join(arena, &.{ root, "appcache", "librarycache" });
    const app_dir = try std.fs.path.join(arena, &.{ cache, app_id });
    const subdirs = try artSubdirs(arena, io, app_dir);
    for (art_names) |name| {
        const flat = try std.fmt.allocPrint(arena, "{s}/{s}_{s}", .{ cache, app_id, name });
        const candidates = [_][]const u8{ try std.fs.path.join(arena, &.{ app_dir, name }), flat };
        for (candidates) |path| {
            Io.Dir.cwd().access(io, path, .{}) catch continue;
            return path;
        }
        for (subdirs) |sub| {
            const path = try std.fs.path.join(arena, &.{ app_dir, sub, name });
            Io.Dir.cwd().access(io, path, .{}) catch continue;
            return path;
        }
    }
    return null;
}

fn artSubdirs(arena: Allocator, io: Io, app_dir: []const u8) ![]const []const u8 {
    var dir = Io.Dir.cwd().openDir(io, app_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    return names.items;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;
const test_io = testing.io;

test "a manifest is installed only when StateFlags has the installed bit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const done = (try parseManifest(a,
        \\"AppState" { "appid" "1245620" "name" "ELDEN RING" "installdir" "ELDEN RING" "StateFlags" "4" }
    )).?;
    try testing.expect(done.installed);
    try testing.expectEqualStrings("ELDEN RING", done.install_dir);
    const updating = (try parseManifest(a,
        \\"AppState" { "appid" "1" "installdir" "x" "StateFlags" "1026" }
    )).?;
    try testing.expect(!updating.installed);
    try testing.expectEqualStrings("1", updating.name);
    try testing.expect(try parseManifest(a, "\"AppState\" { \"name\" \"no id\" }") == null);
}

test "library paths come from every numbered folder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const paths = try libraryPaths(arena.allocator(),
        \\"libraryfolders" {
        \\  "0" { "path" "/home/p/.local/share/Steam" "apps" { "570" "1" } }
        \\  "1" { "path" "/mnt/games" }
        \\  "contentstatsid" "123"
        \\}
    );
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("/mnt/games", paths[1]);
}

test "an explicit tool decides the platform; otherwise Linux support does" {
    try testing.expectEqual(Platform.windows, platformFor("proton_9", "windows,linux"));
    try testing.expectEqual(Platform.linux, platformFor("steamlinuxruntime_sniper", null));
    try testing.expectEqual(Platform.linux, platformFor(null, "windows,linux"));
    try testing.expectEqual(Platform.windows, platformFor(null, "windows"));
    try testing.expectEqual(Platform.windows, platformFor(null, null));
}

test "appinfo type decides what is playable; without it, tool names are filtered" {
    try testing.expect(isPlayable("Game", "Proton Anything"));
    try testing.expect(!isPlayable("Tool", "Some Game"));
    try testing.expect(!isPlayable(null, "Proton 9.0"));
    try testing.expect(!isPlayable(null, "Steam Linux Runtime 3.0 (sniper)"));
    try testing.expect(isPlayable(null, "ELDEN RING"));
}

test "Windows-style launch paths join onto the install directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try joinGamePath(arena.allocator(), "/lib/common/Game", "\\bin\\x64\\game.exe");
    try testing.expectEqualStrings("/lib/common/Game/bin/x64/game.exe", p);
}

test "a launcher URL is a launch target, not a path in the install directory" {
    try testing.expect(isLaunchUrl("steam2ea://launchgame/1328660?platform=steam&theme=NFSHP"));
    try testing.expect(isLaunchUrl("link2ea://launchgame/1238860?platform=steam"));
    try testing.expect(!isLaunchUrl("bin\\x64\\game.exe"));
    try testing.expect(!isLaunchUrl("C:\\Games\\game.exe"));
    try testing.expect(!isLaunchUrl("tools/a://b.exe"));
    try testing.expect(!isLaunchUrl("://x"));
}

test "cover art prefers portrait art, in the app folder or a hashed subfolder, over a header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(test_io, ".", a);

    try tmp.dir.createDirPath(test_io, "appcache/librarycache/20/0f3a9c");
    try tmp.dir.writeFile(test_io, .{ .sub_path = "appcache/librarycache/20/header.jpg", .data = "" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "appcache/librarycache/20/0f3a9c/library_600x900.jpg", .data = "" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "appcache/librarycache/30_header.jpg", .data = "" });

    const hashed = (try artPath(a, test_io, root, "20")).?;
    try testing.expect(std.mem.endsWith(u8, hashed, "librarycache/20/0f3a9c/library_600x900.jpg"));
    const flat = (try artPath(a, test_io, root, "30")).?;
    try testing.expect(std.mem.endsWith(u8, flat, "librarycache/30_header.jpg"));
    try testing.expect(try artPath(a, test_io, root, "40") == null);
}

test "scan finds installed games across libraries listed by the root, once each" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try tmp.dir.realPathFileAlloc(test_io, ".", a);

    var root = try tmp.dir.createDirPathOpen(test_io, ".local/share/Steam/steamapps", .{});
    defer root.close(test_io);
    var other = try tmp.dir.createDirPathOpen(test_io, "games/steamapps", .{});
    defer other.close(test_io);

    try root.writeFile(test_io, .{ .sub_path = "libraryfolders.vdf", .data = try std.fmt.allocPrint(a,
        \\"libraryfolders" {{ "0" {{ "path" "{s}/.local/share/Steam" }} "1" {{ "path" "{s}/games/" }} }}
    , .{ home, home }) });
    try root.writeFile(test_io, .{ .sub_path = "appmanifest_10.acf", .data =
        \\"AppState" { "appid" "10" "name" "Alpha" "installdir" "Alpha" "StateFlags" "4" }
    });
    try root.writeFile(test_io, .{ .sub_path = "appmanifest_1493710.acf", .data =
        \\"AppState" { "appid" "1493710" "name" "Proton Experimental" "installdir" "Proton - Experimental" "StateFlags" "4" }
    });
    try other.writeFile(test_io, .{ .sub_path = "appmanifest_20.acf", .data =
        \\"AppState" { "appid" "20" "name" "Beta" "installdir" "Beta" "StateFlags" "4" }
    });
    try other.writeFile(test_io, .{ .sub_path = "appmanifest_10.acf", .data =
        \\"AppState" { "appid" "10" "name" "Alpha copy" "installdir" "Alpha" "StateFlags" "4" }
    });

    var games: std.ArrayList(Game) = .empty;
    try scan(a, test_io, home, &games);
    std.mem.sort(Game, games.items, {}, Game.lessThan);

    try testing.expectEqual(@as(usize, 2), games.items.len);
    try testing.expectEqualStrings("steam:10", games.items[0].id);
    try testing.expectEqualStrings("Alpha", games.items[0].name);
    try testing.expectEqualStrings("steam:20", games.items[1].id);
    try testing.expect(std.mem.endsWith(u8, games.items[1].install_dir, "games/steamapps/common/Beta"));
}
