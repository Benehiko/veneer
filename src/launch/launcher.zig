const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const game_mod = @import("../library/game.zig");
const Game = game_mod.Game;
const Platform = game_mod.Platform;
const paths = @import("../paths.zig");
const choices_mod = @import("../config/choices.zig");
const Choices = choices_mod.Choices;
const facts_mod = @import("../compat/facts.zig");
const rules = @import("../compat/rules.zig");
const compose = @import("compose.zig");
const plan = @import("plan.zig");
const execute = @import("execute.zig");
const steam_client = @import("steam_client.zig");

pub fn featuresFor(c: Choices, over: compose.Overrides, platform: Platform) rules.Features {
    var f: rules.Features = .empty;
    if (!compose.runsNatively(compose.runnerKind(c.runner), platform)) f.insert(.wine);
    if (c.usesGamescope()) f.insert(.gamescope);
    if (c.usesGamescope() and c.hdr) f.insert(.hdr);
    if (c.upscaling == .optiscaler) {
        f.insert(.optiscaler);
        f.insert(.overlay);
    }
    if (over.overlay) f.insert(.overlay);
    if (over.inject_dlls.len > 0) f.insert(.inject);
    return f;
}

pub fn checks(arena: Allocator, facts: facts_mod.Facts, table: []const rules.Rule, c: Choices, over: compose.Overrides, platform: Platform) Allocator.Error![]const rules.Verdict {
    return rules.evaluate(arena, table, facts, featuresFor(c, over, platform));
}

pub const Prepared = struct {
    plan: plan.Plan,
    runner_name: []const u8,
};

pub fn prepare(arena: Allocator, io: Io, env: *const Environ.Map, game: Game, c: Choices, over: compose.Overrides) !Prepared {
    const outcome = try compose.compose(arena, io, env, game, c, over);
    return .{ .plan = try plan.build(arena, outcome.input), .runner_name = outcome.runner_name };
}

pub fn logDir(arena: Allocator, env: *const Environ.Map) ![]const u8 {
    const state = try paths.dir(arena, env, .state);
    return std.fs.path.join(arena, &.{ state, "logs" });
}

pub fn logPath(arena: Allocator, env: *const Environ.Map, game_id: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}.log", .{try choices_mod.slug(arena, game_id)});
    return std.fs.path.join(arena, &.{ try logDir(arena, env), name });
}

pub fn start(gpa: Allocator, io: Io, env: *const Environ.Map, game: Game, p: plan.Plan, log_path: []const u8) !std.process.Child.Term {
    if (game.source == .steam) {
        if (env.get("HOME")) |home| try steam_client.ensureRunning(io, home);
    }
    return execute.run(gpa, io, env, p, log_path);
}

const testing = std.testing;

test "features follow the choices and the one-off hooks" {
    const plain = featuresFor(.{}, .{}, .linux);
    try testing.expectEqual(@as(usize, 0), plain.count());
    const fsr = featuresFor(.{ .upscaling = .fsr, .hdr = true }, .{}, .linux);
    try testing.expect(fsr.contains(.gamescope) and fsr.contains(.hdr));
    const hdr_alone = featuresFor(.{ .hdr = true }, .{}, .linux);
    try testing.expect(!hdr_alone.contains(.hdr));
    const opti = featuresFor(.{ .upscaling = .optiscaler }, .{}, .windows);
    try testing.expect(opti.contains(.optiscaler) and opti.contains(.overlay) and !opti.contains(.inject));
    const injected = featuresFor(.{}, .{ .inject_dlls = &.{"/x.dll"} }, .windows);
    try testing.expect(injected.contains(.inject));
}

test "Wine checks apply when the game runs through Proton or Wine, not natively" {
    try testing.expect(featuresFor(.{}, .{}, .windows).contains(.wine));
    try testing.expect(!featuresFor(.{}, .{}, .linux).contains(.wine));
    try testing.expect(featuresFor(.{ .runner = "GE-Proton11-11" }, .{}, .linux).contains(.wine));
    try testing.expect(!featuresFor(.{ .runner = "native" }, .{}, .linux).contains(.wine));
}
