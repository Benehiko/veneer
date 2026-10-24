const std = @import("std");
const fs_type = @import("fs_type.zig");

const rtld_next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

const FdFn = *const fn (c_int, *anyopaque) callconv(.c) c_int;
const PathFn = *const fn ([*:0]const u8, *anyopaque) callconv(.c) c_int;

fn resolve(comptime T: type, comptime name: [*:0]const u8) ?T {
    const Cache = struct {
        var ptr: ?*anyopaque = null;
    };
    if (@atomicLoad(?*anyopaque, &Cache.ptr, .acquire)) |p| return @ptrCast(@alignCast(p));
    const p = std.c.dlsym(rtld_next, name) orelse return null;
    @atomicStore(?*anyopaque, &Cache.ptr, p, .release);
    return @ptrCast(@alignCast(p));
}

fn missing() c_int {
    std.c._errno().* = @backingInt(std.c.E.NOSYS);
    return -1;
}

fn patch(rc: c_int, buf: *anyopaque) c_int {
    if (rc == 0) {
        const f_type: *usize = @ptrCast(@alignCast(buf));
        f_type.* = fs_type.local(f_type.*);
    }
    return rc;
}

export fn fstatfs(fd: c_int, buf: *anyopaque) c_int {
    const real = resolve(FdFn, "fstatfs") orelse return missing();
    return patch(real(fd, buf), buf);
}

export fn fstatfs64(fd: c_int, buf: *anyopaque) c_int {
    const real = resolve(FdFn, "fstatfs64") orelse return missing();
    return patch(real(fd, buf), buf);
}

export fn statfs(path: [*:0]const u8, buf: *anyopaque) c_int {
    const real = resolve(PathFn, "statfs") orelse return missing();
    return patch(real(path, buf), buf);
}

export fn statfs64(path: [*:0]const u8, buf: *anyopaque) c_int {
    const real = resolve(PathFn, "statfs64") orelse return missing();
    return patch(real(path, buf), buf);
}
