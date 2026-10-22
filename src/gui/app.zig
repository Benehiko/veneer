const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const dvui = @import("dvui");
const Backend = @import("sdl3gpu-backend");
const library = @import("../library/library.zig");
const Game = library.Game;
const manual = @import("../library/manual.zig");
const steam = @import("../library/steam.zig");
const proton = @import("../runner/proton.zig");
const paths = @import("../paths.zig");
const choices_mod = @import("../config/choices.zig");
const Choices = choices_mod.Choices;
const facts_mod = @import("../compat/facts.zig");
const rules = @import("../compat/rules.zig");
const launcher = @import("../launch/launcher.zig");
const compose = @import("../launch/compose.zig");
const gamescope = @import("../launch/gamescope.zig");
const model = @import("model.zig");
const cache = @import("../library/cache.zig");
const settings_mod = @import("../config/settings.zig");
const optiscaler = @import("../hooks/optiscaler.zig");
const steam_client = @import("../launch/steam_client.zig");
const opti_releases = @import("../optiscaler/releases.zig");
const opti_install = @import("../optiscaler/install.zig");
const ge_proton = @import("../runner/ge_proton.zig");
const theme = @import("theme.zig");

const card_w = 160;
const card_h = 240;
const panel_w = 380;

const Library = struct {
    arena: std.heap.ArenaAllocator,
    games: []const Game = &.{},
    art: []const ?[]const u8 = &.{},
    tools: []const []const u8 = &.{},
    facts: facts_mod.Facts = .{},
    table: []const rules.Rule = &.{},
    probed: bool = false,
};

fn readArt(arena: Allocator, io: Io, games: []const Game) ![]const ?[]const u8 {
    const art = try arena.alloc(?[]const u8, games.len);
    for (games, art) |g, *bytes| {
        bytes.* = if (g.art) |path| Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch null else null;
    }
    return art;
}

fn cachedLibrary(gpa: Allocator, io: Io, env: *const Environ.Map) ?*Library {
    const lib = gpa.create(Library) catch return null;
    lib.* = .{ .arena = .init(gpa) };
    const a = lib.arena.allocator();
    lib.games = cache.load(a, io, env) catch &.{};
    if (lib.games.len == 0) {
        freeLibrary(gpa, lib);
        return null;
    }
    lib.art = readArt(a, io, lib.games) catch {
        freeLibrary(gpa, lib);
        return null;
    };
    return lib;
}

const Selection = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    choices: Choices,
    env_buf: [1024]u8 = @splat(0),
    args_buf: [512]u8 = @splat(0),
    gamescope_buf: [512]u8 = @splat(0),
};

const App = struct {
    gpa: Allocator,
    io: Io,
    env: *const Environ.Map,
    win: *dvui.Window,
    config_dir: []const u8,
    mutex: Io.Mutex = .init,
    closing: bool = false,
    lib: ?*Library = null,
    sel: ?*Selection = null,
    search: [128]u8 = @splat(0),
    scanning: std.atomic.Value(bool) = .init(false),
    installing: std.atomic.Value(bool) = .init(false),
    installing_proton: std.atomic.Value(bool) = .init(false),
    threads: std.ArrayList(std.Thread) = .empty,

    fn startProtonDownload(app: *App) void {
        if (app.installing_proton.swap(true, .acq_rel)) return;
        const t = std.Thread.spawn(.{}, protonWorker, .{app}) catch {
            app.installing_proton.store(false, .release);
            return;
        };
        app.threads.append(app.gpa, t) catch t.detach();
    }

    fn startInstall(app: *App) void {
        if (app.installing.swap(true, .acq_rel)) return;
        const t = std.Thread.spawn(.{}, installWorker, .{app}) catch {
            app.installing.store(false, .release);
            return;
        };
        app.threads.append(app.gpa, t) catch t.detach();
    }

    fn startScan(app: *App) void {
        if (app.scanning.swap(true, .acq_rel)) return;
        const t = std.Thread.spawn(.{}, scanWorker, .{app}) catch {
            app.scanning.store(false, .release);
            return;
        };
        app.threads.append(app.gpa, t) catch t.detach();
    }

    fn post(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        if (app.closing) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        dvui.refresh(app.win, @src(), null);
        dvui.toast(@src(), .{ .window = app.win, .message = msg });
    }

    fn shutdown(app: *App) void {
        app.mutex.lockUncancelable(app.io);
        app.closing = true;
        app.mutex.unlock(app.io);
        for (app.threads.items) |t| t.join();
        app.threads.deinit(app.gpa);
        if (app.lib) |lib| freeLibrary(app.gpa, lib);
        if (app.sel) |sel| freeSelection(app.gpa, sel);
    }

    fn select(app: *App, game: Game) void {
        if (app.sel) |old| {
            if (std.mem.eql(u8, old.id, game.id)) return;
            freeSelection(app.gpa, old);
            app.sel = null;
        }
        const sel = app.gpa.create(Selection) catch return;
        sel.* = .{ .arena = .init(app.gpa), .id = undefined, .choices = .{} };
        const a = sel.arena.allocator();
        sel.id = a.dupe(u8, game.id) catch {
            freeSelection(app.gpa, sel);
            return;
        };
        sel.choices = choices_mod.load(a, app.io, app.config_dir, game.id) catch .{};
        fill(&sel.env_buf, model.envLine(a, sel.choices.env) catch "");
        fill(&sel.args_buf, sel.choices.args);
        fill(&sel.gamescope_buf, sel.choices.gamescope_args);
        app.sel = sel;
    }

    fn save(app: *App) void {
        const sel = app.sel orelse return;
        choices_mod.save(app.gpa, app.io, app.config_dir, sel.id, sel.choices) catch |err| {
            dvui.toast(@src(), .{ .message = @errorName(err) });
        };
    }

    fn pickFile(_: *App, title: [:0]const u8) ?[]const u8 {
        if (!dvui.useTinyFileDialogs) {
            dvui.toast(@src(), .{ .message = "This build has no file dialog; use the command line" });
            return null;
        }
        const picked = dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{ .title = title }) catch null;
        return if (picked) |p| p else null;
    }

    fn pickFolder(_: *App, title: [:0]const u8) ?[]const u8 {
        if (!dvui.useTinyFileDialogs) {
            dvui.toast(@src(), .{ .message = "This build has no file dialog; use the command line" });
            return null;
        }
        const picked = dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{ .title = title }) catch null;
        return if (picked) |p| p else null;
    }

    fn addGame(app: *App) void {
        const arena = dvui.currentWindow().arena();
        const path = app.pickFile("Add a game") orelse return;
        const file = manual.load(arena, app.io, app.config_dir) catch manual.File{};
        const entry: manual.Entry = .{ .name = std.fs.path.stem(path), .exe = path };
        const updated = manual.withAdded(arena, file, entry) catch return;
        manual.save(app.gpa, app.io, app.config_dir, updated) catch |err| {
            dvui.toast(@src(), .{ .message = @errorName(err) });
            return;
        };
        app.startScan();
    }

    fn play(app: *App, id: []const u8) void {
        const owned = app.gpa.dupe(u8, id) catch return;
        const t = std.Thread.spawn(.{}, launchWorker, .{ app, owned }) catch {
            app.gpa.free(owned);
            return;
        };
        app.threads.append(app.gpa, t) catch t.detach();
    }

    fn frame(app: *App) void {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);

        var root = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .style = .window });
        defer root.deinit();

        app.header();

        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();

        const lib = app.lib orelse {
            dvui.labelNoFmt(@src(), "Looking for games…", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .expand = .both });
            return;
        };
        app.grid(lib);
        if (app.sel != null) app.panel(lib);
    }

    fn header(app: *App) void {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(10) });
        defer bar.deinit();

        dvui.labelNoFmt(@src(), "Veneer", .{}, .{ .font = .theme(.title), .gravity_y = 0.5 });
        var te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.search }, .placeholder = "Search games" }, .{
            .expand = .horizontal,
            .gravity_y = 0.5,
            .margin = .{ .x = 16, .w = 16 },
        });
        te.deinit();
        if (dvui.button(@src(), "Add game", .{}, .{ .gravity_y = 0.5 })) app.addGame();
        const label = if (app.scanning.load(.acquire)) "Scanning…" else "Rescan";
        if (dvui.button(@src(), label, .{}, .{ .gravity_y = 0.5 })) app.startScan();
    }

    fn grid(app: *App, lib: *Library) void {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();
        var flex = dvui.flexbox(@src(), .{ .justify_content = .start }, .{ .expand = .horizontal, .padding = .all(8) });
        defer flex.deinit();

        const query = std.mem.sliceTo(&app.search, 0);
        var shown: usize = 0;
        for (lib.games, 0..) |g, i| {
            if (!model.matches(g.name, query)) continue;
            shown += 1;
            if (app.card(lib, g, i)) app.select(g);
        }
        if (shown == 0) {
            const msg = if (lib.games.len == 0) "No games yet. Install one through Steam, or press Add game." else "No game matches the search.";
            dvui.labelNoFmt(@src(), msg, .{}, .{ .margin = .all(16) });
        }
    }

    fn card(app: *App, lib: *Library, g: Game, i: usize) bool {
        const selected = if (app.sel) |s| std.mem.eql(u8, s.id, g.id) else false;
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .id_extra = i,
            .margin = .all(8),
            .padding = .all(6),
            .corners = .all(10),
            .border = .all(if (selected) 2 else 0),
            .background = true,
            .min_size_content = .{ .w = card_w, .h = card_h + 30 },
            .max_size_content = .{ .w = card_w, .h = card_h + 30 },
        });
        defer bw.deinit();
        bw.processEvents();
        bw.drawBackground();

        if (lib.art[i]) |bytes| {
            _ = dvui.image(@src(), .{ .source = .{ .imageFile = .{ .bytes = bytes, .name = g.id } } }, .{
                .min_size_content = .{ .w = card_w, .h = card_h },
                .corners = .all(8),
                .gravity_x = 0.5,
            });
        } else {
            var cover = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = card_w, .h = card_h }, .corners = .all(8), .background = true, .border = .all(1) });
            dvui.labelNoFmt(@src(), g.name, .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .font = .theme(.heading), .max_size_content = .width(card_w - 12) });
            cover.deinit();
        }
        dvui.labelNoFmt(@src(), g.name, .{}, .{ .gravity_x = 0.5, .max_size_content = .width(card_w) });
        return bw.clicked();
    }

    fn panel(app: *App, lib: *Library) void {
        const sel = app.sel.?;
        const game = for (lib.games) |g| {
            if (std.mem.eql(u8, g.id, sel.id)) break g;
        } else {
            freeSelection(app.gpa, sel);
            app.sel = null;
            return;
        };
        const a = sel.arena.allocator();
        const frame_arena = dvui.currentWindow().arena();

        var side = dvui.box(@src(), .{}, .{
            .expand = .vertical,
            .min_size_content = .width(panel_w),
            .max_size_content = .width(panel_w),
            .padding = .all(16),
            .background = true,
        });
        defer side.deinit();

        dvui.labelNoFmt(@src(), game.name, .{}, .{ .font = .theme(.title), .max_size_content = .width(panel_w) });
        dvui.label(@src(), "{s} game, from {s}", .{ if (game.platform == .windows) "Windows" else "Linux", if (game.source == .steam) "Steam" else "your library" }, .{});

        const found: []const rules.Verdict = if (lib.probed) launcher.checks(frame_arena, lib.facts, lib.table, sel.choices, .{}) catch &.{} else &.{};
        const blocked = rules.worst(found) == .@"error";

        if (dvui.button(@src(), if (blocked) "Cannot play (see below)" else "Play", .{}, .{
            .expand = .horizontal,
            .min_size_content = .height(44),
            .font = .theme(.heading),
            .margin = .{ .y = 12, .h = 12 },
        }) and !blocked) app.play(game.id);

        for (found, 0..) |v, i| {
            const prefix = switch (v.severity) {
                .@"error" => "Error: ",
                .warn => "Warning: ",
                .info => "Note: ",
            };
            const text = std.fmt.allocPrint(frame_arena, "{s}{s}", .{ prefix, v.message }) catch continue;
            var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = i, .expand = .horizontal, .background = false });
            tl.addText(text, .{});
            tl.deinit();
        }

        dvui.labelNoFmt(@src(), "Runner", .{}, .{ .margin = .{ .y = 8 } });
        const menu = model.runnerMenu(frame_arena, lib.tools, sel.choices.runner, game.platform) catch return;
        const ge_label = if (app.installing_proton.load(.acquire)) "Downloading GE-Proton…" else "Download GE-Proton (latest)…";
        const labels = std.mem.concat(frame_arena, []const u8, &.{ menu.labels, &.{ "Choose a Wine binary…", ge_label } }) catch return;
        var runner_idx: ?usize = menu.indexOf(sel.choices.runner);
        if (dvui.dropdown(@src(), labels, .{ .choice_nullable = &runner_idx }, .{}, .{ .expand = .horizontal })) {
            if (runner_idx) |k| {
                if (k < menu.values.len) {
                    sel.choices.runner = a.dupe(u8, menu.values[k]) catch sel.choices.runner;
                    app.save();
                } else if (k == menu.values.len) {
                    if (app.pickFile("Choose a Wine binary")) |wine| {
                        sel.choices.runner = a.dupe(u8, wine) catch sel.choices.runner;
                        app.save();
                    }
                } else app.startProtonDownload();
            }
        }
        if (game.platform == .windows and lib.probed and lib.tools.len == 0) {
            dvui.labelNoFmt(@src(), "No Proton is installed.", .{}, .{ .margin = .{ .y = 4 } });
            if (dvui.button(@src(), "Install Proton Experimental", .{}, .{ .expand = .horizontal })) {
                steam_client.requestInstall(app.io, steam_client.proton_experimental_app_id) catch {};
                dvui.toast(@src(), .{ .message = "Steam is installing Proton Experimental. Press Rescan when it finishes." });
            }
        }

        dvui.labelNoFmt(@src(), "Display", .{}, .{ .margin = .{ .y = 8 } });
        var display_idx: ?usize = @backingInt(sel.choices.display);
        if (dvui.dropdown(@src(), &model.display_labels, .{ .choice_nullable = &display_idx }, .{}, .{ .expand = .horizontal })) {
            if (display_idx) |k| {
                sel.choices.display = @fromBackingInt(@intCast(k));
                app.save();
            }
        }

        dvui.labelNoFmt(@src(), "Upscaling", .{}, .{ .margin = .{ .y = 8 } });
        var upscale_idx: ?usize = @backingInt(sel.choices.upscaling);
        if (dvui.dropdown(@src(), &model.upscaling_labels, .{ .choice_nullable = &upscale_idx }, .{}, .{ .expand = .horizontal })) {
            if (upscale_idx) |k| {
                sel.choices.upscaling = @fromBackingInt(@intCast(k));
                app.save();
            }
        }

        if (sel.choices.upscaling == .fsr or sel.choices.upscaling == .nis) {
            dvui.labelNoFmt(@src(), "Render scale", .{}, .{ .margin = .{ .y = 8 } });
            var scale_idx: ?usize = model.scaleIndex(sel.choices.render_scale);
            if (dvui.dropdown(@src(), &model.scale_labels, .{ .choice_nullable = &scale_idx }, .{}, .{ .expand = .horizontal })) {
                if (scale_idx) |k| {
                    sel.choices.render_scale = gamescope.scales[k];
                    app.save();
                }
            }
        }

        if (sel.choices.upscaling == .optiscaler) {
            const s = settings_mod.load(frame_arena, app.io, app.env) catch settings_mod.Settings{};
            const ready = s.optiscaler_dir.len > 0 and optiscaler.looksLikeRelease(app.io, s.optiscaler_dir);
            if (ready) {
                dvui.label(@src(), "OptiScaler from {s}", .{s.optiscaler_dir}, .{ .margin = .{ .y = 4 }, .max_size_content = .width(panel_w) });
            } else {
                dvui.labelNoFmt(@src(), "Choose the folder you extracted an OptiScaler release into.", .{}, .{ .margin = .{ .y = 4 }, .max_size_content = .width(panel_w) });
            }
            if (!ready) {
                const busy = app.installing.load(.acquire);
                if (dvui.button(@src(), if (busy) "Downloading OptiScaler…" else "Download OptiScaler", .{}, .{ .expand = .horizontal }) and !busy) {
                    app.startInstall();
                }
            }
            if (dvui.button(@src(), if (ready) "Change OptiScaler folder…" else "Choose OptiScaler folder…", .{}, .{ .expand = .horizontal })) {
                if (app.pickFolder("Choose the extracted OptiScaler release")) |dir| {
                    if (optiscaler.looksLikeRelease(app.io, dir)) {
                        settings_mod.save(app.gpa, app.io, app.env, .{ .optiscaler_dir = dir }) catch {};
                    } else {
                        dvui.toast(@src(), .{ .message = "That folder has no OptiScaler.dll" });
                    }
                }
            }
        }

        if (sel.choices.usesGamescope()) {
            if (dvui.checkbox(@src(), &sel.choices.hdr, "HDR", .{ .margin = .{ .y = 8 } })) app.save();
        }

        if (dvui.expander(@src(), "Advanced", .{}, .{ .expand = .horizontal, .margin = .{ .y = 12 } })) {
            dvui.labelNoFmt(@src(), "Environment (NAME=value, space separated)", .{}, .{});
            var env_te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &sel.env_buf } }, .{ .expand = .horizontal });
            const env_text = env_te.getText();
            env_te.deinit();
            const env_now = model.envLine(frame_arena, sel.choices.env) catch env_text;
            if (!std.mem.eql(u8, env_text, env_now)) {
                sel.choices.env = model.envList(a, env_text) catch sel.choices.env;
                app.save();
            }

            dvui.labelNoFmt(@src(), "Game arguments", .{}, .{ .margin = .{ .y = 6 } });
            var args_te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &sel.args_buf } }, .{ .expand = .horizontal });
            const args_text = args_te.getText();
            args_te.deinit();
            if (!std.mem.eql(u8, args_text, sel.choices.args)) {
                sel.choices.args = a.dupe(u8, args_text) catch sel.choices.args;
                app.save();
            }

            dvui.labelNoFmt(@src(), "Extra gamescope arguments", .{}, .{ .margin = .{ .y = 6 } });
            var gs_te = dvui.textEntry(@src(), .{ .text = .{ .buffer = &sel.gamescope_buf } }, .{ .expand = .horizontal });
            const gs_text = gs_te.getText();
            gs_te.deinit();
            if (!std.mem.eql(u8, gs_text, sel.choices.gamescope_args)) {
                sel.choices.gamescope_args = a.dupe(u8, gs_text) catch sel.choices.gamescope_args;
                app.save();
            }

            if (game.source == .manual) {
                if (dvui.button(@src(), "Remove from Veneer", .{}, .{ .margin = .{ .y = 12 } })) app.remove(game.id);
            }
        }
    }

    fn remove(app: *App, id: []const u8) void {
        const arena = dvui.currentWindow().arena();
        const file = manual.load(arena, app.io, app.config_dir) catch return;
        const after = (manual.withRemoved(arena, file, id) catch return) orelse return;
        manual.save(app.gpa, app.io, app.config_dir, after) catch return;
        if (app.sel) |s| freeSelection(app.gpa, s);
        app.sel = null;
        app.startScan();
    }
};

fn fill(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
}

fn freeLibrary(gpa: Allocator, lib: *Library) void {
    lib.arena.deinit();
    gpa.destroy(lib);
}

fn freeSelection(gpa: Allocator, sel: *Selection) void {
    sel.arena.deinit();
    gpa.destroy(sel);
}

fn scanWorker(app: *App) void {
    defer app.scanning.store(false, .release);
    const lib = app.gpa.create(Library) catch return;
    lib.* = .{ .arena = .init(app.gpa) };
    const a = lib.arena.allocator();

    lib.games = library.scan(a, app.io, app.env) catch &.{};
    cache.save(app.gpa, app.io, app.env, lib.games) catch {};
    lib.art = readArt(a, app.io, lib.games) catch {
        freeLibrary(app.gpa, lib);
        return;
    };

    if (app.env.get("HOME")) |home| {
        if (steam.locate(a, app.io, home)) |locations| {
            if (proton.discover(a, app.io, locations)) |tools| {
                if (a.alloc([]const u8, tools.len)) |names| {
                    for (tools, names) |t, *n| n.* = t.name;
                    lib.tools = names;
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }
    lib.facts = facts_mod.probe(a, app.io) catch .{};
    lib.table = rules.parse(a, rules.builtin_table) catch &.{};
    lib.probed = true;

    app.mutex.lockUncancelable(app.io);
    defer app.mutex.unlock(app.io);
    if (app.closing) {
        freeLibrary(app.gpa, lib);
        return;
    }
    if (app.lib) |old| freeLibrary(app.gpa, old);
    app.lib = lib;
    dvui.refresh(app.win, @src(), null);
}

fn protonWorker(app: *App) void {
    defer app.installing_proton.store(false, .release);
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const home = app.env.get("HOME") orelse return;
    const locations = steam.locate(a, app.io, home) catch return;
    if (locations.len == 0) return app.post("GE-Proton installs into Steam's compatibilitytools.d, and no Steam install was found", .{});
    app.post("Downloading the latest GE-Proton…", .{});
    const done = ge_proton.install(a, app.gpa, app.io, locations[0].root) catch |err| {
        return app.post("GE-Proton: {s}", .{ge_proton.explain(err) orelse @errorName(err)});
    };
    app.post("{s} is installed; choose it under Runner (restart Steam to see it there too)", .{done.tag});
    app.startScan();
}

fn installWorker(app: *App) void {
    defer app.installing.store(false, .release);
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pinned = opti_releases.parse(a, opti_releases.builtin_table) catch return;
    const release = opti_releases.newest(pinned) orelse return;
    app.post("Downloading OptiScaler {s}…", .{release.tag});
    const dir = opti_install.install(app.gpa, a, app.io, app.env, release) catch |err| {
        return app.post("OptiScaler: {s}", .{opti_install.explain(err) orelse @errorName(err)});
    };
    settings_mod.save(app.gpa, app.io, app.env, .{ .optiscaler_dir = dir }) catch |err| {
        return app.post("OptiScaler installed, but the setting was not saved: {s}", .{@errorName(err)});
    };
    app.post("OptiScaler {s} is ready", .{release.tag});
}

fn launchWorker(app: *App, id: []u8) void {
    defer app.gpa.free(id);
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const games = library.scan(a, app.io, app.env) catch return app.post("Could not read the library", .{});
    const game = switch (library.find(games, id)) {
        .one => |g| g,
        else => return app.post("That game is no longer installed", .{}),
    };
    const c = choices_mod.load(a, app.io, app.config_dir, id) catch Choices{};
    const prepared = launcher.prepare(a, app.io, app.env, game, c, .{}) catch |err| {
        return app.post("{s}: {s}", .{ game.name, compose.explain(err) orelse @errorName(err) });
    };
    const log_path = launcher.logPath(a, app.env, game.id) catch return;
    app.post("Starting {s} with {s}", .{ game.name, prepared.runner_name });
    const term = launcher.start(app.gpa, app.io, app.env, game, prepared.plan, log_path) catch |err| {
        return app.post("{s}: {s}", .{ game.name, compose.explain(err) orelse @errorName(err) });
    };
    switch (term) {
        .exited => |code| if (code == 0)
            app.post("{s} closed", .{game.name})
        else
            app.post("{s} exited with code {d}; the log is {s}", .{ game.name, code, log_path }),
        else => app.post("{s} ended abnormally; the log is {s}", .{ game.name, log_path }),
    }
}

pub fn run(gpa: Allocator, io: Io, env: *const Environ.Map) !void {
    _ = Backend.c.SDL_SetHint(Backend.c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");

    var backend = try Backend.initWindow(.{
        .io = io,
        .allocator = gpa,
        .size = .{ .w = 1280, .h = 820 },
        .min_size = .{ .w = 820, .h = 520 },
        .vsync = true,
        .title = "Veneer",
    });
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = theme.veneer(switch (backend.preferredColorScheme() orelse .dark) {
            .light => false,
            .dark => true,
        }),
        .open_flag = &window_open,
    });
    defer win.deinit();

    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .win = &win,
        .config_dir = try paths.dir(config_arena.allocator(), env, .config),
    };
    defer app.shutdown();
    app.lib = cachedLibrary(gpa, io, env);
    app.startScan();

    var interrupted = false;
    while (window_open) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        _ = try backend.addAllEvents(&win);
        app.frame();
        const end_micros = try win.end(.{});
        const wait_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_micros);
    }
}
