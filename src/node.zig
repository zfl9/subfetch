const std = @import("std");
const util = @import("util.zig");

// ---------------- protocol parameter structs ----------------

pub const Network = enum { tcp, ws, grpc, http };

pub const WsOpts = struct {
    path: []const u8 = "/",
    host: ?[]const u8 = null,
};

pub const GrpcOpts = struct {
    service_name: []const u8 = "",
};

pub const RealityOpts = struct {
    public_key: []const u8,
    short_id: ?[]const u8 = null,
    spider_x: ?[]const u8 = null,
};

/// ss plugin params (obfs-local / v2ray-plugin / shadow-tls)
pub const SsPlugin = union(enum) {
    obfs_local: struct {
        mode: []const u8,
        host: []const u8,
    },
    v2ray_plugin: struct {
        mode: []const u8 = "websocket",
        tls: bool = false,
        host: ?[]const u8 = null,
        path: ?[]const u8 = null,
    },
    shadow_tls: struct {
        host: []const u8,
        password: []const u8,
        version: u8 = 3,
    },
};

// ---------------- per-protocol nodes ----------------

pub const SS = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    cipher: []const u8,
    password: []const u8,
    plugin: ?SsPlugin = null,
};

pub const SSR = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    cipher: []const u8,
    password: []const u8,
    protocol: []const u8,
    obfs: []const u8,
    obfs_param: ?[]const u8 = null,
    protocol_param: ?[]const u8 = null,
};

pub const Vmess = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    uuid: []const u8,
    alter_id: u16 = 0,
    network: Network = .tcp,
    tls: bool = false,
    servername: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    ws: ?WsOpts = null,
    grpc: ?GrpcOpts = null,
};

pub const Vless = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    uuid: []const u8,
    network: Network = .tcp,
    tls: bool = false,
    reality: ?RealityOpts = null,
    flow: ?[]const u8 = null,
    servername: ?[]const u8 = null,
    fingerprint: ?[]const u8 = null,
    skip_cert_verify: bool = false,
    alpn: ?[]const []const u8 = null,
    ws: ?WsOpts = null,
    grpc: ?GrpcOpts = null,
};

pub const Trojan = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    password: []const u8,
    servername: ?[]const u8 = null,
    skip_cert_verify: bool = false,
    alpn: ?[]const []const u8 = null,
    network: Network = .tcp,
    ws: ?WsOpts = null,
    grpc: ?GrpcOpts = null,
};

pub const Hysteria = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    protocol: []const u8 = "udp",
    auth_str: ?[]const u8 = null,
    up: ?[]const u8 = null,
    down: ?[]const u8 = null,
    obfs: ?[]const u8 = null,
    sni: ?[]const u8 = null,
    skip_cert_verify: bool = false,
    alpn: ?[]const []const u8 = null,
};

pub const Hysteria2 = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    password: []const u8,
    servername: ?[]const u8 = null,
    skip_cert_verify: bool = false,
    obfs: ?[]const u8 = null,
    obfs_password: ?[]const u8 = null,
    alpn: ?[]const []const u8 = null,
};

pub const Tuic = struct {
    name: []const u8,
    server: []const u8,
    port: u16,
    uuid: []const u8,
    password: []const u8,
    servername: ?[]const u8 = null,
    skip_cert_verify: bool = false,
    congestion_controller: ?[]const u8 = null,
    udp_relay_mode: ?[]const u8 = null,
    alpn: ?[]const []const u8 = null,
};

// ---------------- unified node ----------------

pub const Node = union(enum) {
    ss: SS,
    ssr: SSR,
    vmess: Vmess,
    vless: Vless,
    trojan: Trojan,
    hysteria: Hysteria,
    hysteria2: Hysteria2,
    tuic: Tuic,

    pub fn name(self: Node) []const u8 {
        return switch (self) {
            .ss => |n| n.name,
            .ssr => |n| n.name,
            .vmess => |n| n.name,
            .vless => |n| n.name,
            .trojan => |n| n.name,
            .hysteria => |n| n.name,
            .hysteria2 => |n| n.name,
            .tuic => |n| n.name,
        };
    }

    pub fn typeName(self: Node) []const u8 {
        return switch (self) {
            .ss => "ss",
            .ssr => "ssr",
            .vmess => "vmess",
            .vless => "vless",
            .trojan => "trojan",
            .hysteria => "hysteria",
            .hysteria2 => "hysteria2",
            .tuic => "tuic",
        };
    }
};

// ---------------- name handling ----------------

const max_name_len = 60;

/// sanitize a name: strip control chars, collapse whitespace, truncate overlong names.
pub fn sanitizeName(allocator: std.mem.Allocator, n: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var prev_space = false;
    for (n) |ch| {
        if (ch < 0x20 or ch == 0x7f) {
            if (!prev_space and buf.items.len > 0) {
                try buf.append(allocator, ' ');
                prev_space = true;
            }
            continue;
        }
        if (ch == ' ' or ch == '\t') {
            if (!prev_space and buf.items.len > 0) {
                try buf.append(allocator, ' ');
                prev_space = true;
            }
            continue;
        }
        prev_space = false;
        try buf.append(allocator, ch);
    }
    // strip trailing spaces
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        buf.items.len -= 1;
    }
    if (buf.items.len > max_name_len) buf.items.len = max_name_len;
    return buf.toOwnedSlice(allocator);
}

/// case-insensitive substring search (byte-wise; non-ASCII passes through).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

/// default info-node keywords (airport notice pseudo-nodes). strong words only:
/// real node names (e.g. "unlimited traffic - HK" style) are never caught.
/// override per-subscription-list via the `info_node_keywords` zon field.
pub const default_info_keywords = [_][]const u8{
    "到期", "剩余", "有效期", "套餐", "官网", // zh: expiry/remain/validity/plan/website
    "expire", "traffic", "usage", "plan", // en (case-insensitive)
};

/// airport notice (info) node detection: name contains any keyword.
/// the broad "remain" keyword (instead of only "remain-traffic") also catches
/// variants like "days until next reset remain: 21".
pub fn isInfoNodeName(name: []const u8, keywords: []const []const u8) bool {
    for (keywords) |kw| {
        if (containsIgnoreCase(name, kw)) return true;
    }
    return false;
}

/// build the full node name: subscription name + separator + node name; empty name falls back to server:port.
pub fn prefixed(
    allocator: std.mem.Allocator,
    sub_name: []const u8,
    raw_name: []const u8,
    sep: []const u8,
    fallback: []const u8,
) ![]const u8 {
    const cleaned = try sanitizeName(allocator, raw_name);
    const base = if (cleaned.len > 0) cleaned else fallback;
    if (sub_name.len == 0) return base;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sub_name, sep, base });
}

// ---------------- tests ----------------

test "sanitizeName strips control chars and collapses spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try sanitizeName(arena.allocator(), "  a\x01\x02  b\tc  ");
    try std.testing.expectEqualStrings("a b c", n);
}

test "prefixed with fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n1 = try prefixed(arena.allocator(), "airport-a", "HK-01", "@", "1.2.3.4:443");
    try std.testing.expectEqualStrings("airport-a@HK-01", n1);
    const n2 = try prefixed(arena.allocator(), "airport-a", "", "@", "1.2.3.4:443");
    try std.testing.expectEqualStrings("airport-a@1.2.3.4:443", n2);
}

test "node name accessor" {
    const n: Node = .{ .trojan = .{
        .name = "t1",
        .server = "s",
        .port = 443,
        .password = "p",
    } };
    try std.testing.expectEqualStrings("t1", n.name());
    try std.testing.expectEqualStrings("trojan", n.typeName());
}

test "isInfoNodeName" {
    // airport notice pseudo-nodes
    try std.testing.expect(isInfoNodeName("到期2026-12-21 剩余流量279.95G", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("剩余流量：100GB", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("有效期至2027-01-01", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("套餐信息 官网：example.com", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("Expire: 2026-12-21", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("Traffic Used: 20GB", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("USAGE: 50%", &default_info_keywords));
    try std.testing.expect(isInfoNodeName("My Plan Info", &default_info_keywords));
    // real node names must NOT match (no false positives)
    try std.testing.expect(!isInfoNodeName("香港1-电信优化", &default_info_keywords));
    try std.testing.expect(!isInfoNodeName("不限流量-香港", &default_info_keywords)); // bare 流量 alone must not match
    try std.testing.expect(!isInfoNodeName("新加坡1-BGP优化", &default_info_keywords));
    try std.testing.expect(!isInfoNodeName("日本4", &default_info_keywords));
    try std.testing.expect(!isInfoNodeName("HK-01-optimized", &default_info_keywords));
}

test "compile-check" {
    _ = &sanitizeName;
    _ = &prefixed;
    _ = &Node.name;
    _ = &Node.typeName;
}
