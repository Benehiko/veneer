const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const jobs = @import("jobs.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn toFile(gpa: Allocator, io: Io, url: []const u8, dest: []const u8, want: ?[32]u8, job: ?jobs.Job) !void {
    jobs.step(job, .downloading, std.fs.path.basename(url));
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var req = client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = "veneer" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch return error.DownloadFailed;
    defer req.deinit();
    req.sendBodiless() catch return error.DownloadFailed;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.DownloadFailed;
    if (response.head.status != .ok) return error.DownloadFailed;
    jobs.total(job, response.head.content_length orelse 0);

    const file = try Io.Dir.cwd().createFile(io, dest, .{});
    defer file.close(io);
    var write_buf: [64 * 1024]u8 = undefined;
    var w = file.writerStreaming(io, &write_buf);

    var transfer_buf: [64]u8 = undefined;
    const body = response.reader(&transfer_buf);
    var hasher = Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = body.readSliceShort(&chunk) catch return error.DownloadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..n]);
        w.interface.writeAll(chunk[0..n]) catch return error.DownloadFailed;
        jobs.advance(job, n);
    }
    w.interface.flush() catch return error.DownloadFailed;

    if (want) |expected| {
        jobs.step(job, .verifying, "");
        var got: [32]u8 = undefined;
        hasher.final(&got);
        if (!std.crypto.timing_safe.eql([32]u8, got, expected)) return error.ChecksumMismatch;
    }
}
