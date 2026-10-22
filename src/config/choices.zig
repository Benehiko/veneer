const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Display = enum { normal, gamescope };

pub const Upscaling = enum { off, fsr, nis, optiscaler };

pub const Choices = struct {
    runner: []const u8 = "auto",
    display: Display = .normal,
    upscaling: Upscaling = .off,
    render_scale: u8 = 77,
    hdr: bool = false,
    env: []const []const u8 = &.{},
    args: []const u8 = "",
    gamescope_args: []const u8 = "",

    pub fn usesGamescope(self: Choices) bool {
        return self.display == .gamescope or self.upscaling == .fsr or self.upscaling == .nis;
    }
};

pub const setting_keys = [_][]const u8{ "runner", "display", "upscaling", "scale", "hdr", "env", "args", "gamescope-args" };

pub fn apply(arena: Allocator, c: Choices, assignment: []const u8) !Choices {
    const eq = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.NotAnAssignment;
    const key = assignment[0..eq];
    const value = assignment[eq + 1 ..];
    var out = c;
    if (std.mem.eql(u8, key, "runner")) {
        out.runner = if (value.len == 0) "auto" else value;
    } else if (std.mem.eql(u8, key, "display")) {
        out.display = std.meta.stringToEnum(Display, value) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "upscaling")) {
        out.upscaling = std.meta.stringToEnum(Upscaling, value) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "scale")) {
        const pct = std.fmt.parseInt(u8, std.mem.trimEnd(u8, value, "%"), 10) catch return error.BadValue;
        if (pct < 25 or pct > 100) return error.BadValue;
        out.render_scale = pct;
    } else if (std.mem.eql(u8, key, "hdr")) {
        out.hdr = parseBool(value) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "env")) {
        if (value.len == 0) {
            out.env = &.{};
        } else {
            const name_end = std.mem.indexOfScalar(u8, value, '=') orelse return error.BadValue;
            if (name_end == 0) return error.BadValue;
            var list: std.ArrayList([]const u8) = .empty;
            for (c.env) |e| {
                if (!std.mem.startsWith(u8, e, value[0 .. name_end + 1])) try list.append(arena, e);
            }
            try list.append(arena, value);
            out.env = list.items;
        }
    } else if (std.mem.eql(u8, key, "args")) {
        out.args = value;
    } else if (std.mem.eql(u8, key, "gamescope-args")) {
        out.gamescope_args = value;
    } else return error.UnknownSetting;
    return out;
}

fn parseBool(v: []const u8) ?bool {
    for ([_][]const u8{ "on", "true", "yes", "1" }) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    for ([_][]const u8{ "off", "false", "no", "0" }) |f| if (std.ascii.eqlIgnoreCase(v, f)) return false;
    return null;
}

pub fn slug(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, id);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_' and c.* != '.') c.* = '-';
    }
    return out;
}

pub fn path(arena: Allocator, config_dir: []const u8, id: []const u8) Allocator.Error![]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}.zon", .{try slug(arena, id)});
    return std.fs.path.join(arena, &.{ config_dir, "games", name });
}

pub fn load(arena: Allocator, io: Io, config_dir: []const u8, id: []const u8) !Choices {
    const file = try path(arena, config_dir, id);
    const text = Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, text);
}

pub fn parse(arena: Allocator, text: []const u8) !Choices {
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Choices, .{
        .gpa = arena,
        .arena = arena,
        .source = try arena.dupeSentinel(u8, text, 0),
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.BadGameSettings,
    };
}

pub fn save(gpa: Allocator, io: Io, config_dir: []const u8, id: []const u8, choices: Choices) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(choices, .{ .emit_default_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');

    const file = try path(arena, config_dir, id);
    const dir_path = std.fs.path.dirname(file).?;
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const base = std.fs.path.basename(file);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{base});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = out.written() });
    try Io.Dir.rename(dir, tmp, dir, base, io);
}

const testing = std.testing;

test "choices survive a save and load, and an absent file means defaults" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    const fresh = try load(a, testing.io, dir, "steam:1");
    try testing.expectEqual(Display.normal, fresh.display);
    try testing.expectEqualStrings("auto", fresh.runner);

    try save(testing.allocator, testing.io, dir, "steam:1", .{
        .display = .gamescope,
        .upscaling = .fsr,
        .render_scale = 67,
        .env = &.{"DXVK_HUD=fps"},
    });
    const back = try load(a, testing.io, dir, "steam:1");
    try testing.expectEqual(Upscaling.fsr, back.upscaling);
    try testing.expectEqual(@as(u8, 67), back.render_scale);
    try testing.expectEqualStrings("DXVK_HUD=fps", back.env[0]);
    try testing.expectEqualStrings("auto", back.runner);
}

test "settings apply one assignment at a time and reject bad values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Choices = .{};
    c = try apply(a, c, "display=gamescope");
    c = try apply(a, c, "upscaling=fsr");
    c = try apply(a, c, "scale=67%");
    c = try apply(a, c, "hdr=on");
    c = try apply(a, c, "runner=GE-Proton9-20");
    try testing.expectEqual(Display.gamescope, c.display);
    try testing.expectEqual(Upscaling.fsr, c.upscaling);
    try testing.expectEqual(@as(u8, 67), c.render_scale);
    try testing.expect(c.hdr);
    try testing.expectEqualStrings("GE-Proton9-20", c.runner);
    try testing.expectEqualStrings("auto", (try apply(a, c, "runner=")).runner);

    try testing.expectError(error.BadValue, apply(a, c, "display=huge"));
    try testing.expectError(error.BadValue, apply(a, c, "scale=10"));
    try testing.expectError(error.BadValue, apply(a, c, "hdr=maybe"));
    try testing.expectError(error.UnknownSetting, apply(a, c, "colour=red"));
    try testing.expectError(error.NotAnAssignment, apply(a, c, "display"));
}

test "env settings replace a variable of the same name, and env= clears them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Choices = .{};
    c = try apply(a, c, "env=DXVK_HUD=fps");
    c = try apply(a, c, "env=PROTON_LOG=1");
    c = try apply(a, c, "env=DXVK_HUD=full");
    try testing.expectEqual(@as(usize, 2), c.env.len);
    try testing.expectEqualStrings("PROTON_LOG=1", c.env[0]);
    try testing.expectEqualStrings("DXVK_HUD=full", c.env[1]);
    try testing.expectEqual(@as(usize, 0), (try apply(a, c, "env=")).env.len);
    try testing.expectError(error.BadValue, apply(a, c, "env=NOVALUE"));
}

test "gamescope upscaling implies the gamescope display" {
    try testing.expect((Choices{ .upscaling = .fsr }).usesGamescope());
    try testing.expect((Choices{ .display = .gamescope }).usesGamescope());
    try testing.expect(!(Choices{ .upscaling = .optiscaler }).usesGamescope());
}

test "slugs keep ids readable and safe as file names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("steam-1245620", try slug(arena.allocator(), "steam:1245620"));
    try testing.expectEqualStrings("a-b-c", try slug(arena.allocator(), "a/b c"));
}
