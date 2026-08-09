const std = @import("std");
const node = @import("node.zig");
const render = @import("render.zig");
const tpl = @import("template.zig");
const Options = render.Options;

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// render sing-box config.json (outbounds + selector + clash_api).
/// with a user template: fills the `"outbounds": []` fill point (template keeps
/// log/inbounds/route/experimental etc.). without a template: built-in default
/// structure (same fill mechanism).
pub fn renderSingbox(
    arena: std.mem.Allocator,
    nodes: []const node.Node,
    opts: Options,
    template: ?[]const u8,
) ![]const render.File {
    var root = ObjectMap.init(arena);

    // log
    var log = ObjectMap.init(arena);
    const log_lvl = if (opts.log_level) |l|
        (if (std.mem.eql(u8, l, "warning")) "warn" else l)
    else
        "info"; // clash says warning, sing-box says warn
    try log.put("level", .{ .string = log_lvl });
    try log.put("timestamp", .{ .bool = true });
    try root.put("log", .{ .object = log });

    // inbounds
    var inbounds = std.json.Array.init(arena);
    var socks = ObjectMap.init(arena);
    try socks.put("type", .{ .string = "socks" });
    try socks.put("tag", .{ .string = "socks-in" });
    try socks.put("listen", .{ .string = opts.listen });
    try socks.put("listen_port", .{ .integer = opts.port });
    try inbounds.append(.{ .object = socks });
    // optional tproxy inbound (socks stays for debug/curl testing)
    if (opts.tproxy_port) |tp| {
        var tproxy = ObjectMap.init(arena);
        try tproxy.put("type", .{ .string = "tproxy" });
        try tproxy.put("tag", .{ .string = "tproxy-in" });
        try tproxy.put("listen", .{ .string = opts.listen });
        try tproxy.put("listen_port", .{ .integer = tp });
        try inbounds.append(.{ .object = tproxy });
        // tproxy_ipv6: add a second tproxy inbound on the v6 loopback (one inbound, one address)
        if (opts.tproxy_ipv6) {
            const v6: ?[]const u8 = if (std.mem.eql(u8, opts.listen, "127.0.0.1"))
                "::1"
            else if (std.mem.eql(u8, opts.listen, "0.0.0.0"))
                "::"
            else
                null; // custom v4 listen has no obvious v6 counterpart; use a user template
            if (v6) |addr| {
                var tproxy6 = ObjectMap.init(arena);
                try tproxy6.put("type", .{ .string = "tproxy" });
                try tproxy6.put("tag", .{ .string = "tproxy-in-v6" });
                try tproxy6.put("listen", .{ .string = addr });
                try tproxy6.put("listen_port", .{ .integer = tp });
                try inbounds.append(.{ .object = tproxy6 });
            }
        }
    }
    try root.put("inbounds", .{ .array = inbounds });

    // outbounds fill point: root carries an empty array; the generated block is
    // inserted textually afterwards (template keeps everything else intact)
    try root.put("outbounds", .{ .array = std.json.Array.init(arena) });

    // route
    var route = ObjectMap.init(arena);
    try route.put("final", .{ .string = "PROXY" });
    try route.put("auto_detect_interface", .{ .bool = true });
    try root.put("route", .{ .object = route });

    // clash_api (node switching via WebUI)
    if (opts.enable_clash_api) {
        var experimental = ObjectMap.init(arena);
        var clash_api = ObjectMap.init(arena);
        try clash_api.put("external_controller", .{ .string = opts.controller });
        if (opts.secret) |s| {
            try clash_api.put("secret", .{ .string = s });
        }
        try experimental.put("clash_api", .{ .object = clash_api });
        try root.put("experimental", .{ .object = experimental });
    }

    // serialize base (with empty outbounds), then fill the outbounds block
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try @import("render.zig").writeJsonValue(out.writer(arena), .{ .object = root });
    try out.append(arena, '\n');
    var text: []const u8 = try out.toOwnedSlice(arena);

    // outbounds block (relative indent, complete JSON array): direct + block + selector + nodes
    var oblock: std.ArrayListUnmanaged(u8) = .empty;
    const ow = oblock.writer(arena);
    const wjv = @import("render.zig").writeJsonValue;

    var elems: std.ArrayListUnmanaged(JsonValue) = .empty;

    var direct = ObjectMap.init(arena);
    try direct.put("type", .{ .string = "direct" });
    try direct.put("tag", .{ .string = "direct" });
    try elems.append(arena, .{ .object = direct });

    var block = ObjectMap.init(arena);
    try block.put("type", .{ .string = "block" });
    try block.put("tag", .{ .string = "block" });
    try elems.append(arena, .{ .object = block });

    var selector = ObjectMap.init(arena);
    try selector.put("type", .{ .string = "selector" });
    try selector.put("tag", .{ .string = "PROXY" });
    var sel_outbounds = std.json.Array.init(arena);
    for (nodes) |n| {
        try sel_outbounds.append(.{ .string = n.name() });
    }
    try selector.put("outbounds", .{ .array = sel_outbounds });
    if (nodes.len > 0) {
        try selector.put("default", .{ .string = nodes[0].name() });
    }
    try elems.append(arena, .{ .object = selector });

    for (nodes) |n| {
        if (try renderOutbound(arena, n)) |ob| {
            try elems.append(arena, ob);
        }
    }

    // serialize: open bracket + elements (separated by commas, each re-indented by 2) + close bracket
    try ow.writeAll("[\n");
    for (elems.items, 0..) |e, i| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        try wjv(buf.writer(arena), e);
        var lines = std.mem.splitScalar(u8, buf.items, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            try ow.writeAll("  ");
            try ow.writeAll(l);
            // comma joins elements on the closing brace line
            if (lines.peek() == null and i + 1 < elems.items.len) try ow.writeAll(",");
            try ow.writeAll("\n");
        }
    }
    try ow.writeAll("\n]\n");

    // user template or the just-serialized default base
    if (template) |t| {
        text = try arena.dupe(u8, t);
    }
    text = try tpl.fillList(arena, text, "\"outbounds\"", oblock.items);

    const file = try arena.alloc(render.File, 1);
    file[0] = .{ .path = "config.json", .content = text };
    return file;
}

/// node -> sing-box outbound; unsupported protocols return null (caller counts skips)
fn renderOutbound(arena: std.mem.Allocator, n: node.Node) !?JsonValue {
    switch (n) {
        .ssr => return null, // sing-box has no ssr support
        else => {},
    }
    var o = ObjectMap.init(arena);
    try o.put("tag", .{ .string = n.name() });
    try o.put("server", .{ .string = serverOf(n) });
    try o.put("server_port", .{ .integer = portOf(n) });

    switch (n) {
        .ss => |v| {
            try o.put("type", .{ .string = "shadowsocks" });
            try o.put("method", .{ .string = v.cipher });
            try o.put("password", .{ .string = v.password });
            if (v.plugin) |p| switch (p) {
                .obfs_local => |pl| {
                    try o.put("plugin", .{ .string = "obfs-local" });
                    try o.put("plugin_opts", .{ .string = try std.fmt.allocPrint(arena, "obfs={s};obfs-host={s}", .{ pl.mode, pl.host }) });
                },
                .shadow_tls => |pl| {
                    try o.put("plugin", .{ .string = "shadow-tls" });
                    try o.put("plugin_opts", .{ .string = try std.fmt.allocPrint(arena, "password={s};host={s};version={d}", .{ pl.password, pl.host, pl.version }) });
                },
                .v2ray_plugin => return null, // sing-box has no v2ray-plugin support
            };
        },
        .vmess => |v| {
            try o.put("type", .{ .string = "vmess" });
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("alter_id", .{ .integer = v.alter_id });
            try o.put("security", .{ .string = "auto" });
            try putTls(arena, &o, v.tls, v.servername, v.fingerprint, false, null, null);
            try putTransport(arena, &o, v.network, v.ws, v.grpc);
        },
        .vless => |v| {
            try o.put("type", .{ .string = "vless" });
            try o.put("uuid", .{ .string = v.uuid });
            if (v.flow) |f| try o.put("flow", .{ .string = f });
            try putTls(arena, &o, v.tls, v.servername, v.fingerprint, v.skip_cert_verify, v.reality, v.alpn);
            try putTransport(arena, &o, v.network, v.ws, v.grpc);
        },
        .trojan => |v| {
            try o.put("type", .{ .string = "trojan" });
            try o.put("password", .{ .string = v.password });
            try putTls(arena, &o, true, v.servername, null, v.skip_cert_verify, null, v.alpn);
            try putTransport(arena, &o, v.network, v.ws, v.grpc);
        },
        .hysteria => |v| {
            try o.put("type", .{ .string = "hysteria" });
            try o.put("up", .{ .string = try mbps(arena, v.up) });
            try o.put("down", .{ .string = try mbps(arena, v.down) });
            if (v.auth_str) |a| {
                // sing-box hysteria auth is base64-encoded
                const enc = std.base64.standard.Encoder;
                const buf = try arena.alloc(u8, enc.calcSize(a.len));
                _ = enc.encode(buf, a);
                try o.put("auth", .{ .string = buf });
            }
            if (v.obfs) |obfs| try o.put("obfs", .{ .string = obfs });
            var tls = ObjectMap.init(arena);
            try tls.put("enabled", .{ .bool = true });
            if (v.sni) |sni| try tls.put("server_name", .{ .string = sni });
            if (v.skip_cert_verify) try tls.put("insecure", .{ .bool = true });
            if (v.alpn) |list| {
                if (list.len > 0) {
                    var arr = std.json.Array.init(arena);
                    for (list) |a| try arr.append(.{ .string = a });
                    try tls.put("alpn", .{ .array = arr });
                }
            }
            try o.put("tls", .{ .object = tls });
        },
        .hysteria2 => |v| {
            try o.put("type", .{ .string = "hysteria2" });
            try o.put("password", .{ .string = v.password });
            if (v.obfs) |obfs| {
                var ob = ObjectMap.init(arena);
                try ob.put("type", .{ .string = obfs });
                if (v.obfs_password) |p| try ob.put("password", .{ .string = p });
                try o.put("obfs", .{ .object = ob });
            }
            var tls = ObjectMap.init(arena);
            try tls.put("enabled", .{ .bool = true });
            if (v.servername) |sni| try tls.put("server_name", .{ .string = sni });
            if (v.skip_cert_verify) try tls.put("insecure", .{ .bool = true });
            if (v.alpn) |list| {
                if (list.len > 0) {
                    var arr = std.json.Array.init(arena);
                    for (list) |a| try arr.append(.{ .string = a });
                    try tls.put("alpn", .{ .array = arr });
                }
            }
            try o.put("tls", .{ .object = tls });
        },
        .tuic => |v| {
            try o.put("type", .{ .string = "tuic" });
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("password", .{ .string = v.password });
            if (v.congestion_controller) |c| try o.put("congestion_control", .{ .string = c });
            if (v.udp_relay_mode) |m| try o.put("udp_relay_mode", .{ .string = m });
            var tls = ObjectMap.init(arena);
            try tls.put("enabled", .{ .bool = true });
            if (v.servername) |sni| try tls.put("server_name", .{ .string = sni });
            if (v.skip_cert_verify) try tls.put("insecure", .{ .bool = true });
            if (v.alpn) |list| {
                if (list.len > 0) {
                    var arr = std.json.Array.init(arena);
                    for (list) |a| try arr.append(.{ .string = a });
                    try tls.put("alpn", .{ .array = arr });
                }
            }
            try o.put("tls", .{ .object = tls });
        },
        .ssr => unreachable,
    }
    return .{ .object = o };
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

fn putTls(
    arena: std.mem.Allocator,
    o: *ObjectMap,
    enabled: bool,
    servername: ?[]const u8,
    fingerprint: ?[]const u8,
    insecure: bool,
    reality: ?node.RealityOpts,
    alpn: ?[]const []const u8,
) !void {
    if (!enabled and servername == null and reality == null and alpn == null) return;
    var tls = ObjectMap.init(arena);
    try tls.put("enabled", .{ .bool = enabled });
    if (servername) |sni| try tls.put("server_name", .{ .string = sni });
    if (insecure) try tls.put("insecure", .{ .bool = true });
    if (alpn) |list| {
        if (list.len > 0) {
            var arr = std.json.Array.init(arena);
            for (list) |a| try arr.append(.{ .string = a });
            try tls.put("alpn", .{ .array = arr });
        }
    }
    if (fingerprint) |fp| {
        var utls = ObjectMap.init(arena);
        try utls.put("enabled", .{ .bool = true });
        try utls.put("fingerprint", .{ .string = fp });
        try tls.put("utls", .{ .object = utls });
    }
    // sing-box reality lives in the tls sub-object
    if (reality) |r| {
        var ro = ObjectMap.init(arena);
        try ro.put("enabled", .{ .bool = true });
        try ro.put("public_key", .{ .string = r.public_key });
        if (r.short_id) |sid| try ro.put("short_id", .{ .string = sid });
        if (r.spider_x) |spx| try ro.put("spider_x", .{ .string = spx });
        try tls.put("reality", .{ .object = ro });
    }
    try o.put("tls", .{ .object = tls });
}

fn putTransport(
    arena: std.mem.Allocator,
    o: *ObjectMap,
    network: node.Network,
    ws: ?node.WsOpts,
    grpc: ?node.GrpcOpts,
) !void {
    switch (network) {
        .tcp => {},
        .ws => {
            var t = ObjectMap.init(arena);
            try t.put("type", .{ .string = "ws" });
            if (ws) |w| {
                try t.put("path", .{ .string = w.path });
                if (w.host) |h| {
                    var headers = ObjectMap.init(arena);
                    try headers.put("Host", .{ .string = h });
                    try t.put("headers", .{ .object = headers });
                }
            }
            try o.put("transport", .{ .object = t });
        },
        .grpc => {
            var t = ObjectMap.init(arena);
            try t.put("type", .{ .string = "grpc" });
            if (grpc) |g| try t.put("service_name", .{ .string = g.service_name });
            try o.put("transport", .{ .object = t });
        },
        .http => {
            var t = ObjectMap.init(arena);
            try t.put("type", .{ .string = "http" });
            try o.put("transport", .{ .object = t });
        },
    }
}

/// upmbps/downmbps number -> sing-box "N Mbps" string
fn mbps(arena: std.mem.Allocator, v: ?[]const u8) ![]const u8 {
    const s = v orelse return "0 Mbps";
    const n = std.fmt.parseInt(u32, s, 10) catch return "0 Mbps";
    return std.fmt.allocPrint(arena, "{d} Mbps", .{n});
}

// ---------------- tests ----------------

const test_nodes = [_]node.Node{
    .{ .trojan = .{
        .name = "HK-01",
        .server = "hk1.example.com",
        .port = 443,
        .password = "pass123",
        .servername = "hk1.example.com",
        .skip_cert_verify = true,
    } },
    .{ .vless = .{
        .name = "KR-01",
        .server = "kr1.example.com",
        .port = 443,
        .uuid = "11111111-2222-3333-4444-555555555555",
        .network = .ws,
        .tls = true,
        .reality = .{ .public_key = "abc-def", .short_id = "ABCDEF" },
        .flow = "xtls-rprx-vision",
        .servername = "www.microsoft.com",
        .fingerprint = "chrome",
        .alpn = &.{ "h2", "http/1.1" },
        .ws = .{ .path = "/ws", .host = "kr1.example.com" },
    } },
    .{
        .ssr = .{ // sing-box does not support ssr; should be skipped
            .name = "ssr-1",
            .server = "s.example.com",
            .port = 443,
            .cipher = "aes-256-cfb",
            .password = "p",
            .protocol = "origin",
            .obfs = "plain",
        },
    },
    .{ .hysteria2 = .{
        .name = "HK-02",
        .server = "hk2.example.com",
        .port = 443,
        .password = "hy2-pass",
        .servername = "hk2.example.com",
        .obfs = "salamander",
        .obfs_password = "obfs123",
    } },
};

test "render singbox json structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = (try renderSingbox(a, &test_nodes, .{ .secret = "sec", .enable_clash_api = true }, null))[0].content;

    // re-parse JSON to validate
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, text, .{});
    const root = v.object;
    const outbounds = root.get("outbounds").?.array;
    // direct + block + selector + 3 nodes (ssr skipped)
    try std.testing.expectEqual(@as(usize, 6), outbounds.items.len);
    try std.testing.expectEqualStrings("direct", outbounds.items[0].object.get("tag").?.string);
    const sel = outbounds.items[2].object;
    try std.testing.expectEqualStrings("PROXY", sel.get("tag").?.string);
    try std.testing.expectEqual(@as(usize, 4), sel.get("outbounds").?.array.items.len);
    // vless reality node
    const vless = outbounds.items[4].object;
    try std.testing.expectEqualStrings("vless", vless.get("type").?.string);
    try std.testing.expectEqualStrings("xtls-rprx-vision", vless.get("flow").?.string);
    const tls = vless.get("tls").?.object;
    try std.testing.expectEqualStrings("www.microsoft.com", tls.get("server_name").?.string);
    const reality = tls.get("reality").?.object;
    try std.testing.expectEqualStrings("abc-def", reality.get("public_key").?.string);
    const alpn = tls.get("alpn").?.array;
    try std.testing.expectEqual(@as(usize, 2), alpn.items.len);
    try std.testing.expectEqualStrings("h2", alpn.items[0].string);
    try std.testing.expectEqualStrings("http/1.1", alpn.items[1].string);
    const transport = vless.get("transport").?.object;
    try std.testing.expectEqualStrings("ws", transport.get("type").?.string);
    // clash_api
    const api = root.get("experimental").?.object.get("clash_api").?.object;
    try std.testing.expectEqualStrings("127.0.0.1:65501", api.get("external_controller").?.string);
    try std.testing.expectEqualStrings("sec", api.get("secret").?.string);
}

test "singbox with user template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tpl_text = "{\n  \"log\": {\"level\": \"debug\"},\n  \"outbounds\": []\n}\n";
    const files = try renderSingbox(a, &test_nodes, .{}, tpl_text);
    try std.testing.expectEqualStrings("config.json", files[0].path);
    const text = files[0].content;
    // user log kept
    try std.testing.expect(std.mem.indexOf(u8, text, "\"level\": \"debug\"") != null);
    // outbounds filled (parse & count)
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, text, .{});
    const outbounds = v.object.get("outbounds").?.array;
    // direct + block + selector + 3 supported nodes (ssr skipped)
    try std.testing.expectEqual(@as(usize, 6), outbounds.items.len);
    // missing fill point -> error
    try std.testing.expectError(error.MissingFillPoint, renderSingbox(a, &test_nodes, .{}, "{\n  \"log\": {}\n}\n"));
}

test "mbps format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("100 Mbps", try mbps(arena.allocator(), "100"));
    try std.testing.expectEqualStrings("0 Mbps", try mbps(arena.allocator(), null));
    try std.testing.expectEqualStrings("0 Mbps", try mbps(arena.allocator(), "abc"));
}

test "compile-check" {
    _ = &renderSingbox;
    _ = &renderOutbound;
    _ = &serverOf;
    _ = &portOf;
    _ = &putTls;
    _ = &putTransport;
    _ = &mbps;
}
