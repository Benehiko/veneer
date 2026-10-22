const std = @import("std");
const Io = std.Io;
const build_info = @import("build_info");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const overlay = @import("hooks/overlay.zig");
const gui = @import("gui/app.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = init.minimal.args.vector;
    const args = try arena.alloc([]const u8, raw.len -| 1);
    for (args, raw[1..]) |*arg, ptr| arg.* = std.mem.sliceTo(ptr, 0);

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;

    if (args.len > 0 and std.mem.eql(u8, args[0], overlay.verb)) {
        overlay.exec(arena, io, args[1..]) catch |err| {
            std.log.err("could not layer files over the game: {s}", .{overlay.explain(err)});
            std.process.exit(1);
        };
    }

    const cmd = cli.parse(args) catch {
        std.log.err("unknown command '{s}'; see `veneer help`", .{args[0]});
        std.process.exit(2);
    };
    const ctx: commands.Ctx = .{ .arena = arena, .gpa = gpa, .io = io, .env = init.environ_map, .out = out };

    const result = switch (cmd.verb) {
        .help => out.writeAll(cli.usage),
        .version => out.print("veneer {s}\n{s}", .{ build_info.version, cli.notice }),
        .window => gui.run(gpa, io, init.environ_map) catch |err| {
            std.log.err("could not open the window ({s}); every feature is also on the command line, see `veneer help`", .{@errorName(err)});
            std.process.exit(1);
        },
        .list => commands.list(ctx),
        .add => commands.add(ctx, cmd.rest),
        .remove => commands.remove(ctx, cmd.rest),
        .show => commands.show(ctx, cmd.rest),
        .set => commands.set(ctx, cmd.rest),
        .run => commands.run(ctx, cmd.rest),
        .runners => commands.runners(ctx),
        .doctor => commands.doctor(ctx),
        .optiscaler => commands.optiscalerDir(ctx, cmd.rest),
        .install_proton => commands.installProton(ctx, cmd.rest),
    };
    result catch |err| {
        out.flush() catch {};
        if (err != error.Reported) std.log.err("{s}", .{@errorName(err)});
        std.process.exit(1);
    };
    try out.flush();
}

test {
    _ = cli;
    _ = @import("paths.zig");
    _ = @import("library/vdf.zig");
    _ = @import("library/appinfo.zig");
    _ = @import("library/exe.zig");
    _ = @import("library/library.zig");
    _ = @import("runner/proton.zig");
    _ = @import("config/choices.zig");
    _ = @import("launch/plan.zig");
    _ = @import("launch/gamescope.zig");
    _ = @import("launch/display.zig");
    _ = @import("launch/steam_client.zig");
    _ = @import("launch/execute.zig");
    _ = @import("launch/compose.zig");
    _ = @import("compat/facts.zig");
    _ = @import("compat/rules.zig");
    _ = @import("hooks/anticheat.zig");
    _ = overlay;
    _ = @import("gui/model.zig");
    _ = @import("launch/launcher.zig");
    _ = @import("config/zonfile.zig");
    _ = @import("library/cache.zig");
    _ = @import("hooks/optiscaler.zig");
    _ = @import("optiscaler/releases.zig");
    _ = @import("optiscaler/unpack.zig");
    _ = @import("optiscaler/install.zig");
    _ = @import("launch/steam_overlay.zig");
    _ = @import("runner/ge_proton.zig");
    _ = @import("runner/steam_install.zig");
    _ = @import("runner/translators.zig");
}
