const std = @import("std");
const Io = std.Io;

pub const pid_file = ".steam/steam.pid";
pub const start_timeout_s = 90;
pub const settle_s = 5;

pub fn parsePid(text: []const u8) ?u32 {
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch return null;
    return if (pid == 0) null else pid;
}

pub fn isSteamComm(comm: []const u8) bool {
    const name = std.mem.trim(u8, comm, " \t\r\n");
    return std.mem.eql(u8, name, "steam") or std.mem.eql(u8, name, "steamwebhelper");
}

pub fn running(io: Io, home: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, pid_file }) catch return false;
    var buf: [32]u8 = undefined;
    const pid = parsePid(Io.Dir.cwd().readFile(io, path, &buf) catch return false) orelse return false;
    const comm_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return false;
    var comm_buf: [64]u8 = undefined;
    return isSteamComm(Io.Dir.cwd().readFile(io, comm_path, &comm_buf) catch return false);
}

pub fn ensureRunning(io: Io, home: []const u8) !void {
    if (running(io, home)) return;
    std.log.info("starting Steam: Steam games need the client for their DRM", .{});
    _ = std.process.spawn(io, .{
        .argv = &.{ "steam", "-silent" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SteamNotStarted;
    var waited: u32 = 0;
    while (waited < start_timeout_s) : (waited += 1) {
        try io.sleep(.fromSeconds(1), .awake);
        if (running(io, home)) {
            try io.sleep(.fromSeconds(settle_s), .awake);
            return;
        }
    }
    return error.SteamNotStarted;
}

pub const proton_experimental_app_id = "1493710";

pub fn installUrl(buf: []u8, app_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "steam://install/{s}", .{app_id});
}

pub fn requestInstall(io: Io, app_id: []const u8) !void {
    var buf: [64]u8 = undefined;
    _ = std.process.spawn(io, .{
        .argv = &.{ "steam", try installUrl(&buf, app_id) },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SteamNotStarted;
}

const testing = std.testing;

test "an install request is a steam:// URL for the app" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("steam://install/1493710", try installUrl(&buf, proton_experimental_app_id));
}

test "the pid file holds one positive number" {
    try testing.expectEqual(@as(u32, 4242), parsePid("4242\n").?);
    try testing.expect(parsePid("") == null);
    try testing.expect(parsePid("0") == null);
    try testing.expect(parsePid("steam") == null);
}

test "only Steam's own process names count as Steam" {
    try testing.expect(isSteamComm("steam\n"));
    try testing.expect(!isSteamComm("bash\n"));
    try testing.expect(!isSteamComm("steamy"));
}
