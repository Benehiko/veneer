const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const latest_api = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest";

pub const Asset = struct {
    name: []const u8,
    browser_download_url: []const u8,
    digest: ?[]const u8 = null,
};

pub const Release = struct {
    tag_name: []const u8,
    assets: []const Asset = &.{},
};

pub const Pick = struct {
    tag: []const u8,
    url: []const u8,
    sha256: [32]u8,
};

pub fn parseRelease(arena: Allocator, json: []const u8) !Release {
    return std.json.parseFromSliceLeaky(Release, arena, json, .{ .ignore_unknown_fields = true });
}

pub fn archSuffix(arch: std.Target.Cpu.Arch) []const u8 {
    return if (arch == .aarch64) "-aarch64.tar.gz" else "-x86_64.tar.gz";
}

pub fn pick(release: Release, arch: std.Target.Cpu.Arch) error{ NoAsset, NoDigest }!Pick {
    var chosen: ?Asset = null;
    for (release.assets) |a| {
        if (std.mem.endsWith(u8, a.name, archSuffix(arch))) chosen = a;
    }
    if (chosen == null and arch == .x86_64) {
        for (release.assets) |a| {
            if (std.mem.endsWith(u8, a.name, ".tar.gz") and std.mem.startsWith(u8, a.name, release.tag_name) and
                a.name.len == release.tag_name.len + ".tar.gz".len) chosen = a;
        }
    }
    const asset = chosen orelse return error.NoAsset;
    const digest = asset.digest orelse return error.NoDigest;
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix) or digest.len != prefix.len + 64) return error.NoDigest;
    var out: Pick = .{ .tag = release.tag_name, .url = asset.browser_download_url, .sha256 = undefined };
    _ = std.fmt.hexToBytes(&out.sha256, digest[prefix.len..]) catch return error.NoDigest;
    return out;
}

pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return false;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn linkStaysInside(link_path: []const u8, target: []const u8) bool {
    if (target.len == 0 or target[0] == '/') return false;
    var depth: isize = 0;
    var base = std.mem.tokenizeScalar(u8, std.fs.path.dirname(link_path) orelse "", '/');
    while (base.next()) |part| {
        if (!std.mem.eql(u8, part, ".")) depth += 1;
    }
    var it = std.mem.tokenizeScalar(u8, target, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return false;
        } else depth += 1;
    }
    return true;
}

pub fn throughLink(name: []const u8, links: []const []const u8) bool {
    for (links) |l| {
        if (name.len > l.len and std.mem.startsWith(u8, name, l) and name[l.len] == '/') return true;
    }
    return false;
}

pub const Compression = enum { gzip, zstd };

pub const zstd_window_len = 1 << 25;

pub fn extract(arena: Allocator, io: Io, archive: []const u8, compression: Compression, dest: Io.Dir) !void {
    const file = try Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &file_buf);
    switch (compression) {
        .gzip => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var gz: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &window);
            try extractTar(arena, io, &gz.reader, dest);
        },
        .zstd => {
            const window = try arena.alloc(u8, zstd_window_len + std.compress.zstd.block_size_max);
            var zs: std.compress.zstd.Decompress = .init(&file_reader.interface, window, .{ .window_len = zstd_window_len });
            try extractTar(arena, io, &zs.reader, dest);
        },
    }
}

pub fn extractTar(arena: Allocator, io: Io, reader: *Io.Reader, dest: Io.Dir) !void {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var links: std.ArrayList([]const u8) = .empty;
    var write_buf: [64 * 1024]u8 = undefined;

    while (try it.next()) |entry| {
        const name = std.mem.trimEnd(u8, entry.name, "/");
        if (name.len == 0) continue;
        if (!safeName(name) or throughLink(name, links.items)) return error.UnsafeArchive;
        switch (entry.kind) {
            .directory => try dest.createDirPath(io, name),
            .sym_link => {
                if (!linkStaysInside(name, entry.link_name)) return error.UnsafeArchive;
                if (std.fs.path.dirname(name)) |parent| try dest.createDirPath(io, parent);
                try dest.symLink(io, entry.link_name, name, .{});
                try links.append(arena, try arena.dupe(u8, name));
            },
            .file => {
                if (std.fs.path.dirname(name)) |parent| try dest.createDirPath(io, parent);
                const executable = entry.mode & 0o100 != 0;
                const out = try dest.createFile(io, name, .{
                    .exclusive = true,
                    .permissions = if (executable) .executable_file else .default_file,
                });
                defer out.close(io);
                var w = out.writer(io, &write_buf);
                try it.streamRemaining(entry, &w.interface);
                try w.interface.flush();
            },
        }
    }
}

pub fn fetchLatest(arena: Allocator, gpa: Allocator, io: Io) !Pick {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(arena);
    const result = client.fetch(.{
        .location = .{ .url = latest_api },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "veneer" } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/vnd.github+json" }},
    }) catch return error.DownloadFailed;
    if (result.status != .ok) return error.DownloadFailed;
    return pick(try parseRelease(arena, body.written()), builtin.cpu.arch);
}

pub fn install(arena: Allocator, gpa: Allocator, io: Io, steam_root: []const u8) !struct { tag: []const u8, dir: []const u8 } {
    const choice = try fetchLatest(arena, gpa, io);
    const tools = try std.fs.path.join(arena, &.{ steam_root, "compatibilitytools.d" });
    if (try installedBuild(arena, io, tools, choice.tag)) |name| {
        return .{ .tag = name, .dir = try std.fs.path.join(arena, &.{ tools, name }) };
    }
    try Io.Dir.cwd().createDirPath(io, tools);

    const archive = try std.fs.path.join(arena, &.{ tools, try std.fmt.allocPrint(arena, ".download-{s}.tar.gz", .{choice.tag}) });
    defer Io.Dir.cwd().deleteFile(io, archive) catch {};
    try download(gpa, io, choice.url, archive, choice.sha256);

    const tmp = try std.fs.path.join(arena, &.{ tools, try std.fmt.allocPrint(arena, ".unpack-{s}", .{choice.tag}) });
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    {
        var dest = try Io.Dir.cwd().openDir(io, tmp, .{});
        defer dest.close(io);
        try extract(arena, io, archive, .gzip, dest);
    }
    const name = try buildDir(arena, io, tmp);
    const installed = try std.fs.path.join(arena, &.{ tools, name });
    Io.Dir.cwd().access(io, installed, .{}) catch {
        try Io.Dir.rename(Io.Dir.cwd(), try std.fs.path.join(arena, &.{ tmp, name }), Io.Dir.cwd(), installed, io);
        return .{ .tag = name, .dir = installed };
    };
    return error.AlreadyInstalled;
}

pub fn isBuildOf(dir_name: []const u8, tag: []const u8) bool {
    return std.mem.eql(u8, dir_name, tag) or
        (std.mem.startsWith(u8, dir_name, tag) and dir_name.len > tag.len and dir_name[tag.len] == '-' and
            std.mem.indexOfScalar(u8, dir_name[tag.len + 1 ..], '-') == null and !std.ascii.isDigit(dir_name[tag.len + 1]));
}

fn installedBuild(arena: Allocator, io: Io, tools: []const u8, tag: []const u8) !?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, tools, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!isBuildOf(entry.name, tag)) continue;
        const script = try std.fs.path.join(arena, &.{ entry.name, "proton" });
        dir.access(io, script, .{}) catch continue;
        return try arena.dupe(u8, entry.name);
    }
    return null;
}

fn buildDir(arena: Allocator, io: Io, root: []const u8) ![]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const script = try std.fs.path.join(arena, &.{ entry.name, "proton" });
        dir.access(io, script, .{}) catch continue;
        return arena.dupe(u8, entry.name);
    }
    return error.NotAProtonBuild;
}

pub fn download(gpa: Allocator, io: Io, url: []const u8, dest: []const u8, want: [32]u8) !void {
    {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        const file = try Io.Dir.cwd().createFile(io, dest, .{});
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var w = file.writerStreaming(io, &buf);
        const result = client.fetch(.{ .location = .{ .url = url }, .response_writer = &w.interface }) catch return error.DownloadFailed;
        try w.interface.flush();
        if (result.status != .ok) return error.DownloadFailed;
    }
    const file = try Io.Dir.cwd().openFile(io, dest, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var r = file.readerStreaming(io, &buf);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hasher.update(chunk);
        r.interface.toss(chunk.len);
    }
    var got: [32]u8 = undefined;
    hasher.final(&got);
    if (!std.crypto.timing_safe.eql([32]u8, got, want)) return error.ChecksumMismatch;
}

pub fn explain(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.DownloadFailed => "could not reach GitHub to download GE-Proton",
        error.NoAsset => "the latest GE-Proton release has no build for this CPU",
        error.NoDigest => "GitHub publishes no checksum for that GE-Proton build, so Veneer will not install it",
        error.ChecksumMismatch => "the GE-Proton download does not match GitHub's checksum; nothing was installed",
        error.UnsafeArchive => "the GE-Proton archive holds paths or links outside its folder; nothing was installed",
        error.NotAProtonBuild => "the GE-Proton archive holds no proton script",
        error.AlreadyInstalled => "that GE-Proton build is already in compatibilitytools.d",
        else => null,
    };
}

const testing = std.testing;

const sample_release =
    \\{"tag_name":"GE-Proton11-11","assets":[
    \\ {"name":"GE-Proton11-11-aarch64.tar.gz","browser_download_url":"https://x/a.tar.gz","digest":"sha256:c70eb3cc1c48a4cf1719d643c86fc069060fc6a1fecb490ec03295f2f7541ad1"},
    \\ {"name":"GE-Proton11-11-x86_64.sha512sum","browser_download_url":"https://x/s","digest":"sha256:ef6b808f788ca07351e64740e8664bfdedb18e0c20072431525f13f7bfca0a9c"},
    \\ {"name":"GE-Proton11-11-x86_64.tar.gz","browser_download_url":"https://x/x.tar.gz","digest":"sha256:aa85986cada5709aa8bbfa8add7f3bfb925cbe15710c98995898d308ff2ca3c1","size":1}
    \\]}
;

test "the build for this CPU is picked, with its digest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const release = try parseRelease(arena.allocator(), sample_release);
    const x86 = try pick(release, .x86_64);
    try testing.expectEqualStrings("https://x/x.tar.gz", x86.url);
    try testing.expectEqual(@as(u8, 0xaa), x86.sha256[0]);
    try testing.expectEqualStrings("https://x/a.tar.gz", (try pick(release, .aarch64)).url);
}

test "an older release named only by its tag still resolves; no digest means no install" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const old = try parseRelease(arena.allocator(),
        \\{"tag_name":"GE-Proton9-20","assets":[{"name":"GE-Proton9-20.tar.gz","browser_download_url":"https://x/o.tar.gz"}]}
    );
    try testing.expectError(error.NoDigest, pick(old, .x86_64));
    try testing.expectError(error.NoAsset, pick(old, .aarch64));
}

test "an installed build is recognised with or without its CPU suffix, never a later release" {
    try testing.expect(isBuildOf("GE-Proton11-11", "GE-Proton11-11"));
    try testing.expect(isBuildOf("GE-Proton11-11-x86_64", "GE-Proton11-11"));
    try testing.expect(!isBuildOf("GE-Proton11-110", "GE-Proton11-11"));
    try testing.expect(!isBuildOf("GE-Proton11-11-2", "GE-Proton11-11"));
    try testing.expect(!isBuildOf("GE-Proton11-1", "GE-Proton11-11"));
}

test "links may point anywhere inside the build, never outside it" {
    try testing.expect(linkStaysInside("GE/files/lib/libfoo.so", "libfoo.so.1"));
    try testing.expect(linkStaysInside("GE/files/lib64/x", "../lib/x"));
    try testing.expect(!linkStaysInside("GE/x", "../../etc/passwd"));
    try testing.expect(!linkStaysInside("GE/x", "/etc/passwd"));
    try testing.expect(!linkStaysInside("x", ".."));
}

test "entries may not climb out, or write through a link" {
    try testing.expect(safeName("GE/files/bin/wine"));
    try testing.expect(!safeName("../x"));
    try testing.expect(!safeName("/abs"));
    const links = [_][]const u8{"GE/escape"};
    try testing.expect(throughLink("GE/escape/passwd", &links));
    try testing.expect(!throughLink("GE/escaped", &links));
}
