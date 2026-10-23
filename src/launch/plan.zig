const std = @import("std");
const Allocator = std.mem.Allocator;
const overlay = @import("../hooks/overlay.zig");
const inject_env = @import("../inject/env.zig");

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Proton = struct {
    script: []const u8,
    compat_data: []const u8,
    steam_root: []const u8,
    install_path: ?[]const u8 = null,
    library: ?[]const u8 = null,
    shader_cache: ?[]const u8 = null,
    runtime: ?Runtime = null,
};

pub const Runtime = struct {
    dir: []const u8,
    argv: []const []const u8,
};

pub const Wine = struct {
    binary: []const u8,
    prefix: []const u8,
};

pub const Native = struct {
    runtime: ?[]const u8 = null,
};

pub const Runner = union(enum) {
    native: Native,
    proton: Proton,
    wine: Wine,
};

pub const Inject = struct {
    injector: []const u8,
    dlls: []const []const u8,
};

pub const Overlay = struct {
    veneer: []const u8,
    lower: []const u8,
    upper: []const u8,
    work: []const u8,
};

pub const Input = struct {
    exe: []const u8,
    args: []const []const u8 = &.{},
    workdir: []const u8,
    app_id: ?[]const u8 = null,
    runner: Runner,
    wrappers: []const []const u8 = &.{},
    inject: ?Inject = null,
    overlay: ?Overlay = null,
    env: []const EnvVar = &.{},
};

pub const BuildError = Allocator.Error || error{InjectNeedsWine};

pub const Plan = struct {
    argv: []const []const u8,
    env: []const EnvVar,
    cwd: []const u8,
};

pub const proton_verb = "waitforexitandrun";

pub fn build(arena: Allocator, in: Input) BuildError!Plan {
    var argv: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList(EnvVar) = .empty;

    try argv.appendSlice(arena, in.wrappers);
    if (in.overlay) |o| {
        try argv.appendSlice(arena, try overlay.wrapperArgv(arena, o.veneer, o.lower, o.upper, o.work, in.workdir));
    }
    switch (in.runner) {
        .native => |n| if (n.runtime) |rt| try argv.append(arena, rt),
        .proton => |p| {
            if (p.runtime) |rt| {
                try argv.appendSlice(arena, rt.argv);
                const tool_dir = std.fs.path.dirname(p.script) orelse p.script;
                try env.append(arena, .{ .name = "STEAM_COMPAT_TOOL_PATHS", .value = try std.fmt.allocPrint(arena, "{s}:{s}", .{ tool_dir, rt.dir }) });
            }
            try argv.appendSlice(arena, &.{ p.script, proton_verb });
            try env.append(arena, .{ .name = "STEAM_COMPAT_DATA_PATH", .value = p.compat_data });
            try env.append(arena, .{ .name = "STEAM_COMPAT_CLIENT_INSTALL_PATH", .value = p.steam_root });
            if (p.install_path) |v| try env.append(arena, .{ .name = "STEAM_COMPAT_INSTALL_PATH", .value = v });
            if (p.library) |v| try env.append(arena, .{ .name = "STEAM_COMPAT_LIBRARY_PATHS", .value = v });
            if (p.shader_cache) |v| {
                try env.append(arena, .{ .name = "STEAM_COMPAT_SHADER_PATH", .value = v });
                try env.append(arena, .{ .name = "STEAM_COMPAT_TRANSCODED_MEDIA_PATH", .value = v });
                try env.append(arena, .{ .name = "STEAM_COMPAT_MEDIA_PATH", .value = try std.fs.path.join(arena, &.{ v, "fozmediav1" }) });
            }
        },
        .wine => |w| {
            try argv.append(arena, w.binary);
            try env.append(arena, .{ .name = "WINEPREFIX", .value = w.prefix });
        },
    }
    if (in.inject) |inj| {
        if (in.runner == .native) return error.InjectNeedsWine;
        try argv.append(arena, inj.injector);
        try env.append(arena, .{ .name = inject_env.game_exe, .value = try winePath(arena, in.exe) });
        try env.append(arena, .{ .name = inject_env.game_args, .value = try windowsCommandLine(arena, in.args) });
        var dlls: std.ArrayList(u8) = .empty;
        for (inj.dlls, 0..) |dll, i| {
            if (i > 0) try dlls.append(arena, ';');
            try dlls.appendSlice(arena, try winePath(arena, dll));
        }
        try env.append(arena, .{ .name = inject_env.dlls, .value = dlls.items });
    } else {
        try argv.append(arena, in.exe);
        try argv.appendSlice(arena, in.args);
    }

    if (in.app_id) |id| {
        try env.append(arena, .{ .name = "SteamAppId", .value = id });
        try env.append(arena, .{ .name = "SteamGameId", .value = id });
        if (in.runner == .proton) try env.append(arena, .{ .name = "STEAM_COMPAT_APP_ID", .value = id });
    }
    for (in.env) |v| try setVar(arena, &env, v);

    return .{ .argv = argv.items, .env = env.items, .cwd = in.workdir };
}

fn setVar(arena: Allocator, env: *std.ArrayList(EnvVar), v: EnvVar) Allocator.Error!void {
    for (env.items) |*have| {
        if (std.mem.eql(u8, have.name, v.name)) {
            have.value = v.value;
            return;
        }
    }
    try env.append(arena, v);
}

pub fn splitArgs(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else if (c == '\\' and q == '"' and i + 1 < line.len and (line[i + 1] == '"' or line[i + 1] == '\\')) {
                i += 1;
                try word.append(arena, line[i]);
            } else try word.append(arena, c);
        } else if (c == '"' or c == '\'') {
            quote = c;
            in_word = true;
        } else if (std.ascii.isWhitespace(c)) {
            if (in_word) {
                try out.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            }
        } else {
            try word.append(arena, c);
            in_word = true;
        }
    }
    if (in_word) try out.append(arena, try word.toOwnedSlice(arena));
    return out.items;
}

pub fn winePath(arena: Allocator, unix_path: []const u8) Allocator.Error![]const u8 {
    const out = try std.fmt.allocPrint(arena, "Z:{s}", .{unix_path});
    std.mem.replaceScalar(u8, out[2..], '/', '\\');
    return out;
}

pub fn windowsCommandLine(arena: Allocator, args: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |arg, n| {
        if (n > 0) try out.append(arena, ' ');
        const plain = arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null;
        if (plain) {
            try out.appendSlice(arena, arg);
            continue;
        }
        try out.append(arena, '"');
        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
                continue;
            }
            const times: usize = if (c == '"') backslashes * 2 + 1 else backslashes;
            try out.appendNTimes(arena, '\\', times);
            backslashes = 0;
            try out.append(arena, c);
        }
        try out.appendNTimes(arena, '\\', backslashes * 2);
        try out.append(arena, '"');
    }
    return out.items;
}

pub fn parseEnvAssignment(text: []const u8) ?EnvVar {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    if (eq == 0) return null;
    return .{ .name = text[0..eq], .value = text[eq + 1 ..] };
}

pub fn writeShell(w: *std.Io.Writer, p: Plan) std.Io.Writer.Error!void {
    try w.writeAll("cd ");
    try shellQuote(w, p.cwd);
    try w.writeAll(" &&");
    for (p.env) |v| {
        try w.print(" {s}=", .{v.name});
        try shellQuote(w, v.value);
    }
    for (p.argv) |a| {
        try w.writeByte(' ');
        try shellQuote(w, a);
    }
    try w.writeByte('\n');
}

pub fn shellQuote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const safe = s.len > 0 and for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./:=,+@%", c) != null)) break false;
    } else true;
    if (safe) return w.writeAll(s);
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

const testing = std.testing;

fn envOf(p: Plan, name: []const u8) ?[]const u8 {
    for (p.env) |v| {
        if (std.mem.eql(u8, v.name, name)) return v.value;
    }
    return null;
}

test "a Proton plan runs wrappers, the script and verb, then the game and its args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{
        .exe = "/lib/common/G/g.exe",
        .args = &.{"-dx12"},
        .workdir = "/lib/common/G",
        .app_id = "42",
        .wrappers = &.{ "gamescope", "-f", "--" },
        .runner = .{ .proton = .{
            .script = "/steam/common/Proton 10.0/proton",
            .compat_data = "/lib/compatdata/42",
            .steam_root = "/steam",
            .install_path = "/lib/common/G",
            .library = "/lib",
            .shader_cache = "/lib/shadercache/42",
        } },
    });
    const want = [_][]const u8{ "gamescope", "-f", "--", "/steam/common/Proton 10.0/proton", proton_verb, "/lib/common/G/g.exe", "-dx12" };
    try testing.expectEqual(want.len, p.argv.len);
    for (want, p.argv) |w, a| try testing.expectEqualStrings(w, a);
    try testing.expectEqualStrings("/lib/compatdata/42", envOf(p, "STEAM_COMPAT_DATA_PATH").?);
    try testing.expectEqualStrings("42", envOf(p, "STEAM_COMPAT_APP_ID").?);
    try testing.expectEqualStrings("42", envOf(p, "SteamAppId").?);
    try testing.expectEqualStrings("/lib/shadercache/42", envOf(p, "STEAM_COMPAT_SHADER_PATH").?);
    try testing.expectEqualStrings("/lib/shadercache/42", envOf(p, "STEAM_COMPAT_TRANSCODED_MEDIA_PATH").?);
    try testing.expectEqualStrings("/lib/shadercache/42/fozmediav1", envOf(p, "STEAM_COMPAT_MEDIA_PATH").?);
}

test "Proton runs inside the Steam Linux Runtime when it needs one, which may reach Proton's directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{
        .exe = "/lib/common/G/g.exe",
        .workdir = "/lib/common/G",
        .wrappers = &.{ "gamescope", "--" },
        .runner = .{ .proton = .{
            .script = "/steam/common/Proton - Experimental/proton",
            .compat_data = "/lib/compatdata/42",
            .steam_root = "/steam",
            .runtime = .{ .dir = "/lib/common/SLR", .argv = &.{ "/lib/common/SLR/_v2-entry-point", "--verb=waitforexitandrun", "--" } },
        } },
    });
    const want = [_][]const u8{ "gamescope", "--", "/lib/common/SLR/_v2-entry-point", "--verb=waitforexitandrun", "--", "/steam/common/Proton - Experimental/proton", proton_verb, "/lib/common/G/g.exe" };
    try testing.expectEqual(want.len, p.argv.len);
    for (want, p.argv) |w, a| try testing.expectEqualStrings(w, a);
    try testing.expectEqualStrings("/steam/common/Proton - Experimental:/lib/common/SLR", envOf(p, "STEAM_COMPAT_TOOL_PATHS").?);
}

test "with injection the runner starts the injector, which learns the game from its environment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{
        .exe = "/g/g.exe",
        .args = &.{ "-dx12", "a b" },
        .workdir = "/g",
        .runner = .{ .wine = .{ .binary = "/opt/wine/bin/wine", .prefix = "/data/prefixes/x" } },
        .inject = .{ .injector = "/v/veneer-inject.exe", .dlls = &.{ "/d/a.dll", "/d/b.dll" } },
    });
    try testing.expectEqual(@as(usize, 2), p.argv.len);
    try testing.expectEqualStrings("/v/veneer-inject.exe", p.argv[1]);
    try testing.expectEqualStrings("Z:\\g\\g.exe", envOf(p, inject_env.game_exe).?);
    try testing.expectEqualStrings("-dx12 \"a b\"", envOf(p, inject_env.game_args).?);
    try testing.expectEqualStrings("Z:\\d\\a.dll;Z:\\d\\b.dll", envOf(p, inject_env.dlls).?);
    try testing.expect(envOf(p, "SteamAppId") == null);
}

test "injection into a native game is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InjectNeedsWine, build(arena.allocator(), .{
        .exe = "/g/run.sh",
        .workdir = "/g",
        .runner = .{ .native = .{} },
        .inject = .{ .injector = "/v/i.exe", .dlls = &.{} },
    }));
}

test "gamescope stays outside the overlay's user namespace, and the overlay re-enters the working directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{
        .exe = "/g/bin/g.exe",
        .workdir = "/g/bin",
        .runner = .{ .wine = .{ .binary = "wine", .prefix = "/p" } },
        .wrappers = &.{ "gamescope", "--" },
        .overlay = .{ .veneer = "/usr/bin/veneer", .lower = "/g", .upper = "/d/up", .work = "/d/work" },
    });
    const want = [_][]const u8{ "gamescope", "--", "/usr/bin/veneer", overlay.verb, "/g", "/d/up", "/d/work", "/g/bin", "--", "wine", "/g/bin/g.exe" };
    try testing.expectEqual(want.len, p.argv.len);
    for (want, p.argv) |w, a| try testing.expectEqualStrings(w, a);
}

test "Windows command lines survive CommandLineToArgvW's backslash rules" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("plain \"\"", try windowsCommandLine(a, &.{ "plain", "" }));
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", try windowsCommandLine(a, &.{"say \"hi\""}));
    try testing.expectEqualStrings("\"C:\\dir with space\\\\\"", try windowsCommandLine(a, &.{"C:\\dir with space\\"}));
    try testing.expectEqualStrings("C:\\no\\space", try windowsCommandLine(a, &.{"C:\\no\\space"}));
    try testing.expectEqualStrings("\"a\\\\\\\"b c\"", try windowsCommandLine(a, &.{"a\\\"b c"}));
}

test "a native game runs directly, or through a runtime, with no Wine variables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const direct = try build(a, .{ .exe = "/g/run.sh", .workdir = "/g", .runner = .{ .native = .{} } });
    try testing.expectEqual(@as(usize, 1), direct.argv.len);
    try testing.expectEqual(@as(usize, 0), direct.env.len);
    const rt = try build(a, .{ .exe = "/g/run.sh", .workdir = "/g", .runner = .{ .native = .{ .runtime = "/s/run.sh" } } });
    try testing.expectEqualStrings("/s/run.sh", rt.argv[0]);
}

test "the player's variables override the planner's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try build(arena.allocator(), .{
        .exe = "/g/g.exe",
        .workdir = "/g",
        .runner = .{ .wine = .{ .binary = "wine", .prefix = "/a" } },
        .env = &.{ .{ .name = "WINEPREFIX", .value = "/b" }, .{ .name = "DXVK_HUD", .value = "fps" } },
    });
    try testing.expectEqualStrings("/b", envOf(p, "WINEPREFIX").?);
    try testing.expectEqualStrings("fps", envOf(p, "DXVK_HUD").?);
    try testing.expectEqual(@as(usize, 2), p.env.len);
}

test "launch argument strings split like a shell, quotes and all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try splitArgs(a, "  -windowed  \"-name=A B\" '-x \"y\"' -q\"u\"ote \"\" \"esc\\\"aped\"");
    const want = [_][]const u8{ "-windowed", "-name=A B", "-x \"y\"", "-quote", "", "esc\"aped" };
    try testing.expectEqual(want.len, args.len);
    for (want, args) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqual(@as(usize, 0), (try splitArgs(a, "   ")).len);
}

test "env assignments need a name" {
    try testing.expectEqualStrings("1", parseEnvAssignment("DXVK_ASYNC=1").?.value);
    try testing.expectEqualStrings("", parseEnvAssignment("EMPTY=").?.value);
    try testing.expect(parseEnvAssignment("=x") == null);
    try testing.expect(parseEnvAssignment("novalue") == null);
}

test "the shell rendering quotes only what needs it" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeShell(&w, .{
        .argv = &.{ "/p/proton", "it's here.exe" },
        .env = &.{.{ .name = "A", .value = "two words" }},
        .cwd = "/g",
    });
    try testing.expectEqualStrings("cd /g && A='two words' /p/proton 'it'\\''s here.exe'\n", w.buffered());
}
