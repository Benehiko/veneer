const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vdf = @import("../library/vdf.zig");
const steam = @import("../library/steam.zig");

pub const poll_s = 2;
pub const start_grace_s = 300;

pub const Phase = enum { queued, downloading, paused, finishing, installed };

pub const Progress = struct {
    phase: Phase,
    done_bytes: u64 = 0,
    total_bytes: u64 = 0,

    pub fn percent(p: Progress) ?u8 {
        if (p.total_bytes == 0) return null;
        return @intCast(@min(100, p.done_bytes * 100 / p.total_bytes));
    }
};

pub fn describe(buf: []u8, p: Progress) []const u8 {
    const text = switch (p.phase) {
        .queued => std.fmt.bufPrint(buf, "queued in Steam", .{}),
        .paused => std.fmt.bufPrint(buf, "paused in Steam; resume it on Steam's Downloads page", .{}),
        .installed => std.fmt.bufPrint(buf, "installed", .{}),
        .downloading, .finishing => |phase| blk: {
            const verb = if (phase == .downloading) "downloading" else "installing";
            break :blk if (p.percent()) |pct| std.fmt.bufPrint(buf, "{s} {d}%", .{ verb, pct }) else std.fmt.bufPrint(buf, "{s}", .{verb});
        },
    };
    return text catch "";
}

pub const AppState = struct {
    pub const update_required: u32 = 1 << 1;
    pub const fully_installed: u32 = 1 << 2;
    pub const update_running: u32 = 1 << 8;
    pub const update_paused: u32 = 1 << 9;
    pub const update_started: u32 = 1 << 10;
    pub const busy = update_required | update_running | update_paused | update_started;
};

fn number(o: vdf.Object, key: []const u8) u64 {
    return std.fmt.parseInt(u64, o.string(key) orelse return 0, 10) catch 0;
}

pub fn parse(arena: Allocator, text: []const u8) vdf.ParseError!?Progress {
    const doc = try vdf.parse(arena, text);
    const state = doc.object("AppState") orelse return null;
    const flags: u32 = std.fmt.parseInt(u32, state.string("StateFlags") orelse "0", 10) catch 0;
    const to_download = number(state, "BytesToDownload");
    const downloaded = number(state, "BytesDownloaded");
    const to_stage = number(state, "BytesToStage");
    const staged = number(state, "BytesStaged");

    if (flags & AppState.fully_installed != 0 and flags & AppState.busy == 0) {
        return .{ .phase = .installed, .done_bytes = to_download, .total_bytes = to_download };
    }
    if (flags & AppState.update_paused != 0) {
        return .{ .phase = .paused, .done_bytes = downloaded, .total_bytes = to_download };
    }
    if (to_download > 0 and downloaded < to_download) {
        return .{ .phase = .downloading, .done_bytes = downloaded, .total_bytes = to_download };
    }
    if (to_download > 0 or to_stage > 0) {
        return .{ .phase = .finishing, .done_bytes = staged, .total_bytes = to_stage };
    }
    return .{ .phase = .queued };
}

pub fn poll(arena: Allocator, io: Io, locations: []const steam.Location, app_id: []const u8) ?Progress {
    const name = std.fmt.allocPrint(arena, "appmanifest_{s}.acf", .{app_id}) catch return null;
    for (locations) |loc| {
        for (loc.libraries) |lib| {
            const path = std.fs.path.join(arena, &.{ lib, "steamapps", name }) catch return null;
            const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
            if (parse(arena, text) catch null) |p| return p;
        }
    }
    return null;
}

pub const Outcome = enum { installed, never_started, stopped };

pub fn follow(gpa: Allocator, io: Io, home: []const u8, app_id: []const u8, ctx: anytype, comptime report: fn (@TypeOf(ctx), ?Progress) bool) !Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var waited: u64 = 0;
    var seen = false;
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        const locations = steam.locate(a, io, home) catch &.{};
        const now = poll(a, io, locations, app_id);
        if (now != null) seen = true;
        if (!report(ctx, now)) return .stopped;
        if (now) |p| {
            if (p.phase == .installed) return .installed;
        }
        if (!seen and waited >= start_grace_s) return .never_started;
        try io.sleep(.fromSeconds(poll_s), .awake);
        waited += poll_s;
    }
}

const testing = std.testing;

fn progressOf(text: []const u8) !Progress {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return (try parse(arena.allocator(), text)).?;
}

test "a manifest mid-download reports the bytes fetched so far" {
    const p = try progressOf(
        \\"AppState" { "appid" "1493710" "StateFlags" "1026" "BytesToDownload" "400" "BytesDownloaded" "100" }
    );
    try testing.expectEqual(Phase.downloading, p.phase);
    try testing.expectEqual(@as(u8, 25), p.percent().?);
}

test "staging after the download counts as finishing; the installed bit alone means done" {
    const staging = try progressOf(
        \\"AppState" { "StateFlags" "1026" "BytesToDownload" "400" "BytesDownloaded" "400" "BytesToStage" "800" "BytesStaged" "200" }
    );
    try testing.expectEqual(Phase.finishing, staging.phase);
    try testing.expectEqual(@as(u8, 25), staging.percent().?);
    const done = try progressOf(
        \\"AppState" { "StateFlags" "4" "BytesToDownload" "400" "BytesDownloaded" "400" }
    );
    try testing.expectEqual(Phase.installed, done.phase);
    const updating = try progressOf(
        \\"AppState" { "StateFlags" "6" "BytesToDownload" "0" }
    );
    try testing.expectEqual(Phase.queued, updating.phase);
    try testing.expect(updating.percent() == null);
}

test "a paused update reads as paused, whatever its bytes" {
    const p = try progressOf(
        \\"AppState" { "StateFlags" "1538" "BytesToDownload" "400" "BytesDownloaded" "100" }
    );
    try testing.expectEqual(Phase.paused, p.phase);
}

test "the manifest is found in whichever library Steam chose" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(testing.io, "second/steamapps");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "second/steamapps/appmanifest_1493710.acf", .data =
        \\"AppState" { "StateFlags" "1026" "BytesToDownload" "10" "BytesDownloaded" "5" }
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const locations = [_]steam.Location{.{
        .root = root,
        .libraries = &.{ try std.fs.path.join(a, &.{ root, "first" }), try std.fs.path.join(a, &.{ root, "second" }) },
    }};
    try testing.expectEqual(Phase.downloading, poll(a, testing.io, &locations, "1493710").?.phase);
    try testing.expect(poll(a, testing.io, &locations, "1") == null);
}
