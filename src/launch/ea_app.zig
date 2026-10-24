const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vdf = @import("../library/vdf.zig");
const steam = @import("../library/steam.zig");

pub const Installer = struct {
    exe: []const u8,
    args: []const u8,
    done_key: []const u8,
    done_value: []const u8,
};

const install_dir_var = "%INSTALLDIR%";
const hklm = "HKEY_LOCAL_MACHINE\\";

pub fn isEaUrl(exe: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(exe, "link2ea://") or std.ascii.startsWithIgnoreCase(exe, "steam2ea://");
}

pub fn fromScript(arena: Allocator, script: vdf.Object, install_dir: []const u8) Allocator.Error!?Installer {
    const processes = script.path(&.{ "installscript", "Run Process" }) orelse return null;
    for (processes.pairs) |pair| {
        const entry = switch (pair.value) {
            .object => |o| o,
            .string => continue,
        };
        const key = entry.string("HasRunStringKey") orelse continue;
        if (std.ascii.findIgnoreCase(key, "\\Electronic Arts\\") == null) continue;
        const process = entry.string("process 1") orelse continue;
        if (!std.ascii.startsWithIgnoreCase(process, install_dir_var)) continue;
        return .{
            .exe = try steam.joinGamePath(arena, install_dir, process[install_dir_var.len..]),
            .args = entry.string("command 1") orelse "",
            .done_key = key,
            .done_value = entry.string("HasRunStringValue") orelse "",
        };
    }
    return null;
}

pub fn hasRun(system_reg: []const u8, full_key: []const u8, expected: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(full_key, hklm)) return false;
    const rest = full_key[hklm.len..];
    const cut = std.mem.lastIndexOfScalar(u8, rest, '\\') orelse return false;
    const key = rest[0..cut];
    const name = rest[cut + 1 ..];

    var in_key = false;
    var lines = std.mem.splitScalar(u8, system_reg, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "[")) {
            in_key = sectionIs(line, key);
        } else if (in_key and valueIs(line, name, expected)) {
            return true;
        }
    }
    return false;
}

fn sectionIs(line: []const u8, key: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, line, ']') orelse return false;
    const section = line[1..end];
    if (regPathEql(section, key)) return true;
    const software = "SOFTWARE\\";
    const wow = "Software\\\\Wow6432Node\\\\";
    return std.ascii.startsWithIgnoreCase(key, software) and
        std.ascii.startsWithIgnoreCase(section, wow) and
        regPathEql(section[wow.len..], key[software.len..]);
}

fn regPathEql(section: []const u8, key: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < section.len and j < key.len) : (j += 1) {
        if (key[j] == '\\') {
            if (!std.mem.startsWith(u8, section[i..], "\\\\")) return false;
            i += 2;
            continue;
        }
        if (std.ascii.toLower(section[i]) != std.ascii.toLower(key[j])) return false;
        i += 1;
    }
    return i == section.len and j == key.len;
}

fn valueIs(line: []const u8, name: []const u8, expected: []const u8) bool {
    if (line.len < name.len + 1 or line[0] != '"') return false;
    if (!std.ascii.eqlIgnoreCase(line[1 .. 1 + name.len], name)) return false;
    const rest = line[1 + name.len ..];
    if (!std.mem.startsWith(u8, rest, "\"=\"") or !std.mem.endsWith(u8, rest, "\"")) return false;
    if (rest.len < 4) return false;
    return std.ascii.eqlIgnoreCase(rest[3 .. rest.len - 1], expected);
}

pub fn find(arena: Allocator, io: Io, install_dir: []const u8) !?Installer {
    var dir = Io.Dir.cwd().openDir(io, install_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, "installscript.vdf")) continue;
        const text = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
        const script = vdf.parse(arena, text) catch continue;
        const installer = try fromScript(arena, script, install_dir) orelse continue;
        Io.Dir.cwd().access(io, installer.exe, .{}) catch {
            std.log.warn("{s} names {s}, which is missing; verify the game's files in Steam", .{ entry.name, installer.exe });
            continue;
        };
        return installer;
    }
    return null;
}

pub fn pending(arena: Allocator, io: Io, exe: []const u8, install_dir: []const u8, system_reg: []const u8) !?Installer {
    if (!isEaUrl(exe)) return null;
    const installer = try find(arena, io, install_dir) orelse return null;
    const reg = Io.Dir.cwd().readFileAlloc(io, system_reg, arena, .limited(512 << 20)) catch "";
    if (hasRun(reg, installer.done_key, installer.done_value)) return null;
    return installer;
}

const testing = std.testing;

const script_fixture =
    \\"installscript"
    \\{
    \\  "Run Process"
    \\  {
    \\    "DirectX" { "process 1" "%INSTALLDIR%\\__Installer\\directx\\DXSETUP.exe" "HasRunKey" "HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\1" }
    \\    "EADesktopSetup"
    \\    {
    \\      "process 1" "%INSTALLDIR%\\__Installer\\Origin\\redist\\internal\\EAappInstaller.exe"
    \\      "command 1" "EAX_LAUNCH_CLIENT=0 IGNORE_INSTALLED=1"
    \\      "HasRunStringKey" "HKEY_LOCAL_MACHINE\\SOFTWARE\\Electronic Arts\\EA Desktop\\InstallSuccessful"
    \\      "HasRunStringValue" "true"
    \\    }
    \\  }
    \\}
;

test "the EA app installer comes from the install script's Run Process entry for EA Desktop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = try vdf.parse(a, script_fixture);
    const inst = (try fromScript(a, script, "/lib/common/NFS")).?;
    try testing.expectEqualStrings("/lib/common/NFS/__Installer/Origin/redist/internal/EAappInstaller.exe", inst.exe);
    try testing.expectEqualStrings("EAX_LAUNCH_CLIENT=0 IGNORE_INSTALLED=1", inst.args);
    try testing.expectEqualStrings("true", inst.done_value);

    const none = try vdf.parse(a, "\"installscript\" { \"Registry\" { } }");
    try testing.expect(try fromScript(a, none, "/x") == null);
}

test "the installer has run when the registry holds its marker, in either registry view" {
    const key = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Electronic Arts\\EA Desktop\\InstallSuccessful";
    const done =
        "WINE REGISTRY Version 2\n\n[Software\\\\Electronic Arts\\\\EA Desktop] 1729784000\n" ++
        "#time=1db2\n\"ClientPath\"=\"C:\\\\x\"\n\"InstallSuccessful\"=\"true\"\n";
    try testing.expect(hasRun(done, key, "true"));
    try testing.expect(!hasRun(done, key, "false"));

    const wow = "[Software\\\\Wow6432Node\\\\Electronic Arts\\\\EA Desktop] 1\r\n\"installsuccessful\"=\"TRUE\"\r\n";
    try testing.expect(hasRun(wow, key, "true"));

    const elsewhere = "[Software\\\\Electronic Arts\\\\EA Desktop\\\\Other] 1\n\"InstallSuccessful\"=\"true\"\n" ++
        "[Software\\\\Electronic Arts\\\\EA Desktop] 1\n\"Version\"=\"13\"\n";
    try testing.expect(!hasRun(elsewhere, key, "true"));
    try testing.expect(!hasRun("", key, "true"));
    try testing.expect(!hasRun(done, "HKEY_CURRENT_USER\\Software\\Electronic Arts\\EA Desktop\\InstallSuccessful", "true"));
}

test "only EA launcher URLs need the EA app" {
    try testing.expect(isEaUrl("steam2ea://launchgame/1328660?platform=steam"));
    try testing.expect(isEaUrl("LINK2EA://launchgame/1"));
    try testing.expect(!isEaUrl("/lib/common/Game/game.exe"));
    try testing.expect(!isEaUrl("steam://rungameid/1"));
}
