const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const program = "gamescope";

pub const Filter = enum { linear, fsr, nis };

pub const Mode = struct {
    width: u32,
    height: u32,
};

pub const Options = struct {
    output: ?Mode = null,
    refresh: ?u32 = null,
    render_scale: u8 = 100,
    filter: Filter = .linear,
    fullscreen: bool = true,
    hdr: bool = false,
    extra: []const []const u8 = &.{},
};

pub const Caps = struct {
    present: bool = false,
    filter_flag: bool = false,
    hdr: bool = false,
};

pub const scales = [_]u8{ 100, 77, 67, 59, 50 };

pub fn renderMode(output: Mode, scale: u8) Mode {
    const s: u32 = @min(@max(scale, 25), 100);
    return .{
        .width = @max(1, (output.width * s + 50) / 100),
        .height = @max(1, (output.height * s + 50) / 100),
    };
}

pub fn argv(arena: Allocator, opts: Options, caps: Caps) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, program);
    if (opts.output) |o| {
        try out.appendSlice(arena, &.{ "-W", try num(arena, o.width), "-H", try num(arena, o.height) });
        const r = renderMode(o, opts.render_scale);
        try out.appendSlice(arena, &.{ "-w", try num(arena, r.width), "-h", try num(arena, r.height) });
    }
    if (opts.refresh) |hz| try out.appendSlice(arena, &.{ "-r", try num(arena, hz) });
    if (opts.fullscreen) try out.append(arena, "-f");
    if (opts.filter != .linear) {
        if (caps.filter_flag) {
            try out.appendSlice(arena, &.{ "-F", @tagName(opts.filter) });
        } else {
            try out.append(arena, if (opts.filter == .fsr) "-U" else "-Y");
        }
    }
    if (opts.hdr and caps.hdr) try out.append(arena, "--hdr-enabled");
    try out.appendSlice(arena, opts.extra);
    try out.append(arena, "--");
    return out.items;
}

fn num(arena: Allocator, v: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{v});
}

pub fn capsFromHelp(help: []const u8) Caps {
    return .{
        .present = true,
        .filter_flag = std.mem.indexOf(u8, help, "--filter") != null,
        .hdr = std.mem.indexOf(u8, help, "--hdr-enabled") != null,
    };
}

pub fn probe(gpa: Allocator, io: Io) Caps {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ program, "--help" },
        .stdout_limit = .limited(256 << 10),
        .stderr_limit = .limited(256 << 10),
    }) catch return .{};
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var caps = capsFromHelp(result.stdout);
    const from_stderr = capsFromHelp(result.stderr);
    caps.filter_flag = caps.filter_flag or from_stderr.filter_flag;
    caps.hdr = caps.hdr or from_stderr.hdr;
    return caps;
}

const testing = std.testing;

test "render size scales the output size and rounds to the nearest pixel" {
    const out: Mode = .{ .width = 2560, .height = 1440 };
    try testing.expectEqual(Mode{ .width = 2560, .height = 1440 }, renderMode(out, 100));
    try testing.expectEqual(Mode{ .width = 1971, .height = 1109 }, renderMode(out, 77));
    try testing.expectEqual(Mode{ .width = 1280, .height = 720 }, renderMode(out, 50));
    try testing.expectEqual(Mode{ .width = 2560, .height = 1440 }, renderMode(out, 200));
}

test "argv names output and render size, the filter, and ends with --" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = try argv(arena.allocator(), .{
        .output = .{ .width = 3840, .height = 2160 },
        .refresh = 120,
        .render_scale = 50,
        .filter = .fsr,
        .hdr = true,
        .extra = &.{"--mangoapp"},
    }, .{ .present = true, .filter_flag = true, .hdr = true });
    const want = [_][]const u8{ "gamescope", "-W", "3840", "-H", "2160", "-w", "1920", "-h", "1080", "-r", "120", "-f", "-F", "fsr", "--hdr-enabled", "--mangoapp", "--" };
    try testing.expectEqual(want.len, a.len);
    for (want, a) |w, got| try testing.expectEqualStrings(w, got);
}

test "an older gamescope gets its old upscaler flags, and HDR only when supported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const old: Caps = .{ .present = true };
    const fsr = try argv(arena.allocator(), .{ .filter = .fsr, .hdr = true, .fullscreen = false }, old);
    try testing.expectEqualStrings("-U", fsr[1]);
    try testing.expectEqual(@as(usize, 3), fsr.len);
    const nis = try argv(arena.allocator(), .{ .filter = .nis, .fullscreen = false }, old);
    try testing.expectEqualStrings("-Y", nis[1]);
}

test "capabilities come from the help text" {
    const caps = capsFromHelp("  -F, --filter  upscaler filter\n  --hdr-enabled  enable HDR\n");
    try testing.expect(caps.present and caps.filter_flag and caps.hdr);
    const old = capsFromHelp("  -U, --fsr-upscaling\n");
    try testing.expect(old.present and !old.filter_flag and !old.hdr);
}
