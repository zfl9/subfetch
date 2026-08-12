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

/// v2ray-plugin params (tls/mode/host/path), named type for renderer reuse
pub const V2rayPlugin = struct {
    mode: []const u8 = "websocket",
    tls: bool = false,
    host: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

/// ss plugin params (obfs-local / v2ray-plugin / shadow-tls)
pub const SsPlugin = union(enum) {
    obfs_local: struct {
        mode: []const u8,
        host: []const u8,
    },
    v2ray_plugin: V2rayPlugin,
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
        // inline else: every variant must carry a `name` field (compile-enforced)
        return switch (self) {
            inline else => |n| n.name,
        };
    }

    pub fn typeName(self: Node) []const u8 {
        return @tagName(self);
    }

    pub fn server(self: Node) []const u8 {
        return switch (self) {
            inline else => |n| n.server,
        };
    }

    pub fn port(self: Node) u16 {
        return switch (self) {
            inline else => |n| n.port,
        };
    }
};

// ---------------- name handling ----------------

const max_name_len = 60;

/// sanitize a name: strip control chars, collapse whitespace, drop decorative
/// codepoints (emoji, misc symbols, variation selectors, ZWJ), truncate overlong
/// names. invalid/truncated UTF-8 tails pass through byte-wise.
fn sanitizeName(allocator: std.mem.Allocator, n: []const u8) error{OutOfMemory}![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var prev_space = false;
    var i: usize = 0;
    while (i < n.len) {
        const b = n[i];
        if (b < 0x80) {
            // ASCII: control chars and whitespace collapse to a single space
            if (b < 0x20 or b == 0x7f or b == ' ' or b == '\t') {
                if (!prev_space and buf.items.len > 0) {
                    try buf.append(allocator, ' ');
                    prev_space = true;
                }
            } else {
                try buf.append(allocator, b);
                prev_space = false;
            }
            i += 1;
            continue;
        }
        // multi-byte: decode one codepoint; truncated/invalid tails pass
        // through byte-wise (never read past the end)
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try buf.append(allocator, b);
            prev_space = false;
            i += 1;
            continue;
        };
        if (i + seq_len > n.len) {
            try buf.appendSlice(allocator, n[i..]);
            break;
        }
        const cp = std.unicode.utf8Decode(n[i .. i + seq_len]) catch {
            try buf.append(allocator, b);
            prev_space = false;
            i += 1;
            continue;
        };
        if (isDecorative(cp)) {
            // drop the decorative codepoint, retracting the space emitted for
            // a preceding whitespace; skip whitespace glued after it too
            if (prev_space and buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
                buf.items.len -= 1;
            }
            prev_space = false;
            i += seq_len;
            while (i < n.len and (n[i] == ' ' or n[i] == '\t' or n[i] == '\r' or n[i] == '\n')) i += 1;
            continue;
        }
        try buf.appendSlice(allocator, n[i .. i + seq_len]);
        prev_space = false;
        i += seq_len;
    }
    // strip trailing spaces
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        buf.items.len -= 1;
    }
    if (buf.items.len > max_name_len) {
        var cut: usize = max_name_len;
        // back off to a UTF-8 character boundary: while buf[cut] is a
        // continuation byte (0b10xxxxxx) it belongs to a multi-byte char
        // that started earlier; cutting there would emit invalid UTF-8
        while (cut > 0 and (buf.items[cut] & 0xC0) == 0x80) : (cut -= 1) {}
        buf.items.len = cut;
    }
    return buf.toOwnedSlice(allocator);
}

/// decorative codepoints dropped from node names: emoji blocks, misc symbols +
/// dingbats, variation selectors, zero-width joiner. CJK extension blocks
/// (U+20000+) are NOT decorative and pass through.
fn isDecorative(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or
        (cp >= 0x2600 and cp <= 0x27BF) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or
        cp == 0x200D;
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
/// override per-subscription-list via the `info_keywords` zon field.
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
) error{OutOfMemory}![]const u8 {
    const cleaned = try sanitizeName(allocator, raw_name);
    const base = if (cleaned.len > 0) cleaned else fallback;
    if (sub_name.len == 0) return base;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ sub_name, sep, base });
}

// ---------------- tests ----------------

test "sanitizeName truncates at UTF-8 boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 50 ASCII + "香港1-电信优化" (18 bytes) = 68 bytes; cut at 60 lands
    // inside "电" (E7 94 B5) -> must back off to the full char boundary
    const long = "A" ** 50 ++ "香港1-电信优化";
    const n = try sanitizeName(arena.allocator(), long);
    // 50 + 香(3) + 港(3) + 1(1) + -(1) = 58 bytes, all complete chars
    try std.testing.expectEqual(@as(usize, 58), n.len);
    try std.testing.expectEqualStrings("A" ** 50 ++ "香港1-", n);
    // short names unaffected
    const short = try sanitizeName(arena.allocator(), "香港1-电信优化");
    try std.testing.expectEqualStrings("香港1-电信优化", short);
}

test "sanitizeName strips control chars and collapses spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try sanitizeName(arena.allocator(), "  a\x01\x02  b\tc  ");
    try std.testing.expectEqualStrings("a b c", n);
}

test "sanitizeName drops emoji and decorative symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 4-byte emoji dropped (with glued whitespace)
    try std.testing.expectEqualStrings("香港1-电信优化", try sanitizeName(a, "🇭🇰 香港1-电信优化"));
    try std.testing.expectEqualStrings("香港1", try sanitizeName(a, "香港🇭🇰1"));
    try std.testing.expectEqualStrings("香港1", try sanitizeName(a, "香港 🇭🇰 1"));
    // 3-byte misc symbol (U+2600) dropped
    try std.testing.expectEqualStrings("香港", try sanitizeName(a, "☀香港"));
    // heart + variation selector (U+FE0F) dropped
    try std.testing.expectEqualStrings("香港", try sanitizeName(a, "❤️香港"));
    // CJK extension B (U+20000) is NOT decorative: passes through
    try std.testing.expectEqualStrings("𠀀香港", try sanitizeName(a, "𠀀香港"));
    // truncated UTF-8 tail passes through byte-wise (no panic)
    try std.testing.expectEqualStrings("abc\xe4", try sanitizeName(a, "abc\xe4"));
    try std.testing.expectEqualStrings("ab\xf0\x9f", try sanitizeName(a, "ab\xf0\x9f"));
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
    _ = &containsIgnoreCase;
    _ = &isInfoNodeName;
    _ = &isDecorative;
    _ = &Node.name;
    _ = &Node.typeName;
}
