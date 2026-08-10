const std = @import("std");
const builtin = @import("builtin");
const render_mod = @import("render.zig");

pub const Subscription = struct {
    /// null/omitted = anonymous subscription (no "name@" prefix);
    /// an explicit "" is rejected: omit the field instead
    name: ?[]const u8 = null,
    url: []const u8,
    ua: ?[]const u8 = null,
};

/// one output target (mirrors -o/--output; .zon: .fmt = .clash etc.)
pub const Output = struct {
    fmt: render_mod.Format,
    tmpl: ?[]const u8 = null,
    path: ?[]const u8 = null,
    /// per-output reload command (overrides global .reload_cmd; CLI --reload-cmd wins)
    reload_cmd: ?[]const u8 = null,
};

pub const Config = struct {
    ua: ?[]const u8 = null,
    /// info-node (airport notice) keyword overrides; null = built-in defaults
    info_keywords: ?[]const []const u8 = null,
    subscriptions: []const Subscription = &.{},
    /// inline node URIs (same semantics as --node)
    nodes: []const []const u8 = &.{},
    /// inline node list files (same semantics as --node-file)
    node_files: []const []const u8 = &.{},
    /// node name separator between subscription name and node name (overrides default "@")
    sep: ?[]const u8 = null,
    /// clash / sing-box API secret (overrides auto-generated UUID; CLI --secret wins)
    secret: ?[]const u8 = null,
    /// per-subscription fetch timeout in seconds (CLI --timeout wins)
    timeout: ?u32 = null,
    /// native client listen address (CLI --listen wins)
    listen: ?[]const u8 = null,
    /// native client listen port (CLI --port wins)
    port: ?u16 = null,
    /// clash mixed-port (CLI --mixed-port wins)
    mixed_port: ?u16 = null,
    /// clash allow-lan, built-in template only (CLI --allow-lan wins)
    allow_lan: ?bool = null,
    /// v6 tproxy dual-stack, built-in templates only: clash ipv6 flag +
    /// sing-box extra tproxy-in-v6 inbound (CLI --tproxy-ipv6 wins);
    /// socks inbound is unaffected (v4/v6 of relayed traffic is the upper layer's
    /// business; the local listen address is just the transport endpoint)
    tproxy_ipv6: ?bool = null,
    /// tproxy inbound port, clash + sing-box built-in templates only;
    /// socks inbound stays (debug/curl testing) (CLI --tproxy-port wins)
    tproxy_port: ?u16 = null,
    /// client log level (clash log-level / sing-box log.level), built-in templates
    /// only: debug|info|warning|error, default info (CLI --log-level wins)
    log_level: ?[]const u8 = null,
    /// clash/singbox external-controller (CLI --controller wins)
    controller: ?[]const u8 = null,
    /// global default reload command after install
    /// (per-output outputs[].reload_cmd overrides; CLI --reload-cmd wins)
    reload_cmd: ?[]const u8 = null,
    /// add clash_api to sing-box output (default off; CLI --singbox-clash-api wins)
    singbox_clash_api: ?bool = null,
    /// output targets (default raw; CLI -o/--output wins)
    outputs: ?[]const Output = null,

    /// free memory allocated by fromSlice (strings + slices).
    /// not needed with an arena; only for precise deallocation.
    pub fn deinit(cfg: *Config, allocator: std.mem.Allocator) void {
        for (cfg.subscriptions) |s| {
            if (s.name) |n| allocator.free(n);
            allocator.free(s.url);
            if (s.ua) |u| allocator.free(u);
        }
        allocator.free(cfg.subscriptions);
        for (cfg.nodes) |n| allocator.free(n);
        allocator.free(cfg.nodes);
        for (cfg.node_files) |f| allocator.free(f);
        allocator.free(cfg.node_files);
        if (cfg.ua) |u| allocator.free(u);
        if (cfg.sep) |s| allocator.free(s);
        if (cfg.secret) |s| allocator.free(s);
        if (cfg.listen) |s| allocator.free(s);
        if (cfg.controller) |s| allocator.free(s);
        if (cfg.reload_cmd) |s| allocator.free(s);
        if (cfg.outputs) |os| {
            for (os) |o| {
                if (o.tmpl) |t| allocator.free(t);
                if (o.path) |p| allocator.free(p);
                if (o.reload_cmd) |c| allocator.free(c);
            }
            allocator.free(os);
        }
        cfg.* = undefined;
    }
};

pub const ParseError = error{
    OutOfMemory,
    ParseZon,
    InvalidSectionName,
    EmptySectionName,
    DuplicateSection,
    MissingUrl,
};

/// parse the config .zon file.
/// type-safe: unknown/missing fields and type errors are reported by std.zon.parse at parse time.
/// returned slices are allocated with the given allocator (arena recommended).
pub fn parse(allocator: std.mem.Allocator, source: [:0]const u8) ParseError!Config {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);
    var cfg = std.zon.parse.fromSlice(Config, allocator, source, &diag, .{}) catch |e| {
        // detailed diagnostics (position, message, notes) go to stderr, then the error name;
        // skipped under zig build test: unit tests deliberately feed broken input and must
        // not touch stdio
        if (!builtin.is_test) {
            var buf: [8192]u8 = undefined;
            var w = std.fs.File.stderr().writer(&buf);
            diag.format(&w.interface) catch {};
            w.interface.flush() catch {};
        }
        return e;
    };
    errdefer cfg.deinit(allocator);

    for (cfg.subscriptions) |s| {
        // null name = anonymous; explicit "" is rejected (omit the field instead)
        if (s.name) |n| {
            if (n.len == 0) return error.EmptySectionName;
            if (!isValidName(n)) return error.InvalidSectionName;
        }
        if (s.url.len == 0) return error.MissingUrl;
    }
    // duplicate subscription name check (anonymous subscriptions may repeat)
    for (cfg.subscriptions, 0..) |s, i| {
        const sn = s.name orelse continue;
        for (cfg.subscriptions[i + 1 ..]) |t| {
            if (t.name) |tn| {
                if (std.mem.eql(u8, sn, tn)) return error.DuplicateSection;
            }
        }
    }
    return cfg;
}

/// subscription name: ASCII alnum/_/- or any non-ASCII bytes (e.g. UTF-8 Chinese), length 1..=32
pub fn isValidName(name: []const u8) bool {
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
        \\    .ua = "clash-verge/v2.2.3",
        \\    .subscriptions = .{
        \\        .{ .name = "hk-airport", .url = "https://example.com/sub?token=abc" },
        \\        .{ .name = "us-airport", .url = "/etc/sub.txt", .ua = "custom/1.0" },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqualStrings("clash-verge/v2.2.3", cfg.ua.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.subscriptions.len);
    try std.testing.expectEqualStrings("hk-airport", cfg.subscriptions[0].name.?);
    try std.testing.expectEqualStrings("https://example.com/sub?token=abc", cfg.subscriptions[0].url);
    try std.testing.expect(cfg.subscriptions[0].ua == null);
    try std.testing.expectEqualStrings("us-airport", cfg.subscriptions[1].name.?);
    try std.testing.expectEqualStrings("custom/1.0", cfg.subscriptions[1].ua.?);
}

test "minimal config" {
    const source = ".{ .subscriptions = .{ .{ .name = \"a\", .url = \"x\" } } }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), cfg.subscriptions.len);
    try std.testing.expect(cfg.ua == null);
}

test "anonymous subscription (omitted name)" {
    const source =
        \\.{
        \\    .subscriptions = .{
        \\        .{ .url = "/tmp/nodes.txt" },
        \\        .{ .url = "/tmp/extra.txt" },
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), cfg.subscriptions.len);
    try std.testing.expect(cfg.subscriptions[0].name == null);
    try std.testing.expect(cfg.subscriptions[1].name == null);
    try std.testing.expectEqualStrings("/tmp/extra.txt", cfg.subscriptions[1].url);
}

test "reject explicit empty name" {
    const source = ".{ .subscriptions = .{ .{ .name = \"\", .url = \"x\" } } }";
    try std.testing.expectError(
        error.EmptySectionName,
        parse(std.testing.allocator, source),
    );
}

test "parse render/deploy config fields" {
    const source =
        \\.{
        \\    .timeout = 42,
        \\    .listen = "0.0.0.0",
        \\    .port = 7890,
        \\    .mixed_port = 7891,
        \\    .controller = "0.0.0.0:9090",
        \\    .reload_cmd = "systemctl restart clash",
        \\    .singbox_clash_api = true,
        \\    .allow_lan = true,
        \\    .tproxy_ipv6 = true,
        \\    .tproxy_port = 60080,
        \\    .log_level = "warning",
        \\    .outputs = .{
        \\        .{ .fmt = .clash, .path = "/etc/clash/config.yaml", .reload_cmd = "systemctl restart clash" },
        \\        .{ .fmt = .singbox, .tmpl = "/etc/singbox.tmpl.json", .path = "/etc/sing-box/config.json" },
        \\    },
        \\    .subscriptions = .{ .{ .name = "airport", .url = "https://x/sub" } },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(?u32, 42), cfg.timeout);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.listen.?);
    try std.testing.expectEqual(@as(?u16, 7890), cfg.port);
    try std.testing.expectEqual(@as(?u16, 7891), cfg.mixed_port);
    try std.testing.expectEqualStrings("0.0.0.0:9090", cfg.controller.?);
    try std.testing.expectEqualStrings("systemctl restart clash", cfg.reload_cmd.?);
    try std.testing.expect(cfg.singbox_clash_api.?);
    try std.testing.expect(cfg.allow_lan.?);
    try std.testing.expect(cfg.tproxy_ipv6.?);
    try std.testing.expectEqual(@as(?u16, 60080), cfg.tproxy_port);
    try std.testing.expectEqualStrings("warning", cfg.log_level.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.outputs.?.len);
    try std.testing.expectEqual(render_mod.Format.clash, cfg.outputs.?[0].fmt);
    try std.testing.expectEqualStrings("/etc/clash/config.yaml", cfg.outputs.?[0].path.?);
    try std.testing.expectEqualStrings("systemctl restart clash", cfg.outputs.?[0].reload_cmd.?);
    try std.testing.expect(cfg.outputs.?[0].tmpl == null);
    try std.testing.expectEqual(render_mod.Format.singbox, cfg.outputs.?[1].fmt);
    try std.testing.expectEqualStrings("/etc/singbox.tmpl.json", cfg.outputs.?[1].tmpl.?);
    try std.testing.expectEqualStrings("/etc/sing-box/config.json", cfg.outputs.?[1].path.?);
    try std.testing.expect(cfg.outputs.?[1].reload_cmd == null);
}

test "parse sep and secret config fields" {
    const source =
        \\.{
        \\    .sep = "|",
        \\    .secret = "my-secret",
        \\    .subscriptions = .{ .{ .name = "airport", .url = "https://x/sub" } },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqualStrings("|", cfg.sep.?);
    try std.testing.expectEqualStrings("my-secret", cfg.secret.?);
    // omitted fields stay null
    try std.testing.expect(cfg.nodes.len == 0);
    try std.testing.expect(cfg.node_files.len == 0);
}

test "parse inline nodes and node_files" {
    const source =
        \\.{
        \\    .nodes = .{ "trojan://a@h1:443#hk", "ss://YQ@h2:8388" },
        \\    .node_files = .{ "/tmp/nodes.txt" },
        \\    .subscriptions = .{ .{ .name = "airport", .url = "https://x/sub" } },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), cfg.nodes.len);
    try std.testing.expectEqualStrings("trojan://a@h1:443#hk", cfg.nodes[0]);
    try std.testing.expectEqual(@as(usize, 1), cfg.node_files.len);
    try std.testing.expectEqualStrings("/tmp/nodes.txt", cfg.node_files[0]);
    try std.testing.expectEqual(@as(usize, 1), cfg.subscriptions.len);
    try std.testing.expectEqualStrings("airport", cfg.subscriptions[0].name.?);
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
    // anonymous via omitted name is valid
    const anon = ".{ .subscriptions = .{ .{ .url = \"x\" } } }";
    var cfg = try parse(std.testing.allocator, anon);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cfg.subscriptions.len);
    try std.testing.expect(cfg.subscriptions[0].name == null);
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
