const std = @import("std");
const node = @import("node.zig");
const render = @import("render.zig");
const Options = render.Options;

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// filename sanitization: keep the name readable while making it safe for the
/// filesystem - separator/dangerous chars (/\:*?"<>| and whitespace) become
/// '_', everything else (CJK, emoji, any byte) passes through untouched.
/// Linux only forbids '/' (and NUL), so nothing else needs escaping; in
/// particular no UTF-8 decoding is required (truncated sequences are harmless
/// bytes here, not a panic risk).
fn safeFileName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var prev_ws = false;
    for (name) |b| {
        switch (b) {
            ' ', '\t', '\r', '\n' => {
                if (!prev_ws and out.items.len > 0) try out.append(arena, '_');
                prev_ws = true;
            },
            '/', '\\', ':', '*', '?', '"', '<', '>', '|' => try out.append(arena, '_'),
            else => {
                try out.append(arena, b);
                prev_ws = false;
            },
        }
    }
    // trim trailing '_' (from trailing whitespace/special chars)
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') out.items.len -= 1;
    if (out.items.len == 0) return "node";
    return out.toOwnedSlice(arena);
}

/// single-node JSON serialization helper: build an object
fn buildObj(arena: std.mem.Allocator, fields: []const struct { []const u8, JsonValue }) !JsonValue {
    var o = ObjectMap.init(arena);
    for (fields) |f| {
        try o.put(f[0], f[1]);
    }
    return .{ .object = o };
}

fn str(v: []const u8) JsonValue {
    return .{ .string = v };
}

fn int(v: i64) JsonValue {
    return .{ .integer = v };
}

/// serialize a node to JSON (std.json.Stringify)
fn jsonToString(arena: std.mem.Allocator, v: JsonValue) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, v, .{ .whitespace = .indent_2 });
}

/// trojan-go / trojan client config.json
fn trojanJson(arena: std.mem.Allocator, v: node.Trojan, opts: Options) !JsonValue {
    var ssl = ObjectMap.init(arena);
    try ssl.put("sni", str(v.servername orelse v.server));
    try ssl.put("verify_cert", .{ .bool = !v.skip_cert_verify });
    if (v.alpn) |alpn| {
        var list = std.json.Array.init(arena);
        for (alpn) |a| try list.append(str(a));
        try ssl.put("alpn", .{ .array = list });
    }

    var fields: std.ArrayListUnmanaged(struct { []const u8, JsonValue }) = .empty;
    try fields.append(arena, .{ "run_type", str("client") });
    try fields.append(arena, .{ "local_addr", str(opts.listen) });
    try fields.append(arena, .{ "local_port", int(opts.port) });
    try fields.append(arena, .{ "remote_addr", str(v.server) });
    try fields.append(arena, .{ "remote_port", int(v.port) });
    var pass = std.json.Array.init(arena);
    try pass.append(str(v.password));
    try fields.append(arena, .{ "password", .{ .array = pass } });
    try fields.append(arena, .{ "ssl", .{ .object = ssl } });
    if (v.network == .ws) {
        var ws = ObjectMap.init(arena);
        try ws.put("enabled", .{ .bool = true });
        const ws_path = if (v.ws) |w| w.path else "/";
        try ws.put("path", str(ws_path));
        if (v.ws) |w| {
            if (w.host) |h| try ws.put("host", str(h));
        }
        try fields.append(arena, .{ "websocket", .{ .object = ws } });
    }
    var mux = ObjectMap.init(arena);
    try mux.put("enabled", .{ .bool = false });
    try fields.append(arena, .{ "mux", .{ .object = mux } });

    return buildObj(arena, fields.items);
}

/// hysteria 1.x client config.json
fn hysteriaJson(arena: std.mem.Allocator, v: node.Hysteria, opts: Options) !JsonValue {
    var fields: std.ArrayListUnmanaged(struct { []const u8, JsonValue }) = .empty;
    const server = try std.fmt.allocPrint(arena, "{s}:{d}", .{ v.server, v.port });
    try fields.append(arena, .{ "server", str(server) });
    try fields.append(arena, .{ "protocol", str(v.protocol) });
    if (v.auth_str) |a| try fields.append(arena, .{ "auth_str", str(a) });
    if (v.up) |u| {
        if (std.fmt.parseInt(i64, u, 10)) |n| {
            try fields.append(arena, .{ "up_mbps", int(n) });
        } else |_| {} // unparseable -> omit, client default applies
    }
    if (v.down) |d| {
        if (std.fmt.parseInt(i64, d, 10)) |n| {
            try fields.append(arena, .{ "down_mbps", int(n) });
        } else |_| {} // unparseable -> omit, client default applies
    }
    if (v.obfs) |obfs| try fields.append(arena, .{ "obfs", str(obfs) });
    var socks = ObjectMap.init(arena);
    try socks.put("listen", str(try std.fmt.allocPrint(arena, "{s}:{d}", .{ opts.listen, opts.port })));
    try fields.append(arena, .{ "socks5", .{ .object = socks } });
    if (v.sni != null or v.skip_cert_verify or v.alpn != null) {
        var tls = ObjectMap.init(arena);
        if (v.sni) |sni| try tls.put("sni", str(sni));
        try tls.put("insecure", .{ .bool = v.skip_cert_verify });
        if (v.alpn) |alpn| {
            if (alpn.len > 0) {
                var arr = std.json.Array.init(arena);
                for (alpn) |a| try arr.append(str(a));
                try tls.put("alpn", .{ .array = arr });
            }
        }
        try fields.append(arena, .{ "tls", .{ .object = tls } });
    }
    return buildObj(arena, fields.items);
}

/// hysteria 2.x client config.yaml (hysteria2 native config is yaml)
fn hysteria2Yaml(arena: std.mem.Allocator, v: node.Hysteria2, opts: Options) ![]const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    const w = list.writer(arena);
    const server = try std.fmt.allocPrint(arena, "{s}:{d}", .{ v.server, v.port });
    try w.print("server: {s}\n", .{server});
    try w.print("auth: {s}\n", .{v.password});
    if (v.servername != null or v.skip_cert_verify or v.alpn != null) {
        try w.print("tls:\n", .{});
        if (v.servername) |sni| try w.print("  sni: {s}\n", .{sni});
        if (v.skip_cert_verify) try w.print("  insecure: true\n", .{});
        if (v.alpn) |alpn| {
            if (alpn.len > 0) {
                try w.print("  alpn:\n", .{});
                for (alpn) |a| try w.print("    - {s}\n", .{a});
            }
        }
    }
    if (v.obfs) |obfs| {
        try w.print("obfs:\n  type: {s}\n", .{obfs});
        if (v.obfs_password) |p| try w.print("  password: {s}\n", .{p});
    }
    try w.print("socks5:\n  listen: {s}:{d}\n", .{ opts.listen, opts.port });
    return list.toOwnedSlice(arena);
}

/// xray-core client config.json (vless outbound + socks inbound)
fn xrayJson(arena: std.mem.Allocator, v: node.Vless, opts: Options) !JsonValue {
    var root = ObjectMap.init(arena);

    var log = ObjectMap.init(arena);
    try log.put("loglevel", str(opts.log_level orelse "info"));
    try root.put("log", .{ .object = log });

    var inbounds = std.json.Array.init(arena);
    var socks = ObjectMap.init(arena);
    try socks.put("protocol", str("socks"));
    try socks.put("listen", str(opts.listen));
    try socks.put("port", int(opts.port));
    var socks_settings = ObjectMap.init(arena);
    try socks_settings.put("udp", .{ .bool = true });
    try socks.put("settings", .{ .object = socks_settings });
    try inbounds.append(.{ .object = socks });
    try root.put("inbounds", .{ .array = inbounds });

    var out = ObjectMap.init(arena);
    try out.put("protocol", str("vless"));
    var settings = ObjectMap.init(arena);
    var user = ObjectMap.init(arena);
    try user.put("id", str(v.uuid));
    try user.put("encryption", str("none"));
    if (v.flow) |f| try user.put("flow", str(f));
    var users = std.json.Array.init(arena);
    try users.append(.{ .object = user });
    var vn = ObjectMap.init(arena);
    try vn.put("address", str(v.server));
    try vn.put("port", int(v.port));
    try vn.put("users", .{ .array = users });
    var vnext = std.json.Array.init(arena);
    try vnext.append(.{ .object = vn });
    try settings.put("vnext", .{ .array = vnext });
    try out.put("settings", .{ .object = settings });

    var stream = ObjectMap.init(arena);
    try stream.put("network", str(@tagName(v.network)));
    const security: []const u8 = if (v.reality != null) "reality" else if (v.tls) "tls" else "none";
    try stream.put("security", str(security));
    if (v.reality) |r| {
        var rs = ObjectMap.init(arena);
        if (v.servername) |sni| try rs.put("serverName", str(sni));
        if (v.fingerprint) |fp| try rs.put("fingerprint", str(fp));
        try rs.put("publicKey", str(r.public_key));
        if (r.short_id) |sid| try rs.put("shortId", str(sid));
        if (r.spider_x) |spx| try rs.put("spiderX", str(spx));
        try stream.put("realitySettings", .{ .object = rs });
    } else if (v.tls) {
        var ts = ObjectMap.init(arena);
        if (v.servername) |sni| try ts.put("serverName", str(sni));
        if (v.skip_cert_verify) try ts.put("allowInsecure", .{ .bool = true });
        if (v.fingerprint) |fp| try ts.put("fingerprint", str(fp));
        if (v.alpn) |alpn| {
            if (alpn.len > 0) {
                var arr = std.json.Array.init(arena);
                for (alpn) |a| try arr.append(str(a));
                try ts.put("alpn", .{ .array = arr });
            }
        }
        try stream.put("tlsSettings", .{ .object = ts });
    }
    switch (v.network) {
        .ws => {
            var ws = ObjectMap.init(arena);
            if (v.ws) |w| {
                try ws.put("path", str(w.path));
                // xray v26+ deprecates headers.Host; use the standalone host field
                if (w.host) |h| try ws.put("host", str(h));
            }
            try stream.put("wsSettings", .{ .object = ws });
        },
        .grpc => {
            var gs = ObjectMap.init(arena);
            if (v.grpc) |g| try gs.put("serviceName", str(g.service_name));
            try stream.put("grpcSettings", .{ .object = gs });
        },
        else => {},
    }
    try out.put("streamSettings", .{ .object = stream });

    var outbounds = std.json.Array.init(arena);
    try outbounds.append(.{ .object = out });
    try root.put("outbounds", .{ .array = outbounds });
    return .{ .object = root };
}

/// shadowsocks-libev/rust client config.json
fn ssJson(arena: std.mem.Allocator, v: node.SS, opts: Options) !JsonValue {
    var o = ObjectMap.init(arena);
    try o.put("server", str(v.server));
    try o.put("server_port", int(v.port));
    try o.put("password", str(v.password));
    try o.put("method", str(v.cipher));
    try o.put("local_address", str(opts.listen));
    try o.put("local_port", int(opts.port));
    try o.put("timeout", int(60));
    try o.put("mode", str("tcp_and_udp"));
    if (v.plugin) |p| switch (p) {
        .obfs_local => |pl| {
            try o.put("plugin", str("obfs-local"));
            try o.put("plugin_opts", str(try std.fmt.allocPrint(arena, "obfs={s};obfs-host={s}", .{ pl.mode, pl.host })));
        },
        .v2ray_plugin => |pl| {
            try o.put("plugin", str("v2ray-plugin"));
            try o.put("plugin_opts", str(try v2rayPluginOpts(arena, pl)));
        },
        .shadow_tls => |pl| {
            try o.put("plugin", str("shadow-tls"));
            try o.put("plugin_opts", str(try std.fmt.allocPrint(arena, "password={s};host={s};version={d}", .{ pl.password, pl.host, pl.version })));
        },
    };
    return .{ .object = o };
}

/// TOR_PT-style plugin_opts for v2ray-plugin
fn v2rayPluginOpts(arena: std.mem.Allocator, pl: anytype) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    try parts.append(arena, try std.fmt.allocPrint(arena, "mode={s}", .{pl.mode}));
    if (pl.tls) try parts.append(arena, "tls");
    if (pl.host) |h| try parts.append(arena, try std.fmt.allocPrint(arena, "host={s}", .{h}));
    if (pl.path) |path| try parts.append(arena, try std.fmt.allocPrint(arena, "path={s}", .{path}));
    return std.mem.join(arena, ";", parts.items);
}

/// shadowsocksr-libev client config.json
fn ssrJson(arena: std.mem.Allocator, v: node.SSR, opts: Options) !JsonValue {
    var o = ObjectMap.init(arena);
    try o.put("server", str(v.server));
    try o.put("server_port", int(v.port));
    try o.put("password", str(v.password));
    try o.put("method", str(v.cipher));
    try o.put("protocol", str(v.protocol));
    try o.put("obfs", str(v.obfs));
    if (v.obfs_param) |p| try o.put("obfs_param", str(p));
    if (v.protocol_param) |p| try o.put("protocol_param", str(p));
    try o.put("local_address", str(opts.listen));
    try o.put("local_port", int(opts.port));
    return .{ .object = o };
}

/// render native client configs: one file per node (service scripts manage the active one)
fn renderNative(
    arena: std.mem.Allocator,
    nodes: []const node.Node,
    opts: Options,
    template: ?[]const u8,
    comptime kind: enum { trojan, hysteria, hysteria2, xray, ss, ssr },
) ![]const render.File {
    _ = template; // native formats have no template support
    var files: std.ArrayListUnmanaged(render.File) = .empty;

    for (nodes) |n| {
        const fname = try safeFileName(arena, n.name());
        const path = switch (kind) {
            .trojan, .hysteria, .xray, .ss, .ssr => try std.fmt.allocPrint(arena, "{s}.json", .{fname}),
            .hysteria2 => try std.fmt.allocPrint(arena, "{s}.yaml", .{fname}),
        };
        const content = switch (kind) {
            .trojan => switch (n) {
                .trojan => |v| try jsonToString(arena, try trojanJson(arena, v, opts)),
                else => continue, // skip non-trojan nodes
            },
            .hysteria => switch (n) {
                .hysteria => |v| try jsonToString(arena, try hysteriaJson(arena, v, opts)),
                else => continue,
            },
            .hysteria2 => switch (n) {
                .hysteria2 => |v| try hysteria2Yaml(arena, v, opts),
                else => continue,
            },
            .xray => switch (n) {
                .vless => |v| try jsonToString(arena, try xrayJson(arena, v, opts)),
                else => continue, // skip non-vless nodes (xray native config)
            },
            .ss => switch (n) {
                .ss => |v| try jsonToString(arena, try ssJson(arena, v, opts)),
                else => continue,
            },
            .ssr => switch (n) {
                .ssr => |v| try jsonToString(arena, try ssrJson(arena, v, opts)),
                else => continue,
            },
        };
        try files.append(arena, .{ .path = path, .content = content });
    }
    if (files.items.len == 0) return error.NoSupportedNodes;
    return files.toOwnedSlice(arena);
}

pub fn renderTrojan(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options, template: ?[]const u8) ![]const render.File {
    return renderNative(arena, nodes, opts, template, .trojan);
}

pub fn renderHysteria(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options, template: ?[]const u8) ![]const render.File {
    return renderNative(arena, nodes, opts, template, .hysteria);
}

pub fn renderHysteria2(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options, template: ?[]const u8) ![]const render.File {
    return renderNative(arena, nodes, opts, template, .hysteria2);
}

pub fn renderXray(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options, template: ?[]const u8) ![]const render.File {
    return renderNative(arena, nodes, opts, template, .xray);
}

pub fn renderSs(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options, template: ?[]const u8) ![]const render.File {
    return renderNative(arena, nodes, opts, template, .ss);
}

pub fn renderSsr(arena: std.mem.Allocator, nodes: []const node.Node, opts: Options, template: ?[]const u8) ![]const render.File {
    return renderNative(arena, nodes, opts, template, .ssr);
}

// ---------------- tests ----------------

const trojan_node = node.Node{ .trojan = .{
    .name = "HK-01",
    .server = "hk1.example.com",
    .port = 443,
    .password = "pass123",
    .servername = "hk1.example.com",
    .skip_cert_verify = true,
} };

const trojan_ws_node = node.Node{
    .trojan = .{
        .name = "JP-01/WS", // filename sanitization test
        .server = "jp1.example.com",
        .port = 8443,
        .password = "pass456",
        .servername = "jp1.example.com",
        .network = .ws,
        .ws = .{ .path = "/ws", .host = "jp1.example.com" },
    },
};

const hy1_node = node.Node{ .hysteria = .{
    .name = "JP-02-hy1",
    .server = "hy1.example.com",
    .port = 36712,
    .protocol = "udp",
    .auth_str = "hy1-auth",
    .up = "100",
    .down = "200",
    .sni = "hy1.example.com",
    .skip_cert_verify = true,
} };

const vless_reality_node = node.Node{ .vless = .{
    .name = "KR-01-Reality",
    .server = "kr1.example.com",
    .port = 443,
    .uuid = "11111111-2222-3333-4444-555555555555",
    .network = .tcp,
    .tls = true,
    .reality = .{ .public_key = "77RU9W8QFgOAX-PK7zhMO6uRbGYetq7E5de25HIujMc", .short_id = "ABCDEF" },
    .flow = "xtls-rprx-vision",
    .servername = "www.microsoft.com",
    .fingerprint = "chrome",
} };

const ss_plugin_node = node.Node{ .ss = .{
    .name = "US-03-obfs",
    .server = "us3.example.com",
    .port = 8388,
    .cipher = "aes-256-gcm",
    .password = "ss-pass",
    .plugin = .{ .obfs_local = .{ .mode = "http", .host = "www.bing.com" } },
} };

const ssr_node = node.Node{ .ssr = .{
    .name = "SSR-node",
    .server = "s.example.com",
    .port = 443,
    .cipher = "aes-256-cfb",
    .password = "ssr-pass",
    .protocol = "auth_aes128_md5",
    .obfs = "tls1.2_ticket_auth",
    .obfs_param = "breakwa11.moe",
    .protocol_param = "param1",
} };

const hy2_node = node.Node{ .hysteria2 = .{
    .name = "HK-02-hy2",
    .server = "hk2.example.com",
    .port = 443,
    .password = "hy2-pass",
    .servername = "hk2.example.com",
    .obfs = "salamander",
    .obfs_password = "obfs123",
} };

test "render trojan files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{ trojan_node, trojan_ws_node };
    const files = try renderTrojan(a, &nodes, .{}, null);

    try std.testing.expectEqual(@as(usize, 2), files.len); // one file per node
    try std.testing.expectEqualStrings("HK-01.json", files[0].path);
    try std.testing.expectEqualStrings("JP-01_WS.json", files[1].path);

    // trojan json content checks
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, files[0].content, .{});
    const o = v.object;
    try std.testing.expectEqualStrings("client", o.get("run_type").?.string);
    try std.testing.expectEqualStrings("hk1.example.com", o.get("remote_addr").?.string);
    try std.testing.expectEqual(@as(i64, 443), o.get("remote_port").?.integer);
    try std.testing.expectEqualStrings("pass123", o.get("password").?.array.items[0].string);
    try std.testing.expectEqualStrings("hk1.example.com", o.get("ssl").?.object.get("sni").?.string);
    try std.testing.expectEqual(false, o.get("ssl").?.object.get("verify_cert").?.bool);

    // ws node
    const v2 = try std.json.parseFromSliceLeaky(JsonValue, a, files[1].content, .{});
    const ws = v2.object.get("websocket").?.object;
    try std.testing.expectEqual(true, ws.get("enabled").?.bool);
    try std.testing.expectEqualStrings("/ws", ws.get("path").?.string);
}

test "render hysteria files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{hy1_node};
    const files = try renderHysteria(a, &nodes, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, files[0].content, .{});
    const o = v.object;
    try std.testing.expectEqualStrings("hy1.example.com:36712", o.get("server").?.string);
    try std.testing.expectEqualStrings("hy1-auth", o.get("auth_str").?.string);
    try std.testing.expectEqual(@as(i64, 100), o.get("up_mbps").?.integer);
    try std.testing.expectEqual(true, o.get("tls").?.object.get("insecure").?.bool);
}

test "render hysteria2 files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{hy2_node};
    const files = try renderHysteria2(a, &nodes, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("HK-02-hy2.yaml", files[0].path);
    const text = files[0].content;
    try std.testing.expect(std.mem.indexOf(u8, text, "server: hk2.example.com:443") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "auth: hy2-pass") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type: salamander") != null);
}

test "render xray files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{ vless_reality_node, hy2_node };
    const files = try renderXray(a, &nodes, .{}, null);
    // only the vless node is rendered (hy2 skipped)
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("KR-01-Reality.json", files[0].path);

    const v = try std.json.parseFromSliceLeaky(JsonValue, a, files[0].content, .{});
    const root = v.object;
    // socks inbound
    const inb = root.get("inbounds").?.array.items[0].object;
    try std.testing.expectEqualStrings("socks", inb.get("protocol").?.string);
    try std.testing.expectEqual(@as(i64, 1080), inb.get("port").?.integer);
    // vless outbound
    const out = root.get("outbounds").?.array.items[0].object;
    try std.testing.expectEqualStrings("vless", out.get("protocol").?.string);
    const vn = out.get("settings").?.object.get("vnext").?.array.items[0].object;
    try std.testing.expectEqualStrings("kr1.example.com", vn.get("address").?.string);
    const user = vn.get("users").?.array.items[0].object;
    try std.testing.expectEqualStrings("xtls-rprx-vision", user.get("flow").?.string);
    // streamSettings: reality
    const stream = out.get("streamSettings").?.object;
    try std.testing.expectEqualStrings("reality", stream.get("security").?.string);
    const rs = stream.get("realitySettings").?.object;
    try std.testing.expectEqualStrings("77RU9W8QFgOAX-PK7zhMO6uRbGYetq7E5de25HIujMc", rs.get("publicKey").?.string);
    try std.testing.expectEqualStrings("ABCDEF", rs.get("shortId").?.string);
    try std.testing.expectEqualStrings("chrome", rs.get("fingerprint").?.string);
}

test "render ss files with plugin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{ ss_plugin_node, vless_reality_node };
    const files = try renderSs(a, &nodes, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), files.len);

    const v = try std.json.parseFromSliceLeaky(JsonValue, a, files[0].content, .{});
    const o = v.object;
    try std.testing.expectEqualStrings("us3.example.com", o.get("server").?.string);
    try std.testing.expectEqual(@as(i64, 8388), o.get("server_port").?.integer);
    try std.testing.expectEqualStrings("aes-256-gcm", o.get("method").?.string);
    try std.testing.expectEqualStrings("ss-pass", o.get("password").?.string);
    try std.testing.expectEqualStrings("127.0.0.1", o.get("local_address").?.string);
    try std.testing.expectEqualStrings("obfs-local", o.get("plugin").?.string);
    try std.testing.expectEqualStrings("obfs=http;obfs-host=www.bing.com", o.get("plugin_opts").?.string);
}

test "render ssr files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{ssr_node};
    const files = try renderSsr(a, &nodes, .{}, null);
    try std.testing.expectEqual(@as(usize, 1), files.len);

    const v = try std.json.parseFromSliceLeaky(JsonValue, a, files[0].content, .{});
    const o = v.object;
    try std.testing.expectEqualStrings("auth_aes128_md5", o.get("protocol").?.string);
    try std.testing.expectEqualStrings("tls1.2_ticket_auth", o.get("obfs").?.string);
    try std.testing.expectEqualStrings("breakwa11.moe", o.get("obfs_param").?.string);
    try std.testing.expectEqualStrings("param1", o.get("protocol_param").?.string);
    try std.testing.expectEqual(@as(i64, 443), o.get("server_port").?.integer);
}

test "safeFileName sanitization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // emoji passes through (valid filename bytes on linux), whitespace collapses
    try std.testing.expectEqualStrings("🇭🇰_香港1-电信优化", try safeFileName(a, "🇭🇰 香港1-电信优化"));
    try std.testing.expectEqualStrings("🇭🇰香港1", try safeFileName(a, "🇭🇰香港1"));
    // separator chars become '_', readability kept
    try std.testing.expectEqualStrings("JP-01_WS", try safeFileName(a, "JP-01/WS"));
    try std.testing.expectEqualStrings("a_b_c", try safeFileName(a, "a:b*c"));
    // whitespace collapse + trim
    try std.testing.expectEqualStrings("香港_1", try safeFileName(a, "香港  1"));
    try std.testing.expectEqualStrings("香港1", try safeFileName(a, " 香港1 "));
    // CJK / alnum pass through
    try std.testing.expectEqualStrings("日本1-电信优化", try safeFileName(a, "日本1-电信优化"));
    try std.testing.expectEqualStrings("HK-01", try safeFileName(a, "HK-01"));
    // truncated UTF-8 tails pass through byte-wise (no panic, no decoding)
    try std.testing.expectEqualStrings("abc\xe4", try safeFileName(a, "abc\xe4"));
    try std.testing.expectEqualStrings("ab\xf0\x9f", try safeFileName(a, "ab\xf0\x9f"));
}

test "no supported nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]node.Node{.{ .ss = .{
        .name = "ss-1",
        .server = "s.example.com",
        .port = 8388,
        .cipher = "aes-256-gcm",
        .password = "p",
    } }};
    try std.testing.expectError(error.NoSupportedNodes, renderTrojan(arena.allocator(), &nodes, .{}, null));
}

test "compile-check" {
    _ = &renderTrojan;
    _ = &renderHysteria;
    _ = &renderHysteria2;
    _ = &renderXray;
    _ = &renderSs;
    _ = &renderSsr;
    _ = &renderNative;
    _ = &trojanJson;
    _ = &hysteriaJson;
    _ = &hysteria2Yaml;
    _ = &xrayJson;
    _ = &ssJson;
    _ = &ssrJson;
    _ = &v2rayPluginOpts;
    _ = &safeFileName;
    _ = &buildObj;
    _ = &str;
    _ = &int;
    _ = &jsonToString;
}
