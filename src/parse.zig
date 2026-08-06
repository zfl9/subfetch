const std = @import("std");
const node = @import("node.zig");
const uri = @import("uri.zig");
const sniff = @import("sniff.zig");
const yaml = @import("yaml.zig");

pub const ParseError = error{
    OutOfMemory,
    SniffError,
    MissingField,
    InvalidPort,
    UnsupportedType,
    UnsupportedNetwork,
    InvalidUri,
    BadBase64,
    InvalidJson,
    UnsupportedPlugin,
    UnknownFormat,
};

pub const ParseResult = struct {
    nodes: []const node.Node,
    skipped: usize,
};

/// parse a single subscription payload (any format) into a node list. names already carry the subscription prefix.
pub fn parseSubscription(
    arena: std.mem.Allocator,
    sub_name: []const u8,
    text: []const u8,
    sep: []const u8,
) ParseError!ParseResult {
    const s = sniff.sniff(arena, text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SniffError,
    };
    var nodes: std.ArrayListUnmanaged(node.Node) = .empty;
    var skipped: usize = 0;

    switch (s) {
        .uris => |lines| {
            for (lines) |line| {
                nodes.append(arena, uri.parseUri(arena, line, sub_name, sep) catch {
                    skipped += 1;
                    continue;
                }) catch return error.OutOfMemory;
            }
        },
        .json => |value| switch (value) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .string => |str| {
                            nodes.append(arena, uri.parseUri(arena, str, sub_name, sep) catch {
                                skipped += 1;
                                continue;
                            }) catch return error.OutOfMemory;
                        },
                        .object => |obj| {
                            nodes.append(arena, jsonNodeToNode(arena, obj, sub_name, sep) catch {
                                skipped += 1;
                                continue;
                            }) catch return error.OutOfMemory;
                        },
                        else => skipped += 1,
                    }
                }
            },
            // JSON object with a proxies key (clash JSON) does not exist in the wild:
            // clash subscriptions are always YAML, so unsupported
            .object => return error.UnknownFormat,
            else => return error.UnknownFormat,
        },
        .clash => |root| {
            const m = yaml.mappingOf(root) orelse return error.UnknownFormat;
            const pv = yaml.mappingGet(m, "proxies") orelse return error.UnknownFormat;
            const proxies = yaml.sequenceOf(pv) orelse return error.UnknownFormat;
            for (proxies) |item| {
                const pm = yaml.mappingOf(item) orelse {
                    skipped += 1;
                    continue;
                };
                nodes.append(arena, clashYamlToNode(arena, pm, sub_name, sep) catch {
                    skipped += 1;
                    continue;
                }) catch return error.OutOfMemory;
            }
        },
    }
    return .{ .nodes = try nodes.toOwnedSlice(arena), .skipped = skipped };
}

// ---------------- clash node conversion ----------------

fn parsePort(s: []const u8) ParseError!u16 {
    if (s.len == 0 or s.len > 5) return error.InvalidPort;
    return std.fmt.parseInt(u16, s, 10) catch error.InvalidPort;
}

fn yBool(v: ?[]const u8) bool {
    return v != null and (std.mem.eql(u8, v.?, "true") or std.mem.eql(u8, v.?, "1"));
}

fn nameFor(arena: std.mem.Allocator, raw_name: []const u8, sub_name: []const u8, sep: []const u8, server: []const u8, port: u16) ParseError![]const u8 {
    const fallback = std.fmt.allocPrint(arena, "{s}:{d}", .{ server, port }) catch return error.OutOfMemory;
    return node.prefixed(arena, sub_name, raw_name, sep, fallback) catch error.OutOfMemory;
}

/// clash YAML node (yaml tree mapping) -> Node
fn clashYamlToNode(arena: std.mem.Allocator, m: []const yaml.MappingEntry, sub_name: []const u8, sep: []const u8) ParseError!node.Node {
    const get = yaml.mappingGetScalar;
    const type_str = get(m, "type") orelse return error.UnsupportedType;
    const server = get(m, "server") orelse return error.MissingField;
    const port = try parsePort(get(m, "port") orelse return error.MissingField);
    const raw_name = get(m, "name") orelse "";
    const name = try nameFor(arena, raw_name, sub_name, sep, server, port);

    if (std.mem.eql(u8, type_str, "ss")) {
        return .{ .ss = .{
            .name = name,
            .server = server,
            .port = port,
            .cipher = get(m, "cipher") orelse return error.MissingField,
            .password = get(m, "password") orelse return error.MissingField,
        } };
    }
    if (std.mem.eql(u8, type_str, "ssr")) {
        return .{ .ssr = .{
            .name = name,
            .server = server,
            .port = port,
            .cipher = get(m, "cipher") orelse return error.MissingField,
            .password = get(m, "password") orelse return error.MissingField,
            .protocol = get(m, "protocol") orelse "origin",
            .obfs = get(m, "obfs") orelse "plain",
            .obfs_param = get(m, "obfs-param"),
            .protocol_param = get(m, "protocol-param"),
        } };
    }
    if (std.mem.eql(u8, type_str, "vmess")) {
        const net = parseNet(get(m, "network")) catch .tcp;
        return .{ .vmess = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = get(m, "uuid") orelse return error.MissingField,
            .alter_id = if (get(m, "alterId")) |v| std.fmt.parseInt(u16, v, 10) catch 0 else 0,
            .network = net,
            .tls = yBool(get(m, "tls")),
            .servername = get(m, "servername") orelse get(m, "sni"),
            .fingerprint = get(m, "client-fingerprint"),
            .ws = try wsOpts(m, net),
            .grpc = try grpcOpts(m, net),
        } };
    }
    if (std.mem.eql(u8, type_str, "vless")) {
        const net = parseNet(get(m, "network")) catch .tcp;
        const reality_v = yaml.mappingGet(m, "reality-opts");
        const reality = if (reality_v) |rv| blk: {
            const rm = yaml.mappingOf(rv) orelse return error.MissingField;
            break :blk node.RealityOpts{
                .public_key = get(rm, "public-key") orelse return error.MissingField,
                .short_id = get(rm, "short-id"),
                .spider_x = get(rm, "spider-x"),
            };
        } else null;
        return .{ .vless = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = get(m, "uuid") orelse return error.MissingField,
            .network = net,
            .tls = yBool(get(m, "tls")),
            .reality = reality,
            .flow = get(m, "flow"),
            .servername = get(m, "servername") orelse get(m, "sni"),
            .fingerprint = get(m, "client-fingerprint"),
            .skip_cert_verify = yBool(get(m, "skip-cert-verify")),
            .alpn = try yamlAlpn(arena, yaml.mappingGet(m, "alpn")),
            .ws = try wsOpts(m, net),
            .grpc = try grpcOpts(m, net),
        } };
    }
    if (std.mem.eql(u8, type_str, "trojan")) {
        const net = parseNet(get(m, "network")) catch .tcp;
        return .{ .trojan = .{
            .name = name,
            .server = server,
            .port = port,
            .password = get(m, "password") orelse return error.MissingField,
            .servername = get(m, "servername") orelse get(m, "sni"),
            .skip_cert_verify = yBool(get(m, "skip-cert-verify")),
            .alpn = try yamlAlpn(arena, yaml.mappingGet(m, "alpn")),
            .network = net,
            .ws = try wsOpts(m, net),
            .grpc = try grpcOpts(m, net),
        } };
    }
    if (std.mem.eql(u8, type_str, "hysteria")) {
        return .{ .hysteria = .{
            .name = name,
            .server = server,
            .port = port,
            .protocol = get(m, "protocol") orelse "udp",
            .auth_str = get(m, "auth-str") orelse get(m, "auth"),
            .up = get(m, "up"),
            .down = get(m, "down"),
            .obfs = get(m, "obfs"),
            .sni = get(m, "sni"),
            .skip_cert_verify = yBool(get(m, "skip-cert-verify")),
            .alpn = try yamlAlpn(arena, yaml.mappingGet(m, "alpn")),
        } };
    }
    if (std.mem.eql(u8, type_str, "hysteria2")) {
        return .{ .hysteria2 = .{
            .name = name,
            .server = server,
            .port = port,
            .password = get(m, "password") orelse return error.MissingField,
            .servername = get(m, "servername") orelse get(m, "sni"),
            .skip_cert_verify = yBool(get(m, "skip-cert-verify")),
            .obfs = get(m, "obfs"),
            .obfs_password = get(m, "obfs-password"),
            .alpn = try yamlAlpn(arena, yaml.mappingGet(m, "alpn")),
        } };
    }
    if (std.mem.eql(u8, type_str, "tuic")) {
        return .{ .tuic = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = get(m, "uuid") orelse return error.MissingField,
            .password = get(m, "password") orelse return error.MissingField,
            .servername = get(m, "servername") orelse get(m, "sni"),
            .skip_cert_verify = yBool(get(m, "skip-cert-verify")),
            .congestion_controller = get(m, "congestion-controller"),
            .udp_relay_mode = get(m, "udp-relay-mode"),
            .alpn = try yamlAlpn(arena, yaml.mappingGet(m, "alpn")),
        } };
    }
    return error.UnsupportedType;
}

/// clash YAML alpn (yaml sequence) -> []const []const u8
fn yamlAlpn(arena: std.mem.Allocator, v: ?yaml.YamlValue) ParseError!?[]const []const u8 {
    const val = v orelse return null;
    const seq = yaml.sequenceOf(val) orelse {
        // some subscriptions use comma-separated strings
        const s = yaml.scalarOf(val) orelse return null;
        return alpnFromString(arena, s);
    };
    if (seq.len == 0) return null;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (seq) |item| {
        const s = yaml.scalarOf(item) orelse continue;
        try out.append(arena, s);
    }
    if (out.items.len == 0) return null;
    return @as(?[]const []const u8, try out.toOwnedSlice(arena));
}

/// comma-separated string -> alpn list
fn alpnFromString(arena: std.mem.Allocator, s: []const u8) ParseError!?[]const []const u8 {
    if (s.len == 0) return null;
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len > 0) try out.append(arena, t);
    }
    if (out.items.len == 0) return null;
    return @as(?[]const []const u8, try out.toOwnedSlice(arena));
}

/// v2rayN JSON node (with "add"/"ps" fields) -> Node
fn jsonNodeToNode(arena: std.mem.Allocator, obj: std.json.ObjectMap, sub_name: []const u8, sep: []const u8) ParseError!node.Node {
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
    const raw_name = getStr(obj, "ps") orelse "";
    const name = try nameFor(arena, raw_name, sub_name, sep, server, port);

    const net = parseNet(getStr(obj, "net")) catch .tcp;
    return .{ .vmess = .{
        .name = name,
        .server = server,
        .port = port,
        .uuid = getStr(obj, "id") orelse return error.MissingField,
        .alter_id = if (getStr(obj, "aid")) |v| std.fmt.parseInt(u16, v, 10) catch 0 else 0,
        .network = net,
        .tls = std.mem.eql(u8, getStr(obj, "tls") orelse "", "tls"),
        .servername = getStr(obj, "sni"),
        .fingerprint = getStr(obj, "fp"),
        .ws = if (net == .ws) .{ .path = getStr(obj, "path") orelse "/", .host = getStr(obj, "host") } else null,
        .grpc = if (net == .grpc) .{ .service_name = getStr(obj, "serviceName") orelse getStr(obj, "path") orelse "" } else null,
    } };
}

/// clash JSON object (type/server fields) -> Node (reuses yaml conversion field semantics)
fn parseNet(s: ?[]const u8) ParseError!node.Network {
    const v = s orelse return .tcp;
    if (std.mem.eql(u8, v, "tcp")) return .tcp;
    if (std.mem.eql(u8, v, "ws")) return .ws;
    if (std.mem.eql(u8, v, "grpc")) return .grpc;
    if (std.mem.eql(u8, v, "http")) return .http;
    return error.UnsupportedNetwork;
}

fn wsOpts(m: []const yaml.MappingEntry, net: node.Network) ParseError!?node.WsOpts {
    if (net != .ws) return null;
    const get = yaml.mappingGetScalar;
    const wv = yaml.mappingGet(m, "ws-opts");
    if (wv) |w| {
        const wm = yaml.mappingOf(w) orelse return error.MissingField;
        var host: ?[]const u8 = null;
        if (yaml.mappingGet(wm, "headers")) |hv| {
            const hm = yaml.mappingOf(hv) orelse return error.MissingField;
            host = get(hm, "Host");
        }
        return .{ .path = get(wm, "path") orelse "/", .host = host };
    }
    // fall back to flat fields when there is no ws-opts block (some subscriptions do this)
    return .{ .path = get(m, "path") orelse "/", .host = get(m, "host") };
}

fn grpcOpts(m: []const yaml.MappingEntry, net: node.Network) ParseError!?node.GrpcOpts {
    if (net != .grpc) return null;
    const get = yaml.mappingGetScalar;
    const gv = yaml.mappingGet(m, "grpc-opts");
    if (gv) |g| {
        const gm = yaml.mappingOf(g) orelse return error.MissingField;
        return .{ .service_name = get(gm, "grpc-service-name") orelse "" };
    }
    return .{ .service_name = get(m, "grpc-service-name") orelse "" };
}

// ---------------- tests ----------------

test "parse base64 subscription" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "trojan://pass@hk1.example.com:443?sni=hk1.example.com#香港1\ntrojan://pass@us1.example.com:443?sni=us1.example.com#美国1";
    const enc_buf = try a.alloc(u8, std.base64.standard.Encoder.calcSize(plain.len));
    _ = std.base64.standard.Encoder.encode(enc_buf, plain);
    const r = try parseSubscription(a, "机场A", enc_buf, "｜");
    try std.testing.expectEqual(@as(usize, 2), r.nodes.len);
    try std.testing.expectEqualStrings("机场A｜香港1", r.nodes[0].name());
}

test "parse clash yaml subscription" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\proxies:
        \\  - name: TW-01
        \\    type: trojan
        \\    server: tw1.example.com
        \\    port: 443
        \\    password: tw-pass
        \\  - name: SOCKS
        \\    type: socks5
        \\    server: 1.2.3.4
        \\    port: 1080
    ;
    const r = try parseSubscription(arena.allocator(), "机场B", text, "｜");
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), r.skipped);
    try std.testing.expectEqualStrings("机场B｜TW-01", r.nodes[0].name());
    try std.testing.expectEqualStrings("trojan", r.nodes[0].typeName());
}

test "parse v2rayn json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "[{\"ps\":\"台湾1\",\"add\":\"tw2.example.com\",\"port\":\"443\",\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"tls\",\"sni\":\"tw2.example.com\"}]";
    const r = try parseSubscription(arena.allocator(), "机场C", text, "｜");
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    try std.testing.expectEqualStrings("机场C｜台湾1", r.nodes[0].name());
    try std.testing.expectEqualStrings("tw2.example.com", r.nodes[0].vmess.server);
    try std.testing.expect(r.nodes[0].vmess.tls);
}

test "parse clash yaml alpn list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\proxies:
        \\  - name: JP-01
        \\    type: vless
        \\    server: jp1.example.com
        \\    port: 443
        \\    uuid: 11111111-2222-3333-4444-555555555555
        \\    tls: true
        \\    network: tcp
        \\    servername: jp1.example.com
        \\    alpn:
        \\      - h2
        \\      - http/1.1
    ;
    const r = try parseSubscription(arena.allocator(), "机场D", text, "｜");
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    const alpn = r.nodes[0].vless.alpn.?;
    try std.testing.expectEqual(@as(usize, 2), alpn.len);
    try std.testing.expectEqualStrings("h2", alpn[0]);
    try std.testing.expectEqualStrings("http/1.1", alpn[1]);
}

test "parse errors propagate" {
    try std.testing.expectError(
        error.SniffError,
        parseSubscription(std.testing.allocator, "机场A", "<html>error</html>", "｜"),
    );
}

test "compile-check" {
    // reference every fn/var in this file (including private ones)
    _ = &parseSubscription;
    _ = &clashYamlToNode;
    _ = &jsonNodeToNode;
    _ = &parseNet;
    _ = &parsePort;
    _ = &yBool;
    _ = &nameFor;
    _ = &wsOpts;
    _ = &grpcOpts;
    _ = &yamlAlpn;
    _ = &alpnFromString;
    // local decls inside function bodies (e.g. getStr in jsonNodeToNode/clashObjToNode)
    // cannot be referenced from outside due to Zig scoping; covered by behavioral tests
}
