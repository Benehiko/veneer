const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const env_name = "VENEER_GAME";

const grace_polls = 30;
const poll_ms = 100;

pub const Match = struct {
    game_id: ?[]const u8 = null,
    upper: ?[]const u8 = null,
};

pub fn tagged(environ: []const u8, game_id: []const u8) bool {
    var it = std.mem.splitScalar(u8, environ, 0);
    while (it.next()) |entry| {
        if (entry.len != env_name.len + 1 + game_id.len) continue;
        if (!std.mem.startsWith(u8, entry, env_name) or entry[env_name.len] != '=') continue;
        if (std.mem.eql(u8, entry[env_name.len + 1 ..], game_id)) return true;
    }
    return false;
}

pub fn escapeMountPath(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path) |c| switch (c) {
        ' ', '\t', '\n', '\\' => try out.print(arena, "\\{o:0>3}", .{c}),
        else => try out.append(arena, c),
    };
    return out.items;
}

pub fn holdsUpper(mountinfo: []const u8, escaped_upper: []const u8) bool {
    const key = "upperdir=";
    var rest = mountinfo;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        const value = rest[at + key.len ..];
        if (std.mem.startsWith(u8, value, escaped_upper)) {
            const after = value[escaped_upper.len..];
            if (after.len == 0 or after[0] == ',' or after[0] == ' ' or after[0] == '\n') return true;
        }
        rest = value;
    }
    return false;
}

fn matches(proc: Io.Dir, io: Io, buf: []u8, pid: linux.pid_t, m: Match) bool {
    var path_buf: [64]u8 = undefined;
    if (m.game_id) |id| {
        const path = std.fmt.bufPrint(&path_buf, "{d}/environ", .{pid}) catch return false;
        if (proc.readFile(io, path, buf)) |environ| {
            if (tagged(environ, id)) return true;
        } else |_| {}
    }
    if (m.upper) |upper| {
        const path = std.fmt.bufPrint(&path_buf, "{d}/mountinfo", .{pid}) catch return false;
        if (proc.readFile(io, path, buf)) |info| {
            if (holdsUpper(info, upper)) return true;
        } else |_| {}
    }
    return false;
}

pub fn find(arena: Allocator, io: Io, buf: []u8, m: Match) Allocator.Error![]const linux.pid_t {
    var proc = Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return &.{};
    defer proc.close(io);
    const self = linux.getpid();
    var found: std.ArrayList(linux.pid_t) = .empty;
    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(linux.pid_t, entry.name, 10) catch continue;
        if (pid == self) continue;
        if (matches(proc, io, buf, pid, m)) try found.append(arena, pid);
    }
    return found.items;
}

pub fn match(arena: Allocator, game_id: []const u8, upper: ?[]const u8) Allocator.Error!Match {
    return .{ .game_id = game_id, .upper = if (upper) |u| try escapeMountPath(arena, u) else null };
}

pub fn holders(arena: Allocator, io: Io, upper: []const u8) ![]const linux.pid_t {
    const buf = try arena.alloc(u8, 1 << 20);
    return find(arena, io, buf, .{ .upper = try escapeMountPath(arena, upper) });
}

pub fn stop(arena: Allocator, io: Io, m: Match) !usize {
    const buf = try arena.alloc(u8, 1 << 20);
    const pids = try find(arena, io, buf, m);
    if (pids.len == 0) return 0;
    for (pids) |pid| _ = linux.kill(pid, .TERM);
    var polls: usize = 0;
    while (polls < grace_polls) : (polls += 1) {
        try io.sleep(.fromMilliseconds(poll_ms), .awake);
        if ((try find(arena, io, buf, m)).len == 0) return pids.len;
    }
    for (try find(arena, io, buf, m)) |pid| _ = linux.kill(pid, .KILL);
    return pids.len;
}

const testing = std.testing;

test "a process belongs to the game whose id its environment carries, exactly" {
    const environ = "HOME=/home/p\x00VENEER_GAME=steam:1620730\x00WINEDLLOVERRIDES=dxgi=n,b\x00";
    try testing.expect(tagged(environ, "steam:1620730"));
    try testing.expect(!tagged(environ, "steam:162073"));
    try testing.expect(!tagged(environ, "steam:16207301"));
    try testing.expect(!tagged("HOME=/home/p\x00", "steam:1620730"));
    try testing.expect(!tagged("XVENEER_GAME=steam:1\x00", "steam:1"));
}

test "a process holds the overlay whose upper layer its mount table names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const upper = try escapeMountPath(a, "/home/my name/.local/share/veneer/overlay/steam-1/upper");
    try testing.expectEqualStrings("/home/my\\040name/.local/share/veneer/overlay/steam-1/upper", upper);

    const info =
        "22 1 0:21 / / rw - ext4 /dev/nvme0n1p2 rw\n" ++
        "530 22 0:60 / /games/Hell\\040Is\\040Us rw - overlay overlay rw,lowerdir=/games/Hell\\040Is\\040Us,upperdir=/home/my\\040name/.local/share/veneer/overlay/steam-1/upper,workdir=/home/my\\040name/.local/share/veneer/overlay/steam-1/work,userxattr\n";
    try testing.expect(holdsUpper(info, upper));
    try testing.expect(!holdsUpper(info, try escapeMountPath(a, "/home/my name/.local/share/veneer/overlay/steam-")));
    try testing.expect(!holdsUpper("22 1 0:21 / / rw - ext4 /dev/nvme0n1p2 rw\n", upper));
}
