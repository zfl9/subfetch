//! subscription decoding: content bytes -> node list.
//! sniffs the format (uri list / base64 / clash yaml / v2rayN json /
//! sing-box json) then parses into nodes; single node URIs (ss:// etc.)
//! are handled by uri.zig, raw transport by fetch.zig.
const std = @import("std");
const node = @import("node.zig");
const uri = @import("uri.zig");
const sniff = @import("sniff.zig");
const yaml = @import("yaml.zig");

pub const ParseError = uri.ParseError || sniff.SniffError || error{
    ParseMissingField,
    ParseInvalidPort,
    ParseUnsupportedType,
    ParseUnsupportedPlugin,
    ParseMissingOutbounds,
    ParseOutboundsNotArray,
    ParseBadJsonRoot,
    ParseMissingProxies,
    ParseProxiesNotSequence,
};

pub const SkippedLine = struct {
    /// display text: raw URI line (uri-list), or node name (json/yaml entries)
    text: []const u8,
    /// parse error name (comptime string, no allocation; empty when no error
    /// object was available, e.g. a non-mapping clash proxy entry)
    reason: []const u8 = "",
};

pub const ParseResult = struct {
    nodes: []const node.Node,
    skipped: usize,
    /// skipped entries (display text + failure reason), for verbose diagnostics
    skipped_lines: []const SkippedLine = &.{},
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
    const s = try sniff.sniff(arena, text);
    var nodes: std.ArrayListUnmanaged(node.Node) = .empty;
    var skipped: usize = 0;
    var skipped_lines: std.ArrayListUnmanaged(SkippedLine) = .empty;
    var info: usize = 0;
    var info_names: std.ArrayListUnmanaged([]const u8) = .empty;

    switch (s) {
        .uris => |lines| {
            for (lines) |line| {
                const n = uri.parseUri(arena, line, sub_name, sep) catch |e| {
                    skipped += 1;
                    try skipped_lines.append(arena, .{ .text = line, .reason = @errorName(e) });
                    continue;
                };
                try addParsedNode(arena, &nodes, n, sub_name, sep, keywords, &info, &info_names);
            }
        },
        .json => |value| switch (value) {
            .array => |arr| {
                for (arr.items) |item| {
                    switch (item) {
                        .string => |str| {
                            const n = uri.parseUri(arena, str, sub_name, sep) catch |e| {
                                skipped += 1;
                                try skipped_lines.append(arena, .{ .text = str, .reason = @errorName(e) });
                                continue;
                            };
                            try addParsedNode(arena, &nodes, n, sub_name, sep, keywords, &info, &info_names);
                        },
                        .object => |obj| {
                            const n = jsonNodeToNode(arena, obj, sub_name, sep) catch |e| {
                                skipped += 1;
                                try skipped_lines.append(arena, .{ .text = jsonDisplayName(arena, obj), .reason = @errorName(e) });
                                continue;
                            };
                            try addParsedNode(arena, &nodes, n, sub_name, sep, keywords, &info, &info_names);
                        },
                        else => skipped += 1,
                    }
                }
            },
            // sing-box subscription: {"outbounds": [...]}
            .object => |obj| {
                const ob = obj.get("outbounds") orelse return error.ParseMissingOutbounds;
                const arr = switch (ob) {
                    .array => |a| a,
                    else => return error.ParseOutboundsNotArray,
                };
                for (arr.items) |item| {
                    const oobj = switch (item) {
                        .object => |o| o,
                        else => {
                            skipped += 1;
                            continue;
                        },
                    };
                    const n = singboxOutboundToNode(arena, oobj, sub_name, sep) catch |e| {
                        skipped += 1;
                        try skipped_lines.append(arena, .{ .text = jsonDisplayName(arena, oobj), .reason = @errorName(e) });
                        continue;
                    };
                    try addParsedNode(arena, &nodes, n, sub_name, sep, keywords, &info, &info_names);
                }
            },
            else => return error.ParseBadJsonRoot,
        },
        .clash => |root| {
            const m = yaml.mappingOf(root) orelse return error.ParseMissingProxies;
            const pv = yaml.mappingGet(m, "proxies") orelse return error.ParseMissingProxies;
            const proxies = yaml.sequenceOf(pv) orelse return error.ParseProxiesNotSequence;
            for (proxies) |item| {
                const pm = yaml.mappingOf(item) orelse {
                    skipped += 1;
                    continue;
                };
                const n = clashYamlToNode(arena, pm, sub_name, sep) catch |e| {
                    skipped += 1;
                    if (yaml.mappingGet(pm, "name")) |nv| switch (nv) {
                        .scalar => |nm| try skipped_lines.append(arena, .{ .text = nm, .reason = @errorName(e) }),
                        else => {},
                    };
                    continue;
                };
                try addParsedNode(arena, &nodes, n, sub_name, sep, keywords, &info, &info_names);
            }
        },
    }
    return .{
        .nodes = try nodes.toOwnedSlice(arena),
        .skipped = skipped,
        .skipped_lines = try skipped_lines.toOwnedSlice(arena),
        .info = info,
        .info_names = try info_names.toOwnedSlice(arena),
    };
}

/// best-effort display name for a skipped json node: v2rayN uses "ps",
/// sing-box uses "tag", "name" is the generic fallback (empty when absent)
fn jsonDisplayName(arena: std.mem.Allocator, obj: std.json.ObjectMap) []const u8 {
    _ = arena;
    for ([_][]const u8{ "ps", "tag", "name" }) |k| {
        if (obj.get(k)) |v| {
            if (v == .string) return v.string;
        }
    }
    return "";
}

/// info-filter one successfully parsed node + append it: info (notice) nodes are
/// counted but not appended (shared by all subscription formats).
fn addParsedNode(
    arena: std.mem.Allocator,
    nodes: *std.ArrayListUnmanaged(node.Node),
    n: node.Node,
    sub_name: []const u8,
    sep: []const u8,
    keywords: []const []const u8,
    info: *usize,
    info_names: *std.ArrayListUnmanaged([]const u8),
) ParseError!void {
    if (try filterInfoNode(arena, n, sub_name, sep, keywords, info, info_names)) return;
    try nodes.append(arena, n);
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

fn yBool(v: ?[]const u8) bool {
    return v != null and (std.mem.eql(u8, v.?, "true") or std.mem.eql(u8, v.?, "1"));
}

/// clash YAML node (yaml tree mapping) -> Node
fn clashYamlToNode(arena: std.mem.Allocator, m: []const yaml.MappingEntry, sub_name: []const u8, sep: []const u8) ParseError!node.Node {
    const get = yaml.mappingGetScalar;
    const type_str = get(m, "type") orelse return error.ParseUnsupportedType;
    const server = get(m, "server") orelse return error.ParseMissingField;
    const port = try uri.parsePort(get(m, "port") orelse return error.ParseMissingField);
    const raw_name = get(m, "name") orelse "";
    const name = try uri.makeName(arena, raw_name, sub_name, sep, server, port);

    if (std.mem.eql(u8, type_str, "ss")) {
        return .{ .ss = .{
            .name = name,
            .server = server,
            .port = port,
            .cipher = get(m, "cipher") orelse return error.ParseMissingField,
            .password = get(m, "password") orelse return error.ParseMissingField,
            .plugin = try ssPluginFromYaml(arena, m),
        } };
    }
    if (std.mem.eql(u8, type_str, "ssr")) {
        return .{ .ssr = .{
            .name = name,
            .server = server,
            .port = port,
            .cipher = get(m, "cipher") orelse return error.ParseMissingField,
            .password = get(m, "password") orelse return error.ParseMissingField,
            .protocol = get(m, "protocol") orelse "origin",
            .obfs = get(m, "obfs") orelse "plain",
            .obfs_param = get(m, "obfs-param"),
            .protocol_param = get(m, "protocol-param"),
        } };
    }
    if (std.mem.eql(u8, type_str, "vmess")) {
        const net = uri.parseNetwork(get(m, "network")) catch .tcp;
        return .{ .vmess = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = get(m, "uuid") orelse return error.ParseMissingField,
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
        const net = uri.parseNetwork(get(m, "network")) catch .tcp;
        const reality_v = yaml.mappingGet(m, "reality-opts");
        const reality: ?node.RealityOpts = if (reality_v) |rv| blk: {
            const rm = yaml.mappingOf(rv) orelse return error.ParseMissingField;
            break :blk .{
                .public_key = get(rm, "public-key") orelse return error.ParseMissingField,
                .short_id = get(rm, "short-id"),
                .spider_x = get(rm, "spider-x"),
            };
        } else null;
        return .{ .vless = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = get(m, "uuid") orelse return error.ParseMissingField,
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
        const net = uri.parseNetwork(get(m, "network")) catch .tcp;
        return .{ .trojan = .{
            .name = name,
            .server = server,
            .port = port,
            .password = get(m, "password") orelse return error.ParseMissingField,
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
            .password = get(m, "password") orelse return error.ParseMissingField,
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
            .uuid = get(m, "uuid") orelse return error.ParseMissingField,
            .password = get(m, "password") orelse return error.ParseMissingField,
            .servername = get(m, "servername") orelse get(m, "sni"),
            .skip_cert_verify = yBool(get(m, "skip-cert-verify")),
            .congestion_controller = get(m, "congestion-controller"),
            .udp_relay_mode = get(m, "udp-relay-mode"),
            .alpn = try yamlAlpn(arena, yaml.mappingGet(m, "alpn")),
        } };
    }
    return error.ParseUnsupportedType;
}

/// clash YAML ss plugin: plugin + plugin-opts (obfs-local / v2ray-plugin / shadow-tls)
fn ssPluginFromYaml(arena: std.mem.Allocator, m: []const yaml.MappingEntry) ParseError!?node.SsPlugin {
    _ = arena;
    const get = yaml.mappingGetScalar;
    const plugin = get(m, "plugin") orelse return null;
    const opts = yaml.mappingGet(m, "plugin-opts");
    const om = if (opts) |o| yaml.mappingOf(o) orelse return error.ParseMissingField else null;

    if (std.mem.eql(u8, plugin, "obfs-local")) {
        return .{
            .obfs_local = .{
                .mode = if (om) |mm| get(mm, "mode") orelse "http" else "http",
                // obfs-local default host, matching the ss:// URI parser (www.bing.com)
                .host = if (om) |mm| get(mm, "host") orelse "www.bing.com" else "www.bing.com",
            },
        };
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
    return error.ParseUnsupportedPlugin;
}

/// clash YAML alpn (yaml sequence) -> []const []const u8
fn yamlAlpn(arena: std.mem.Allocator, v: ?yaml.YamlValue) ParseError!?[]const []const u8 {
    const val = v orelse return null;
    const seq = yaml.sequenceOf(val) orelse {
        // some subscriptions use comma-separated strings
        const s = yaml.scalarOf(val) orelse return null;
        return uri.parseAlpn(arena, s);
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

/// json object field helpers (shared by sing-box and v2rayN node parsing)
fn jsonGetStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jsonGetBool(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn jsonGetPort(o: std.json.ObjectMap, key: []const u8) ParseError!u16 {
    const v = o.get(key) orelse return error.ParseMissingField;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= 65535) @intCast(i) else error.ParseInvalidPort,
        .string => |s| std.fmt.parseInt(u16, s, 10) catch error.ParseInvalidPort,
        else => error.ParseInvalidPort,
    };
}

fn jsonGetObj(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .object => |m| m,
        else => null,
    };
}

/// sing-box outbound object (subscription format: {"outbounds": [...]}) -> Node.
/// field layout differs from v2rayN: type/tag/server/server_port, tls{}, transport{}.
fn singboxOutboundToNode(arena: std.mem.Allocator, obj: std.json.ObjectMap, sub_name: []const u8, sep: []const u8) ParseError!node.Node {
    const server = jsonGetStr(obj, "server") orelse return error.ParseMissingField;
    const port = try jsonGetPort(obj, "server_port");
    const raw_name = jsonGetStr(obj, "tag") orelse "";
    const name = try uri.makeName(arena, raw_name, sub_name, sep, server, port);

    // tls {} block
    const tls = jsonGetObj(obj, "tls");
    const tls_enabled = if (tls) |t| jsonGetBool(t, "enabled") else false;
    const server_name = if (tls) |t| jsonGetStr(t, "server_name") else null;
    const insecure = if (tls) |t| jsonGetBool(t, "insecure") else false;
    const fingerprint: ?[]const u8 = if (tls) |t| blk: {
        if (jsonGetObj(t, "utls")) |u| break :blk jsonGetStr(u, "fingerprint");
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
    const transport = jsonGetObj(obj, "transport");
    const t_type = if (transport) |tr| jsonGetStr(tr, "type") else null;
    const network: node.Network = std.meta.stringToEnum(node.Network, t_type orelse "") orelse .tcp;
    var ws: ?node.WsOpts = null;
    var grpc: ?node.GrpcOpts = null;
    if (transport) |tr| switch (network) {
        .ws => {
            var host: ?[]const u8 = null;
            if (jsonGetObj(tr, "headers")) |h| host = jsonGetStr(h, "Host");
            ws = .{ .path = jsonGetStr(tr, "path") orelse "/", .host = host };
        },
        .grpc => {
            grpc = .{ .service_name = jsonGetStr(tr, "service_name") orelse "" };
        },
        else => {},
    };

    const ob_type = jsonGetStr(obj, "type") orelse return error.ParseMissingField;
    if (std.mem.eql(u8, ob_type, "vless")) {
        var reality: ?node.RealityOpts = null;
        if (tls) |t| {
            if (jsonGetObj(t, "reality")) |r| {
                if (jsonGetBool(r, "enabled")) {
                    reality = .{
                        .public_key = jsonGetStr(r, "public_key") orelse return error.ParseMissingField,
                        .short_id = jsonGetStr(r, "short_id"),
                    };
                }
            }
        }
        return .{ .vless = .{
            .name = name,
            .server = server,
            .port = port,
            .uuid = jsonGetStr(obj, "uuid") orelse return error.ParseMissingField,
            .network = network,
            .tls = tls_enabled,
            .reality = reality,
            .flow = jsonGetStr(obj, "flow"),
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
            .uuid = jsonGetStr(obj, "uuid") orelse return error.ParseMissingField,
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
            .password = jsonGetStr(obj, "password") orelse return error.ParseMissingField,
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
            .cipher = jsonGetStr(obj, "method") orelse return error.ParseMissingField,
            .password = jsonGetStr(obj, "password") orelse return error.ParseMissingField,
        };
        // sing-box plugin + plugin_opts (TOR_PT style, same as ss:// plugin param)
        if (jsonGetStr(obj, "plugin")) |p| {
            const opts_text = jsonGetStr(obj, "plugin_opts");
            const full = if (opts_text) |po|
                try std.fmt.allocPrint(arena, "{s};{s}", .{ p, po })
            else
                p;
            n.plugin = uri.parseSsPlugin(arena, full) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.ParseUnsupportedPlugin,
            };
        }
        return .{ .ss = n };
    }
    if (std.mem.eql(u8, ob_type, "hysteria2")) {
        var obfs: ?[]const u8 = null;
        var obfs_pw: ?[]const u8 = null;
        if (jsonGetObj(obj, "obfs")) |o| {
            if (std.mem.eql(u8, jsonGetStr(o, "type") orelse "", "salamander")) {
                obfs = jsonGetStr(o, "type");
                obfs_pw = jsonGetStr(o, "password");
            }
        }
        return .{ .hysteria2 = .{
            .name = name,
            .server = server,
            .port = port,
            .password = jsonGetStr(obj, "password") orelse return error.ParseMissingField,
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
            .auth_str = jsonGetStr(obj, "auth_str") orelse jsonGetStr(obj, "auth"),
            .up = jsonGetStr(obj, "up"),
            .down = jsonGetStr(obj, "down"),
            .obfs = jsonGetStr(obj, "obfs"),
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
            .uuid = jsonGetStr(obj, "uuid") orelse return error.ParseMissingField,
            .password = jsonGetStr(obj, "password") orelse return error.ParseMissingField,
            .servername = server_name,
            .skip_cert_verify = insecure,
            .congestion_controller = jsonGetStr(obj, "congestion_control"),
            .udp_relay_mode = jsonGetStr(obj, "udp_relay_mode"),
            .alpn = alpn,
        } };
    }
    // non-node outbounds (direct/block/selector/dns/...)
    return error.ParseUnsupportedType;
}

/// v2rayN JSON node (with "add"/"ps" fields) -> Node
fn jsonNodeToNode(arena: std.mem.Allocator, obj: std.json.ObjectMap, sub_name: []const u8, sep: []const u8) ParseError!node.Node {
    const server = jsonGetStr(obj, "add") orelse return error.ParseMissingField;
    const port = try uri.parsePort(jsonGetStr(obj, "port") orelse return error.ParseMissingField);
    const raw_name = jsonGetStr(obj, "ps") orelse "";
    const name = try uri.makeName(arena, raw_name, sub_name, sep, server, port);

    const net = uri.parseNetwork(jsonGetStr(obj, "net")) catch .tcp;
    return .{ .vmess = .{
        .name = name,
        .server = server,
        .port = port,
        .uuid = jsonGetStr(obj, "id") orelse return error.ParseMissingField,
        .alter_id = if (jsonGetStr(obj, "aid")) |v| std.fmt.parseInt(u16, v, 10) catch 0 else 0,
        .network = net,
        .tls = std.mem.eql(u8, jsonGetStr(obj, "tls") orelse "", "tls"),
        .servername = jsonGetStr(obj, "sni"),
        .fingerprint = jsonGetStr(obj, "fp"),
        .ws = if (net == .ws) .{ .path = jsonGetStr(obj, "path") orelse "/", .host = jsonGetStr(obj, "host") } else null,
        .grpc = if (net == .grpc) .{ .service_name = jsonGetStr(obj, "serviceName") orelse jsonGetStr(obj, "path") orelse "" } else null,
    } };
}

/// clash JSON object (type/server fields) -> Node (reuses yaml conversion field semantics)
fn wsOpts(m: []const yaml.MappingEntry, net: node.Network) ParseError!?node.WsOpts {
    if (net != .ws) return null;
    const get = yaml.mappingGetScalar;
    const wv = yaml.mappingGet(m, "ws-opts");
    if (wv) |w| {
        const wm = yaml.mappingOf(w) orelse return error.ParseMissingField;
        var host: ?[]const u8 = null;
        if (yaml.mappingGet(wm, "headers")) |hv| {
            const hm = yaml.mappingOf(hv) orelse return error.ParseMissingField;
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
        const gm = yaml.mappingOf(g) orelse return error.ParseMissingField;
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
        error.SniffHtmlPage,
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
    _ = &addParsedNode;
    _ = &filterInfoNode;
    _ = &clashYamlToNode;
    _ = &singboxOutboundToNode;
    _ = &jsonNodeToNode;
    _ = &yBool;
    _ = &wsOpts;
    _ = &grpcOpts;
    _ = &yamlAlpn;
    _ = &ssPluginFromYaml;
}
