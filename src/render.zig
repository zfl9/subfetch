const std = @import("std");
const node = @import("node.zig");
const render_clash = @import("render_clash.zig");
const render_singbox = @import("render_singbox.zig");
const render_native = @import("render_native.zig");
const render_raw = @import("render_raw.zig");
const Node = node.Node;

/// client log level; members are the sing-box spellings (warn/err) so
/// @tagName works directly there; clash/xray need clashName().
/// enum so .zon parses type-checked (std.zon type-driven) and CLI
/// validation is a single parse() lookup.
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    /// clash/xray spelling (warn->warning, err->error); @tagName for sing-box
    pub fn clashName(self: LogLevel) []const u8 {
        return switch (self) {
            .warn => "warning",
            .err => "error",
            else => @tagName(self),
        };
    }
};

/// output format
pub const Format = enum {
    clash,
    singbox,
    trojan,
    hysteria,
    hysteria2,
    raw,
    /// xray-core native config (vless)
    xray,
    /// shadowsocks-libev/rust native config
    ss,
    /// shadowsocksr-libev native config
    ssr,

    pub fn parse(s: []const u8) ?Format {
        return std.meta.stringToEnum(Format, s);
    }
};

/// render options (output customization fields)
pub const Options = struct {
    /// socks5 listen address for native clients (trojan/hysteria/hysteria2)
    listen: []const u8 = "127.0.0.1",
    /// socks5 listen port for native clients
    port: u16 = 1080,
    /// clash mixed-port
    mixed_port: u16 = 65500,
    /// clash / sing-box external-controller
    controller: []const u8 = "127.0.0.1:65501",
    /// clash / sing-box API secret
    secret: ?[]const u8 = null,
    /// clash allow-lan (built-in template only)
    allow_lan: bool = false,
    /// v6 tproxy dual-stack (built-in templates only)
    tproxy_ipv6: bool = false,
    /// tproxy inbound port (clash + sing-box built-in templates; null = off)
    tproxy_port: ?u16 = null,
    /// client log level (built-in templates; null = info)
    log_level: ?LogLevel = null,
    /// whether sing-box enables clash_api (node switching via WebUI).
    /// default off: main passes the CLI/.zon flag explicitly; the struct
    /// default is false so accidental Options{} construction cannot enable it
    singbox_clash_api: bool = false,
};

pub const File = struct {
    path: []const u8,
    content: []const u8,
};

/// whether `fmt` accepts a node of this protocol (protocol-level filter basis).
/// per-node sub-type filters (e.g. sing-box's v2ray-plugin) still live inside
/// the renderers; this is the explicit protocol-level filter for reporting.
pub fn supports(fmt: Format, n: Node) bool {
    return switch (fmt) {
        .clash, .raw => true, // aggregate formats accept all 8 protocols
        .singbox => n != .ssr, // sing-box has no ssr support
        .trojan => n == .trojan,
        .hysteria => n == .hysteria,
        .hysteria2 => n == .hysteria2,
        .xray => n == .vless,
        .ss => n == .ss,
        .ssr => n == .ssr,
    };
}

/// render all nodes for the given format. returns output files
/// (single-file formats: one element; native formats: one file per node).
/// node names are deduped + reserved-name protected here (renderer layer
/// responsibility); raw keeps the original names (data export).
pub fn render(
    arena: std.mem.Allocator,
    fmt: Format,
    nodes: []const Node,
    opts: Options,
    template: ?[]const u8,
) ![]const File {
    const use_nodes = if (fmt == .raw) nodes else try uniqueNames(arena, nodes);
    return switch (fmt) {
        .clash => render_clash.renderClash(arena, use_nodes, opts, template),
        .singbox => render_singbox.renderSingbox(arena, use_nodes, opts, template),
        .trojan => render_native.renderTrojan(arena, use_nodes, opts),
        .hysteria => render_native.renderHysteria(arena, use_nodes, opts),
        .hysteria2 => render_native.renderHysteria2(arena, use_nodes, opts),
        .xray => render_native.renderXray(arena, use_nodes, opts),
        .ss => render_native.renderSs(arena, use_nodes, opts),
        .ssr => render_native.renderSsr(arena, use_nodes, opts),
        .raw => render_raw.renderRaw(arena, use_nodes),
    };
}

/// dedupe node names + guard against reserved names (group names AUTO/PROXY etc.).
/// returns a new allocated []Node (original name fields untouched; only name slices replaced).
pub fn uniqueNames(arena: std.mem.Allocator, nodes_in: []const Node) ![]Node {
    var out: std.ArrayListUnmanaged(Node) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;

    for (nodes_in) |n| {
        var name = n.name();
        // reserved name conflict: append suffix
        const reserved = [_][]const u8{ "PROXY", "AUTO", "DIRECT", "REJECT", "PASS", "GLOBAL" };
        for (reserved) |r| {
            if (std.mem.eql(u8, name, r)) {
                name = try std.fmt.allocPrint(arena, "{s}-1", .{name});
                break;
            }
        }
        // duplicate name: increment suffix
        var i: usize = 2;
        var final = name;
        while (used.contains(final)) : (i += 1) {
            final = try std.fmt.allocPrint(arena, "{s}-{d}", .{ name, i });
        }
        try used.put(arena, final, {});
        try out.append(arena, renameNode(n, final));
    }
    return out.toOwnedSlice(arena);
}

/// copy a node with the name replaced
fn renameNode(n: Node, new_name: []const u8) Node {
    return switch (n) {
        .ss => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .ss = x };
        },
        .ssr => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .ssr = x };
        },
        .vmess => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .vmess = x };
        },
        .vless => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .vless = x };
        },
        .trojan => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .trojan = x };
        },
        .hysteria => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .hysteria = x };
        },
        .hysteria2 => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .hysteria2 = x };
        },
        .tuic => |v| blk: {
            var x = v;
            x.name = new_name;
            break :blk .{ .tuic = x };
        },
    };
}

test "uniqueNames dedupe and reserved names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mk = struct {
        fn trojan(nm: []const u8) Node {
            return .{ .trojan = .{ .name = nm, .server = "s", .port = 443, .password = "p" } };
        }
    }.trojan;

    // duplicates get -2/-3 suffixes
    const dup = [_]Node{ mk("A"), mk("A"), mk("A") };
    const dup_out = try uniqueNames(a, &dup);
    try std.testing.expectEqualStrings("A", dup_out[0].name());
    try std.testing.expectEqualStrings("A-2", dup_out[1].name());
    try std.testing.expectEqualStrings("A-3", dup_out[2].name());

    // reserved names get -1 (protect clash/singbox fixed group tags)
    const res = [_]Node{ mk("PROXY"), mk("AUTO"), mk("DIRECT") };
    const res_out = try uniqueNames(a, &res);
    try std.testing.expectEqualStrings("PROXY-1", res_out[0].name());
    try std.testing.expectEqualStrings("AUTO-1", res_out[1].name());
    try std.testing.expectEqualStrings("DIRECT-1", res_out[2].name());

    // reserved + duplicate: PROXY, PROXY -> PROXY-1, PROXY-1-2
    const resdup = [_]Node{ mk("PROXY"), mk("PROXY") };
    const rd_out = try uniqueNames(a, &resdup);
    try std.testing.expectEqualStrings("PROXY-1", rd_out[0].name());
    try std.testing.expectEqualStrings("PROXY-1-2", rd_out[1].name());

    // cross-subscription same node name stays untouched (sub@name is unique)
    const cross = [_]Node{ mk("sub1@HK-01"), mk("sub2@HK-01") };
    const cross_out = try uniqueNames(a, &cross);
    try std.testing.expectEqualStrings("sub1@HK-01", cross_out[0].name());
    try std.testing.expectEqualStrings("sub2@HK-01", cross_out[1].name());

    // no duplicates: unchanged
    const clean = [_]Node{ mk("X"), mk("Y") };
    const clean_out = try uniqueNames(a, &clean);
    try std.testing.expectEqualStrings("X", clean_out[0].name());
    try std.testing.expectEqualStrings("Y", clean_out[1].name());
}

test "supports filter" {
    const tro = node.Node{ .trojan = .{
        .name = "t",
        .server = "s",
        .port = 443,
        .password = "p",
    } };
    const ssr = node.Node{ .ssr = .{
        .name = "r",
        .server = "s",
        .port = 443,
        .cipher = "aes-256-cfb",
        .password = "p",
        .protocol = "origin",
        .obfs = "plain",
    } };
    const vl = node.Node{ .vless = .{
        .name = "v",
        .server = "s",
        .port = 443,
        .uuid = "11111111-2222-3333-4444-555555555555",
    } };

    try std.testing.expect(supports(.clash, tro));
    try std.testing.expect(supports(.clash, ssr));
    try std.testing.expect(supports(.raw, ssr));
    try std.testing.expect(!supports(.singbox, ssr));
    try std.testing.expect(supports(.singbox, tro));
    try std.testing.expect(!supports(.trojan, vl));
    try std.testing.expect(supports(.trojan, tro));
    try std.testing.expect(supports(.xray, vl));
    try std.testing.expect(!supports(.xray, tro));
}

test "compile-check" {
    _ = &render;
    _ = &uniqueNames;
    _ = &renameNode;
    _ = &supports;
    _ = &Format.parse;
}

test "LogLevel clashName spelling" {
    // clash/xray want the long spellings; sing-box uses @tagName directly
    try std.testing.expectEqualStrings("warning", LogLevel.warn.clashName());
    try std.testing.expectEqualStrings("error", LogLevel.err.clashName());
    try std.testing.expectEqualStrings("debug", LogLevel.debug.clashName());
    try std.testing.expectEqualStrings("info", LogLevel.info.clashName());
}

test "LogLevel stringToEnum roundtrip" {
    // members are the CLI/.zon value domain (no legacy aliases)
    try std.testing.expectEqual(LogLevel.debug, std.meta.stringToEnum(LogLevel, "debug"));
    try std.testing.expectEqual(LogLevel.info, std.meta.stringToEnum(LogLevel, "info"));
    try std.testing.expectEqual(LogLevel.warn, std.meta.stringToEnum(LogLevel, "warn"));
    try std.testing.expectEqual(LogLevel.err, std.meta.stringToEnum(LogLevel, "err"));
    try std.testing.expect(std.meta.stringToEnum(LogLevel, "warning") == null);
    try std.testing.expect(std.meta.stringToEnum(LogLevel, "error") == null);
    try std.testing.expect(std.meta.stringToEnum(LogLevel, "bogus") == null);
}
