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
    /// whether sing-box enables clash_api (node switching via WebUI)
    enable_clash_api: bool = true,
};

/// render result
pub const Output = union(enum) {
    /// single-file text (clash / singbox / raw)
    single: []const u8,
    /// multi-file (native formats: one json per node + current.json)
    files: []const File,
};

pub const File = struct {
    path: []const u8,
    content: []const u8,
};

/// render all nodes for the given format. strings are allocated from the arena.
pub fn render(
    arena: std.mem.Allocator,
    fmt: Format,
    nodes: []const Node,
    opts: Options,
) !Output {
    return switch (fmt) {
        .clash => .{ .single = try @import("render_clash.zig").renderClash(arena, nodes, opts) },
        .singbox => .{ .single = try @import("render_singbox.zig").renderSingbox(arena, nodes, opts) },
        .trojan => .{ .files = try @import("render_native.zig").renderTrojan(arena, nodes, opts) },
        .hysteria => .{ .files = try @import("render_native.zig").renderHysteria(arena, nodes, opts) },
        .hysteria2 => .{ .files = try @import("render_native.zig").renderHysteria2(arena, nodes, opts) },
        .xray => .{ .files = try @import("render_native.zig").renderXray(arena, nodes, opts) },
        .ss => .{ .files = try @import("render_native.zig").renderSs(arena, nodes, opts) },
        .ssr => .{ .files = try @import("render_native.zig").renderSsr(arena, nodes, opts) },
        .raw => .{ .single = try @import("render_raw.zig").renderRaw(arena, nodes) },
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

/// recursively serialize std.json.Value to JSON text (objects expanded, arrays inline; readability first)
pub fn writeJsonValue(w: anytype, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.print("{}", .{b}),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeJsonString(w, s),
        .array => |a| {
            try w.writeAll("[");
            for (a.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try writeJsonValue(w, item);
            }
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
                try writeJsonString(w, entry.key_ptr.*);
                try w.writeAll(": ");
                try writeJsonValue(w, entry.value_ptr.*);
            }
            try w.writeAll("\n}");
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
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{X:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeAll("\"");
}

// ---------------- tests ----------------

const sample_nodes = [_]node.Node{
    .{ .trojan = .{
        .name = "HK-01",
        .server = "hk1.example.com",
        .port = 443,
        .password = "pass123",
        .servername = "hk1.example.com",
        .skip_cert_verify = true,
    } },
    .{
        .trojan = .{
            .name = "HK-01", // duplicate-name test
            .server = "hk2.example.com",
            .port = 443,
            .password = "pass456",
        },
    },
    .{
        .ss = .{
            .name = "AUTO", // reserved-name test
            .server = "sg1.example.com",
            .port = 8388,
            .cipher = "aes-256-gcm",
            .password = "sspass",
        },
    },
};

test "uniqueNames dedupe and reserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try uniqueNames(arena.allocator(), &sample_nodes);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("HK-01", out[0].name());
    try std.testing.expectEqualStrings("HK-01-2", out[1].name());
    try std.testing.expectEqualStrings("AUTO-1", out[2].name());
    // original node name is unaffected
    try std.testing.expectEqualStrings("HK-01", sample_nodes[1].name());
}

test "format parse" {
    try std.testing.expectEqual(Format.clash, Format.parse("clash").?);
    try std.testing.expectEqual(Format.singbox, Format.parse("singbox").?);
    try std.testing.expectEqual(Format.trojan, Format.parse("trojan").?);
    try std.testing.expectEqual(Format.raw, Format.parse("raw").?);
    try std.testing.expect(Format.parse("nope") == null);
}

test "writeJsonValue escapes" {
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
    try std.testing.expectEqualStrings("[1, 2]", try q(arena.allocator(), .{ .array = blk: {
        var a = std.json.Array.init(arena.allocator());
        try a.append(.{ .integer = 1 });
        try a.append(.{ .integer = 2 });
        break :blk a;
    } }));
}

test "compile-check" {
    _ = &render;
    _ = &uniqueNames;
    _ = &renameNode;
    _ = &Format.parse;
    _ = &writeJsonValue;
    _ = &writeJsonString;
}
