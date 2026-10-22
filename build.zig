const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("build.zig"), b.path("src") };
    b.step("fmt", "Format the Zig sources in place").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);

    if (target.result.os.tag != .linux) {
        const fail = b.addFail(b.fmt(
            "veneer runs on Linux only; {s} is not supported. Build with -Dtarget=x86_64-linux-gnu or -Dtarget=aarch64-linux-gnu",
            .{@tagName(target.result.os.tag)},
        ));
        b.getInstallStep().dependOn(&fail.step);
        b.step("test", "Run unit tests").dependOn(&fail.step);
        return;
    }

    const build_info = b.createModule(.{
        .root_source_file = b.path("src/build_info.zig"),
        .imports = &.{.{ .name = "build_options", .module = buildOptions(b) }},
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_info", .module = build_info }},
    });
    root.addAnonymousImport("compat_rules", .{ .root_source_file = b.path("data/compat.tsv") });

    const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3gpu });
    root.addImport("dvui", dvui_dep.module("dvui_sdl3gpu"));
    root.addImport("sdl3gpu-backend", dvui_dep.module("sdl3gpu"));

    const exe = b.addExecutable(.{ .name = "veneer", .root_module = root });
    b.installArtifact(exe);

    const injector = b.addExecutable(.{
        .name = "veneer-inject",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inject/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
            .optimize = optimize,
        }),
    });
    b.installArtifact(injector);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Build and run veneer").dependOn(&run.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
}

fn buildOptions(b: *std.Build) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", b.option(
        []const u8,
        "version",
        "version stamped into the binary (default: git describe)",
    ) orelse describeVersion(b));
    return opts.createModule();
}

fn describeVersion(b: *std.Build) []const u8 {
    b.graph.poisonCache();
    const root = b.root.toString(b.allocator) catch @panic("OOM");
    const out = switch (b.runFallible(
        &.{ "git", "-C", root, "describe", "--tags", "--dirty", "--always" },
        .{ .stderr_behavior = .ignore },
    )) {
        .success => |stdout| stdout,
        else => return "unknown",
    };
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return if (trimmed.len == 0) "unknown" else b.dupe(trimmed);
}
