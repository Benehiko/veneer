const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Device = struct {
    vendor_id: u32,
    name: []const u8,
    driver_name: []const u8,
    driver_info: []const u8,
    discrete: bool,
};

const Handle = ?*anyopaque;
const Result = i32;
const PfnVoid = ?*const fn () callconv(.c) void;

const ApplicationInfo = extern struct {
    s_type: u32 = 0,
    p_next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32,
};

const InstanceCreateInfo = extern struct {
    s_type: u32 = 1,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    application_info: ?*const ApplicationInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?*const anyopaque = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?*const anyopaque = null,
};

const DriverProperties = extern struct {
    s_type: u32 = 1000196000,
    p_next: ?*anyopaque = null,
    driver_id: u32 = 0,
    driver_name: [256]u8 = @splat(0),
    driver_info: [256]u8 = @splat(0),
    conformance_version: [4]u8 = @splat(0),
};

const Properties2 = extern struct {
    s_type: u32 = 1000059001,
    p_next: ?*anyopaque = null,
    properties: [2048]u8 align(8) = @splat(0),
};

const vendor_id_offset = 8;
const device_type_offset = 16;
const device_name_offset = 20;
const discrete_gpu = 2;
const api_1_1 = (1 << 22) | (1 << 12);

const GetInstanceProcAddr = *const fn (Handle, [*:0]const u8) callconv(.c) PfnVoid;
const CreateInstance = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Handle) callconv(.c) Result;
const DestroyInstance = *const fn (Handle, ?*const anyopaque) callconv(.c) void;
const EnumeratePhysicalDevices = *const fn (Handle, *u32, ?[*]Handle) callconv(.c) Result;
const GetPhysicalDeviceProperties2 = *const fn (Handle, *Properties2) callconv(.c) void;

pub const Error = Allocator.Error || error{
    NoLoader,
    MissingEntryPoint,
    InstanceFailed,
    EnumerateFailed,
};

pub fn explain(err: Error) []const u8 {
    return switch (err) {
        error.NoLoader => "libvulkan.so.1 could not be loaded (install the Vulkan loader)",
        error.MissingEntryPoint => "the Vulkan loader lacks a Vulkan 1.1 entry point",
        error.InstanceFailed => "the Vulkan loader found no usable driver (vkCreateInstance failed)",
        error.EnumerateFailed => "listing Vulkan devices failed",
        error.OutOfMemory => "out of memory",
    };
}

pub fn devices(arena: Allocator) Error![]const Device {
    var lib = std.DynLib.open("libvulkan.so.1") catch return error.NoLoader;
    defer lib.close();
    const gipa = lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingEntryPoint;

    const create: CreateInstance = @ptrCast(gipa(null, "vkCreateInstance") orelse return error.MissingEntryPoint);
    const app: ApplicationInfo = .{ .application_name = "veneer", .api_version = api_1_1 };
    var instance: Handle = null;
    if (create(&.{ .application_info = &app }, null, &instance) != 0) return error.InstanceFailed;
    const destroy: DestroyInstance = @ptrCast(gipa(instance, "vkDestroyInstance") orelse return error.MissingEntryPoint);
    defer destroy(instance, null);

    const enumerate: EnumeratePhysicalDevices = @ptrCast(gipa(instance, "vkEnumeratePhysicalDevices") orelse return error.MissingEntryPoint);
    const props2: GetPhysicalDeviceProperties2 = @ptrCast(gipa(instance, "vkGetPhysicalDeviceProperties2") orelse return error.MissingEntryPoint);

    var count: u32 = 0;
    if (enumerate(instance, &count, null) != 0) return error.EnumerateFailed;
    const handles = try arena.alloc(Handle, count);
    if (enumerate(instance, &count, handles.ptr) < 0) return error.EnumerateFailed;

    const out = try arena.alloc(Device, count);
    for (handles[0..count], out) |h, *d| {
        var driver: DriverProperties = .{};
        var props: Properties2 = .{ .p_next = &driver };
        props2(h, &props);
        d.* = .{
            .vendor_id = std.mem.readInt(u32, props.properties[vendor_id_offset..][0..4], .little),
            .discrete = std.mem.readInt(u32, props.properties[device_type_offset..][0..4], .little) == discrete_gpu,
            .name = try arena.dupe(u8, std.mem.sliceTo(props.properties[device_name_offset..][0..256], 0)),
            .driver_name = try arena.dupe(u8, std.mem.sliceTo(&driver.driver_name, 0)),
            .driver_info = try arena.dupe(u8, std.mem.sliceTo(&driver.driver_info, 0)),
        };
    }
    return out;
}
