const std = @import("std");
const Io = std.Io;

pub const capacity = 32;
pub const text_len = 160;

pub const Step = enum {
    queued,
    scanning,
    waiting_for_steam,
    downloading,
    verifying,
    unpacking,
    installing,
    launching,
    running,
    done,
    failed,

    pub fn label(s: Step) []const u8 {
        return switch (s) {
            .queued => "Queued",
            .scanning => "Scanning",
            .waiting_for_steam => "Waiting for Steam",
            .downloading => "Downloading",
            .verifying => "Verifying",
            .unpacking => "Unpacking",
            .installing => "Installing",
            .launching => "Starting",
            .running => "Running",
            .done => "Done",
            .failed => "Failed",
        };
    }

    pub fn finished(s: Step) bool {
        return s == .done or s == .failed;
    }
};

pub const View = struct {
    id: u32 = 0,
    title_buf: [text_len]u8 = undefined,
    title_len: usize = 0,
    detail_buf: [text_len]u8 = undefined,
    detail_len: usize = 0,
    step: Step = .queued,
    done_units: u64 = 0,
    total_units: u64 = 0,

    pub fn title(v: *const View) []const u8 {
        return v.title_buf[0..v.title_len];
    }

    pub fn detail(v: *const View) []const u8 {
        return v.detail_buf[0..v.detail_len];
    }

    pub fn fraction(v: View) ?f32 {
        if (v.step == .done) return 1;
        if (v.total_units == 0) return null;
        const f = @as(f64, @floatFromInt(v.done_units)) / @as(f64, @floatFromInt(v.total_units));
        return @floatCast(@min(1.0, f));
    }

    fn permille(v: View) ?u32 {
        const f = v.fraction() orelse return null;
        return @intFromFloat(f * 1000);
    }
};

fn copyInto(buf: *[text_len]u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, text_len);
    @memcpy(buf[0..n], text[0..n]);
    len.* = n;
}

pub const Notify = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (?*anyopaque) void = null,

    fn call(n: Notify) void {
        if (n.func) |f| f(n.ctx);
    }
};

pub const Board = struct {
    io: Io,
    notify: Notify = .{},
    mutex: Io.Mutex = .init,
    slots: [capacity]View = @splat(.{}),
    used: [capacity]bool = @splat(false),
    next_id: u32 = 1,

    pub fn start(b: *Board, first: Step, title: []const u8) ?Job {
        const id = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const slot = b.freeSlot() orelse return null;
            const id = b.next_id;
            b.next_id +%= 1;
            if (b.next_id == 0) b.next_id = 1;
            b.slots[slot] = .{ .id = id, .step = first };
            copyInto(&b.slots[slot].title_buf, &b.slots[slot].title_len, title);
            b.used[slot] = true;
            break :blk id;
        };
        b.notify.call();
        return .{ .board = b, .id = id };
    }

    fn freeSlot(b: *Board) ?usize {
        for (b.used, 0..) |u, i| {
            if (!u) return i;
        }
        var oldest: ?usize = null;
        for (b.slots, 0..) |s, i| {
            if (!s.step.finished()) continue;
            if (oldest == null or s.id < b.slots[oldest.?].id) oldest = i;
        }
        return oldest;
    }

    fn find(b: *Board, id: u32) ?*View {
        for (&b.slots, b.used) |*s, u| {
            if (u and s.id == id) return s;
        }
        return null;
    }

    fn update(b: *Board, id: u32, comptime always_notify: bool, change: anytype) void {
        const changed = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            const v = b.find(id) orelse return;
            const before = v.*;
            change.apply(v);
            break :blk always_notify or before.step != v.step or before.permille() != v.permille();
        };
        if (changed) b.notify.call();
    }

    pub fn snapshot(b: *Board, out: []View) []View {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var n: usize = 0;
        for (b.slots, b.used) |s, u| {
            if (!u or n == out.len) continue;
            out[n] = s;
            n += 1;
        }
        std.mem.sort(View, out[0..n], {}, newestFirst);
        return out[0..n];
    }

    pub fn view(b: *Board, id: u32) ?View {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const v = b.find(id) orelse return null;
        return v.*;
    }

    pub fn running(b: *Board) usize {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var n: usize = 0;
        for (b.slots, b.used) |s, u| {
            if (u and !s.step.finished()) n += 1;
        }
        return n;
    }

    pub fn clearFinished(b: *Board) void {
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            for (b.slots, &b.used) |s, *u| {
                if (u.* and s.step.finished()) u.* = false;
            }
        }
        b.notify.call();
    }
};

fn newestFirst(_: void, a: View, b: View) bool {
    const a_live = !a.step.finished();
    const b_live = !b.step.finished();
    if (a_live != b_live) return a_live;
    return a.id > b.id;
}

pub const Job = struct {
    board: *Board,
    id: u32,

    pub fn title(j: Job, text: []const u8) void {
        j.board.update(j.id, true, struct {
            t: []const u8,
            fn apply(c: @This(), v: *View) void {
                copyInto(&v.title_buf, &v.title_len, c.t);
            }
        }{ .t = text });
    }

    pub fn step(j: Job, s: Step, detail_text: []const u8) void {
        j.board.update(j.id, true, struct {
            s: Step,
            d: []const u8,
            fn apply(c: @This(), v: *View) void {
                v.step = c.s;
                v.done_units = 0;
                v.total_units = 0;
                copyInto(&v.detail_buf, &v.detail_len, c.d);
            }
        }{ .s = s, .d = detail_text });
    }

    pub fn total(j: Job, units: u64) void {
        j.board.update(j.id, false, struct {
            n: u64,
            fn apply(c: @This(), v: *View) void {
                v.total_units = c.n;
            }
        }{ .n = units });
    }

    pub fn progress(j: Job, done_units: u64, total_units: u64) void {
        j.board.update(j.id, false, struct {
            d: u64,
            t: u64,
            fn apply(c: @This(), v: *View) void {
                v.done_units = c.d;
                v.total_units = c.t;
            }
        }{ .d = done_units, .t = total_units });
    }

    pub fn advance(j: Job, units: u64) void {
        j.board.update(j.id, false, struct {
            n: u64,
            fn apply(c: @This(), v: *View) void {
                v.done_units += c.n;
            }
        }{ .n = units });
    }

    pub fn finish(j: Job, detail_text: []const u8) void {
        j.step(.done, detail_text);
    }

    pub fn fail(j: Job, detail_text: []const u8) void {
        j.step(.failed, detail_text);
    }
};

pub fn step(job: ?Job, s: Step, detail_text: []const u8) void {
    if (job) |j| j.step(s, detail_text);
}

pub fn advance(job: ?Job, units: u64) void {
    if (job) |j| j.advance(units);
}

pub fn progress(job: ?Job, done_units: u64, total_units: u64) void {
    if (job) |j| j.progress(done_units, total_units);
}

pub fn total(job: ?Job, units: u64) void {
    if (job) |j| j.total(units);
}

const testing = std.testing;

const Counter = struct {
    n: usize = 0,
    fn bump(ctx: ?*anyopaque) void {
        const c: *Counter = @ptrCast(@alignCast(ctx.?));
        c.n += 1;
    }
};

test "a job reports its step and fraction, and the board lists running jobs first, newest first" {
    var board: Board = .{ .io = testing.io };
    const a = board.start(.downloading, "GE-Proton").?;
    const b = board.start(.scanning, "Library").?;
    a.total(200);
    a.advance(50);
    b.finish("12 games");

    var buf: [capacity]View = undefined;
    const views = board.snapshot(&buf);
    try testing.expectEqual(@as(usize, 2), views.len);
    try testing.expectEqualStrings("GE-Proton", views[0].title());
    try testing.expectEqual(@as(f32, 0.25), views[0].fraction().?);
    try testing.expectEqual(Step.done, views[1].step);
    try testing.expectEqual(@as(f32, 1), views[1].fraction().?);
    try testing.expectEqual(@as(usize, 1), board.running());

    a.step(.unpacking, "");
    try testing.expect(board.snapshot(&buf)[0].fraction() == null);
}

test "progress wakes the window only when the step or the tenth of a percent changes" {
    var counter: Counter = .{};
    var board: Board = .{ .io = testing.io, .notify = .{ .ctx = &counter, .func = Counter.bump } };
    const j = board.start(.downloading, "x").?;
    j.total(1_000_000);
    const after_start = counter.n;
    j.advance(10);
    j.advance(10);
    try testing.expectEqual(after_start, counter.n);
    j.advance(1000);
    try testing.expectEqual(after_start + 1, counter.n);
    j.step(.unpacking, "");
    try testing.expectEqual(after_start + 2, counter.n);
}

test "a full board makes room by dropping the oldest finished job, never a running one" {
    var board: Board = .{ .io = testing.io };
    var first: ?Job = null;
    for (0..capacity) |i| {
        const j = board.start(.downloading, "x").?;
        if (i == 0) first = j;
    }
    try testing.expect(board.start(.downloading, "y") == null);
    first.?.finish("");
    const later = board.start(.downloading, "z").?;
    first.?.advance(5);
    var buf: [capacity]View = undefined;
    for (board.snapshot(&buf)) |v| try testing.expect(v.id != first.?.id);
    try testing.expect(later.id != first.?.id);
    board.clearFinished();
    try testing.expectEqual(@as(usize, capacity), board.snapshot(&buf).len);
}

test "a job's view follows its steps until it is cleared" {
    var board: Board = .{ .io = testing.io };
    const j = board.start(.launching, "Game").?;
    try testing.expectEqual(Step.launching, board.view(j.id).?.step);
    j.fail("exited with code 1");
    const v = board.view(j.id).?;
    try testing.expectEqual(Step.failed, v.step);
    try testing.expectEqualStrings("exited with code 1", v.detail());
    board.clearFinished();
    try testing.expect(board.view(j.id) == null);
}

test "long titles are cut to fit" {
    var board: Board = .{ .io = testing.io };
    const long: [text_len + 20]u8 = @splat('x');
    _ = board.start(.queued, &long).?;
    var buf: [capacity]View = undefined;
    try testing.expectEqual(@as(usize, text_len), board.snapshot(&buf)[0].title().len);
}
