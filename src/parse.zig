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
    /// info (notice) nodes filtered out: airport pseudo-nodes (expiry/remain-traffic notices)
    info: usize,
    /// names of the filtered info nodes (for verbose display)
    info_names: []const []const u8,
};

/// parse a single subscription payload (any format) into a node list. names already carry the subscription prefix.
pub fn parseSubscription(
    arena: std.mem.Allocator,
    sub_name: []const u8,
    text: []const u8,
    sep: []const u8,
    keywords: []const []const u8,
) ParseError!ParseResult {
    const s = sniff.sniff(arena, text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SniffError,
    };
    var nodes: std.ArrayListUnmanaged(node.Node) = .empty;
    var skipped: usize = 0;
    var info: usize = 0;
    var info_names: std.ArrayListUnmanaged([]const u8) = .empty;

    switch (s) {
        .uris => |lines| {
            for (lines) |line| {
                const n = uri.parseUri(arena, line, sub_name, sep) catch {
                    skipped += 1;
                    continue;
                };
                if (try filterInfoNode(arena, n, sub_name, sep, keywords, &info, &info_names)) continue;
                nodes.append(arena, n) catch return error.OutOfMemory;
            }
        },
        .json => |value| switch (value) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .string => |str| {
                            const n = uri.parseUri(arena, str, sub_name, sep) catch {
                                skipped += 1;
                                continue;
                            };
                            if (try filterInfoNode(arena, n, sub_name, sep, keywords, &info, &info_names)) continue;
                            nodes.append(arena, n) catch return error.OutOfMemory;
                        },
                        .object => |obj| {
                            const n = jsonNodeToNode(arena, obj, sub_name, sep) catch {
                                skipped += 1;
                                continue;
                            };
                            if (try filterInfoNode(arena, n, sub_name, sep, keywords, &info, &info_names)) continue;
                            nodes.append(arena, n) catch return error.OutOfMemory;
                        },
                        else => skipped += 1,
                    }
                }
            },
            // sing-box subscription: {"outbounds": [...]}
            .object => |obj| {
                const ob = obj.get("outbounds") orelse return error.UnknownFormat;
                const arr = switch (ob) {
                    .array => |a| a,
                    else => return error.UnknownFormat,
                };
                for (arr.items) |item| {
                    const oobj = switch (item) {
                        .object => |o| o,
                        else => {
                            skipped += 1;
                            continue;
                        },
                    };
                    const n = singboxOutboundToNode(arena, oobj, sub_name, sep) catch {
                        skipped += 1;
                        continue;
                    };
                    if (try filterInfoNode(arena, n, sub_name, sep, keywords, &info, &info_names)) continue;
                    nodes.append(arena, n) catch return error.OutOfMemory;
                }
            },
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
                const n = clashYamlToNode(arena, pm, sub_name, sep) catch {
                    skipped += 1;
                    continue;
                };
                if (try filterInfoNode(arena, n, sub_name, sep, keywords, &info, &info_names)) continue;
                nodes.append(arena, n) catch return error.OutOfMemory;
            }
        },
    }
    return .{
        .nodes = try nodes.toOwnedSlice(arena),
        .skipped = skipped,
        .info = info,
        .info_names = try info_names.toOwnedSlice(arena),
    };
}

/// filter airport notice nodes (info pseudo-nodes like "expiry 2026-12-21, remain traffic 279.95G").
/// returns true when the node is an info node (already counted); caller skips it.
fn filterInfoNode(
    arena: std.mem.Allocator,
    n: node.Node,
    sub_name: []const u8,
    sep: []const u8,
    keywords: []const []const u8,
    info: *usize,
    info_names: *std.ArrayListUnmanaged([]const u8),
) ParseError!bool {
    // judge on the raw name (strip the "sub@sep" prefix so subscription names cannot match)
    const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ sub_name, sep });
    const raw = if (std.mem.startsWith(u8, n.name(), prefix)) n.name()[prefix.len..] else n.name();
    if (!node.isInfoNodeName(raw, keywords)) return false;
    info.* += 1;
    try info_names.append(arena, n.name());
    return true;
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
            .plugin = try ssPluginFromYaml(arena, m),
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

/// clash YAML ss plugin: plugin + plugin-opts (obfs-local / v2ray-plugin / shadow-tls)
fn ssPluginFromYaml(arena: std.mem.Allocator, m: []const yaml.MappingEntry) ParseError!?node.SsPlugin {
    _ = arena;
    const get = yaml.mappingGetScalar;
    const plugin = get(m, "plugin") orelse return null;
    const opts = yaml.mappingGet(m, "plugin-opts");
    const om = if (opts) |o| yaml.mappingOf(o) orelse return error.MissingField else null;

    if (std.mem.eql(u8, plugin, "obfs-local")) {
        return .{ .obfs_local = .{
            .mode = if (om) |mm| get(mm, "mode") orelse "http" else "http",
            .host = if (om) |mm| get(mm, "host") orelse "" else "",
        } };
    }
    if (std.mem.eql(u8, plugin, "v2ray-plugin")) {
        var result: node.SsPlugin = .{ .v2ray_plugin = .{} };
        const vp = &result.v2ray_plugin;
        if (om) |mm| {
            if (get(mm, "mode")) |m2| vp.mode = m2;
            vp.tls = yBool(get(mm, "tls"));
            vp.host = get(mm, "host");
            vp.path = get(mm, "path");
        }
        return result;
    }
    if (std.mem.eql(u8, plugin, "shadow-tls")) {
        const ver = if (om) |mm| get(mm, "version") orelse "3" else "3";
        const version: u8 = std.fmt.parseInt(u8, ver, 10) catch 3;
        return .{ .shadow_tls = .{
            .host = if (om) |mm| get(mm, "host") orelse "" else "",
            .password = if (om) |mm| get(mm, "password") orelse "" else "",
            .version = version,
        } };
    }
    return error.UnsupportedPlugin;
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
/// sing-box outbound object (subscription format: {"outbounds": [...]}) -> Node.
/// field layout differs from v2rayN: type/tag/server/server_port, tls{}, transport{}.
fn singboxOutboundToNode(arena: std.mem.Allocator, obj: std.json.ObjectMap, sub_name: []const u8, sep: []const u8) ParseError!node.Node {
    const getStr = struct {
        fn get(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
            const v = o.get(key) orelse return null;
            return switch (v) {
                .string => |s| s,
                else => null,
            };
        }
    }.get;
    const getBool = struct {
        fn get(o: std.json.ObjectMap, key: []const u8) bool {
            const v = o.get(key) orelse return false;
            return switch (v) {
                .bool => |b| b,
                else => false,
            };
        }
    }.get;
    const getPort = struct {
        fn get(o: std.json.ObjectMap, key: []const u8) ParseError!u16 {
            const v = o.get(key) orelse return error.MissingField;
            return switch (v) {
                .integer => |i| if (i >= 0 and i <= 65535) @intCast(i) else error.InvalidPort,
                .string => |s| std.fmt.parseInt(u16, s, 10) catch error.InvalidPort,
                else => error.InvalidPort,
            };
        }
    }.get;
    const getObj = struct {
        fn get(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
            const v = o.get(key) orelse return null;
            return switch (v) {
                .object => |m| m,
                else => null,
            };
        }
    }.get;

    const server = getStr(obj, "server") orelse return error.MissingField;
    const port = try getPort(obj, "server_port");
    const raw_name = getStr(obj, "tag") orelse "";
    const name = try nameFor(arena, raw_name, sub_name, sep, server, port);

    // tls {} block
    const tls = getObj(obj, "tls");
    const tls_enabled = if (tls) |t| getBool(t, "enabled") else false;
    const server_name = if (tls) |t| getStr(t, "server_name") else null;
    const insecure = if (tls) |t| getBool(t, "insecure") else false;
    const fingerprint = if (tls) |t| blk: {
        if (getObj(t, "utls")) |u| break :blk getStr(u, "fingerprint");
        break :blk null;
    } else null;
    const alpn: ?[]const []const u8 = if (tls) |t| blk: {
        const v = t.get("alpn") orelse break :blk null;
        const arr = switch (v) {
            .array => |a| a,
            else => break :blk null,
        };
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (arr.items) |item| {
            switch (item) {
                .string => |s| try list.append(arena, s),
                else => {},
            }
        }
        break :blk if (list.items.len > 0) list.items else null;
    } else null;

    // transport {} block (ws / grpc / http)
    const transport = getObj(obj, "transport");
    const t_type = if (transport) |tr| getStr(tr, "type") else null;
    const network: node.Network = if (std.mem.eql(u8, t_type orelse "", "ws")) .ws else if (std.mem.eql(u8, t_type orelse "", "grpc")) .grpc else if (std.mem.eql(u8, t_type orelse "", "http")) .http else .tcp;
    var ws: ?node.WsOpts = null;
    var grpc: ?node.GrpcOpts = null;
    if (transport) |tr| {
        if (std.mem.eql(u8, getStr(tr, "type") orelse "", "ws")) {
            var host: ?[]const u8 = null;
            if (getObj(tr, "headers")) |h| host = getStr(h, "Host");
            ws = .{ .path = getStr(tr, "path") orelse "/", .host = host };
        } else if (std.mem.eql(u8, getStr(tr, "type") orelse "", "grpc")) {
            grpc = .{ .service_name = getStr(tr, "service_name") orelse "" };
        }
    }

    const ob_type = getStr(obj, "type") orelse return error.MissingField;
    if (std.mem.eql(u8, ob_type, "vless")) {
        var reality: ?node.RealityOpts = null;
        if (tls) |t| {
            if (getObj(t, "reality")) |r| {
                if (getBool(r, "enabled")) {
                    reality = .{
                        .public_key = getStr(r, "public_key") orelse return error.MissingField,
                        .short_id = getStr(r, "short_id"),
                    };
                }
            }
        }
        return .{ .vless = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = getStr(obj, "uuid") orelse return error.MissingField,
            .network = network,
            .tls = tls_enabled,
            .reality = reality,
            .flow = getStr(obj, "flow"),
            .servername = server_name,
            .fingerprint = fingerprint,
            .skip_cert_verify = insecure,
            .alpn = alpn,
            .ws = ws,
            .grpc = grpc,
        } };
    }
    if (std.mem.eql(u8, ob_type, "vmess")) {
        // alter_id: integer or numeric string; missing/illegal -> 0 (modern vmess)
        const alter_id: u16 = if (obj.get("alter_id")) |v| switch (v) {
            .integer => |i| if (i >= 0 and i <= 65535) @intCast(i) else 0,
            .string => |s| std.fmt.parseInt(u16, s, 10) catch 0,
            else => 0,
        } else 0;
        return .{ .vmess = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = getStr(obj, "uuid") orelse return error.MissingField,
            .alter_id = alter_id,
            .network = network,
            .tls = tls_enabled,
            .servername = server_name,
            .fingerprint = fingerprint,
            .ws = ws,
            .grpc = grpc,
        } };
    }
    if (std.mem.eql(u8, ob_type, "trojan")) {
        return .{ .trojan = .{
            .name = name,
            .server = server,
            .port = port,
            .password = getStr(obj, "password") orelse return error.MissingField,
            .servername = server_name,
            .skip_cert_verify = insecure,
            .alpn = alpn,
            .network = network,
            .ws = ws,
            .grpc = grpc,
        } };
    }
    if (std.mem.eql(u8, ob_type, "shadowsocks")) {
        var n: node.SS = .{
            .name = name,
            .server = server,
            .port = port,
            .cipher = getStr(obj, "method") orelse return error.MissingField,
            .password = getStr(obj, "password") orelse return error.MissingField,
        };
        // sing-box plugin + plugin_opts (TOR_PT style, same as ss:// plugin param)
        if (getStr(obj, "plugin")) |p| {
            const opts_text = getStr(obj, "plugin_opts");
            const full = if (opts_text) |po|
                try std.fmt.allocPrint(arena, "{s};{s}", .{ p, po })
            else
                p;
            n.plugin = uri.parseSsPlugin(arena, full) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.UnsupportedPlugin,
            };
        }
        return .{ .ss = n };
    }
    if (std.mem.eql(u8, ob_type, "hysteria2")) {
        var obfs: ?[]const u8 = null;
        var obfs_pw: ?[]const u8 = null;
        if (getObj(obj, "obfs")) |o| {
            if (std.mem.eql(u8, getStr(o, "type") orelse "", "salamander")) {
                obfs = getStr(o, "type");
                obfs_pw = getStr(o, "password");
            }
        }
        return .{ .hysteria2 = .{
            .name = name,
            .server = server,
            .port = port,
            .password = getStr(obj, "password") orelse return error.MissingField,
            .servername = server_name,
            .skip_cert_verify = insecure,
            .obfs = obfs,
            .obfs_password = obfs_pw,
            .alpn = alpn,
        } };
    }
    if (std.mem.eql(u8, ob_type, "hysteria")) {
        return .{ .hysteria = .{
            .name = name,
            .server = server,
            .port = port,
            .auth_str = getStr(obj, "auth_str") orelse getStr(obj, "auth"),
            .up = getStr(obj, "up"),
            .down = getStr(obj, "down"),
            .obfs = getStr(obj, "obfs"),
            .sni = server_name,
            .skip_cert_verify = insecure,
            .alpn = alpn,
        } };
    }
    if (std.mem.eql(u8, ob_type, "tuic")) {
        return .{ .tuic = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = getStr(obj, "uuid") orelse return error.MissingField,
            .password = getStr(obj, "password") orelse "",
            .servername = server_name,
            .skip_cert_verify = insecure,
            .congestion_controller = getStr(obj, "congestion_control"),
            .udp_relay_mode = getStr(obj, "udp_relay_mode"),
            .alpn = alpn,
        } };
    }
    // non-node outbounds (direct/block/selector/dns/...)
    return error.UnsupportedType;
}

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
    const plain = "trojan://pass@hk1.example.com:443?sni=hk1.example.com#HK-01\ntrojan://pass@us1.example.com:443?sni=us1.example.com#US-01";
    const enc_buf = try a.alloc(u8, std.base64.standard.Encoder.calcSize(plain.len));
    _ = std.base64.standard.Encoder.encode(enc_buf, plain);
    const r = try parseSubscription(a, "airport-a", enc_buf, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 2), r.nodes.len);
    try std.testing.expectEqualStrings("airport-a@HK-01", r.nodes[0].name());
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
    const r = try parseSubscription(arena.allocator(), "airport-b", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), r.skipped);
    try std.testing.expectEqualStrings("airport-b@TW-01", r.nodes[0].name());
    try std.testing.expectEqualStrings("trojan", r.nodes[0].typeName());
}

test "parse v2rayn json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "[{\"ps\":\"TW-01\",\"add\":\"tw2.example.com\",\"port\":\"443\",\"id\":\"11111111-2222-3333-4444-555555555555\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"tls\",\"sni\":\"tw2.example.com\"}]";
    const r = try parseSubscription(arena.allocator(), "airport-c", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    try std.testing.expectEqualStrings("airport-c@TW-01", r.nodes[0].name());
    try std.testing.expectEqualStrings("tw2.example.com", r.nodes[0].vmess.server);
    try std.testing.expect(r.nodes[0].vmess.tls);
}

test "parse clash yaml ss plugin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\proxies:
        \\  - name: SG-OBSF
        \\    type: ss
        \\    server: sg1.example.com
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: p1
        \\    plugin: obfs-local
        \\    plugin-opts:
        \\      mode: http
        \\      host: www.bing.com
        \\  - name: SG-STLS
        \\    type: ss
        \\    server: sg2.example.com
        \\    port: 8443
        \\    cipher: aes-256-gcm
        \\    password: p2
        \\    plugin: shadow-tls
        \\    plugin-opts:
        \\      host: www.bing.com
        \\      password: st-pw
        \\      version: 3
    ;
    const r = try parseSubscription(arena.allocator(), "airport", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 2), r.nodes.len);
    const p0 = r.nodes[0].ss.plugin.?;
    try std.testing.expectEqualStrings("http", p0.obfs_local.mode);
    try std.testing.expectEqualStrings("www.bing.com", p0.obfs_local.host);
    const p1 = r.nodes[1].ss.plugin.?;
    try std.testing.expectEqualStrings("st-pw", p1.shadow_tls.password);
    try std.testing.expectEqual(@as(u8, 3), p1.shadow_tls.version);
}

test "parse singbox vmess alter_id and tuic udp_relay_mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{
        \\  "outbounds": [
        \\    { "type": "vmess", "tag": "vm-1", "server": "1.2.3.4", "server_port": 443,
        \\      "uuid": "11111111-2222-3333-4444-555555555555", "alter_id": 1 },
        \\    { "type": "tuic", "tag": "tc-1", "server": "5.6.7.8", "server_port": 443,
        \\      "uuid": "11111111-2222-3333-4444-555555555555", "password": "p",
        \\      "udp_relay_mode": "quic" }
        \\  ]
        \\}
    ;
    const r = try parseSubscription(arena.allocator(), "sb", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 2), r.nodes.len);
    try std.testing.expectEqual(@as(u16, 1), r.nodes[0].vmess.alter_id);
    try std.testing.expectEqualStrings("quic", r.nodes[1].tuic.udp_relay_mode.?);
    // missing alter_id -> 0
    const text2 =
        \\{
        \\  "outbounds": [
        \\    { "type": "vmess", "tag": "vm-2", "server": "1.2.3.4", "server_port": 443,
        \\      "uuid": "11111111-2222-3333-4444-555555555555" }
        \\  ]
        \\}
    ;
    const r2 = try parseSubscription(arena.allocator(), "sb", text2, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(u16, 0), r2.nodes[0].vmess.alter_id);
}

test "parse singbox shadowsocks plugin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\{
        \\  "outbounds": [
        \\    { "type": "shadowsocks", "tag": "ss-obfs", "server": "8.8.8.8", "server_port": 8388,
        \\      "method": "aes-256-gcm", "password": "p",
        \\      "plugin": "obfs-local", "plugin_opts": "obfs=http;obfs-host=www.bing.com" }
        \\  ]
        \\}
    ;
    const r = try parseSubscription(arena.allocator(), "sb", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    const plugin = r.nodes[0].ss.plugin.?;
    try std.testing.expectEqualStrings("http", plugin.obfs_local.mode);
    try std.testing.expectEqualStrings("www.bing.com", plugin.obfs_local.host);
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
    const r = try parseSubscription(arena.allocator(), "airport-d", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 1), r.nodes.len);
    const alpn = r.nodes[0].vless.alpn.?;
    try std.testing.expectEqual(@as(usize, 2), alpn.len);
    try std.testing.expectEqualStrings("h2", alpn[0]);
    try std.testing.expectEqualStrings("http/1.1", alpn[1]);
}

test "parse errors propagate" {
    try std.testing.expectError(
        error.SniffError,
        parseSubscription(std.testing.allocator, "airport-a", "<html>error</html>", "@", &node.default_info_keywords),
    );
}

test "parse filters info nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "trojan://pass@hk1.example.com:443?sni=hk1.example.com#香港1-电信优化\ntrojan://pass@hk2.example.com:443?sni=hk2.example.com#到期2026-12-21 剩余流量279.95G\ntrojan://pass@jp1.example.com:443?sni=jp1.example.com#日本1-电信优化\n";
    const r = try parseSubscription(a, "sub", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 2), r.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), r.info);
    try std.testing.expectEqual(@as(usize, 1), r.info_names.len);
    try std.testing.expectEqualStrings("sub@到期2026-12-21 剩余流量279.95G", r.info_names[0]);
    try std.testing.expectEqualStrings("sub@香港1-电信优化", r.nodes[0].name());
    try std.testing.expectEqualStrings("sub@日本1-电信优化", r.nodes[1].name());
    // no info nodes: info == 0
    const r2 = try parseSubscription(a, "sub", "trojan://pass@hk1.example.com:443#香港1\n", "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 1), r2.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), r2.info);
}

test "parse singbox subscription (outbounds)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{
        \\  "outbounds": [
        \\    { "type": "vless", "tag": "reality-1", "server": "1.2.3.4", "server_port": 443,
        \\      "uuid": "09ac0a61-777e-4048-ba72-84f1d30e3a82", "flow": "xtls-rprx-vision",
        \\      "tls": { "enabled": true, "server_name": "osxapps.itunes.apple.com",
        \\               "utls": { "enabled": true, "fingerprint": "chrome" },
        \\               "reality": { "enabled": true, "public_key": "dNR9791Fyzm-c7ozAQ1z2ok5P0YXjrQKeBYPvbAKYks", "short_id": "51fb77f0b8e8c7a3" } } },
        \\    { "type": "vless", "tag": "ws-1", "server": "5.6.7.8", "server_port": 8443,
        \\      "uuid": "09ac0a61-777e-4048-ba72-84f1d30e3a82", "tls": { "enabled": true, "server_name": "ws.example.com" },
        \\      "transport": { "type": "ws", "path": "/ws", "headers": { "Host": "ws.example.com" } } },
        \\    { "type": "trojan", "tag": "tr-1", "server": "9.9.9.9", "server_port": 443,
        \\      "password": "pw", "tls": { "enabled": true, "server_name": "tr.example.com" } },
        \\    { "type": "shadowsocks", "tag": "ss-1", "server": "8.8.8.8", "server_port": 8388,
        \\      "method": "aes-128-gcm", "password": "sp" },
        \\    { "type": "hysteria2", "tag": "hy2-1", "server": "7.7.7.7", "server_port": 443,
        \\      "password": "hp", "tls": { "enabled": true, "server_name": "hy2.example.com" },
        \\      "obfs": { "type": "salamander", "password": "op" } },
        \\    { "type": "direct", "tag": "direct-out" },
        \\    { "type": "block", "tag": "block-out" }
        \\  ]
        \\}
    ;
    const r = try parseSubscription(a, "sb", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 5), r.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), r.skipped); // direct/block skipped
    // vless reality
    const v = r.nodes[0].vless;
    try std.testing.expectEqualStrings("sb@reality-1", v.name);
    try std.testing.expectEqualStrings("1.2.3.4", v.server);
    try std.testing.expectEqual(@as(u16, 443), v.port);
    try std.testing.expect(v.tls);
    try std.testing.expect(v.reality != null);
    try std.testing.expectEqualStrings("dNR9791Fyzm-c7ozAQ1z2ok5P0YXjrQKeBYPvbAKYks", v.reality.?.public_key);
    try std.testing.expectEqualStrings("51fb77f0b8e8c7a3", v.reality.?.short_id.?);
    try std.testing.expectEqualStrings("xtls-rprx-vision", v.flow.?);
    try std.testing.expectEqualStrings("osxapps.itunes.apple.com", v.servername.?);
    try std.testing.expectEqualStrings("chrome", v.fingerprint.?);
    // vless ws
    const w = r.nodes[1].vless;
    try std.testing.expectEqual(node.Network.ws, w.network);
    try std.testing.expectEqualStrings("/ws", w.ws.?.path);
    try std.testing.expectEqualStrings("ws.example.com", w.ws.?.host.?);
    // trojan
    const t = r.nodes[2].trojan;
    try std.testing.expectEqualStrings("pw", t.password);
    try std.testing.expectEqualStrings("tr.example.com", t.servername.?);
    // ss
    const s = r.nodes[3].ss;
    try std.testing.expectEqualStrings("aes-128-gcm", s.cipher);
    try std.testing.expectEqualStrings("sp", s.password);
    // hysteria2 with salamander obfs
    const h = r.nodes[4].hysteria2;
    try std.testing.expectEqualStrings("hp", h.password);
    try std.testing.expectEqualStrings("salamander", h.obfs.?);
    try std.testing.expectEqualStrings("op", h.obfs_password.?);
}

test "parse anonymous subscription (no prefix, info filtered)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "trojan://pass@hk1.example.com:443?sni=hk1.example.com#香港1-电信优化\ntrojan://pass@hk2.example.com:443?sni=hk2.example.com#到期2026-12-21 剩余流量279.95G\ntrojan://pass@jp1.example.com:443?sni=jp1.example.com#日本1-电信优化\n";
    const r3 = try parseSubscription(a, "", text, "@", &node.default_info_keywords);
    try std.testing.expectEqual(@as(usize, 2), r3.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), r3.info);
    try std.testing.expectEqualStrings("到期2026-12-21 剩余流量279.95G", r3.info_names[0]);
    try std.testing.expectEqualStrings("香港1-电信优化", r3.nodes[0].name());
    try std.testing.expectEqualStrings("日本1-电信优化", r3.nodes[1].name());
}

test "compile-check" {
    _ = &parseSubscription;
    _ = &filterInfoNode;
    _ = &clashYamlToNode;
    _ = &singboxOutboundToNode;
    _ = &jsonNodeToNode;
    _ = &parseNet;
    _ = &parsePort;
    _ = &yBool;
    _ = &nameFor;
    _ = &wsOpts;
    _ = &grpcOpts;
    _ = &yamlAlpn;
    _ = &alpnFromString;
    _ = &ssPluginFromYaml;
}
