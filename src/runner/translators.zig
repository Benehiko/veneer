const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const paths = @import("../paths.zig");
const ge_proton = @import("ge_proton.zig");

pub const builtin_table = @embedFile("translator_releases");

pub const marker_name = ".veneer-translators";

pub const Release = struct {
    name: []const u8,
    tag: []const u8,
    url: []const u8,
    sha256: [32]u8,

    pub fn compression(r: Release) ge_proton.Compression {
        return if (std.mem.endsWith(u8, r.url, ".tar.zst")) .zstd else .gzip;
    }
};

pub fn parse(arena: Allocator, text: []const u8) (Allocator.Error || error{BadRelease})![]const Release {
    var out: std.ArrayList(Release) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const name = cols.next() orelse return error.BadRelease;
        const tag = cols.next() orelse return error.BadRelease;
        const url = cols.next() orelse return error.BadRelease;
        const hex = cols.next() orelse return error.BadRelease;
        if (cols.next() != null or name.len == 0 or tag.len == 0 or hex.len != 64) return error.BadRelease;
        if (!ge_proton.safeName(name) or std.mem.indexOfScalar(u8, name, '/') != null) return error.BadRelease;
        if (!std.mem.startsWith(u8, url, "https://")) return error.BadRelease;
        if (!std.mem.endsWith(u8, url, ".tar.gz") and !std.mem.endsWith(u8, url, ".tar.zst")) return error.BadRelease;
        var r: Release = .{ .name = name, .tag = tag, .url = url, .sha256 = undefined };
        _ = std.fmt.hexToBytes(&r.sha256, hex) catch return error.BadRelease;
        for (out.items) |have| {
            if (std.mem.eql(u8, have.name, name)) return error.BadRelease;
        }
        try out.append(arena, r);
    }
    return out.items;
}

pub const ArchDirs = struct {
    x64: []const u8,
    x32: ?[]const u8,
};

pub fn archDirs(arena: Allocator, io: Io, root: []const u8) !ArchDirs {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return error.NotATranslatorRelease;
    defer dir.close(io);
    if (dir.access(io, "x64", .{})) |_| {
        var x32: ?[]const u8 = null;
        for ([_][]const u8{ "x32", "x86" }) |name| {
            dir.access(io, name, .{}) catch continue;
            x32 = try std.fs.path.join(arena, &.{ root, name });
            break;
        }
        return .{ .x64 = try std.fs.path.join(arena, &.{ root, "x64" }), .x32 = x32 };
    } else |_| {}
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const sub = try std.fs.path.join(arena, &.{ root, entry.name });
        var inner = Io.Dir.cwd().openDir(io, sub, .{}) catch continue;
        defer inner.close(io);
        inner.access(io, "x64", .{}) catch continue;
        return archDirs(arena, io, sub);
    }
    return error.NotATranslatorRelease;
}

pub fn dllNames(arena: Allocator, io: Io, dir_path: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".dll")) continue;
        try out.append(arena, try arena.dupe(u8, entry.name));
    }
    return out.items;
}

pub fn nativeOverride(arena: Allocator, dlls: []const []const u8) Allocator.Error!?[]const u8 {
    var stems: std.ArrayList([]const u8) = .empty;
    for (dlls) |dll| {
        const stem = if (std.ascii.endsWithIgnoreCase(dll, ".dll")) dll[0 .. dll.len - 4] else dll;
        const lower = try std.ascii.allocLowerString(arena, stem);
        for (stems.items) |have| {
            if (std.mem.eql(u8, have, lower)) break;
        } else try stems.append(arena, lower);
    }
    if (stems.items.len == 0) return null;
    std.mem.sort([]const u8, stems.items, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    for (stems.items, 0..) |s, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, s);
    }
    try out.appendSlice(arena, "=n,b");
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn markerText(arena: Allocator, releases: []const Release) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (releases) |r| {
        try out.appendSlice(arena, r.name);
        try out.append(arena, ' ');
        try out.appendSlice(arena, r.tag);
        try out.append(arena, '\n');
    }
    return out.items;
}

fn cacheDir(arena: Allocator, env: *const Environ.Map) ![]const u8 {
    return std.fs.path.join(arena, &.{ try paths.dir(arena, env, .data), "translators" });
}

fn cached(arena: Allocator, io: Io, env: *const Environ.Map, r: Release) !?ArchDirs {
    const dir = try std.fs.path.join(arena, &.{ try cacheDir(arena, env), try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, r.tag }) });
    return archDirs(arena, io, dir) catch null;
}

pub fn ensureCached(arena: Allocator, io: Io, env: *const Environ.Map, r: Release) !ArchDirs {
    if (try cached(arena, io, env, r)) |dirs| return dirs;
    const base = try cacheDir(arena, env);
    try Io.Dir.cwd().createDirPath(io, base);
    const label = try std.fmt.allocPrint(arena, "{s}-{s}", .{ r.name, r.tag });

    std.log.info("downloading {s} {s} for the Wine prefix", .{ r.name, r.tag });
    const archive = try std.fs.path.join(arena, &.{ base, try std.fmt.allocPrint(arena, ".download-{s}", .{label}) });
    defer Io.Dir.cwd().deleteFile(io, archive) catch {};
    try ge_proton.download(arena, io, r.url, archive, r.sha256);

    const tmp = try std.fs.path.join(arena, &.{ base, try std.fmt.allocPrint(arena, ".unpack-{s}", .{label}) });
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    {
        var dest = try Io.Dir.cwd().openDir(io, tmp, .{});
        defer dest.close(io);
        try ge_proton.extract(arena, io, archive, r.compression(), dest);
    }
    _ = try archDirs(arena, io, tmp);
    const final = try std.fs.path.join(arena, &.{ base, label });
    Io.Dir.cwd().deleteTree(io, final) catch {};
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
    return archDirs(arena, io, final);
}

fn boot(arena: Allocator, io: Io, env: *const Environ.Map, wine: []const u8, prefix: []const u8) !void {
    const reg = try std.fs.path.join(arena, &.{ prefix, "system.reg" });
    if (Io.Dir.cwd().access(io, reg, .{})) |_| return else |_| {}
    std.log.info("creating the Wine prefix {s}", .{prefix});
    var child_env = Environ.Map.init(arena);
    var it = env.iterator();
    while (it.next()) |e| try child_env.put(e.key_ptr.*, e.value_ptr.*);
    try child_env.put("WINEPREFIX", prefix);
    try child_env.put("WINEDEBUG", "-all");
    try child_env.put("WINEDLLOVERRIDES", "mscoree,mshtml=");
    var child = std.process.spawn(io, .{
        .argv = &.{ wine, "wineboot", "--init" },
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.WinebootFailed;
    const term = child.wait(io) catch return error.WinebootFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.WinebootFailed,
        else => return error.WinebootFailed,
    }
    Io.Dir.cwd().access(io, reg, .{}) catch return error.WinebootFailed;
}

fn copyDlls(arena: Allocator, io: Io, from: []const u8, to: []const u8) !void {
    var dest = try Io.Dir.cwd().openDir(io, to, .{});
    defer dest.close(io);
    for (try dllNames(arena, io, from)) |name| {
        const src = try std.fs.path.join(arena, &.{ from, name });
        const bytes = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(256 << 20));
        try dest.writeFile(io, .{ .sub_path = name, .data = bytes });
    }
}

pub fn setUp(arena: Allocator, io: Io, env: *const Environ.Map, wine: []const u8, prefix: []const u8, dry_run: bool) ![]const []const u8 {
    const releases = try parse(arena, builtin_table);
    var dlls: std.ArrayList([]const u8) = .empty;
    if (dry_run) {
        for (releases) |r| {
            if (try cached(arena, io, env, r)) |dirs| try dlls.appendSlice(arena, try dllNames(arena, io, dirs.x64));
        }
        return dlls.items;
    }

    const all = try arena.alloc(ArchDirs, releases.len);
    for (releases, all) |r, *dirs| dirs.* = try ensureCached(arena, io, env, r);
    for (all) |dirs| try dlls.appendSlice(arena, try dllNames(arena, io, dirs.x64));

    const marker = try std.fs.path.join(arena, &.{ prefix, marker_name });
    const want = try markerText(arena, releases);
    if (Io.Dir.cwd().readFileAlloc(io, marker, arena, .limited(64 << 10))) |have| {
        if (std.mem.eql(u8, have, want)) return dlls.items;
    } else |_| {}

    try boot(arena, io, env, wine, prefix);
    const windows = try std.fs.path.join(arena, &.{ prefix, "drive_c", "windows" });
    const system32 = try std.fs.path.join(arena, &.{ windows, "system32" });
    const syswow64 = try std.fs.path.join(arena, &.{ windows, "syswow64" });
    const wow64 = if (Io.Dir.cwd().access(io, syswow64, .{})) |_| true else |_| false;
    for (all) |dirs| {
        if (wow64) {
            try copyDlls(arena, io, dirs.x64, system32);
            if (dirs.x32) |x32| try copyDlls(arena, io, x32, syswow64);
        } else if (dirs.x32) |x32| {
            try copyDlls(arena, io, x32, system32);
        }
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = want });
    return dlls.items;
}

pub fn explain(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DownloadFailed => "could not download DXVK or VKD3D-Proton from GitHub",
        error.ChecksumMismatch => "a DXVK or VKD3D-Proton download does not match its pinned SHA-256; nothing was installed",
        error.UnsafeArchive => "a DXVK or VKD3D-Proton archive holds paths or links outside its folder; nothing was installed",
        error.NotATranslatorRelease => "a DXVK or VKD3D-Proton archive has no x64 folder",
        error.WinebootFailed => "`wine wineboot --init` could not create the Wine prefix",
        error.BadRelease => "the built-in DXVK and VKD3D-Proton table is malformed",
        else => null,
    };
}

const testing = std.testing;

test "the shipped table parses, one row per translator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(), builtin_table);
    try testing.expect(list.len > 0);
}

test "rows need a name, a tag, an https tarball and a 64-digit hash; zst picks zstd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ab8 = "abababab";
    const hash = ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8 ++ ab8;
    const list = try parse(a, "# h\ndxvk\tv1\thttps://x/d.tar.gz\t" ++ hash ++ "\nvkd3d\tv2\thttps://x/v.tar.zst\t" ++ hash ++ "\n");
    try testing.expectEqual(ge_proton.Compression.gzip, list[0].compression());
    try testing.expectEqual(ge_proton.Compression.zstd, list[1].compression());
    try testing.expectError(error.BadRelease, parse(a, "dxvk\tv1\thttp://x/d.tar.gz\t" ++ hash));
    try testing.expectError(error.BadRelease, parse(a, "dxvk\tv1\thttps://x/d.zip\t" ++ hash));
    try testing.expectError(error.BadRelease, parse(a, "../x\tv1\thttps://x/d.tar.gz\t" ++ hash));
    try testing.expectError(error.BadRelease, parse(a, "dxvk\tv1\thttps://x/d.tar.gz\tabc"));
    try testing.expectError(error.BadRelease, parse(a, "dxvk\tv1\thttps://x/d.tar.gz\t" ++ hash ++ "\ndxvk\tv2\thttps://x/e.tar.gz\t" ++ hash));
}

test "overrides name every DLL once, lower case, as native then builtin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("d3d11,d3d12,dxgi=n,b", (try nativeOverride(a, &.{ "dxgi.dll", "d3d11.dll", "D3D12.DLL", "dxgi" })).?);
    try testing.expect(try nativeOverride(a, &.{}) == null);
}

test "the release folder is found at the top or one level down, x32 or x86 alike" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "dxvk/dxvk-3.1.1/x64");
    try tmp.dir.createDirPath(testing.io, "dxvk/dxvk-3.1.1/x32");
    try tmp.dir.createDirPath(testing.io, "vkd3d/x64");
    try tmp.dir.createDirPath(testing.io, "vkd3d/x86");
    try tmp.dir.createDirPath(testing.io, "empty/docs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vkd3d/x64/d3d12.dll", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "vkd3d/x64/README", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    const dxvk = try archDirs(a, testing.io, try std.fs.path.join(a, &.{ root, "dxvk" }));
    try testing.expect(std.mem.endsWith(u8, dxvk.x64, "dxvk-3.1.1/x64"));
    try testing.expect(std.mem.endsWith(u8, dxvk.x32.?, "dxvk-3.1.1/x32"));
    const vkd3d = try archDirs(a, testing.io, try std.fs.path.join(a, &.{ root, "vkd3d" }));
    try testing.expect(std.mem.endsWith(u8, vkd3d.x32.?, "vkd3d/x86"));
    const names = try dllNames(a, testing.io, vkd3d.x64);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("d3d12.dll", names[0]);
    try testing.expectError(error.NotATranslatorRelease, archDirs(a, testing.io, try std.fs.path.join(a, &.{ root, "empty" })));
}
