const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const game_mod = @import("../library/game.zig");
const Game = game_mod.Game;
const Platform = game_mod.Platform;
const steam = @import("../library/steam.zig");
const proton = @import("../runner/proton.zig");
const paths = @import("../paths.zig");
const choices_mod = @import("../config/choices.zig");
const Choices = choices_mod.Choices;
const plan = @import("plan.zig");
const gamescope = @import("gamescope.zig");
const display = @import("display.zig");
const anticheat = @import("../hooks/anticheat.zig");
const inject_env = @import("../inject/env.zig");
const optiscaler = @import("../hooks/optiscaler.zig");
const settings_mod = @import("../config/settings.zig");
const steam_overlay = @import("steam_overlay.zig");
const translators = @import("../runner/translators.zig");

pub const Error = error{
    NoExecutable,
    NoProton,
    NoSteam,
    NoGamescope,
    OptiScalerUnavailable,
    NativeGameOnWine,
};

pub const Outcome = struct {
    input: plan.Input,
    runner_name: []const u8,
};

pub const Overrides = struct {
    output: ?gamescope.Mode = null,
    extra_args: []const []const u8 = &.{},
    inject_dlls: []const []const u8 = &.{},
    overlay: bool = false,
    optiscaler_dir: ?[]const u8 = null,
    dry_run: bool = false,
};

pub fn overlayDirs(arena: Allocator, env: *const Environ.Map, game_id: []const u8) !struct { upper: []const u8, work: []const u8 } {
    const data = try paths.dir(arena, env, .data);
    const base = try std.fs.path.join(arena, &.{ data, "overlay", try choices_mod.slug(arena, game_id) });
    return .{
        .upper = try std.fs.path.join(arena, &.{ base, "upper" }),
        .work = try std.fs.path.join(arena, &.{ base, "work" }),
    };
}

fn hooks(arena: Allocator, io: Io, env: *const Environ.Map, game: Game, runner: plan.Runner, over: Overrides) !struct { inject: ?plan.Inject, overlay: ?plan.Overlay } {
    if (over.inject_dlls.len == 0 and !over.overlay) return .{ .inject = null, .overlay = null };
    if (anticheat.detect(io, game.install_dir)) |marker| {
        std.log.err("{s} ships {s}", .{ game.name, marker });
        return error.AntiCheat;
    }
    const self_dir = try std.process.executableDirPathAlloc(io, arena);

    var inject: ?plan.Inject = null;
    if (over.inject_dlls.len > 0) {
        if (runner == .native) return error.InjectNeedsWine;
        const injector = try std.fs.path.join(arena, &.{ self_dir, inject_env.exe_name });
        Io.Dir.cwd().access(io, injector, .{}) catch return error.NoInjector;
        const dlls = try arena.alloc([]const u8, over.inject_dlls.len);
        for (over.inject_dlls, dlls) |given, *dll| {
            dll.* = Io.Dir.cwd().realPathFileAlloc(io, given, arena) catch return error.DllNotFound;
        }
        inject = .{ .injector = injector, .dlls = dlls };
    }

    var ovl: ?plan.Overlay = null;
    if (over.overlay) {
        const dirs = try overlayDirs(arena, env, game.id);
        const exe_rel = try optiscaler.targetWithin(arena, io, game.install_dir, game.exe.?);
        if (over.optiscaler_dir != null and exe_rel == null) return error.ExeOutsideInstall;
        if (!over.dry_run) {
            try Io.Dir.cwd().createDirPath(io, dirs.upper);
            try Io.Dir.cwd().createDirPath(io, dirs.work);
            if (over.optiscaler_dir) |release| try optiscaler.stage(arena, io, release, dirs.upper, exe_rel.?);
        }
        ovl = .{
            .veneer = try std.process.executablePathAlloc(io, arena),
            .lower = game.install_dir,
            .upper = dirs.upper,
            .work = dirs.work,
        };
    }
    return .{ .inject = inject, .overlay = ovl };
}

pub const RunnerKind = union(enum) {
    auto,
    native,
    wine: []const u8,
    named: []const u8,
};

pub fn runnerKind(runner: []const u8) RunnerKind {
    if (runner.len == 0 or std.mem.eql(u8, runner, "auto")) return .auto;
    if (std.mem.eql(u8, runner, "native")) return .native;
    if (std.mem.indexOfScalar(u8, runner, '/') != null) return .{ .wine = runner };
    return .{ .named = runner };
}

pub fn runsNatively(kind: RunnerKind, platform: Platform) bool {
    return switch (kind) {
        .native => true,
        .auto => platform == .linux,
        .wine, .named => false,
    };
}

pub fn compose(
    arena: Allocator,
    io: Io,
    env: *const Environ.Map,
    game: Game,
    choices: Choices,
    over: Overrides,
) !Outcome {
    const exe = game.exe orelse return error.NoExecutable;
    const home = env.get("HOME") orelse "/";
    const kind = runnerKind(choices.runner);

    var runner: plan.Runner = undefined;
    var runner_name: []const u8 = undefined;
    var native_dlls: []const []const u8 = &.{};
    if (runsNatively(kind, game.platform)) {
        if (game.platform == .windows) return error.NativeGameOnWine;
        runner = .{ .native = .{ .runtime = try steamRuntime(arena, io, game) } };
        runner_name = "native";
    } else switch (kind) {
        .wine => |binary| {
            const prefix = try ownPrefix(arena, io, env, game, over.dry_run);
            runner = .{ .wine = .{ .binary = binary, .prefix = prefix } };
            runner_name = binary;
            native_dlls = translators.setUp(arena, io, env, binary, prefix, over.dry_run) catch |err| blk: {
                std.log.warn("DirectX games may fall back to WineD3D: {s}", .{translators.explain(err) orelse @errorName(err)});
                break :blk &.{};
            };
        },
        else => {
            const locations = try steam.locate(arena, io, home);
            if (locations.len == 0) return error.NoSteam;
            const tools = try proton.discover(arena, io, locations);
            const wanted: ?[]const u8 = switch (kind) {
                .named => |n| n,
                else => if (game.steam) |s| s.compat_tool else null,
            };
            const tool = proton.forGame(tools, wanted) orelse return error.NoProton;
            if (kind == .named and !std.mem.eql(u8, tool.name, kind.named) and
                !(tool.internal != null and std.mem.eql(u8, tool.internal.?, kind.named)))
            {
                std.log.warn("no Proton named '{s}'; using {s}", .{ kind.named, tool.name });
            }
            runner_name = tool.name;
            runner = .{ .proton = if (game.steam) |s| .{
                .script = tool.script,
                .compat_data = try std.fs.path.join(arena, &.{ s.steamapps, "compatdata", s.app_id }),
                .steam_root = s.root,
                .install_path = game.install_dir,
                .library = s.steamapps,
            } else .{
                .script = tool.script,
                .compat_data = try ownPrefix(arena, io, env, game, over.dry_run),
                .steam_root = locations[0].root,
            } };
        },
    }

    var effective = over;
    if (choices.upscaling == .optiscaler) {
        if (runner == .native) return error.OptiScalerNeedsWine;
        const s = settings_mod.load(arena, io, env) catch settings_mod.Settings{};
        if (s.optiscaler_dir.len == 0) return error.OptiScalerNotSet;
        if (!optiscaler.looksLikeRelease(io, s.optiscaler_dir)) return error.OptiScalerMissing;
        effective.overlay = true;
        effective.optiscaler_dir = s.optiscaler_dir;
    }

    var wrappers: []const []const u8 = &.{};
    if (choices.usesGamescope()) {
        const caps = gamescope.probe(arena, io);
        if (!caps.present) return error.NoGamescope;
        wrappers = try gamescope.argv(arena, .{
            .output = over.output orelse display.nativeMode(io),
            .render_scale = if (choices.upscaling == .off) 100 else choices.render_scale,
            .filter = switch (choices.upscaling) {
                .fsr => .fsr,
                .nis => .nis,
                else => .linear,
            },
            .hdr = choices.hdr,
            .extra = try plan.splitArgs(arena, choices.gamescope_args),
        }, caps);
    }

    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, try plan.splitArgs(arena, game.args));
    try args.appendSlice(arena, try plan.splitArgs(arena, choices.args));
    try args.appendSlice(arena, over.extra_args);

    var vars: std.ArrayList(plan.EnvVar) = .empty;
    var overridden: std.ArrayList([]const u8) = .empty;
    try overridden.appendSlice(arena, native_dlls);
    if (effective.optiscaler_dir != null) try overridden.append(arena, optiscaler.proxy_dll);
    if (try translators.nativeOverride(arena, overridden.items)) |value| try vars.append(arena, .{ .name = "WINEDLLOVERRIDES", .value = value });
    if (game.steam) |s| try vars.appendSlice(arena, try steam_overlay.vars(arena, io, s.root, s.app_id, env.get("LD_PRELOAD")));
    for (choices.env) |assignment| {
        const v = plan.parseEnvAssignment(assignment) orelse {
            std.log.warn("ignoring '{s}': not NAME=value", .{assignment});
            continue;
        };
        try vars.append(arena, v);
    }

    const h = try hooks(arena, io, env, game, runner, effective);

    return .{
        .runner_name = runner_name,
        .input = .{
            .inject = h.inject,
            .overlay = h.overlay,
            .exe = exe,
            .args = args.items,
            .workdir = game.workdir orelse std.fs.path.dirname(exe) orelse game.install_dir,
            .app_id = if (game.steam) |s| s.app_id else null,
            .runner = runner,
            .wrappers = wrappers,
            .env = vars.items,
        },
    };
}

fn ownPrefix(arena: Allocator, io: Io, env: *const Environ.Map, game: Game, dry_run: bool) ![]const u8 {
    const data = try paths.dir(arena, env, .data);
    const prefix = try std.fs.path.join(arena, &.{ data, "prefixes", try choices_mod.slug(arena, game.id) });
    if (!dry_run) try Io.Dir.cwd().createDirPath(io, prefix);
    return prefix;
}

fn steamRuntime(arena: Allocator, io: Io, game: Game) !?[]const u8 {
    const s = game.steam orelse return null;
    const script = try std.fs.path.join(arena, &.{ s.root, "ubuntu12_32", "steam-runtime", "run.sh" });
    Io.Dir.cwd().access(io, script, .{}) catch return null;
    return script;
}

pub fn explain(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoExecutable => "Veneer does not know this game's executable (Steam's appinfo has no launch entry for this platform)",
        error.NoProton => "no Proton is installed: install Proton Experimental from Steam, or pick a Wine binary",
        error.NoSteam => "no Steam install found, and Proton comes from Steam: pick a Wine binary instead",
        error.NoGamescope => "gamescope is not on PATH: install it with your package manager, or choose the normal display",
        error.OptiScalerNeedsWine => "OptiScaler is a Windows DLL: it works only for Windows games under Proton or Wine",
        error.OptiScalerNotSet => "choose an extracted OptiScaler release first (`veneer optiscaler <folder>`, or the button on the game page)",
        error.OptiScalerMissing => "the OptiScaler folder has no OptiScaler.dll; choose the folder you extracted the release into",
        error.ExeOutsideInstall => "the game's executable is outside its install directory, so OptiScaler cannot be layered beside it",
        error.NativeGameOnWine => "this is a Windows game: it cannot run natively",
        error.SteamNotStarted => "Steam did not start; start it yourself, then try again",
        error.AntiCheat => "the game ships anti-cheat, so Veneer will not inject into it or layer files over it",
        error.NoInjector => "veneer-inject.exe is missing from beside the veneer binary; rebuild with `zig build`",
        error.InjectNeedsWine => "DLL injection works only for Windows games under Proton or Wine",
        error.DllNotFound => "a DLL to inject does not exist",
        else => null,
    };
}

const testing = std.testing;

test "the runner choice reads as auto, native, a Wine path, or a tool name" {
    try testing.expect(runnerKind("auto") == .auto);
    try testing.expect(runnerKind("") == .auto);
    try testing.expect(runnerKind("native") == .native);
    try testing.expectEqualStrings("/opt/wine/bin/wine", runnerKind("/opt/wine/bin/wine").wine);
    try testing.expectEqualStrings("GE-Proton9-20", runnerKind("GE-Proton9-20").named);
}
