const std = @import("std");

pub const Verb = enum {
    window,
    help,
    version,
    list,
    add,
    remove,
    show,
    set,
    run,
    runners,
    doctor,
    optiscaler,
    install_proton,
};

pub const Command = struct {
    verb: Verb,
    rest: []const []const u8 = &.{},
};

const spellings = [_]struct { word: []const u8, verb: Verb }{
    .{ .word = "-h", .verb = .help },
    .{ .word = "--help", .verb = .help },
    .{ .word = "help", .verb = .help },
    .{ .word = "-V", .verb = .version },
    .{ .word = "--version", .verb = .version },
    .{ .word = "version", .verb = .version },
    .{ .word = "list", .verb = .list },
    .{ .word = "ls", .verb = .list },
    .{ .word = "add", .verb = .add },
    .{ .word = "remove", .verb = .remove },
    .{ .word = "rm", .verb = .remove },
    .{ .word = "show", .verb = .show },
    .{ .word = "set", .verb = .set },
    .{ .word = "run", .verb = .run },
    .{ .word = "play", .verb = .run },
    .{ .word = "runners", .verb = .runners },
    .{ .word = "doctor", .verb = .doctor },
    .{ .word = "optiscaler", .verb = .optiscaler },
    .{ .word = "install-proton", .verb = .install_proton },
};

pub fn parse(args: []const []const u8) error{UnknownCommand}!Command {
    if (args.len == 0) return .{ .verb = .window };
    for (spellings) |s| {
        if (std.mem.eql(u8, args[0], s.word)) return .{ .verb = s.verb, .rest = args[1..] };
    }
    return error.UnknownCommand;
}

pub const Flags = struct {
    args: []const []const u8,

    pub fn has(self: Flags, name: []const u8) bool {
        for (self.args) |a| {
            if (std.mem.eql(u8, a, name)) return true;
        }
        return false;
    }

    pub fn value(self: Flags, name: []const u8) ?[]const u8 {
        for (self.args, 0..) |a, i| {
            if (std.mem.eql(u8, a, name) and i + 1 < self.args.len) return self.args[i + 1];
            if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') return a[name.len + 1 ..];
        }
        return null;
    }

    pub fn positional(self: Flags, takes_value: []const []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.args.len) : (i += 1) {
            const a = self.args[i];
            if (std.mem.eql(u8, a, "--")) return if (i + 1 < self.args.len) self.args[i + 1] else null;
            if (!std.mem.startsWith(u8, a, "-")) return a;
            for (takes_value) |name| {
                if (std.mem.eql(u8, a, name)) i += 1;
            }
        }
        return null;
    }

    pub fn afterDashes(self: Flags) []const []const u8 {
        for (self.args, 0..) |a, i| {
            if (std.mem.eql(u8, a, "--")) return self.args[i + 1 ..];
        }
        return &.{};
    }
};

pub const notice =
    \\Copyright (C) the Veneer contributors
    \\License GPL-3.0-or-later <https://www.gnu.org/licenses/gpl-3.0.html>
    \\This is free software: you may change and share it. There is NO WARRANTY.
    \\
;

pub const usage =
    \\usage: veneer [command]
    \\
    \\  (none)                      open the launcher window
    \\  list                        list every game Veneer found
    \\  add <exe> [--name NAME] [--args ARGS]
    \\                              add a game that Steam does not know
    \\  remove <game>               remove a game added with `add`
    \\  show <game>                 what Veneer knows about a game, and its settings
    \\  set <game> key=value...     change a game's settings and save them
    \\  run <game> [key=value...] [--dry-run] [--force] [--size WxH] [-- game args]
    \\                              launch a game; key=value applies to this launch only
    \\  runners                     list the Proton builds Veneer can use
    \\  doctor                      what this system supports, and known problems
    \\  optiscaler [folder]         show or choose the extracted OptiScaler release to use
    \\  optiscaler install [tag]    download a pinned OptiScaler release, verify and unpack it
    \\                              (needs bsdtar, 7zz or 7z; see docs/guides/optiscaler.md)
    \\  optiscaler releases         the pinned releases, and which is installed
    \\  install-proton              ask Steam to install Proton Experimental, and follow its progress
    \\  install-proton ge           download and verify the latest GE-Proton into Steam's compatibilitytools.d
    \\  help                        show this text
    \\  version                     print the version
    \\
    \\A game is named by its id (from `list`), its Steam app id, or its name.
    \\
    \\Settings:
    \\  runner=auto|native|<Proton name>|</path/to/wine>
    \\  display=normal|gamescope
    \\  upscaling=off|fsr|nis|optiscaler      fsr and nis run in gamescope
    \\  scale=100|77|67|59|50                 render scale for fsr and nis, in %
    \\  hdr=on|off
    \\  env=NAME=value                        repeat for more; env= clears them
    \\  args="..."                            extra game arguments
    \\  gamescope-args="..."                  extra gamescope arguments
    \\
    \\Veneer is free software under GPL-3.0-or-later, with NO WARRANTY.
    \\
;

const testing = std.testing;

test "no arguments opens the window" {
    try testing.expectEqual(Verb.window, (try parse(&.{})).verb);
}

test "every spelling maps to its verb and keeps the rest" {
    for (spellings) |s| {
        const cmd = try parse(&.{ s.word, "x" });
        try testing.expectEqual(s.verb, cmd.verb);
        try testing.expectEqualStrings("x", cmd.rest[0]);
    }
    try testing.expectError(error.UnknownCommand, parse(&.{"lanch"}));
}

test "flags take a following or an attached value" {
    const f: Flags = .{ .args = &.{ "--name", "Hades", "--fsr=67", "--gamescope" } };
    try testing.expectEqualStrings("Hades", f.value("--name").?);
    try testing.expectEqualStrings("67", f.value("--fsr").?);
    try testing.expect(f.has("--gamescope"));
    try testing.expect(f.value("--gamescope") == null);
    try testing.expect(f.value("--missing") == null);
}

test "the positional argument skips flags and their values" {
    const f: Flags = .{ .args = &.{ "--name", "Hades", "/g/hades.exe", "--", "-x" } };
    try testing.expectEqualStrings("/g/hades.exe", f.positional(&.{"--name"}).?);
    try testing.expectEqualStrings("-x", f.afterDashes()[0]);
    const dashed: Flags = .{ .args = &.{ "--", "-weird-name" } };
    try testing.expectEqualStrings("-weird-name", dashed.positional(&.{}).?);
}
