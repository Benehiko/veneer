const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const verb = "__overlay";

pub const Request = struct {
    lower: []const u8,
    upper: []const u8,
    work: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
};

pub fn wrapperArgv(arena: Allocator, veneer: []const u8, lower: []const u8, upper: []const u8, work: []const u8, cwd: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ veneer, verb, lower, upper, work, cwd, "--" });
}

pub fn parseRequest(args: []const []const u8) error{BadOverlayRequest}!Request {
    if (args.len < 6 or !std.mem.eql(u8, args[4], "--")) return error.BadOverlayRequest;
    return .{ .lower = args[0], .upper = args[1], .work = args[2], .cwd = args[3], .argv = args[5..] };
}

pub fn mountOptions(arena: Allocator, lower: []const u8, upper: []const u8, work: []const u8) ![:0]const u8 {
    for ([_][]const u8{ lower, upper, work }) |p| {
        if (!std.fs.path.isAbsolute(p)) return error.RelativeOverlayPath;
        if (std.mem.indexOfAny(u8, p, ",:\\") != null) return error.UnsupportedOverlayPath;
    }
    return std.fmt.allocPrintSentinel(arena, "lowerdir={s},upperdir={s},workdir={s},userxattr", .{ lower, upper, work }, 0);
}

pub fn idMap(buf: []u8, id: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d} {d} 1\n", .{ id, id });
}

fn check(rc: usize) !void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .PERM, .ACCES => return error.NamespaceDenied,
        .INVAL => return error.NamespaceInvalid,
        .NOENT => return error.FileNotFound,
        else => return error.Unexpected,
    }
}

fn writeProc(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY }, 0);
    try check(rc);
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    try check(linux.write(fd, data.ptr, data.len));
}

pub fn enter(arena: Allocator, req: Request) !void {
    const options = try mountOptions(arena, req.lower, req.upper, req.work);
    const target = try arena.dupeSentinel(u8, req.lower, 0);
    const cwd = try arena.dupeSentinel(u8, req.cwd, 0);
    const uid = linux.getuid();
    const gid = linux.getgid();

    check(linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNS)) catch return error.UserNamespaceDenied;
    var buf: [64]u8 = undefined;
    writeProc("/proc/self/setgroups", "deny") catch return error.IdMapDenied;
    writeProc("/proc/self/uid_map", try idMap(&buf, uid)) catch return error.IdMapDenied;
    writeProc("/proc/self/gid_map", try idMap(&buf, gid)) catch return error.IdMapDenied;
    check(linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0)) catch return error.MountDenied;
    const mounted = linux.errno(linux.mount("overlay", target, "overlay", 0, @intFromPtr(options.ptr)));
    if (mounted != .SUCCESS) {
        std.log.err("mount -t overlay -o {s} on {s}: {s}", .{ options, req.lower, @tagName(mounted) });
        return if (mounted == .BUSY) error.OverlayInUse else error.OverlayMountFailed;
    }
    check(linux.chdir(cwd)) catch return error.WorkdirGone;
}

pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.UserNamespaceDenied => "this system does not let programs create user namespaces (check kernel.unprivileged_userns_clone, or AppArmor's restriction on Ubuntu)",
        error.IdMapDenied => "the user namespace was created, but the kernel refused the id map",
        error.MountDenied => "mounting is not allowed here (a sandbox such as Flatpak or Landlock may forbid it)",
        error.OverlayMountFailed => "the kernel refused the overlay mount; the error code is on the line above, and `journalctl -k -g overlayfs` shows the kernel's reason (unprivileged overlayfs needs Linux 5.11 or later, and the upper directory on a filesystem that supports it)",
        error.OverlayInUse => "an earlier launch of this game is still running and holds its overlay; stop it (Stop leftover processes, or `veneer stop <game>`) and try again",
        error.WorkdirGone => "the game's working directory vanished after the mount",
        error.BadOverlayRequest => "the overlay command line is malformed",
        error.UnsupportedOverlayPath => "a path contains a comma, colon or backslash, which overlayfs cannot take",
        else => @errorName(err),
    };
}

pub fn exec(arena: Allocator, io: Io, args: []const []const u8) !noreturn {
    const req = try parseRequest(args);
    try enter(arena, req);
    const err = std.process.replace(io, .{ .argv = req.argv });
    return err;
}

const testing = std.testing;

test "the wrapper argv round-trips through the request parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, try wrapperArgv(a, "/bin/veneer", "/g", "/d/up", "/d/work", "/g/bin"));
    try argv.appendSlice(a, &.{ "proton", "run", "game.exe" });
    try testing.expectEqualStrings(verb, argv.items[1]);
    const req = try parseRequest(argv.items[2..]);
    try testing.expectEqualStrings("/g", req.lower);
    try testing.expectEqualStrings("/g/bin", req.cwd);
    try testing.expectEqual(@as(usize, 3), req.argv.len);
    try testing.expectError(error.BadOverlayRequest, parseRequest(&.{ "/a", "/b", "/c", "/d", "proton" }));
    try testing.expectError(error.BadOverlayRequest, parseRequest(&.{ "/a", "/b", "/c", "/d", "--" }));
}

test "mount options name the three layers and refuse paths overlayfs would misread" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = try mountOptions(a, "/lib/common/ELDEN RING", "/d/up", "/d/work");
    try testing.expectEqualStrings("lowerdir=/lib/common/ELDEN RING,upperdir=/d/up,workdir=/d/work,userxattr", opts);
    try testing.expectError(error.UnsupportedOverlayPath, mountOptions(a, "/g/a,b", "/u", "/w"));
    try testing.expectError(error.UnsupportedOverlayPath, mountOptions(a, "/g", "/u:x", "/w"));
    try testing.expectError(error.RelativeOverlayPath, mountOptions(a, "g", "/u", "/w"));
}

test "the id map maps the player onto themselves and nobody else" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1000 1000 1\n", try idMap(&buf, 1000));
}
