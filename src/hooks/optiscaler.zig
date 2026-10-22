const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const source_dll = "OptiScaler.dll";
pub const proxy_dll = "dxgi.dll";
pub const ini_name = "OptiScaler.ini";
pub const dll_override = "dxgi=n,b";

pub fn looksLikeRelease(io: Io, dir: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer d.close(io);
    d.access(io, source_dll, .{}) catch return false;
    return true;
}

pub fn stagedName(name: []const u8) []const u8 {
    return if (std.ascii.eqlIgnoreCase(name, source_dll)) proxy_dll else name;
}

pub fn exeDirWithin(install_dir: []const u8, exe: []const u8) ?[]const u8 {
    const exe_dir = std.fs.path.dirname(exe) orelse return null;
    const root = std.mem.trimEnd(u8, install_dir, "/");
    if (std.mem.eql(u8, exe_dir, root)) return "";
    if (!std.mem.startsWith(u8, exe_dir, root) or exe_dir.len <= root.len or exe_dir[root.len] != '/') return null;
    return exe_dir[root.len + 1 ..];
}

pub fn stage(arena: Allocator, io: Io, release_dir: []const u8, upper: []const u8, exe_rel_dir: []const u8) !void {
    const target_path = try std.fs.path.join(arena, &.{ upper, exe_rel_dir });
    try Io.Dir.cwd().createDirPath(io, target_path);
    var target = try Io.Dir.cwd().openDir(io, target_path, .{});
    defer target.close(io);
    var release = try Io.Dir.cwd().openDir(io, release_dir, .{ .iterate = true });
    defer release.close(io);

    var it = release.iterate();
    while (try it.next(io)) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, ini_name)) {
            target.access(io, ini_name, .{}) catch {
                try Io.Dir.copyFile(release, entry.name, target, ini_name, io, .{});
            };
            continue;
        }
        const dest = stagedName(entry.name);
        target.deleteFile(io, dest) catch {};
        const source = try std.fs.path.join(arena, &.{ release_dir, entry.name });
        try target.symLink(io, source, dest, .{ .is_directory = entry.kind == .directory });
    }
}

const testing = std.testing;

test "OptiScaler's DLL takes the proxy name; everything else keeps its own" {
    try testing.expectEqualStrings(proxy_dll, stagedName("OptiScaler.dll"));
    try testing.expectEqualStrings(proxy_dll, stagedName("optiscaler.DLL"));
    try testing.expectEqualStrings("amd_fidelityfx_dx12.dll", stagedName("amd_fidelityfx_dx12.dll"));
}

test "the exe's directory is found relative to the install" {
    try testing.expectEqualStrings("Game", exeDirWithin("/l/ELDEN RING", "/l/ELDEN RING/Game/eldenring.exe").?);
    try testing.expectEqualStrings("", exeDirWithin("/l/Sekiro/", "/l/Sekiro/sekiro.exe").?);
    try testing.expectEqualStrings("bin/x64", exeDirWithin("/l/G", "/l/G/bin/x64/g.exe").?);
    try testing.expect(exeDirWithin("/l/G", "/l/Gx/g.exe") == null);
    try testing.expect(exeDirWithin("/l/G", "/other/g.exe") == null);
}

test "staging links the release beside the exe, renames the DLL, and keeps an edited ini" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    var rel = try tmp.dir.createDirPathOpen(testing.io, "release/Licenses", .{});
    rel.close(testing.io);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "release/OptiScaler.dll", .data = "MZ" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "release/OptiScaler.ini", .data = "[Upscalers]\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "release/libxess.dll", .data = "MZ" });

    const release = try std.fs.path.join(a, &.{ root, "release" });
    const upper = try std.fs.path.join(a, &.{ root, "upper" });
    try testing.expect(looksLikeRelease(testing.io, release));

    try stage(a, testing.io, release, upper, "Game");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "upper/Game/OptiScaler.ini", .data = "edited by the player\n" });
    try stage(a, testing.io, release, upper, "Game");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("MZ", try tmp.dir.readFile(testing.io, "upper/Game/dxgi.dll", &buf));
    try testing.expectEqualStrings("MZ", try tmp.dir.readFile(testing.io, "upper/Game/libxess.dll", &buf));
    try testing.expectEqualStrings("edited by the player\n", try tmp.dir.readFile(testing.io, "upper/Game/OptiScaler.ini", &buf));
    try tmp.dir.access(testing.io, "upper/Game/Licenses", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "upper/Game/OptiScaler.dll", .{}));
}
