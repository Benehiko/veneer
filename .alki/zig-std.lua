local zig_std = {
  name = "zig-std",
  version = "1",
  permissions = { "files" },
}

zig_std.files = {
  read = { "/usr/lib/zig" },
}

return zig_std
