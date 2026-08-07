const std = @import("std");
const node = @import("node.zig");
const render = @import("render.zig");
const Options = render.Options;

const Writer = std.Io.Writer;

/// render mihomo/clash config.yaml (hand-written emitter, fixed structure)
pub fn renderClash(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options) ![]const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    const w = list.writer(arena);

    try w.print("mixed-port: {d}\n", .{opts.mixed_port});
    try w.print("allow-lan: false\n", .{});
    try w.print("mode: rule\n", .{});
    try w.print("log-level: info\n", .{});
    try w.print("ipv6: false\n", .{});
    try w.print("external-controller: {s}\n", .{opts.controller});
    if (opts.secret) |s| {
        try w.print("secret: {s}\n", .{s});
    }
    try w.print("profile:\n  store-selected: true\n", .{});
    try w.print("dns:\n  enable: false\n", .{});
    try w.print("tun:\n  enable: false\n", .{});

    // proxies
    try w.print("proxies:\n", .{});
    for (nodes) |n| {
        try renderProxy(w, n);
    }
    // proxy-groups
    const names = try collectNames(arena, nodes);
    try w.print("proxy-groups:\n", .{});
    try w.print("- name: PROXY\n  type: select\n  proxies:\n  - AUTO\n", .{});
    for (names) |nm| {
        try w.print("  - ", .{});
        try yamlStr(w, nm);
        try w.print("\n", .{});
    }
    try w.print("- name: AUTO\n  type: url-test\n  interval: 30\n  tolerance: 50\n  proxies:\n", .{});
    for (names) |nm| {
        try w.print("  - ", .{});
        try yamlStr(w, nm);
        try w.print("\n", .{});
    }

    // rules: no splitting, single MATCH
    try w.print("rules:\n- MATCH,PROXY\n", .{});

    return list.toOwnedSlice(arena);
}

fn collectNames(arena: std.mem.Allocator, nodes: []const node.Node) ![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (nodes) |n| {
        try names.append(arena, n.name());
    }
    return names.toOwnedSlice(arena);
}

fn renderProxy(w: anytype, n: node.Node) !void {
    const S = struct {
        fn f(w2: anytype, key: []const u8, value: []const u8) !void {
            try w2.print("    {s}: ", .{key});
            try yamlStr(w2, value);
            try w2.print("\n", .{});
        }
        fn fi(w2: anytype, key: []const u8, value: u16) !void {
            try w2.print("    {s}: {d}\n", .{ key, value });
        }
        fn fb(w2: anytype, key: []const u8, value: bool) !void {
            try w2.print("    {s}: {}\n", .{ key, value });
        }
        fn fo(w2: anytype, key: []const u8, value: ?[]const u8) !void {
            if (value) |v| try f(w2, key, v);
        }
        fn falpn(w2: anytype, alpn: ?[]const []const u8) !void {
            const list = alpn orelse return;
            if (list.len == 0) return;
            try w2.print("    alpn: [", .{});
            for (list, 0..) |a, i| {
                if (i > 0) try w2.print(", ", .{});
                try yamlStr(w2, a);
            }
            try w2.print("]\n", .{});
        }
    };
    const f = S.f;
    const fi = S.fi;
    const fb = S.fb;
    const fo = S.fo;
    const falpn = S.falpn;

    try w.print("  - name: ", .{});
    try yamlStr(w, n.name());
    try w.print("\n", .{});

    switch (n) {
        .ss => |v| {
            try f(w, "type", "ss");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "cipher", v.cipher);
            try f(w, "password", v.password);
            if (v.plugin) |p| switch (p) {
                .obfs_local => |o| {
                    try f(w, "plugin", "obfs-local");
                    try w.print("    plugin-opts:\n      mode: {s}\n      host: {s}\n", .{ o.mode, o.host });
                },
                .v2ray_plugin => |o| {
                    try f(w, "plugin", "v2ray-plugin");
                    try w.print("    plugin-opts:\n      mode: {s}\n", .{o.mode});
                    if (o.tls) try w.print("      tls: true\n", .{});
                    if (o.host) |h| try w.print("      host: {s}\n", .{h});
                    if (o.path) |path| try w.print("      path: {s}\n", .{path});
                },
                .shadow_tls => |o| {
                    try f(w, "plugin", "shadow-tls");
                    try w.print("    plugin-opts:\n      host: {s}\n      password: {s}\n      version: {d}\n", .{ o.host, o.password, o.version });
                },
            };
            try fb(w, "udp", true);
        },
        .ssr => |v| {
            try f(w, "type", "ssr");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "cipher", v.cipher);
            try f(w, "password", v.password);
            try f(w, "protocol", v.protocol);
            try fo(w, "protocol-param", v.protocol_param);
            try f(w, "obfs", v.obfs);
            try fo(w, "obfs-param", v.obfs_param);
            try fb(w, "udp", true);
        },
        .vmess => |v| {
            try f(w, "type", "vmess");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "uuid", v.uuid);
            try w.print("    alterId: {d}\n", .{v.alter_id});
            try f(w, "cipher", "auto");
            try f(w, "network", @tagName(v.network));
            if (v.tls) try fb(w, "tls", true);
            try fo(w, "servername", v.servername);
            try fo(w, "client-fingerprint", v.fingerprint);
            try renderWsGrpc(w, v.ws, v.grpc);
            try fb(w, "udp", true);
        },
        .vless => |v| {
            try f(w, "type", "vless");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "uuid", v.uuid);
            try f(w, "network", @tagName(v.network));
            if (v.tls) try fb(w, "tls", true);
            try fo(w, "flow", v.flow);
            try fo(w, "servername", v.servername);
            try fo(w, "client-fingerprint", v.fingerprint);
            if (v.reality) |r| {
                try w.print("    reality-opts:\n      public-key: {s}\n", .{r.public_key});
                if (r.short_id) |sid| try w.print("      short-id: {s}\n", .{sid});
                if (r.spider_x) |spx| try w.print("      spider-x: {s}\n", .{spx});
            }
            if (v.skip_cert_verify) try fb(w, "skip-cert-verify", true);
            try falpn(w, v.alpn);
            try renderWsGrpc(w, v.ws, v.grpc);
            try fb(w, "udp", true);
        },
        .trojan => |v| {
            try f(w, "type", "trojan");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "password", v.password);
            try fo(w, "servername", v.servername);
            if (v.skip_cert_verify) try fb(w, "skip-cert-verify", true);
            try falpn(w, v.alpn);
            if (v.network != .tcp) try f(w, "network", @tagName(v.network));
            try renderWsGrpc(w, v.ws, v.grpc);
            try fb(w, "udp", true);
        },
        .hysteria => |v| {
            try f(w, "type", "hysteria");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "protocol", v.protocol);
            try fo(w, "auth_str", v.auth_str);
            try fo(w, "up", v.up);
            try fo(w, "down", v.down);
            try fo(w, "obfs", v.obfs);
            try fo(w, "sni", v.sni);
            if (v.skip_cert_verify) try fb(w, "skip-cert-verify", true);
            try falpn(w, v.alpn);
            try fb(w, "udp", true);
        },
        .hysteria2 => |v| {
            try f(w, "type", "hysteria2");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "password", v.password);
            try fo(w, "servername", v.servername);
            if (v.skip_cert_verify) try fb(w, "skip-cert-verify", true);
            try fo(w, "obfs", v.obfs);
            try fo(w, "obfs-password", v.obfs_password);
            try falpn(w, v.alpn);
            try fb(w, "udp", true);
        },
        .tuic => |v| {
            try f(w, "type", "tuic");
            try f(w, "server", v.server);
            try fi(w, "port", v.port);
            try f(w, "uuid", v.uuid);
            try f(w, "password", v.password);
            try fo(w, "servername", v.servername);
            if (v.skip_cert_verify) try fb(w, "skip-cert-verify", true);
            try fo(w, "congestion-controller", v.congestion_controller);
            try fo(w, "udp-relay-mode", v.udp_relay_mode);
            try falpn(w, v.alpn);
            try fb(w, "udp", true);
        },
    }
}

fn renderWsGrpc(w: anytype, ws: ?node.WsOpts, grpc: ?node.GrpcOpts) !void {
    if (ws) |o| {
        try w.print("    ws-opts:\n      path: ", .{});
        try yamlStr(w, o.path);
        try w.print("\n", .{});
        if (o.host) |h| {
            try w.print("      headers:\n        Host: ", .{});
            try yamlStr(w, h);
            try w.print("\n", .{});
        }
    }
    if (grpc) |o| {
        try w.print("    grpc-opts:\n      grpc-service-name: ", .{});
        try yamlStr(w, o.service_name);
        try w.print("\n", .{});
    }
}

/// YAML scalar output: plain when safe, double-quoted escaping otherwise
fn yamlStr(w: anytype, s: []const u8) !void {
    if (isPlainSafe(s)) {
        try w.writeAll(s);
        return;
    }
    try w.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    try w.print("\\x{X:0>2}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeAll("\"");
}

fn isPlainSafe(s: []const u8) bool {
    if (s.len == 0) return false;
    // YAML plain scalars cannot start with these characters
    const special = "-?:,[]{}#&*!|>'\"%@`";
    if (std.mem.indexOfScalar(u8, special, s[0]) != null) return false;
    for (s) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    if (std.mem.indexOf(u8, s, ": ") != null) return false;
    if (std.mem.indexOf(u8, s, " #") != null) return false;
    // conservative: quote anything with quotes/backslashes (parser compatibility)
    if (std.mem.indexOfScalar(u8, s, '"') != null) return false;
    if (std.mem.indexOfScalar(u8, s, '\\') != null) return false;
    return true;
}

// ---------------- tests ----------------

const test_nodes = [_]node.Node{
    .{ .trojan = .{
        .name = "香港1-电信优化",
        .server = "hk1.example.com",
        .port = 443,
        .password = "pass123",
        .servername = "hk1.example.com",
        .skip_cert_verify = true,
    } },
    .{ .vless = .{
        .name = "韩国1-Reality",
        .server = "kr1.example.com",
        .port = 443,
        .uuid = "11111111-2222-3333-4444-555555555555",
        .network = .tcp,
        .tls = true,
        .reality = .{ .public_key = "abc-def", .short_id = "ABCDEF" },
        .flow = "xtls-rprx-vision",
        .servername = "www.microsoft.com",
        .fingerprint = "chrome",
    } },
    .{ .ss = .{
        .name = "新加坡3-SS",
        .server = "sg3.example.com",
        .port = 8388,
        .cipher = "aes-256-gcm",
        .password = "ss-pass",
        .plugin = .{ .obfs_local = .{ .mode = "http", .host = "www.bing.com" } },
    } },
    .{ .vmess = .{
        .name = "节点:带冒号",
        .server = "de1.example.com",
        .port = 443,
        .uuid = "11111111-2222-3333-4444-555555555555",
        .network = .ws,
        .tls = true,
        .ws = .{ .path = "/vmess", .host = "de1.example.com" },
    } },
};

test "render clash config structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const yaml = try renderClash(arena.allocator(), &test_nodes, .{ .secret = "test-secret" });

    // re-parse with libyaml to validate structure
    const ymod = @import("yaml.zig");
    const root = try ymod.parse(arena.allocator(), yaml);
    const m = ymod.mappingOf(root).?;
    try std.testing.expectEqualStrings("65500", ymod.mappingGetScalar(m, "mixed-port").?);
    try std.testing.expectEqualStrings("test-secret", ymod.mappingGetScalar(m, "secret").?);
    try std.testing.expectEqualStrings("127.0.0.1:65501", ymod.mappingGetScalar(m, "external-controller").?);
    const proxies = ymod.sequenceOf(ymod.mappingGet(m, "proxies").?).?;
    try std.testing.expectEqual(@as(usize, 4), proxies.len);
    const groups = ymod.sequenceOf(ymod.mappingGet(m, "proxy-groups").?).?;
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    const rules = ymod.sequenceOf(ymod.mappingGet(m, "rules").?).?;
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings("MATCH,PROXY", ymod.scalarOf(rules[0]).?);

    // spot-check node fields
    const p0 = ymod.mappingOf(proxies[0]).?;
    try std.testing.expectEqualStrings("trojan", ymod.mappingGetScalar(p0, "type").?);
    try std.testing.expectEqualStrings("true", ymod.mappingGetScalar(p0, "skip-cert-verify").?);
    const p1 = ymod.mappingOf(proxies[1]).?;
    try std.testing.expectEqualStrings("vless", ymod.mappingGetScalar(p1, "type").?);
    const ro = ymod.mappingOf(ymod.mappingGet(p1, "reality-opts").?).?;
    try std.testing.expectEqualStrings("abc-def", ymod.mappingGetScalar(ro, "public-key").?);
    // node name with special chars is quoted and round-trips
    try std.testing.expectEqualStrings("节点:带冒号", ymod.mappingGetScalar(ymod.mappingOf(proxies[3]).?, "name").?);
}

test "yaml scalar quoting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = struct {
        fn render(a: std.mem.Allocator, s: []const u8) ![]const u8 {
            var list: std.ArrayListUnmanaged(u8) = .empty;
            try yamlStr(list.writer(a), s);
            return list.toOwnedSlice(a);
        }
    }.render;
    try std.testing.expectEqualStrings("plain", try q(arena.allocator(), "plain"));
    try std.testing.expectEqualStrings("with space", try q(arena.allocator(), "with space"));
    try std.testing.expectEqualStrings("a:b c", try q(arena.allocator(), "a:b c")); // colon without trailing space: plain is legal
    try std.testing.expectEqualStrings("\"a: b\"", try q(arena.allocator(), "a: b")); // colon + space requires quotes
    try std.testing.expectEqualStrings("\"x\\\"y\"", try q(arena.allocator(), "x\"y"));
    try std.testing.expectEqualStrings("中文节点", try q(arena.allocator(), "中文节点")); // non-ASCII plain is safe
}

test "compile-check" {
    _ = &renderClash;
    _ = &renderProxy;
    _ = &renderWsGrpc;
    _ = &yamlStr;
    _ = &isPlainSafe;
    _ = &collectNames;
    _ = &test_nodes;
}
