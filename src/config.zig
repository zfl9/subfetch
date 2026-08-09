const std = @import("std");

pub const Subscription = struct {
    /// empty/omitted = anonymous: behaves like --node-file (no prefix, no info filtering)
    name: []const u8 = "",
    url: []const u8,
    ua: ?[]const u8 = null,
    enable: bool = true,
};

pub const Config = struct {
    default_ua: ?[]const u8 = null,
    /// info-node (airport notice) keyword overrides; null = built-in defaults
    info_node_keywords: ?[]const []const u8 = null,
    subscriptions: []const Subscription = &.{},

    /// free memory allocated by fromSlice (strings + slices).
    /// not needed with an arena; only for precise deallocation.
    pub fn deinit(cfg: *Config, allocator: std.mem.Allocator) void {
        for (cfg.subscriptions) |s| {
            allocator.free(s.name);
            allocator.free(s.url);
            if (s.ua) |u| allocator.free(u);
        }
        allocator.free(cfg.subscriptions);
        if (cfg.default_ua) |u| allocator.free(u);
        cfg.* = undefined;
    }
};

pub const ParseError = error{
    OutOfMemory,
    ParseZon,
    InvalidSectionName,
    DuplicateSection,
    MissingUrl,
};

/// parse the subscription list .zon config.
/// type-safe: unknown/missing fields and type errors are reported by std.zon.parse at parse time.
/// returned slices are allocated with the given allocator (arena recommended).
pub fn parse(allocator: std.mem.Allocator, source: [:0]const u8) ParseError!Config {
    var cfg = try std.zon.parse.fromSlice(Config, allocator, source, null, .{});
    errdefer cfg.deinit(allocator);

    for (cfg.subscriptions) |s| {
        // empty name = anonymous subscription (like --node-file); any other name must be valid
        if (s.name.len != 0 and !isValidName(s.name)) return error.InvalidSectionName;
        if (s.url.len == 0) return error.MissingUrl;
    }
    // duplicate subscription name check (anonymous subscriptions may repeat)
    for (cfg.subscriptions, 0..) |s, i| {
        if (s.name.len == 0) continue;
        for (cfg.subscriptions[i + 1 ..]) |t| {
            if (std.mem.eql(u8, s.name, t.name)) return error.DuplicateSection;
        }
    }
    return cfg;
}

/// subscription name: ASCII alnum/_/- or any non-ASCII bytes (e.g. UTF-8 Chinese), length 1..=32
fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| {
        if (c < 0x80) {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
    }
    return true;
}

// ---------------- tests ----------------

test "parse basic zon config" {
    const source =
        \\.{
        \\    .default_ua = "clash-verge/v2.2.3",
        \\    .subscriptions = .{
        \\        .{ .name = "hk-airport", .url = "https://example.com/sub?token=abc" },
        \\        .{ .name = "us-airport", .url = "/etc/sub.txt", .ua = "custom/1.0", .enable = false },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqualStrings("clash-verge/v2.2.3", cfg.default_ua.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.subscriptions.len);
    try std.testing.expectEqualStrings("hk-airport", cfg.subscriptions[0].name);
    try std.testing.expectEqualStrings("https://example.com/sub?token=abc", cfg.subscriptions[0].url);
    try std.testing.expect(cfg.subscriptions[0].enable);
    try std.testing.expect(cfg.subscriptions[0].ua == null);
    try std.testing.expectEqualStrings("us-airport", cfg.subscriptions[1].name);
    try std.testing.expectEqualStrings("custom/1.0", cfg.subscriptions[1].ua.?);
    try std.testing.expect(!cfg.subscriptions[1].enable);
}

test "minimal config" {
    const source = ".{ .subscriptions = .{ .{ .name = \"a\", .url = \"x\" } } }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), cfg.subscriptions.len);
    try std.testing.expect(cfg.default_ua == null);
}

test "anonymous subscription (omitted name)" {
    const source =
        \\.{
        \\    .subscriptions = .{
        \\        .{ .url = "/tmp/nodes.txt" },
        \\        .{ .name = "", .url = "/tmp/extra.txt" },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), cfg.subscriptions.len);
    try std.testing.expectEqualStrings("", cfg.subscriptions[0].name);
    try std.testing.expectEqualStrings("", cfg.subscriptions[1].name);
    try std.testing.expectEqualStrings("/tmp/extra.txt", cfg.subscriptions[1].url);
}

test "reject duplicate name" {
    const source = ".{ .subscriptions = .{ .{ .name = \"a\", .url = \"x\" }, .{ .name = \"a\", .url = \"y\" } } }";
    try std.testing.expectError(
        error.DuplicateSection,
        parse(std.testing.allocator, source),
    );
}

test "reject invalid name" {
    const source = ".{ .subscriptions = .{ .{ .name = \"a:b\", .url = \"x\" } } }";
    try std.testing.expectError(
        error.InvalidSectionName,
        parse(std.testing.allocator, source),
    );
    // empty name is valid: anonymous subscription
    const anon = ".{ .subscriptions = .{ .{ .name = \"\", .url = \"x\" } } }";
    const cfg = try parse(std.testing.allocator, anon);
    try std.testing.expectEqual(@as(usize, 1), cfg.subscriptions.len);
    try std.testing.expectEqualStrings("", cfg.subscriptions[0].name);
}

test "reject empty url" {
    const source = ".{ .subscriptions = .{ .{ .name = \"a\", .url = \"\" } } }";
    try std.testing.expectError(
        error.MissingUrl,
        parse(std.testing.allocator, source),
    );
}

test "reject unknown field" {
    // fromSlice error paths may leak intermediate allocations; use an arena
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = ".{ .subscriptions = .{ .{ .name = \"a\", .url = \"x\", .urll = \"y\" } } }";
    try std.testing.expectError(
        error.ParseZon,
        parse(arena.allocator(), source),
    );
}

test "reject missing url field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = ".{ .subscriptions = .{ .{ .name = \"a\" } } }";
    try std.testing.expectError(
        error.ParseZon,
        parse(arena.allocator(), source),
    );
}

test "compile-check" {
    _ = &parse;
    _ = &isValidName;
    _ = &Config.deinit;
}
