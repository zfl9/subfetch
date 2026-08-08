const std = @import("std");
const node = @import("node.zig");
const render = @import("render.zig");

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// render raw format: node JSON list (for other tools/scripts)
pub fn renderRaw(arena: std.mem.Allocator, nodes: []const node.Node) ![]const render.File {
    var arr = std.json.Array.init(arena);
    for (nodes) |n| {
        try arr.append(try nodeToJson(arena, n));
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try @import("render.zig").writeJsonValue(out.writer(arena), .{ .array = arr });
    try out.append(arena, '\n');
    const text = try out.toOwnedSlice(arena);
    const file = try arena.alloc(render.File, 1);
    file[0] = .{ .path = "nodes.json", .content = text };
    return file;
}

/// field names follow mihomo/clash YAML naming (mihomo covers all 8 protocols; no native fallback needed).
/// full field coverage (empty optional values omitted) for downstream scripts.
fn nodeToJson(arena: std.mem.Allocator, n: node.Node) !JsonValue {
    var o = ObjectMap.init(arena);
    try o.put("type", .{ .string = n.typeName() });
    try o.put("name", .{ .string = n.name() });
    try o.put("server", .{ .string = serverOf(n) });
    try o.put("port", .{ .integer = portOf(n) });

    switch (n) {
        .ss => |v| {
            try o.put("cipher", .{ .string = v.cipher });
            try o.put("password", .{ .string = v.password });
            try putSsPlugin(arena, &o, v.plugin);
        },
        .ssr => |v| {
            try o.put("cipher", .{ .string = v.cipher });
            try o.put("password", .{ .string = v.password });
            try o.put("protocol", .{ .string = v.protocol });
            try o.put("obfs", .{ .string = v.obfs });
            try putOpt(arena, &o, "obfs-param", v.obfs_param);
            try putOpt(arena, &o, "protocol-param", v.protocol_param);
        },
        .vmess => |v| {
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("alterId", .{ .integer = v.alter_id });
            try o.put("network", .{ .string = @tagName(v.network) });
            if (v.tls) try o.put("tls", .{ .bool = true });
            try putOpt(arena, &o, "servername", v.servername);
            try putOpt(arena, &o, "client-fingerprint", v.fingerprint);
            try putWsGrpc(arena, &o, v.network, v.ws, v.grpc);
        },
        .vless => |v| {
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("network", .{ .string = @tagName(v.network) });
            if (v.tls) try o.put("tls", .{ .bool = true });
            try putOpt(arena, &o, "flow", v.flow);
            try putOpt(arena, &o, "servername", v.servername);
            try putOpt(arena, &o, "client-fingerprint", v.fingerprint);
            if (v.skip_cert_verify) try o.put("skip-cert-verify", .{ .bool = true });
            try putAlpn(arena, &o, v.alpn);
            if (v.reality) |r| {
                var ro = ObjectMap.init(arena);
                try ro.put("public-key", .{ .string = r.public_key });
                try putOpt(arena, &ro, "short-id", r.short_id);
                try putOpt(arena, &ro, "spider-x", r.spider_x);
                try o.put("reality-opts", .{ .object = ro });
            }
            try putWsGrpc(arena, &o, v.network, v.ws, v.grpc);
        },
        .trojan => |v| {
            try o.put("password", .{ .string = v.password });
            try putOpt(arena, &o, "servername", v.servername);
            if (v.skip_cert_verify) try o.put("skip-cert-verify", .{ .bool = true });
            try putAlpn(arena, &o, v.alpn);
            if (v.network != .tcp) try o.put("network", .{ .string = @tagName(v.network) });
            try putWsGrpc(arena, &o, v.network, v.ws, v.grpc);
        },
        .hysteria => |v| {
            try o.put("protocol", .{ .string = v.protocol });
            try putOpt(arena, &o, "auth_str", v.auth_str);
            try putOpt(arena, &o, "up", v.up);
            try putOpt(arena, &o, "down", v.down);
            try putOpt(arena, &o, "obfs", v.obfs);
            try putOpt(arena, &o, "sni", v.sni);
            if (v.skip_cert_verify) try o.put("skip-cert-verify", .{ .bool = true });
            try putAlpn(arena, &o, v.alpn);
        },
        .hysteria2 => |v| {
            try o.put("password", .{ .string = v.password });
            try putOpt(arena, &o, "servername", v.servername);
            if (v.skip_cert_verify) try o.put("skip-cert-verify", .{ .bool = true });
            try putOpt(arena, &o, "obfs", v.obfs);
            try putOpt(arena, &o, "obfs-password", v.obfs_password);
            try putAlpn(arena, &o, v.alpn);
        },
        .tuic => |v| {
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("password", .{ .string = v.password });
            try putOpt(arena, &o, "servername", v.servername);
            if (v.skip_cert_verify) try o.put("skip-cert-verify", .{ .bool = true });
            try putOpt(arena, &o, "congestion-controller", v.congestion_controller);
            try putOpt(arena, &o, "udp-relay-mode", v.udp_relay_mode);
            try putAlpn(arena, &o, v.alpn);
        },
    }
    return .{ .object = o };
}

/// ss plugin: mihomo plugin + plugin-opts (nested object)
fn putSsPlugin(arena: std.mem.Allocator, o: *ObjectMap, plugin: ?node.SsPlugin) !void {
    const p = plugin orelse return;
    switch (p) {
        .obfs_local => |pl| {
            try o.put("plugin", .{ .string = "obfs-local" });
            var opts = ObjectMap.init(arena);
            try opts.put("mode", .{ .string = pl.mode });
            try opts.put("host", .{ .string = pl.host });
            try o.put("plugin-opts", .{ .object = opts });
        },
        .v2ray_plugin => |pl| {
            try o.put("plugin", .{ .string = "v2ray-plugin" });
            var opts = ObjectMap.init(arena);
            try opts.put("mode", .{ .string = pl.mode });
            if (pl.tls) try opts.put("tls", .{ .bool = true });
            try putOpt(arena, &opts, "host", pl.host);
            try putOpt(arena, &opts, "path", pl.path);
            try o.put("plugin-opts", .{ .object = opts });
        },
        .shadow_tls => |pl| {
            try o.put("plugin", .{ .string = "shadow-tls" });
            var opts = ObjectMap.init(arena);
            try opts.put("host", .{ .string = pl.host });
            try opts.put("password", .{ .string = pl.password });
            try opts.put("version", .{ .integer = pl.version });
            try o.put("plugin-opts", .{ .object = opts });
        },
    }
}

/// ws/grpc transport: mihomo ws-opts / grpc-opts (nested objects)
fn putWsGrpc(arena: std.mem.Allocator, o: *ObjectMap, network: node.Network, ws: ?node.WsOpts, grpc: ?node.GrpcOpts) !void {
    switch (network) {
        .ws => {
            if (ws) |w| {
                var opts = ObjectMap.init(arena);
                try opts.put("path", .{ .string = w.path });
                if (w.host) |h| {
                    var headers = ObjectMap.init(arena);
                    try headers.put("Host", .{ .string = h });
                    try opts.put("headers", .{ .object = headers });
                }
                try o.put("ws-opts", .{ .object = opts });
            }
        },
        .grpc => {
            if (grpc) |g| {
                var opts = ObjectMap.init(arena);
                try opts.put("grpc-service-name", .{ .string = g.service_name });
                try o.put("grpc-opts", .{ .object = opts });
            }
        },
        else => {},
    }
}

/// alpn array
fn putAlpn(arena: std.mem.Allocator, o: *ObjectMap, alpn: ?[]const []const u8) !void {
    const list = alpn orelse return;
    if (list.len == 0) return;
    var arr = std.json.Array.init(arena);
    for (list) |a| try arr.append(.{ .string = a });
    try o.put("alpn", .{ .array = arr });
}

/// optional string: emitted only when non-empty
fn putOpt(arena: std.mem.Allocator, o: *ObjectMap, key: []const u8, v: ?[]const u8) !void {
    _ = arena;
    const val = v orelse return;
    if (val.len == 0) return;
    try o.put(key, .{ .string = val });
}

fn serverOf(n: node.Node) []const u8 {
    return switch (n) {
        .ss => |v| v.server,
        .ssr => |v| v.server,
        .vmess => |v| v.server,
        .vless => |v| v.server,
        .trojan => |v| v.server,
        .hysteria => |v| v.server,
        .hysteria2 => |v| v.server,
        .tuic => |v| v.server,
    };
}

fn portOf(n: node.Node) u16 {
    return switch (n) {
        .ss => |v| v.port,
        .ssr => |v| v.port,
        .vmess => |v| v.port,
        .vless => |v| v.port,
        .trojan => |v| v.port,
        .hysteria => |v| v.port,
        .hysteria2 => |v| v.port,
        .tuic => |v| v.port,
    };
}

// ---------------- tests ----------------

test "render raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{
        .{ .trojan = .{
            .name = "HK-01",
            .server = "hk1.example.com",
            .port = 443,
            .password = "pass123",
        } },
        .{ .ss = .{
            .name = "SG-03-SS",
            .server = "sg3.example.com",
            .port = 8388,
            .cipher = "aes-256-gcm",
            .password = "ss-pass",
        } },
    };
    const text = (try renderRaw(a, &nodes))[0].content;
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, text, .{});
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
    const t = v.array.items[0].object;
    try std.testing.expectEqualStrings("trojan", t.get("type").?.string);
    try std.testing.expectEqualStrings("HK-01", t.get("name").?.string);
    try std.testing.expectEqualStrings("pass123", t.get("password").?.string);
    const s = v.array.items[1].object;
    try std.testing.expectEqualStrings("aes-256-gcm", s.get("cipher").?.string);
}

test "raw full fields (vless reality + ws/grpc + alpn + plugin)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{
        .{ .vless = .{
            .name = "kr1",
            .server = "kr1.example.com",
            .port = 443,
            .uuid = "11111111-2222-3333-4444-555555555555",
            .network = .ws,
            .tls = true,
            .reality = .{ .public_key = "pubkey123", .short_id = "ABCD", .spider_x = "/spx" },
            .flow = "xtls-rprx-vision",
            .servername = "www.example.com",
            .fingerprint = "chrome",
            .skip_cert_verify = true,
            .alpn = &.{ "h2", "http/1.1" },
            .ws = .{ .path = "/ws", .host = "kr1.example.com" },
        } },
        .{ .trojan = .{
            .name = "jp1",
            .server = "jp1.example.com",
            .port = 8443,
            .password = "p",
            .network = .grpc,
            .grpc = .{ .service_name = "svc1" },
        } },
        .{ .ss = .{
            .name = "us1",
            .server = "us1.example.com",
            .port = 8388,
            .cipher = "aes-256-gcm",
            .password = "p",
            .plugin = .{ .shadow_tls = .{ .host = "www.bing.com", .password = "st", .version = 3 } },
        } },
    };
    const text = (try renderRaw(a, &nodes))[0].content;
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, text, .{});
    const arr = v.array.items;

    // vless: full fields (reality-opts spider-x, alpn, ws-opts headers)
    const vl = arr[0].object;
    try std.testing.expectEqualStrings("chrome", vl.get("client-fingerprint").?.string);
    try std.testing.expect(vl.get("skip-cert-verify").?.bool);
    const ro = vl.get("reality-opts").?.object;
    try std.testing.expectEqualStrings("/spx", ro.get("spider-x").?.string);
    try std.testing.expectEqualStrings("h2", vl.get("alpn").?.array.items[0].string);
    const ws = vl.get("ws-opts").?.object;
    try std.testing.expectEqualStrings("/ws", ws.get("path").?.string);
    try std.testing.expectEqualStrings("kr1.example.com", ws.get("headers").?.object.get("Host").?.string);

    // trojan: grpc-opts + network
    const tj = arr[1].object;
    try std.testing.expectEqualStrings("grpc", tj.get("network").?.string);
    try std.testing.expectEqualStrings("svc1", tj.get("grpc-opts").?.object.get("grpc-service-name").?.string);

    // ss: shadow-tls plugin
    const ss = arr[2].object;
    try std.testing.expectEqualStrings("shadow-tls", ss.get("plugin").?.string);
    const po = ss.get("plugin-opts").?.object;
    try std.testing.expectEqual(@as(i64, 3), po.get("version").?.integer);
}

test "compile-check" {
    _ = &renderRaw;
    _ = &nodeToJson;
    _ = &putSsPlugin;
    _ = &putWsGrpc;
    _ = &putAlpn;
    _ = &putOpt;
    _ = &serverOf;
    _ = &portOf;
}
