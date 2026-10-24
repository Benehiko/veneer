const std = @import("std");

pub const ext4: usize = 0xEF53;

const network = [_]u32{
    0x6969,
    0x517b,
    0xff534d42,
    0xfe534d42,
};

pub fn isNetwork(f_type: usize) bool {
    const low: u32 = @truncate(f_type);
    for (network) |magic| {
        if (low == magic) return true;
    }
    return false;
}

pub fn local(f_type: usize) usize {
    return if (isNetwork(f_type)) ext4 else f_type;
}

const testing = std.testing;

test "network filesystems read as ext4; every other type is kept" {
    try testing.expectEqual(ext4, local(0x6969));
    try testing.expectEqual(ext4, local(0x517b));
    try testing.expectEqual(ext4, local(0xff534d42));
    try testing.expectEqual(ext4, local(0xfe534d42));
    try testing.expectEqual(@as(usize, 0x9123683E), local(0x9123683E));
    try testing.expectEqual(@as(usize, 0x01021994), local(0x01021994));
}

test "a type sign-extended by a 64-bit long still counts as network" {
    const cifs_as_long: usize = @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0xff534d42)))));
    try testing.expect(isNetwork(cifs_as_long));
}
