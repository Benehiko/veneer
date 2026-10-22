const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const paths = @import("../paths.zig");
const releases = @import("releases.zig");
const unpack = @import("unpack.zig");
const stage = @import("../hooks/optiscaler.zig");

pub const guide = "docs/guides/optiscaler.md";

pub fn baseDir(arena: Allocator, env: *const Environ.Map) ![]const u8 {
    return std.fs.path.join(arena, &.{ try paths.dir(arena, env, .data), "optiscaler" });
}

pub fn installedDir(arena: Allocator, io: Io, env: *const Environ.Map, tag: []const u8) !?[]const u8 {
    const dir = try std.fs.path.join(arena, &.{ try baseDir(arena, env), tag });
    return unpack.releaseDir(arena, io, dir, stage.source_dll) catch null;
}

pub fn install(gpa: Allocator, arena: Allocator, io: Io, env: *const Environ.Map, release: releases.Release) ![]const u8 {
    if (try installedDir(arena, io, env, release.tag)) |dir| return dir;
    const tool = (try unpack.find(arena, io, env)) orelse return error.NoUnpacker;

    const base = try baseDir(arena, env);
    try Io.Dir.cwd().createDirPath(io, base);
    const archive = try std.fs.path.join(arena, &.{ base, try std.fmt.allocPrint(arena, ".download-{s}", .{release.fileName()}) });
    defer Io.Dir.cwd().deleteFile(io, archive) catch {};

    try download(gpa, io, release.url, archive);
    try verify(arena, io, archive, release.sha256);

    var tool_env = try unpack.childEnv(gpa, env);
    defer tool_env.deinit();

    const listing = try std.process.run(arena, io, .{
        .argv = try unpack.listArgv(arena, tool, archive),
        .environ_map = &tool_env,
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    if (!exitedZero(listing.term)) return error.UnpackFailed;
    try unpack.checkListing(try unpack.listedPaths(arena, tool.kind, listing.stdout));

    const tmp = try std.fs.path.join(arena, &.{ base, try std.fmt.allocPrint(arena, ".unpack-{s}", .{release.tag}) });
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    try Io.Dir.cwd().createDirPath(io, tmp);
    errdefer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    const extracted = try std.process.run(arena, io, .{
        .argv = try unpack.extractArgv(arena, tool, archive, tmp),
        .environ_map = &tool_env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    if (!exitedZero(extracted.term)) return error.UnpackFailed;
    _ = try unpack.releaseDir(arena, io, tmp, stage.source_dll);

    const final = try std.fs.path.join(arena, &.{ base, release.tag });
    Io.Dir.cwd().deleteTree(io, final) catch {};
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
    return unpack.releaseDir(arena, io, final, stage.source_dll);
}

fn exitedZero(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn download(gpa: Allocator, io: Io, url: []const u8, dest: []const u8) !void {
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

pub fn digestMatches(bytes: []const u8, want: [32]u8) bool {
    var got: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &got, .{});
    return std.crypto.timing_safe.eql([32]u8, got, want);
}

fn verify(arena: Allocator, io: Io, archive: []const u8, want: [32]u8) !void {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, archive, arena, .limited(1 << 30));
    if (!digestMatches(bytes, want)) return error.ChecksumMismatch;
}

pub fn explain(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoUnpacker => "no bsdtar, 7zz or 7z on PATH: install one (see " ++ guide ++ "), or extract the release yourself and choose its folder",
        error.DownloadFailed => "the download from GitHub failed; check the network and try again",
        error.ChecksumMismatch => "the download does not match the pinned SHA-256; Veneer deleted it and installed nothing",
        error.UnsafeArchive => "the archive holds paths outside its folder or symlinks; Veneer refused to unpack it",
        error.EmptyArchive => "the archive is empty",
        error.UnpackFailed => "the unpacker failed on this archive; try another of bsdtar, 7zz or 7z",
        error.NotAnOptiScalerRelease => "the archive holds no OptiScaler.dll",
        error.UnknownRelease => "Veneer has no pinned release with that tag; see `veneer optiscaler releases`",
        else => null,
    };
}

const testing = std.testing;

test "only the exact bytes match a pinned digest" {
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("archive", &want, .{});
    try testing.expect(digestMatches("archive", want));
    try testing.expect(!digestMatches("archivf", want));
}
