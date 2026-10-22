const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const plan = @import("plan.zig");

pub fn environment(gpa: Allocator, parent: *const Environ.Map, p: plan.Plan) !Environ.Map {
    var env = Environ.Map.init(gpa);
    errdefer env.deinit();
    var it = parent.iterator();
    while (it.next()) |entry| try env.put(entry.key_ptr.*, entry.value_ptr.*);
    for (p.env) |v| try env.put(v.name, v.value);
    return env;
}

pub fn run(gpa: Allocator, io: Io, parent: *const Environ.Map, p: plan.Plan, log_path: []const u8) !std.process.Child.Term {
    var env = try environment(gpa, parent, p);
    defer env.deinit();

    const log_dir = std.fs.path.dirname(log_path) orelse ".";
    try Io.Dir.cwd().createDirPath(io, log_dir);
    var prev_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prev = try std.fmt.bufPrint(&prev_buf, "{s}.prev", .{log_path});
    Io.Dir.rename(Io.Dir.cwd(), log_path, Io.Dir.cwd(), prev, io) catch {};

    const log = try Io.Dir.cwd().createFile(io, log_path, .{});
    defer log.close(io);
    {
        var buf: [4096]u8 = undefined;
        var w = log.writerStreaming(io, &buf);
        try w.interface.writeAll("# veneer launch\n");
        try plan.writeShell(&w.interface, p);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    var child = try std.process.spawn(io, .{
        .argv = p.argv,
        .environ_map = &env,
        .cwd = .{ .path = p.cwd },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    return child.wait(io);
}

const testing = std.testing;

test "the child environment is the parent's with the plan's variables on top" {
    var parent = Environ.Map.init(testing.allocator);
    defer parent.deinit();
    try parent.put("HOME", "/home/p");
    try parent.put("WINEPREFIX", "/old");

    var env = try environment(testing.allocator, &parent, .{
        .argv = &.{"x"},
        .cwd = "/",
        .env = &.{.{ .name = "WINEPREFIX", .value = "/new" }},
    });
    defer env.deinit();
    try testing.expectEqualStrings("/home/p", env.get("HOME").?);
    try testing.expectEqualStrings("/new", env.get("WINEPREFIX").?);
}
