const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const cli = @import("cli.zig");
const paths = @import("paths.zig");
const library = @import("library/library.zig");
const manual = @import("library/manual.zig");
const steam = @import("library/steam.zig");
const proton = @import("runner/proton.zig");
const choices_mod = @import("config/choices.zig");
const compose = @import("launch/compose.zig");
const plan = @import("launch/plan.zig");
const display = @import("launch/display.zig");
const launcher = @import("launch/launcher.zig");
const steam_client = @import("launch/steam_client.zig");
const settings_mod = @import("config/settings.zig");
const optiscaler = @import("hooks/optiscaler.zig");
const opti_releases = @import("optiscaler/releases.zig");
const opti_install = @import("optiscaler/install.zig");
const facts_mod = @import("compat/facts.zig");
const rules = @import("compat/rules.zig");
const Game = library.Game;

pub const Ctx = struct {
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    env: *const Environ.Map,
    out: *Io.Writer,
};

pub fn list(ctx: Ctx) !void {
    const games = try library.scan(ctx.arena, ctx.io, ctx.env);
    if (games.len == 0) {
        try ctx.out.writeAll("no games found: install one through Steam, or `veneer add <exe>`\n");
        return;
    }
    var id_width: usize = 2;
    for (games) |g| id_width = @max(id_width, g.id.len);
    for (games) |g| {
        try ctx.out.print("{s}", .{g.id});
        try ctx.out.splatByteAll(' ', id_width - g.id.len + 2);
        try ctx.out.print("{s:<8} {s}", .{ @tagName(g.platform), g.name });
        if (g.exe == null) try ctx.out.writeAll("  (no launch executable known)");
        try ctx.out.writeByte('\n');
    }
}

pub fn add(ctx: Ctx, args: []const []const u8) !void {
    const flags: cli.Flags = .{ .args = args };
    const takes = [_][]const u8{ "--name", "--args" };
    const given = flags.positional(&takes) orelse return fail("add: name the game's executable, e.g. `veneer add ~/Games/x/x.exe`", .{});
    const exe = try Io.Dir.cwd().realPathFileAlloc(ctx.io, given, ctx.arena);
    const stem = std.fs.path.stem(exe);
    const entry: manual.Entry = .{
        .name = flags.value("--name") orelse stem,
        .exe = exe,
        .args = flags.value("--args") orelse "",
    };
    const config_dir = try paths.dir(ctx.arena, ctx.env, .config);
    const file = try manual.load(ctx.arena, ctx.io, config_dir);
    try manual.save(ctx.gpa, ctx.io, config_dir, try manual.withAdded(ctx.arena, file, entry));
    const game = try manual.toGame(ctx.arena, ctx.io, entry);
    try ctx.out.print("added {s}  {s}  {s}\n", .{ game.id, @tagName(game.platform), game.name });
}

pub fn remove(ctx: Ctx, args: []const []const u8) !void {
    const query = (cli.Flags{ .args = args }).positional(&.{}) orelse return fail("remove: name the game to remove", .{});
    const games = try library.scan(ctx.arena, ctx.io, ctx.env);
    const game = try pick(games, query);
    if (game.source != .manual) return fail("remove: {s} comes from Steam; uninstall it there", .{game.name});
    const config_dir = try paths.dir(ctx.arena, ctx.env, .config);
    const file = try manual.load(ctx.arena, ctx.io, config_dir);
    const after = (try manual.withRemoved(ctx.arena, file, game.id)) orelse return fail("remove: {s} is not in {s}", .{ game.id, manual.file_name });
    try manual.save(ctx.gpa, ctx.io, config_dir, after);
    try ctx.out.print("removed {s}  {s}\n", .{ game.id, game.name });
}

const Target = struct {
    game: Game,
    choices: choices_mod.Choices,
    config_dir: []const u8,
};

fn target(ctx: Ctx, query: []const u8, assignments: []const []const u8) !Target {
    const games = try library.scan(ctx.arena, ctx.io, ctx.env);
    const game = try pick(games, query);
    const config_dir = try paths.dir(ctx.arena, ctx.env, .config);
    var c = choices_mod.load(ctx.arena, ctx.io, config_dir, game.id) catch |err| switch (err) {
        error.BadGameSettings => return fail("the settings file for {s} is not valid ZON; fix or delete it", .{game.id}),
        else => return err,
    };
    for (assignments) |a| {
        c = choices_mod.apply(ctx.arena, c, a) catch |err| return switch (err) {
            error.UnknownSetting => fail("unknown setting in '{s}'; settings are: {s}", .{ a, settingList() }),
            error.BadValue => fail("bad value in '{s}'", .{a}),
            error.NotAnAssignment => fail("'{s}' is not key=value", .{a}),
            else => err,
        };
    }
    return .{ .game = game, .choices = c, .config_dir = config_dir };
}

fn settingList() []const u8 {
    comptime var text: []const u8 = "";
    inline for (choices_mod.setting_keys, 0..) |k, i| {
        text = text ++ (if (i == 0) "" else ", ") ++ k;
    }
    return text;
}

pub fn set(ctx: Ctx, args: []const []const u8) !void {
    if (args.len == 0) return fail("set: name a game, then key=value settings", .{});
    const t = try target(ctx, args[0], args[1..]);
    try choices_mod.save(ctx.gpa, ctx.io, t.config_dir, t.game.id, t.choices);
    try ctx.out.print("{s}  {s}\n", .{ t.game.id, t.game.name });
    try writeChoices(ctx.out, t.choices);
}

fn writeChoices(out: *Io.Writer, c: choices_mod.Choices) !void {
    try out.print("  runner     {s}\n  display    {s}\n  upscaling  {s}", .{ c.runner, @tagName(c.display), @tagName(c.upscaling) });
    if (c.upscaling == .fsr or c.upscaling == .nis) try out.print(" at {d}%", .{c.render_scale});
    try out.print("\n  hdr        {s}\n", .{if (c.hdr) "on" else "off"});
    if (c.args.len > 0) try out.print("  args       {s}\n", .{c.args});
    if (c.gamescope_args.len > 0) try out.print("  gamescope  {s}\n", .{c.gamescope_args});
    for (c.env) |e| try out.print("  env        {s}\n", .{e});
}

pub fn show(ctx: Ctx, args: []const []const u8) !void {
    if (args.len == 0) return fail("show: name a game", .{});
    const t = try target(ctx, args[0], &.{});
    const g = t.game;
    try ctx.out.print("{s}  {s}\n  platform   {s} ({s})\n  install    {s}\n", .{ g.id, g.name, @tagName(g.platform), @tagName(g.source), g.install_dir });
    try ctx.out.print("  exe        {s}\n", .{g.exe orelse "(unknown)"});
    if (g.args.len > 0) try ctx.out.print("  game args  {s}\n", .{g.args});
    if (g.workdir) |w| try ctx.out.print("  workdir    {s}\n", .{w});
    if (g.art) |a| try ctx.out.print("  art        {s}\n", .{a});
    if (g.steam) |s| {
        if (g.platform == .windows) try ctx.out.print("  steam tool {s}\n", .{s.compat_tool orelse "(none mapped)"});
    }
    try writeChoices(ctx.out, t.choices);
}

pub fn runners(ctx: Ctx) !void {
    const home = ctx.env.get("HOME") orelse return fail("HOME is not set", .{});
    const tools = try proton.discover(ctx.arena, ctx.io, try steam.locate(ctx.arena, ctx.io, home));
    if (tools.len == 0) {
        try ctx.out.writeAll("no Proton found: install Proton Experimental from Steam\n");
        return;
    }
    const default = proton.newest(tools);
    for (tools) |t| {
        const mark: []const u8 = if (default != null and std.mem.eql(u8, default.?.dir, t.dir)) "*" else " ";
        try ctx.out.print("{s} {s}", .{ mark, t.name });
        if (t.internal) |i| try ctx.out.print("  ({s})", .{i});
        try ctx.out.print("\n    {s}\n", .{t.dir});
    }
    try ctx.out.writeAll("* used when Steam maps no tool to a game\n");
}

fn verdicts(ctx: Ctx, f: facts_mod.Facts, features: rules.Features) ![]const rules.Verdict {
    const table = rules.parse(ctx.arena, rules.builtin_table) catch return fail("the built-in compatibility table is malformed", .{});
    return rules.evaluate(ctx.arena, table, f, features);
}

fn writeVerdicts(out: *Io.Writer, found: []const rules.Verdict) !void {
    for (found) |v| {
        try out.print("  {s:<5}  {s}: {s}\n         {s}\n", .{ @tagName(v.severity), @tagName(v.feature), v.message, v.source });
    }
}

pub fn doctor(ctx: Ctx) !void {
    const f = try facts_mod.probe(ctx.arena, ctx.io);
    const out = ctx.out;
    if (f.kernel) |k| try out.print("kernel     {f}\n", .{k}) else try out.writeAll("kernel     unknown\n");
    try out.print("userns     {s}\n", .{if (f.userns) "allowed" else "restricted"});
    for (f.gpus) |g| try out.print("gpu        {s} ({s})\n", .{ @tagName(g.vendor), g.kernel_driver });
    if (f.vk.len == 0) try out.print("vulkan     no devices: {s}\n", .{f.vk_error orelse "the driver reported none (is /dev/dri accessible?)"});
    for (f.vk) |d| try out.print("vulkan     {s}: {s} {s}\n", .{ d.name, d.driver_name, d.driver_info });
    if (f.rocm) |r| {
        try out.print("rocm       {f}\n", .{r});
    } else try out.print("rocm       {s}\n", .{if (f.rocm_present) "installed, version unknown" else "not installed"});
    if (f.gamescope.present) {
        try out.print("gamescope  present{s}{s}\n", .{ if (f.gamescope.filter_flag) ", -F filters" else ", old upscaler flags", if (f.gamescope.hdr) ", HDR" else "" });
    } else try out.writeAll("gamescope  not found\n");
    if (display.nativeMode(ctx.io)) |m| try out.print("display    {d}x{d}\n", .{ m.width, m.height });

    const found = try verdicts(ctx, f, .full);
    if (found.len == 0) {
        try out.writeAll("\nno known problems for any feature\n");
    } else {
        try out.writeAll("\nchecks, across every feature:\n");
        try writeVerdicts(out, found);
    }
}

pub fn run(ctx: Ctx, args: []const []const u8) !void {
    var query: ?[]const u8 = null;
    var assignments: std.ArrayList([]const u8) = .empty;
    var dry = false;
    var force = false;
    var dlls: std.ArrayList([]const u8) = .empty;
    var over: compose.Overrides = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            over.extra_args = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            dry = true;
            over.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--overlay")) {
            over.overlay = true;
        } else if (std.mem.eql(u8, a, "--inject")) {
            i += 1;
            if (i == args.len) return fail("--inject needs a DLL path", .{});
            try dlls.append(ctx.arena, args[i]);
        } else if (std.mem.eql(u8, a, "--size")) {
            i += 1;
            if (i == args.len) return fail("--size needs WIDTHxHEIGHT", .{});
            over.output = display.parseMode(args[i]) orelse return fail("--size needs WIDTHxHEIGHT, not '{s}'", .{args[i]});
        } else if (std.mem.startsWith(u8, a, "-")) {
            return fail("run: unknown option '{s}'", .{a});
        } else if (query == null) {
            query = a;
        } else {
            try assignments.append(ctx.arena, a);
        }
    }
    over.inject_dlls = dlls.items;
    const t = try target(ctx, query orelse return fail("run: name a game", .{}), assignments.items);
    const checks = try verdicts(ctx, try facts_mod.probe(ctx.arena, ctx.io), launcher.featuresFor(t.choices, over));
    for (checks) |v| switch (v.severity) {
        .@"error" => std.log.err("{s}: {s}", .{ @tagName(v.feature), v.message }),
        .warn => std.log.warn("{s}: {s}", .{ @tagName(v.feature), v.message }),
        .info => std.log.info("{s}: {s}", .{ @tagName(v.feature), v.message }),
    };
    if (rules.worst(checks) == .@"error" and !force and !dry) {
        return fail("not launching {s} because of the errors above; change the settings, or pass --force", .{t.game.name});
    }
    const prepared = launcher.prepare(ctx.arena, ctx.io, ctx.env, t.game, t.choices, over) catch |err| {
        if (compose.explain(err)) |msg| return fail("{s}: {s}", .{ t.game.name, msg });
        return err;
    };
    if (dry) {
        try plan.writeShell(ctx.out, prepared.plan);
        return;
    }
    const log_path = try launcher.logPath(ctx.arena, ctx.env, t.game.id);
    try ctx.out.print("launching {s} with {s}\nlog: {s}\n", .{ t.game.name, prepared.runner_name, log_path });
    try ctx.out.flush();
    const term = launcher.start(ctx.gpa, ctx.io, ctx.env, t.game, prepared.plan, log_path) catch |err| {
        return fail("{s}", .{compose.explain(err) orelse @errorName(err)});
    };
    switch (term) {
        .exited => |code| try ctx.out.print("{s} exited with code {d}\n", .{ t.game.name, code }),
        else => try ctx.out.print("{s} ended: {any}\n", .{ t.game.name, term }),
    }
}

pub fn optiscalerDir(ctx: Ctx, args: []const []const u8) !void {
    var s = try settings_mod.load(ctx.arena, ctx.io, ctx.env);
    const pinned = opti_releases.parse(ctx.arena, opti_releases.builtin_table) catch return fail("the built-in OptiScaler release table is malformed", .{});
    if (args.len > 0 and std.mem.eql(u8, args[0], "releases")) {
        for (pinned) |r| {
            const installed = try opti_install.installedDir(ctx.arena, ctx.io, ctx.env, r.tag);
            const in_use = if (installed) |dir| std.mem.eql(u8, dir, s.optiscaler_dir) else false;
            try ctx.out.print("{s} {s:<8} {s}\n", .{ if (in_use) "*" else " ", r.tag, if (installed != null) "installed" else r.fileName() });
        }
        try ctx.out.writeAll("* in use\n");
        return;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "install")) {
        const release = if (args.len > 1)
            opti_releases.find(pinned, args[1]) orelse return fail("{s}", .{opti_install.explain(error.UnknownRelease).?})
        else
            opti_releases.newest(pinned) orelse return fail("no OptiScaler release is pinned", .{});
        try ctx.out.print("installing OptiScaler {s}\n", .{release.tag});
        try ctx.out.flush();
        const dir = opti_install.install(ctx.gpa, ctx.arena, ctx.io, ctx.env, release) catch |err| {
            return fail("{s}", .{opti_install.explain(err) orelse @errorName(err)});
        };
        s.optiscaler_dir = dir;
        try settings_mod.save(ctx.gpa, ctx.io, ctx.env, s);
        try ctx.out.print("OptiScaler {s} installed in {s}\nturn it on per game with `veneer set <game> upscaling=optiscaler`\n", .{ release.tag, dir });
        return;
    }
    if (args.len == 0) {
        if (s.optiscaler_dir.len == 0) {
            try ctx.out.writeAll("no OptiScaler release chosen: `veneer optiscaler install`, or `veneer optiscaler <folder you extracted it into>`\n");
        } else {
            const ok = optiscaler.looksLikeRelease(ctx.io, s.optiscaler_dir);
            try ctx.out.print("{s}{s}\n", .{ s.optiscaler_dir, if (ok) "" else "  (no OptiScaler.dll there)" });
        }
        return;
    }
    const dir = Io.Dir.cwd().realPathFileAlloc(ctx.io, args[0], ctx.arena) catch return fail("optiscaler: '{s}' does not exist", .{args[0]});
    if (!optiscaler.looksLikeRelease(ctx.io, dir)) return fail("optiscaler: {s} has no OptiScaler.dll; name the folder you extracted the release into", .{dir});
    s.optiscaler_dir = dir;
    try settings_mod.save(ctx.gpa, ctx.io, ctx.env, s);
    try ctx.out.print("OptiScaler release: {s}\nturn it on per game with `veneer set <game> upscaling=optiscaler`\n", .{dir});
}

pub fn installProton(ctx: Ctx) !void {
    steam_client.requestInstall(ctx.io, steam_client.proton_experimental_app_id) catch return fail("could not start Steam to install Proton", .{});
    try ctx.out.writeAll("Steam is installing Proton Experimental; it appears in `veneer runners` when Steam finishes\n");
}

pub fn pick(games: []const Game, query: []const u8) !Game {
    return switch (library.find(games, query)) {
        .one => |g| g,
        .none => fail("no game matches '{s}'; see `veneer list`", .{query}),
        .many => |n| fail("{d} games match '{s}'; use the id from `veneer list`", .{ n, query }),
    };
}

pub fn fail(comptime fmt: []const u8, args: anytype) error{Reported} {
    std.log.err(fmt, args);
    return error.Reported;
}
