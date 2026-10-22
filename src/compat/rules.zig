const std = @import("std");
const Allocator = std.mem.Allocator;
const facts_mod = @import("facts.zig");
const Facts = facts_mod.Facts;
const Version = facts_mod.Version;

pub const builtin_table = @embedFile("compat_rules");

pub const Feature = enum { any, overlay, inject, gamescope, hdr, optiscaler };

pub const Features = std.EnumSet(Feature);

pub const Severity = enum {
    info,
    warn,
    @"error",

    pub fn rank(s: Severity) u8 {
        return @backingInt(s);
    }
};

pub const Check = enum { kernel, mesa, nvidia, rocm, userns, gamescope, gamescope_hdr, vulkan, gpu };

pub const Op = enum {
    lt,
    le,
    gt,
    ge,
    eq,
    ne,

    fn parse(text: []const u8) ?Op {
        const table = [_]struct { []const u8, Op }{ .{ "<", .lt }, .{ "<=", .le }, .{ ">", .gt }, .{ ">=", .ge }, .{ "==", .eq }, .{ "!=", .ne } };
        for (table) |e| if (std.mem.eql(u8, text, e[0])) return e[1];
        return null;
    }

    fn holds(op: Op, o: std.math.Order) bool {
        return switch (op) {
            .lt => o == .lt,
            .le => o != .gt,
            .gt => o == .gt,
            .ge => o != .lt,
            .eq => o == .eq,
            .ne => o != .eq,
        };
    }
};

pub const Rule = struct {
    feature: Feature,
    check: Check,
    op: Op,
    value: []const u8,
    severity: Severity,
    message: []const u8,
    source: []const u8,
};

pub const Verdict = struct {
    feature: Feature,
    severity: Severity,
    message: []const u8,
    source: []const u8,
};

pub const ParseError = Allocator.Error || error{BadRule};

pub fn parse(arena: Allocator, text: []const u8) ParseError![]const Rule {
    var out: std.ArrayList(Rule) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var cols: [7][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, '\t');
        for (&cols) |*c| c.* = it.next() orelse return error.BadRule;
        if (it.next() != null) return error.BadRule;
        const rule: Rule = .{
            .feature = std.meta.stringToEnum(Feature, cols[0]) orelse return error.BadRule,
            .check = std.meta.stringToEnum(Check, cols[1]) orelse return error.BadRule,
            .op = Op.parse(cols[2]) orelse return error.BadRule,
            .value = cols[3],
            .severity = std.meta.stringToEnum(Severity, cols[4]) orelse return error.BadRule,
            .message = cols[5],
            .source = cols[6],
        };
        if (!valueFits(rule)) return error.BadRule;
        try out.append(arena, rule);
    }
    return out.items;
}

fn valueFits(r: Rule) bool {
    return switch (r.check) {
        .kernel, .mesa, .nvidia, .rocm => Version.parse(r.value) != null,
        .userns, .gamescope, .gamescope_hdr, .vulkan => (std.mem.eql(u8, r.value, "yes") or std.mem.eql(u8, r.value, "no")) and (r.op == .eq or r.op == .ne),
        .gpu => std.meta.stringToEnum(facts_mod.Vendor, r.value) != null and (r.op == .eq or r.op == .ne),
    };
}

fn fires(r: Rule, f: Facts) bool {
    switch (r.check) {
        .kernel, .mesa, .nvidia, .rocm => {
            const have = switch (r.check) {
                .kernel => f.kernel,
                .mesa => f.mesa,
                .nvidia => f.nvidia,
                .rocm => f.rocm,
                else => unreachable,
            } orelse return false;
            return r.op.holds(have.order(Version.parse(r.value).?));
        },
        .userns, .gamescope, .gamescope_hdr, .vulkan => {
            const have = switch (r.check) {
                .userns => f.userns,
                .gamescope => f.gamescope.present,
                .gamescope_hdr => f.gamescope.hdr,
                .vulkan => f.vk.len > 0,
                else => unreachable,
            };
            const want = std.mem.eql(u8, r.value, "yes");
            return (have == want) == (r.op == .eq);
        },
        .gpu => {
            const vendor = f.primaryVendor() orelse return false;
            const want = std.meta.stringToEnum(facts_mod.Vendor, r.value).?;
            return (vendor == want) == (r.op == .eq);
        },
    }
}

pub fn evaluate(arena: Allocator, rules: []const Rule, f: Facts, features: Features) Allocator.Error![]const Verdict {
    var out: std.ArrayList(Verdict) = .empty;
    for (rules) |r| {
        if (r.feature != .any and !features.contains(r.feature)) continue;
        if (!fires(r, f)) continue;
        try out.append(arena, .{ .feature = r.feature, .severity = r.severity, .message = r.message, .source = r.source });
    }
    std.mem.sort(Verdict, out.items, {}, worseFirst);
    return out.items;
}

fn worseFirst(_: void, a: Verdict, b: Verdict) bool {
    return a.severity.rank() > b.severity.rank();
}

pub fn worst(verdicts: []const Verdict) ?Severity {
    return if (verdicts.len == 0) null else verdicts[0].severity;
}

const testing = std.testing;

test "the shipped table parses, and every row cites a source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = try parse(arena.allocator(), builtin_table);
    try testing.expect(rules.len > 0);
    for (rules) |r| try testing.expect(std.mem.startsWith(u8, r.source, "https://"));
}

test "malformed rows are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadRule, parse(a, "overlay\tkernel\t<\t5.11\terror\tmsg"));
    try testing.expectError(error.BadRule, parse(a, "overlay\tkernel\t~\t5.11\terror\tmsg\thttps://x"));
    try testing.expectError(error.BadRule, parse(a, "overlay\tkernel\t<\tnew\terror\tmsg\thttps://x"));
    try testing.expectError(error.BadRule, parse(a, "overlay\tuserns\t<\tno\terror\tmsg\thttps://x"));
    try testing.expectError(error.BadRule, parse(a, "warp\tkernel\t<\t5\terror\tmsg\thttps://x"));
}

test "a rule fires only for the features in play, worst first, and never on unknown facts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = try parse(a, "overlay\tkernel\t<\t5.11\terror\told kernel\thttps://a\n" ++
        "any\tmesa\t<\t25.0\twarn\told mesa\thttps://b\n" ++
        "hdr\tgamescope_hdr\t==\tno\twarn\tno hdr\thttps://c\n" ++
        "optiscaler\tgpu\t==\tintel\tinfo\tintel\thttps://d\n");
    const old: Facts = .{ .kernel = Version.parse("5.10").?, .gamescope = .{ .present = true } };

    const none = try evaluate(a, rules, old, .empty);
    try testing.expectEqual(@as(usize, 0), none.len);

    const with_overlay = try evaluate(a, rules, old, .initMany(&.{ .overlay, .hdr }));
    try testing.expectEqual(@as(usize, 2), with_overlay.len);
    try testing.expectEqualStrings("old kernel", with_overlay[0].message);
    try testing.expectEqual(Severity.@"error", worst(with_overlay).?);

    var new = old;
    new.kernel = Version.parse("6.17").?;
    new.mesa = Version.parse("24.3").?;
    const mesa = try evaluate(a, rules, new, .initOne(.overlay));
    try testing.expectEqual(@as(usize, 1), mesa.len);
    try testing.expectEqualStrings("old mesa", mesa[0].message);
}
