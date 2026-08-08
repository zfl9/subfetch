const std = @import("std");
const util = @import("util.zig");
const node = @import("node.zig");
const Node = node.Node;

pub const ParseError = error{
    OutOfMemory,
    InvalidUri,
    UnsupportedScheme,
    BadBase64,
    MissingField,
    InvalidPort,
    UnsupportedPlugin,
    InvalidJson,
    UnsupportedNetwork,
};

// ---------------- manual URI parsing ----------------
// std.Uri is not used: base64 fields in subscription links may contain '/' etc.,
// which std.Uri would mis-split as path; manual splitting only honors '@' '?' '#',
// matching v1 (Python urlsplit) behavior with more control.

const ManualUri = struct {
    scheme: []const u8,
    userinfo: ?[]const u8 = null,
    host: []const u8,
    port: ?u16 = null,
    query: []const u8 = "",
    fragment: []const u8 = "",
    body: []const u8, // full authority (without query/fragment)
};

fn parseUriManual(url: []const u8) ?ManualUri {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const scheme = url[0..scheme_end];
    var rest = url[scheme_end + 3 ..];

    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    const body = rest;

    var userinfo: ?[]const u8 = null;
    var hostport = rest;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| {
        userinfo = rest[0..i];
        hostport = rest[i + 1 ..];
    }

    var host = hostport;
    var port: ?u16 = null;
    if (hostport.len > 0 and hostport[0] == '[') {
        // IPv6 literal [::1]:443
        if (std.mem.indexOfScalar(u8, hostport, ']')) |close| {
            host = hostport[1..close];
            if (close + 1 < hostport.len and hostport[close + 1] == ':') {
                port = parsePort(hostport[close + 2 ..]) catch null;
            }
        }
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |i| {
        host = hostport[0..i];
        port = parsePort(hostport[i + 1 ..]) catch null;
    }

    return .{ .scheme = scheme, .userinfo = userinfo, .host = host, .port = port, .query = query, .fragment = fragment, .body = body };
}

fn parsePort(s: []const u8) !u16 {
    if (s.len == 0 or s.len > 5) return error.InvalidPort;
    return std.fmt.parseInt(u16, s, 10) catch error.InvalidPort;
}

// ---------------- basic helpers ----------------

/// lenient base64 decode: strips whitespace, converts url-safe charset, pads. null on failure.
const b64Decode = util.b64Decode;

/// percent decode; zero-copy returns the original slice when no % is present.
const urlDecode = util.urlDecode;

const QueryParam = struct { key: []const u8, value: []const u8 };

fn parseQuery(allocator: std.mem.Allocator, query: []const u8) ParseError![]QueryParam {
    if (query.len == 0) return &.{};
    var params: std.ArrayListUnmanaged(QueryParam) = .empty;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        var key = pair;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            key = pair[0..eq];
            value = pair[eq + 1 ..];
        }
        try params.append(allocator, .{
            .key = try urlDecode(allocator, key),
            .value = try urlDecode(allocator, value),
        });
    }
    return params.toOwnedSlice(allocator);
}

fn queryGet(params: []const QueryParam, key: []const u8) ?[]const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.value;
    }
    return null;
}

fn queryBool(params: []const QueryParam, key: []const u8) bool {
    const v = queryGet(params, key) orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true") or
        std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "on");
}

fn parseNetwork(s: []const u8) ParseError!node.Network {
    if (std.mem.eql(u8, s, "tcp")) return .tcp;
    if (std.mem.eql(u8, s, "ws")) return .ws;
    if (std.mem.eql(u8, s, "grpc")) return .grpc;
    if (std.mem.eql(u8, s, "http")) return .http;
    return error.UnsupportedNetwork;
}

fn parseAlpn(allocator: std.mem.Allocator, v: ?[]const u8) ParseError!?[]const []const u8 {
    const s = v orelse return null;
    if (s.len == 0) return null;
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len > 0) try list.append(allocator, t);
    }
    if (list.items.len == 0) return null;
    return @as(?[]const []const u8, try list.toOwnedSlice(allocator));
}

/// normalize the reality public-key to urlsafe base64 without padding (a hard mihomo requirement).
fn normalizeRealityKey(allocator: std.mem.Allocator, key: []const u8) ParseError![]const u8 {
    const raw = (try b64Decode(allocator, key)) orelse return key;
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(raw.len));
    _ = enc.encode(out, raw);
    for (out) |*ch| {
        ch.* = switch (ch.*) {
            '+' => '-',
            '/' => '_',
            else => ch.*,
        };
    }
    var end = out.len;
    while (end > 0 and out[end - 1] == '=') end -= 1;
    return out[0..end];
}

fn makeName(
    allocator: std.mem.Allocator,
    p: *const ManualUri,
    sub_name: []const u8,
    sep: []const u8,
    server: []const u8,
    port: u16,
) ParseError![]const u8 {
    const fragment = try urlDecode(allocator, p.fragment);
    const fallback = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ server, port });
    return node.prefixed(allocator, sub_name, fragment, sep, fallback);
}

fn applyWsGrpc(
    ws: *?node.WsOpts,
    grpc: *?node.GrpcOpts,
    network: node.Network,
    params: []const QueryParam,
) void {
    switch (network) {
        .ws => {
            ws.* = .{ .path = queryGet(params, "path") orelse "/", .host = queryGet(params, "host") };
        },
        .grpc => {
            grpc.* = .{ .service_name = queryGet(params, "serviceName") orelse queryGet(params, "path") orelse "" };
        },
        else => {},
    }
}

// ---------------- ss ----------------

fn parseSsPlugin(allocator: std.mem.Allocator, plugin: []const u8) ParseError!node.SsPlugin {
    const decoded = try urlDecode(allocator, plugin);
    const PluginKV = struct { key: []const u8, value: ?[]const u8 };
    var kv: std.ArrayListUnmanaged(PluginKV) = .empty;
    var parts = std.mem.splitScalar(u8, decoded, ';');
    const name = parts.next() orelse return error.UnsupportedPlugin;
    while (parts.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        if (std.mem.indexOfScalar(u8, t, '=')) |eq| {
            try kv.append(allocator, .{ .key = t[0..eq], .value = t[eq + 1 ..] });
        } else {
            try kv.append(allocator, .{ .key = t, .value = null });
        }
    }
    const kvGet = struct {
        fn get(kvs: []const PluginKV, key: []const u8) ?[]const u8 {
            for (kvs) |e| {
                if (std.mem.eql(u8, e.key, key)) return e.value;
            }
            return null;
        }
    }.get;

    if (std.mem.eql(u8, name, "obfs-local")) {
        return .{ .obfs_local = .{
            .mode = kvGet(kv.items, "obfs") orelse "http",
            .host = kvGet(kv.items, "obfs-host") orelse "www.bing.com",
        } };
    }
    if (std.mem.eql(u8, name, "v2ray-plugin")) {
        var result: node.SsPlugin = .{ .v2ray_plugin = .{} };
        const vp = &result.v2ray_plugin;
        if (kvGet(kv.items, "mode")) |m| vp.mode = m;
        for (kv.items) |e| {
            if (std.mem.eql(u8, e.key, "tls")) vp.tls = true;
        }
        vp.host = kvGet(kv.items, "host");
        vp.path = kvGet(kv.items, "path");
        return result;
    }
    if (std.mem.eql(u8, name, "shadow-tls")) {
        const ver = kvGet(kv.items, "version") orelse "3";
        const version: u8 = std.fmt.parseInt(u8, ver, 10) catch 3;
        return .{ .shadow_tls = .{
            .host = kvGet(kv.items, "host") orelse "",
            .password = kvGet(kv.items, "password") orelse "",
            .version = version,
        } };
    }
    return error.UnsupportedPlugin;
}

fn parseSs(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    if (p.userinfo) |ui| {
        // SIP002: base64(method:password)@host:port?plugin=...
        const user = try urlDecode(arena, ui);
        const decoded = (try b64Decode(arena, user)) orelse return error.BadBase64;
        const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return error.MissingField;
        const cipher = try arena.dupe(u8, decoded[0..colon]);
        const password = try arena.dupe(u8, decoded[colon + 1 ..]);
        if (p.host.len == 0) return error.MissingField;
        const port = p.port orelse return error.InvalidPort;
        var n: node.SS = .{
            .name = try makeName(arena, p, sub_name, sep, p.host, port),
            .server = try urlDecode(arena, p.host),
            .port = port,
            .cipher = cipher,
            .password = password,
        };
        const params = try parseQuery(arena, p.query);
        if (queryGet(params, "plugin")) |plugin| {
            n.plugin = try parseSsPlugin(arena, plugin);
        }
        return .{ .ss = n };
    }
    // legacy: base64(method:password@host:port)
    const decoded = (try b64Decode(arena, p.body)) orelse return error.BadBase64;
    if (std.mem.lastIndexOfScalar(u8, decoded, '@')) |at| {
        const mp = decoded[0..at];
        const hp = decoded[at + 1 ..];
        const colon = std.mem.indexOfScalar(u8, mp, ':') orelse return error.MissingField;
        const cipher = try arena.dupe(u8, mp[0..colon]);
        const password = try arena.dupe(u8, mp[colon + 1 ..]);
        const host = hp[0 .. std.mem.lastIndexOfScalar(u8, hp, ':') orelse hp.len];
        const port = if (std.mem.lastIndexOfScalar(u8, hp, ':')) |i| try parsePort(hp[i + 1 ..]) else return error.InvalidPort;
        if (host.len == 0) return error.MissingField;
        return .{ .ss = .{
            .name = try makeName(arena, p, sub_name, sep, host, port),
            .server = host,
            .port = port,
            .cipher = cipher,
            .password = password,
        } };
    }
    return error.MissingField;
}

// ---------------- ssr ----------------

fn parseSsr(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    const decoded = (try b64Decode(arena, p.body)) orelse return error.BadBase64;
    const text = decoded;
    var main = text;
    var params_text: []const u8 = "";
    if (std.mem.indexOfScalar(u8, text, '?')) |i| {
        main = text[0..i];
        params_text = text[i + 1 ..];
    }
    var parts = std.mem.splitScalar(u8, main, ':');
    const host = parts.next() orelse return error.MissingField;
    const port = try parsePort(parts.next() orelse return error.MissingField);
    const protocol = parts.next() orelse return error.MissingField;
    const cipher = parts.next() orelse return error.MissingField;
    const obfs = parts.next() orelse return error.MissingField;
    const b64pass = parts.next() orelse return error.MissingField;
    // use the raw password when base64 decoding fails
    const password = (try b64Decode(arena, b64pass)) orelse try arena.dupe(u8, b64pass);

    var n: node.SSR = .{
        .name = try makeName(arena, p, sub_name, sep, host, port),
        .server = try urlDecode(arena, host),
        .port = port,
        .cipher = cipher,
        .password = password,
        .protocol = protocol,
        .obfs = obfs,
    };
    if (params_text.len > 0) {
        const params = try parseQuery(arena, params_text);
        if (queryGet(params, "obfsparam")) |v| n.obfs_param = try b64Str(arena, v);
        if (queryGet(params, "protoparam")) |v| n.protocol_param = try b64Str(arena, v);
        // the ssr node name lives in the remarks param (base64-encoded)
        if (queryGet(params, "remarks")) |v| {
            const remarks = try b64Str(arena, v);
            const fallback = try std.fmt.allocPrint(arena, "{s}:{d}", .{ host, port });
            n.name = try node.prefixed(arena, sub_name, remarks, sep, fallback);
        }
    }
    return .{ .ssr = n };
}

fn b64Str(allocator: std.mem.Allocator, s: []const u8) ParseError![]const u8 {
    const dec = try b64Decode(allocator, s);
    if (dec) |d| {
        if (d.len > 0) return d;
    }
    return s;
}

// ---------------- vmess / vless ----------------

fn vmessFromJson(arena: std.mem.Allocator, json_text: []const u8, sub_name: []const u8, sep: []const u8) ParseError!Node {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{}) catch return error.InvalidJson;
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };
    const getStr = struct {
        fn get(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
            const v = o.get(key) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }
    }.get;

    const server = getStr(obj, "add") orelse return error.MissingField;
    const port = try parsePort(getStr(obj, "port") orelse return error.MissingField);
    const uuid = getStr(obj, "id") orelse return error.MissingField;
    const raw_name = getStr(obj, "ps") orelse "";
    const fallback = try std.fmt.allocPrint(arena, "{s}:{d}", .{ server, port });
    const name = try node.prefixed(arena, sub_name, raw_name, sep, fallback);

    var n: node.Vmess = .{
        .name = name,
        .server = server,
        .port = port,
        .uuid = uuid,
    };
    if (getStr(obj, "aid")) |aid| {
        n.alter_id = std.fmt.parseInt(u16, aid, 10) catch 0;
    }
    if (getStr(obj, "net")) |net| {
        n.network = parseNetwork(net) catch .tcp;
    }
    if (std.mem.eql(u8, getStr(obj, "tls") orelse "", "tls")) n.tls = true;
    n.servername = getStr(obj, "sni");
    n.fingerprint = getStr(obj, "fp");
    if (getStr(obj, "host")) |host| {
        if (n.network == .ws) {
            n.ws = .{ .path = getStr(obj, "path") orelse "/", .host = host };
        }
    } else if (n.network == .ws) {
        n.ws = .{ .path = getStr(obj, "path") orelse "/" };
    }
    if (n.network == .grpc) {
        n.grpc = .{ .service_name = getStr(obj, "serviceName") orelse getStr(obj, "path") orelse "" };
    }
    return .{ .vmess = n };
}

fn parseXurl(arena: std.mem.Allocator, p: *const ManualUri, typ: enum { vmess, vless }, sub_name: []const u8, sep: []const u8) ParseError!Node {
    const uuid = try urlDecode(arena, p.userinfo orelse return error.MissingField);
    if (uuid.len == 0) return error.MissingField;
    if (p.host.len == 0) return error.MissingField;
    const port = p.port orelse return error.InvalidPort;
    const server = try urlDecode(arena, p.host);
    const params = try parseQuery(arena, p.query);
    const network = parseNetwork(queryGet(params, "type") orelse "tcp") catch return error.UnsupportedNetwork;
    const security = queryGet(params, "security") orelse "none";
    const name = try makeName(arena, p, sub_name, sep, server, port);

    if (typ == .vmess) {
        var n: node.Vmess = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = uuid,
            .network = network,
        };
        if (std.mem.eql(u8, security, "tls")) n.tls = true;
        n.servername = queryGet(params, "sni");
        n.fingerprint = queryGet(params, "fp");
        applyWsGrpc(&n.ws, &n.grpc, network, params);
        return .{ .vmess = n };
    }

    var n: node.Vless = .{
        .name = name,
        .server = server,
        .port = port,
        .uuid = uuid,
        .network = network,
    };
    if (std.mem.eql(u8, security, "tls")) {
        n.tls = true;
    } else if (std.mem.eql(u8, security, "reality")) {
        n.tls = true;
        n.reality = .{
            .public_key = try normalizeRealityKey(arena, queryGet(params, "pbk") orelse return error.MissingField),
            .short_id = queryGet(params, "sid"),
            .spider_x = queryGet(params, "spx"),
        };
    }
    n.flow = queryGet(params, "flow");
    n.servername = queryGet(params, "sni");
    n.fingerprint = queryGet(params, "fp");
    n.skip_cert_verify = queryBool(params, "allowInsecure");
    n.alpn = try parseAlpn(arena, queryGet(params, "alpn"));
    applyWsGrpc(&n.ws, &n.grpc, network, params);
    return .{ .vless = n };
}

fn parseVmess(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    if (p.userinfo != null) return parseXurl(arena, p, .vmess, sub_name, sep);
    // legacy: base64(JSON)
    const decoded = (try b64Decode(arena, p.body)) orelse return error.BadBase64;
    return vmessFromJson(arena, decoded, sub_name, sep);
}

// ---------------- trojan / hysteria / hysteria2 / tuic ----------------

fn parseTrojan(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    const password = try urlDecode(arena, p.userinfo orelse return error.MissingField);
    if (password.len == 0) return error.MissingField;
    if (p.host.len == 0) return error.MissingField;
    // port omitted defaults to 443 (parsePortOrDefault behavior in community implementations)
    const port = p.port orelse 443;
    const server = try urlDecode(arena, p.host);
    const params = try parseQuery(arena, p.query);

    var n: node.Trojan = .{
        .name = try makeName(arena, p, sub_name, sep, server, port),
        .server = server,
        .port = port,
        .password = password,
    };
    n.servername = queryGet(params, "sni") orelse queryGet(params, "peer");
    // v2rayN ecosystem uses allowInsecure; clash-verge/mihomo ecosystem uses skip-cert-verify
    n.skip_cert_verify = queryBool(params, "allowInsecure") or queryBool(params, "skip-cert-verify");
    n.alpn = try parseAlpn(arena, queryGet(params, "alpn"));
    const net = queryGet(params, "type") orelse "";
    if (std.mem.eql(u8, net, "ws")) {
        n.network = .ws;
        n.ws = .{ .path = queryGet(params, "path") orelse "/", .host = queryGet(params, "host") };
    } else if (std.mem.eql(u8, net, "grpc")) {
        n.network = .grpc;
        n.grpc = .{ .service_name = queryGet(params, "serviceName") orelse queryGet(params, "path") orelse "" };
    }
    return .{ .trojan = n };
}

fn parseHysteria(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    if (p.host.len == 0) return error.MissingField;
    const port = p.port orelse 443;
    const server = try urlDecode(arena, p.host);
    const params = try parseQuery(arena, p.query);

    var n: node.Hysteria = .{
        .name = try makeName(arena, p, sub_name, sep, server, port),
        .server = server,
        .port = port,
    };
    if (queryGet(params, "protocol")) |v| n.protocol = v;
    n.auth_str = queryGet(params, "auth");
    n.sni = queryGet(params, "peer");
    n.skip_cert_verify = queryBool(params, "insecure");
    n.up = queryGet(params, "upmbps");
    n.down = queryGet(params, "downmbps");
    n.obfs = queryGet(params, "obfs");
    n.alpn = try parseAlpn(arena, queryGet(params, "alpn"));
    return .{ .hysteria = n };
}

fn parseHy2(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    const password = try urlDecode(arena, p.userinfo orelse return error.MissingField);
    if (p.host.len == 0) return error.MissingField;
    // port omitted defaults to 443 (explicit in the official hy2 URI spec)
    const port = p.port orelse 443;
    const server = try urlDecode(arena, p.host);
    const params = try parseQuery(arena, p.query);

    var n: node.Hysteria2 = .{
        .name = try makeName(arena, p, sub_name, sep, server, port),
        .server = server,
        .port = port,
        .password = password,
    };
    n.servername = queryGet(params, "sni") orelse queryGet(params, "peer");
    n.skip_cert_verify = queryBool(params, "insecure");
    // obfs=none is equivalent to unset (clash-verge behavior)
    if (queryGet(params, "obfs")) |obfs| {
        if (!std.mem.eql(u8, obfs, "none")) n.obfs = obfs;
    }
    n.obfs_password = queryGet(params, "obfs-password");
    n.alpn = try parseAlpn(arena, queryGet(params, "alpn"));
    return .{ .hysteria2 = n };
}

fn parseTuic(arena: std.mem.Allocator, p: *const ManualUri, sub_name: []const u8, sep: []const u8) ParseError!Node {
    const ui = try urlDecode(arena, p.userinfo orelse return error.MissingField);
    const colon = std.mem.indexOfScalar(u8, ui, ':') orelse return error.MissingField;
    const uuid = ui[0..colon];
    const password = ui[colon + 1 ..];
    if (p.host.len == 0) return error.MissingField;
    // port omitted defaults to 443 (parsePortOrDefault behavior in community implementations)
    const port = p.port orelse 443;
    const server = try urlDecode(arena, p.host);
    const params = try parseQuery(arena, p.query);

    var n: node.Tuic = .{
        .name = try makeName(arena, p, sub_name, sep, server, port),
        .server = server,
        .port = port,
        .uuid = uuid,
        .password = password,
    };
    n.servername = queryGet(params, "sni");
    // EAimTY official uses underscores; mihomo/clash-verge ecosystem uses hyphens; support both
    n.skip_cert_verify = queryBool(params, "allow_insecure") or
        queryBool(params, "allow-insecure") or
        queryBool(params, "skip-cert-verify");
    n.congestion_controller = queryGet(params, "congestion_control") orelse queryGet(params, "congestion-controller");
    n.udp_relay_mode = queryGet(params, "udp_relay_mode") orelse queryGet(params, "udp-relay-mode");
    n.alpn = try parseAlpn(arena, queryGet(params, "alpn"));
    return .{ .tuic = n };
}

// ---------------- unified entry ----------------

/// parse a single node URI. the name already carries the subscription prefix.
pub fn parseUri(
    arena: std.mem.Allocator,
    url: []const u8,
    sub_name: []const u8,
    sep: []const u8,
) ParseError!Node {
    const p = parseUriManual(url) orelse return error.InvalidUri;
    if (std.mem.eql(u8, p.scheme, "ss")) return parseSs(arena, &p, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "ssr")) return parseSsr(arena, &p, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "vmess")) return parseVmess(arena, &p, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "vless")) return parseXurl(arena, &p, .vless, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "trojan")) return parseTrojan(arena, &p, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "hysteria")) return parseHysteria(arena, &p, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "hysteria2") or std.mem.eql(u8, p.scheme, "hy2")) return parseHy2(arena, &p, sub_name, sep);
    if (std.mem.eql(u8, p.scheme, "tuic")) return parseTuic(arena, &p, sub_name, sep);
    return error.UnsupportedScheme;
}

// ---------------- tests ----------------

const test_ss_sip002 = "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@sg3.example.com:8388#SG-03-SS";
const test_ss_obfs = "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@us3.example.com:8388?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dwww.bing.com#US-03-obfs";
const test_vmess_url = "vmess://22222222-3333-4444-5555-666666666666@sg1.example.com:443?encryption=auto&security=tls&type=ws&host=sg1.example.com&path=%2Fvmess&sni=sg1.example.com&fp=chrome#SG-01-new";
const test_vless_reality = "vless://11111111-2222-3333-4444-555555555555@kr1.example.com:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com&fp=chrome&pbk=77RU9W8QFgOAX%2BPK7zhMO6uRbGYetq7E5de25HIujMc%3D&sid=ABCDEF#KR-01-Reality";
const test_trojan = "trojan://tw-pass-123@hk1.example.com:443?sni=hk1.example.com&allowInsecure=1#HK-01-CM";
const test_hy2 = "hysteria2://hy2-pass@hk2.example.com:443?insecure=1&sni=hk2.example.com&obfs=salamander&obfs-password=obfs123#HK-02-hy2";
const test_hy1 = "hysteria://hy1.example.com:36712?protocol=udp&auth=hy1-auth&peer=hy1.example.com&insecure=1&upmbps=100&downmbps=200#JP-02-hy1";
const test_tuic = "tuic://11111111-2222-3333-4444-555555555555:tuic-pass@sg2.example.com:443?sni=sg2.example.com&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#SG-02-TUIC";

test "parse ss sip002" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_ss_sip002, "airport-a", "@");
    try std.testing.expectEqualStrings("ss", n.typeName());
    try std.testing.expectEqualStrings("airport-a@SG-03-SS", n.name());
    const ss = n.ss;
    try std.testing.expectEqualStrings("sg3.example.com", ss.server);
    try std.testing.expectEqual(@as(u16, 8388), ss.port);
    try std.testing.expectEqualStrings("aes-256-gcm", ss.cipher);
    try std.testing.expectEqualStrings("password", ss.password);
    try std.testing.expect(ss.plugin == null);
}

test "parse ss obfs-local plugin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_ss_obfs, "", "@");
    const plugin = n.ss.plugin.?;
    try std.testing.expectEqualStrings("http", plugin.obfs_local.mode);
    try std.testing.expectEqualStrings("www.bing.com", plugin.obfs_local.host);
}

test "parse ss legacy base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // base64("aes-256-gcm:password@1.2.3.4:8388")
    const link = try std.fmt.allocPrint(arena.allocator(), "ss://{s}#legacy-node", .{try b64(arena.allocator(), "aes-256-gcm:password@1.2.3.4:8388")});
    const n = try parseUri(arena.allocator(), link, "", "@");
    try std.testing.expectEqualStrings("1.2.3.4", n.ss.server);
    try std.testing.expectEqual(@as(u16, 8388), n.ss.port);
    try std.testing.expectEqualStrings("legacy-node", n.name());
}

test "parse ssr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // build an ssr link (same shape as fixtures/ssr.txt)
    const b64u = std.base64.url_safe;
    var pass_buf: [64]u8 = undefined;
    const pass = b64u.Encoder.encode(&pass_buf, "ssrpass123");
    const main = try std.fmt.allocPrint(arena.allocator(), "1.2.3.4:443:origin:aes-256-cfb:plain:{s}", .{pass});
    var remarks_buf: [64]u8 = undefined;
    const remarks = b64u.Encoder.encode(&remarks_buf, "SSR-test-node");
    const link_body = try std.fmt.allocPrint(arena.allocator(), "{s}?remarks={s}", .{ main, remarks });
    var enc_buf: [512]u8 = undefined;
    const enc = b64u.Encoder.encode(&enc_buf, link_body);
    const link = try std.fmt.allocPrint(arena.allocator(), "ssr://{s}", .{enc});

    const n = try parseUri(arena.allocator(), link, "", "@");
    try std.testing.expectEqualStrings("1.2.3.4", n.ssr.server);
    try std.testing.expectEqual(@as(u16, 443), n.ssr.port);
    try std.testing.expectEqualStrings("aes-256-cfb", n.ssr.cipher);
    try std.testing.expectEqualStrings("ssrpass123", n.ssr.password);
    try std.testing.expectEqualStrings("origin", n.ssr.protocol);
    try std.testing.expectEqualStrings("plain", n.ssr.obfs);
    try std.testing.expectEqualStrings("SSR-test-node", n.name());
}

test "parse vmess legacy json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"v\":\"2\",\"ps\":\"JP-01-legacy\",\"add\":\"jp1.example.com\",\"port\":\"443\",\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"jp1.example.com\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"jp1.example.com\",\"fp\":\"chrome\"}";
    const link = try std.fmt.allocPrint(arena.allocator(), "vmess://{s}", .{try b64(arena.allocator(), json)});
    const n = try parseUri(arena.allocator(), link, "", "@");
    try std.testing.expectEqualStrings("JP-01-legacy", n.name());
    const v = n.vmess;
    try std.testing.expectEqualStrings("jp1.example.com", v.server);
    try std.testing.expectEqual(@as(u16, 443), v.port);
    try std.testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", v.uuid);
    try std.testing.expect(v.tls);
    try std.testing.expectEqual(node.Network.ws, v.network);
    try std.testing.expectEqualStrings("/vmess", v.ws.?.path);
    try std.testing.expectEqualStrings("jp1.example.com", v.ws.?.host.?);
}

test "parse vmess url style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_vmess_url, "", "@");
    try std.testing.expectEqualStrings("SG-01-new", n.name());
    const v = n.vmess;
    try std.testing.expectEqualStrings("sg1.example.com", v.server);
    try std.testing.expect(v.tls);
    try std.testing.expectEqual(node.Network.ws, v.network);
    try std.testing.expectEqualStrings("/vmess", v.ws.?.path);
    try std.testing.expectEqualStrings("sg1.example.com", v.ws.?.host.?);
}

test "parse vless reality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_vless_reality, "", "@");
    try std.testing.expectEqualStrings("KR-01-Reality", n.name());
    const v = n.vless;
    try std.testing.expect(v.tls);
    try std.testing.expectEqualStrings("xtls-rprx-vision", v.flow.?);
    try std.testing.expectEqualStrings("www.microsoft.com", v.servername.?);
    try std.testing.expectEqualStrings("chrome", v.fingerprint.?);
    const r = v.reality.?;
    // pbk normalized to urlsafe without padding
    try std.testing.expectEqualStrings("77RU9W8QFgOAX-PK7zhMO6uRbGYetq7E5de25HIujMc", r.public_key);
    try std.testing.expectEqualStrings("ABCDEF", r.short_id.?);
}

test "parse trojan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_trojan, "airport-b", "@");
    try std.testing.expectEqualStrings("airport-b@HK-01-CM", n.name());
    const t = n.trojan;
    try std.testing.expectEqualStrings("tw-pass-123", t.password);
    try std.testing.expectEqualStrings("hk1.example.com", t.servername.?);
    try std.testing.expect(t.skip_cert_verify);
}

test "parse hysteria2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_hy2, "", "@");
    const h = n.hysteria2;
    try std.testing.expectEqualStrings("hy2-pass", h.password);
    try std.testing.expectEqualStrings("hk2.example.com", h.servername.?);
    try std.testing.expect(h.skip_cert_verify);
    try std.testing.expectEqualStrings("salamander", h.obfs.?);
    try std.testing.expectEqualStrings("obfs123", h.obfs_password.?);
}

test "parse hysteria1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_hy1, "", "@");
    const h = n.hysteria;
    try std.testing.expectEqualStrings("udp", h.protocol);
    try std.testing.expectEqualStrings("hy1-auth", h.auth_str.?);
    try std.testing.expectEqualStrings("hy1.example.com", h.sni.?);
    try std.testing.expectEqualStrings("100", h.up.?);
    try std.testing.expectEqualStrings("200", h.down.?);
}

test "parse tuic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try parseUri(arena.allocator(), test_tuic, "", "@");
    const t = n.tuic;
    try std.testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", t.uuid);
    try std.testing.expectEqualStrings("tuic-pass", t.password);
    try std.testing.expectEqualStrings("sg2.example.com", t.servername.?);
    try std.testing.expectEqualStrings("bbr", t.congestion_controller.?);
    try std.testing.expectEqualStrings("native", t.udp_relay_mode.?);
    try std.testing.expect(t.skip_cert_verify);
}

test "parse tuic hyphenated params and default port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // mihomo/clash-verge ecosystem: hyphenated params + omitted port
    const link = "tuic://11111111-2222-3333-4444-555555555555:tuic-pass@sg3.example.com?congestion-controller=bbr&udp-relay-mode=quic&skip-cert-verify=1#SG-03-TUIC";
    const n = try parseUri(arena.allocator(), link, "", "@");
    const t = n.tuic;
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("bbr", t.congestion_controller.?);
    try std.testing.expectEqualStrings("quic", t.udp_relay_mode.?);
    try std.testing.expect(t.skip_cert_verify);
}

test "parse trojan skip-cert-verify and default port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const link = "trojan://pass@hk2.example.com?skip-cert-verify=1#HK-02";
    const n = try parseUri(arena.allocator(), link, "", "@");
    try std.testing.expectEqual(@as(u16, 443), n.trojan.port);
    try std.testing.expect(n.trojan.skip_cert_verify);
}

test "parse hysteria2 peer alias and obfs none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // peer is a sni alias; obfs=none should be ignored
    const link = "hysteria2://pass@hk3.example.com?peer=real.example.com&obfs=none#HK-03";
    const n = try parseUri(arena.allocator(), link, "", "@");
    try std.testing.expectEqual(@as(u16, 443), n.hysteria2.port);
    try std.testing.expectEqualStrings("real.example.com", n.hysteria2.servername.?);
    try std.testing.expect(n.hysteria2.obfs == null);
}

test "parse errors" {
    try std.testing.expectError(error.InvalidUri, parseUri(std.testing.allocator, "notaurl", "", "@"));
    try std.testing.expectError(error.UnsupportedScheme, parseUri(std.testing.allocator, "http://x.com/", "", "@"));
    try std.testing.expectError(error.UnsupportedScheme, parseUri(std.testing.allocator, "socks5://1.2.3.4:1080", "", "@"));
}

fn b64(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(s.len));
    _ = enc.encode(out, s);
    return out;
}

test "compile-check" {
    _ = &parseUri;
    _ = &parseSs;
    _ = &parseSsr;
    _ = &parseVmess;
    _ = &parseXurl;
    _ = &vmessFromJson;
    _ = &parseTrojan;
    _ = &parseHysteria;
    _ = &parseHy2;
    _ = &parseTuic;
    _ = &parseSsPlugin;
    _ = &parseUriManual;
    _ = &parsePort;
    _ = &parseQuery;
    _ = &queryGet;
    _ = &queryBool;
    _ = &parseNetwork;
    _ = &parseAlpn;
    _ = &normalizeRealityKey;
    _ = &makeName;
    _ = &applyWsGrpc;
    _ = &b64Str;
    _ = &b64;
}
