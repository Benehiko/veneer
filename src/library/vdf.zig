const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    object: Object,
};

pub const Pair = struct {
    key: []const u8,
    value: Value,
};

pub const Object = struct {
    pairs: []const Pair = &.{},

    pub fn get(self: Object, key: []const u8) ?Value {
        for (self.pairs) |pair| {
            if (std.ascii.eqlIgnoreCase(pair.key, key)) return pair.value;
        }
        return null;
    }

    pub fn string(self: Object, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .string => |s| s,
            .object => null,
        };
    }

    pub fn object(self: Object, key: []const u8) ?Object {
        return switch (self.get(key) orelse return null) {
            .object => |o| o,
            .string => null,
        };
    }

    pub fn path(self: Object, keys: []const []const u8) ?Object {
        var at = self;
        for (keys) |key| at = at.object(key) orelse return null;
        return at;
    }
};

pub const max_depth = 64;

pub const ParseError = Allocator.Error || error{
    UnexpectedEnd,
    UnexpectedToken,
    UnterminatedString,
    TooDeep,
};

pub fn parse(arena: Allocator, text: []const u8) ParseError!Object {
    var p: Parser = .{ .arena = arena, .text = text };
    return p.object(0, false);
}

const Token = union(enum) {
    open,
    close,
    string: []const u8,
    end,
};

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,

    fn next(p: *Parser) ParseError!Token {
        p.skip();
        if (p.pos >= p.text.len) return .end;
        switch (p.text[p.pos]) {
            '{' => {
                p.pos += 1;
                return .open;
            },
            '}' => {
                p.pos += 1;
                return .close;
            },
            '"' => return .{ .string = try p.quoted() },
            else => return .{ .string = p.bare() },
        }
    }

    fn skip(p: *Parser) void {
        while (p.pos < p.text.len) {
            const c = p.text[p.pos];
            if (std.ascii.isWhitespace(c)) {
                p.pos += 1;
            } else if (c == '/' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '/') {
                while (p.pos < p.text.len and p.text[p.pos] != '\n') p.pos += 1;
            } else if (c == '[') {
                while (p.pos < p.text.len and p.text[p.pos] != ']') p.pos += 1;
                if (p.pos < p.text.len) p.pos += 1;
            } else return;
        }
    }

    fn quoted(p: *Parser) ParseError![]const u8 {
        p.pos += 1;
        const start = p.pos;
        var escaped = false;
        while (p.pos < p.text.len) : (p.pos += 1) {
            switch (p.text[p.pos]) {
                '\\' => {
                    escaped = true;
                    p.pos += 1;
                    if (p.pos >= p.text.len) break;
                },
                '"' => {
                    const raw = p.text[start..p.pos];
                    p.pos += 1;
                    return if (escaped) try unescape(p.arena, raw) else raw;
                },
                else => {},
            }
        }
        return error.UnterminatedString;
    }

    fn bare(p: *Parser) []const u8 {
        const start = p.pos;
        while (p.pos < p.text.len) : (p.pos += 1) {
            const c = p.text[p.pos];
            if (std.ascii.isWhitespace(c) or c == '{' or c == '}' or c == '"') break;
        }
        return p.text[start..p.pos];
    }

    fn object(p: *Parser, depth: usize, closing: bool) ParseError!Object {
        if (depth > max_depth) return error.TooDeep;
        var pairs: std.ArrayList(Pair) = .empty;
        while (true) {
            switch (try p.next()) {
                .end => {
                    if (closing) return error.UnexpectedEnd;
                    break;
                },
                .close => {
                    if (!closing) return error.UnexpectedToken;
                    break;
                },
                .open => return error.UnexpectedToken,
                .string => |key| {
                    const value: Value = switch (try p.next()) {
                        .string => |s| .{ .string = s },
                        .open => .{ .object = try p.object(depth + 1, true) },
                        .close => return error.UnexpectedToken,
                        .end => return error.UnexpectedEnd,
                    };
                    try pairs.append(p.arena, .{ .key = key, .value = value });
                },
            }
        }
        return .{ .pairs = try pairs.toOwnedSlice(p.arena) };
    }
};

fn unescape(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            c = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                else => |e| e,
            };
        }
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

const testing = std.testing;

test "nested blocks are reachable by path, keys ignore case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\"InstallConfigStore"
        \\{
        \\    "Software" { "valve" { "Steam" { "CompatToolMapping" {
        \\        "0" { "name" "proton_experimental" }
        \\    } } } }
        \\}
    );
    const mapping = doc.path(&.{ "InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping" }).?;
    try testing.expectEqualStrings("proton_experimental", mapping.object("0").?.string("NAME").?);
}

test "escapes are decoded and only escaped strings are copied" {
    const text =
        \\"k" "a \"quoted\" path\\with\tbits"
        \\"plain" "untouched"
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), text);
    try testing.expectEqualStrings("a \"quoted\" path\\with\tbits", doc.string("k").?);
    const plain = doc.string("plain").?;
    const at = @intFromPtr(plain.ptr);
    try testing.expect(at >= @intFromPtr(text.ptr) and at < @intFromPtr(text.ptr) + text.len);
}

test "comments, conditionals and bare words are tolerated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\// a comment
        \\root {
        \\    key value [$WIN32]
        \\    other "x" // trailing
        \\}
    );
    try testing.expectEqualStrings("value", doc.object("root").?.string("key").?);
    try testing.expectEqualStrings("x", doc.object("root").?.string("other").?);
}

test "a string where an object is expected reads as missing, not as a crash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "\"a\" \"b\"");
    try testing.expect(doc.object("a") == null);
    try testing.expect(doc.string("missing") == null);
}

test "malformed input is an error, not a partial tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnexpectedEnd, parse(a, "\"a\" { \"b\" \"c\""));
    try testing.expectError(error.UnexpectedToken, parse(a, "}"));
    try testing.expectError(error.UnexpectedToken, parse(a, "\"a\" }"));
    try testing.expectError(error.UnexpectedEnd, parse(a, "\"dangling\""));
    try testing.expectError(error.UnterminatedString, parse(a, "\"a\" \"open"));
    try testing.expectError(error.UnterminatedString, parse(a, "\"a\" \"ends in \\"));
}

test "nesting deeper than the limit is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..max_depth + 2) |_| try text.appendSlice(a, "k { ");
    try testing.expectError(error.TooDeep, parse(a, text.items));
}
