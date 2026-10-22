const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const gamescope = @import("../launch/gamescope.zig");
const vulkan = @import("vulkan.zig");

pub const Version = struct {
    major: u32,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn parse(text: []const u8) ?Version {
        var i: usize = 0;
        while (i < text.len and !std.ascii.isDigit(text[i])) i += 1;
        if (i == text.len) return null;
        var parts = [3]u32{ 0, 0, 0 };
        var n: usize = 0;
        while (n < 3 and i < text.len and std.ascii.isDigit(text[i])) : (n += 1) {
            const start = i;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
            parts[n] = std.fmt.parseInt(u32, text[start..i], 10) catch return null;
            if (i < text.len and text[i] == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) i += 1 else {
                n += 1;
                break;
            }
        }
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    pub fn format(v: Version, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    }
};

pub const Vendor = enum { amd, nvidia, intel, other };

pub fn vendorFromId(id: u32) Vendor {
    return switch (id) {
        0x1002 => .amd,
        0x10de => .nvidia,
        0x8086 => .intel,
        else => .other,
    };
}

pub const Gpu = struct {
    vendor: Vendor,
    kernel_driver: []const u8,
};

pub const Facts = struct {
    kernel: ?Version = null,
    gpus: []const Gpu = &.{},
    vk: []const vulkan.Device = &.{},
    vk_error: ?[]const u8 = null,
    mesa: ?Version = null,
    nvidia: ?Version = null,
    rocm: ?Version = null,
    rocm_present: bool = false,
    userns: bool = false,
    gamescope: gamescope.Caps = .{},

    pub fn primaryDevice(self: Facts) ?vulkan.Device {
        for (self.vk) |d| {
            if (d.discrete) return d;
        }
        return if (self.vk.len > 0) self.vk[0] else null;
    }

    pub fn primaryVendor(self: Facts) ?Vendor {
        if (self.primaryDevice()) |d| return vendorFromId(d.vendor_id);
        if (self.gpus.len > 0) return self.gpus[0].vendor;
        return null;
    }

    pub fn vulkanApi(self: Facts) ?Version {
        const d = self.primaryDevice() orelse return null;
        return if (d.api_version == 0) null else apiVersion(d.api_version);
    }
};

pub fn apiVersion(packed_version: u32) Version {
    return .{
        .major = (packed_version >> 22) & 0x7f,
        .minor = (packed_version >> 12) & 0x3ff,
        .patch = packed_version & 0xfff,
    };
}

pub fn mesaFrom(devices: []const vulkan.Device) ?Version {
    for (devices) |d| {
        if (std.mem.startsWith(u8, d.driver_info, "Mesa")) return Version.parse(d.driver_info);
    }
    return null;
}

pub fn nvidiaFrom(devices: []const vulkan.Device) ?Version {
    for (devices) |d| {
        if (vendorFromId(d.vendor_id) == .nvidia and !std.mem.startsWith(u8, d.driver_info, "Mesa")) return Version.parse(d.driver_info);
    }
    return null;
}

pub fn usernsAllowed(unprivileged_clone: ?[]const u8, max_namespaces: ?[]const u8, apparmor_restrict: ?[]const u8) bool {
    if (unprivileged_clone) |v| {
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \n"), "0")) return false;
    }
    if (max_namespaces) |v| {
        const n = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \n"), 10) catch 1;
        if (n == 0) return false;
    }
    if (apparmor_restrict) |v| {
        if (std.mem.eql(u8, std.mem.trim(u8, v, " \n"), "1")) return false;
    }
    return true;
}

fn readSmall(io: Io, path: []const u8, buf: []u8) ?[]const u8 {
    return Io.Dir.cwd().readFile(io, path, buf) catch null;
}

pub fn probe(arena: Allocator, io: Io) !Facts {
    var facts: Facts = .{};

    var uts: std.os.linux.utsname = undefined;
    if (std.os.linux.uname(&uts) == 0) facts.kernel = Version.parse(std.mem.sliceTo(&uts.release, 0));

    var b1: [16]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [16]u8 = undefined;
    facts.userns = usernsAllowed(
        readSmall(io, "/proc/sys/kernel/unprivileged_userns_clone", &b1),
        readSmall(io, "/proc/sys/user/max_user_namespaces", &b2),
        readSmall(io, "/proc/sys/kernel/apparmor_restrict_unprivileged_userns", &b3),
    );

    facts.gpus = try sysfsGpus(arena, io);
    facts.vk = vulkan.devices(arena) catch |err| blk: {
        facts.vk_error = vulkan.explain(err);
        break :blk &.{};
    };
    facts.mesa = mesaFrom(facts.vk);
    facts.nvidia = nvidiaFrom(facts.vk);

    if (Io.Dir.cwd().access(io, "/opt/rocm", .{})) |_| {
        facts.rocm_present = true;
        var vb: [64]u8 = undefined;
        if (readSmall(io, "/opt/rocm/.info/version", &vb)) |text| facts.rocm = Version.parse(text);
    } else |_| {}

    facts.gamescope = gamescope.probe(arena, io);
    return facts;
}

fn sysfsGpus(arena: Allocator, io: Io) ![]const Gpu {
    var out: std.ArrayList(Gpu) = .empty;
    var dir = Io.Dir.cwd().openDir(io, "/sys/class/drm", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "card") or std.mem.indexOfScalar(u8, entry.name, '-') != null) continue;
        var path_buf: [256]u8 = undefined;
        var buf: [16]u8 = undefined;
        const vendor_path = std.fmt.bufPrint(&path_buf, "{s}/device/vendor", .{entry.name}) catch continue;
        const text = dir.readFile(io, vendor_path, &buf) catch continue;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 0) catch continue;
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const driver_path = std.fmt.bufPrint(&path_buf, "{s}/device/driver", .{entry.name}) catch continue;
        const len = dir.readLink(io, driver_path, &link_buf) catch 0;
        try out.append(arena, .{
            .vendor = vendorFromId(id),
            .kernel_driver = try arena.dupe(u8, std.fs.path.basename(link_buf[0..len])),
        });
    }
    return out.items;
}

const testing = std.testing;

test "versions parse out of kernel, Mesa and driver strings" {
    try testing.expectEqual(Version{ .major = 6, .minor = 17, .patch = 2 }, Version.parse("6.17.2-arch1-1").?);
    try testing.expectEqual(Version{ .major = 25, .minor = 2, .patch = 4 }, Version.parse("Mesa 25.2.4-arch1.1").?);
    try testing.expectEqual(Version{ .major = 580, .minor = 95 }, Version.parse("580.95").?);
    try testing.expectEqual(Version{ .major = 7 }, Version.parse("7").?);
    try testing.expectEqual(Version{ .major = 6, .minor = 4 }, Version.parse("6.4.").?);
    try testing.expect(Version.parse("none") == null);
}

test "versions order component by component" {
    const v = Version.parse;
    try testing.expectEqual(std.math.Order.lt, v("5.10.200").?.order(v("5.11").?));
    try testing.expectEqual(std.math.Order.gt, v("25.10").?.order(v("25.2.9").?));
    try testing.expectEqual(std.math.Order.eq, v("6.0").?.order(v("6.0.0").?));
}

test "any one restricting sysctl turns user namespaces off" {
    try testing.expect(usernsAllowed(null, null, null));
    try testing.expect(usernsAllowed("1\n", "63000\n", "0\n"));
    try testing.expect(!usernsAllowed("0\n", null, null));
    try testing.expect(!usernsAllowed(null, "0\n", null));
    try testing.expect(!usernsAllowed(null, null, "1\n"));
}

test "Mesa and NVIDIA versions come from the Vulkan driver info" {
    const devs = [_]vulkan.Device{
        .{ .vendor_id = 0x10de, .name = "RTX", .driver_name = "NVIDIA", .driver_info = "580.95.05", .discrete = true },
        .{ .vendor_id = 0x1002, .name = "Radeon", .driver_name = "radv", .driver_info = "Mesa 25.2.4", .discrete = false },
    };
    try testing.expectEqual(@as(u32, 25), mesaFrom(&devs).?.major);
    try testing.expectEqual(@as(u32, 580), nvidiaFrom(&devs).?.major);
    const facts: Facts = .{ .vk = &devs };
    try testing.expectEqual(Vendor.nvidia, facts.primaryVendor().?);
}

test "the Vulkan version is the discrete GPU's, unpacked from Vulkan's encoding" {
    const vk_1_3_280 = (1 << 22) | (3 << 12) | 280;
    const vk_1_4_309 = (1 << 22) | (4 << 12) | 309;
    const devs = [_]vulkan.Device{
        .{ .api_version = vk_1_4_309, .vendor_id = 0x8086, .name = "iGPU", .driver_name = "anv", .driver_info = "Mesa 25.2.4", .discrete = false },
        .{ .api_version = vk_1_3_280, .vendor_id = 0x1002, .name = "dGPU", .driver_name = "radv", .driver_info = "Mesa 25.2.4", .discrete = true },
    };
    const facts: Facts = .{ .vk = &devs };
    try testing.expectEqual(Version{ .major = 1, .minor = 3, .patch = 280 }, facts.vulkanApi().?);
    try testing.expect((Facts{}).vulkanApi() == null);
}
