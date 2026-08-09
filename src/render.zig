const std = @import("std");
const node = @import("node.zig");
const Node = node.Node;

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
        if (std.mem.eql(u8, s, "clash")) return .clash;
        if (std.mem.eql(u8, s, "singbox")) return .singbox;
        if (std.mem.eql(u8, s, "trojan")) return .trojan;
        if (std.mem.eql(u8, s, "hysteria")) return .hysteria;
        if (std.mem.eql(u8, s, "hysteria2")) return .hysteria2;
        if (std.mem.eql(u8, s, "raw")) return .raw;
        if (std.mem.eql(u8, s, "xray")) return .xray;
        if (std.mem.eql(u8, s, "ss")) return .ss;
        if (std.mem.eql(u8, s, "ssr")) return .ssr;
        return null;
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
    log_level: ?[]const u8 = null,
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
        .clash => @import("render_clash.zig").renderClash(arena, use_nodes, opts, template),
        .singbox => @import("render_singbox.zig").renderSingbox(arena, use_nodes, opts, template),
        .trojan => @import("render_native.zig").renderTrojan(arena, use_nodes, opts, template),
        .hysteria => @import("render_native.zig").renderHysteria(arena, use_nodes, opts, template),
        .hysteria2 => @import("render_native.zig").renderHysteria2(arena, use_nodes, opts, template),
        .xray => @import("render_native.zig").renderXray(arena, use_nodes, opts, template),
        .ss => @import("render_native.zig").renderSs(arena, use_nodes, opts, template),
        .ssr => @import("render_native.zig").renderSsr(arena, use_nodes, opts, template),
        .raw => @import("render_raw.zig").renderRaw(arena, use_nodes, template),
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

/// recursively serialize std.json.Value to JSON text: objects expanded with 2-space
/// indentation, arrays inline (readability first). Exact output is what gets written
/// to disk, so indentation matters for the generated config.json files.
pub fn writeJsonValue(w: anytype, v: std.json.Value) !void {
    try writeJsonValueLevel(w, v, 0);
}

fn writeJsonValueLevel(w: anytype, v: std.json.Value, level: usize) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.print("{}", .{b}),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeJsonString(w, s),
        .array => |a| {
            if (a.items.len == 0) {
                try w.writeAll("[]");
                return;
            }
            // standard pretty style: every element on its own indented line
            try w.writeAll("[\n");
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(",\n");
                var indent: usize = 0;
                while (indent <= level) : (indent += 1) try w.writeAll("  ");
                try writeJsonValueLevel(w, item, level + 1);
            }
            try w.writeAll("\n");
            var close_indent: usize = 0;
            while (close_indent < level) : (close_indent += 1) try w.writeAll("  ");
            try w.writeAll("]");
        },
        .object => |o| {
            if (o.count() == 0) {
                try w.writeAll("{}");
                return;
            }
            try w.writeAll("{\n");
            var it = o.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeAll(",\n");
                first = false;
                var indent: usize = 0;
                while (indent <= level) : (indent += 1) try w.writeAll("  ");
                try writeJsonString(w, entry.key_ptr.*);
                try w.writeAll(": ");
                try writeJsonValueLevel(w, entry.value_ptr.*, level + 1);
            }
            try w.writeAll("\n");
            var close_indent: usize = 0;
            while (close_indent < level) : (close_indent += 1) try w.writeAll("  ");
            try w.writeAll("}");
        },
    }
}

/// JSON string escaping (non-ASCII bytes pass through as UTF-8)
pub fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(ch),
        }
    }
    try w.writeAll("\"");
}

test "writeJsonValue escapes and indents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const q = struct {
        fn render(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
            var list: std.ArrayListUnmanaged(u8) = .empty;
            try writeJsonValue(list.writer(a), v);
            return list.toOwnedSlice(a);
        }
    }.render;
    try std.testing.expectEqualStrings("null", try q(arena.allocator(), .null));
    try std.testing.expectEqualStrings("123", try q(arena.allocator(), .{ .integer = 123 }));
    try std.testing.expectEqualStrings("\"a\\\"b\"", try q(arena.allocator(), .{ .string = "a\"b" }));
    try std.testing.expectEqualStrings(
        \\[
        \\  1,
        \\  2
        \\]
    , try q(arena.allocator(), .{ .array = blk: {
        var a = std.json.Array.init(arena.allocator());
        try a.append(.{ .integer = 1 });
        try a.append(.{ .integer = 2 });
        break :blk a;
    } }));
    // object with 2-space indentation
    const obj = try q(arena.allocator(), .{ .object = blk_obj: {
        var o = std.json.ObjectMap.init(arena.allocator());
        try o.put("log", .{ .object = blk_log: {
            var l = std.json.ObjectMap.init(arena.allocator());
            try l.put("level", .{ .string = "info" });
            break :blk_log l;
        } });
        break :blk_obj o;
    } });
    try std.testing.expectEqualStrings(
        \\{
        \\  "log": {
        \\    "level": "info"
        \\  }
        \\}
    , obj);
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
        .name = "t", .server = "s", .port = 443, .password = "p",
    } };
    const ssr = node.Node{ .ssr = .{
        .name = "r", .server = "s", .port = 443, .cipher = "aes-256-cfb", .password = "p", .protocol = "origin", .obfs = "plain",
    } };
    const vl = node.Node{ .vless = .{
        .name = "v", .server = "s", .port = 443, .uuid = "11111111-2222-3333-4444-555555555555",
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
    _ = &writeJsonValue;
    _ = &writeJsonString;
}
