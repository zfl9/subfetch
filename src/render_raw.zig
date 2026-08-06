const std = @import("std");
const node = @import("node.zig");

const JsonValue = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// render raw format: node JSON list (for other tools/scripts)
pub fn renderRaw(arena: std.mem.Allocator, nodes: []const node.Node) ![]const u8 {
    var arr = std.json.Array.init(arena);
    for (nodes) |n| {
        try arr.append(try nodeToJson(arena, n));
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try @import("render.zig").writeJsonValue(out.writer(arena), .{ .array = arr });
    try out.append(arena, '\n');
    return out.toOwnedSlice(arena);
}

fn nodeToJson(arena: std.mem.Allocator, n: node.Node) !JsonValue {
    var o = ObjectMap.init(arena);
    try o.put("type", .{ .string = n.typeName() });
    try o.put("name", .{ .string = n.name() });
    try o.put("server", .{ .string = serverOf(n) });
    try o.put("port", .{ .integer = portOf(n) });

    switch (n) {
        .ss => |v| {
            try o.put("cipher", .{ .string = v.cipher });
            try o.put("password", .{ .string = v.password });
        },
        .ssr => |v| {
            try o.put("cipher", .{ .string = v.cipher });
            try o.put("password", .{ .string = v.password });
            try o.put("protocol", .{ .string = v.protocol });
            try o.put("obfs", .{ .string = v.obfs });
            if (v.obfs_param) |p| try o.put("obfs-param", .{ .string = p });
            if (v.protocol_param) |p| try o.put("protocol-param", .{ .string = p });
        },
        .vmess => |v| {
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("alterId", .{ .integer = v.alter_id });
            try o.put("network", .{ .string = @tagName(v.network) });
            if (v.tls) try o.put("tls", .{ .bool = true });
            if (v.servername) |s| try o.put("servername", .{ .string = s });
        },
        .vless => |v| {
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("network", .{ .string = @tagName(v.network) });
            if (v.tls) try o.put("tls", .{ .bool = true });
            if (v.flow) |f| try o.put("flow", .{ .string = f });
            if (v.servername) |s| try o.put("servername", .{ .string = s });
            if (v.reality) |r| {
                var ro = ObjectMap.init(arena);
                try ro.put("public-key", .{ .string = r.public_key });
                if (r.short_id) |sid| try ro.put("short-id", .{ .string = sid });
                try o.put("reality-opts", .{ .object = ro });
            }
        },
        .trojan => |v| {
            try o.put("password", .{ .string = v.password });
            if (v.servername) |s| try o.put("servername", .{ .string = s });
            if (v.skip_cert_verify) try o.put("skip-cert-verify", .{ .bool = true });
        },
        .hysteria => |v| {
            if (v.auth_str) |a| try o.put("auth-str", .{ .string = a });
            if (v.up) |u| try o.put("up-mbps", .{ .string = u });
            if (v.down) |d| try o.put("down-mbps", .{ .string = d });
            if (v.sni) |s| try o.put("sni", .{ .string = s });
        },
        .hysteria2 => |v| {
            try o.put("password", .{ .string = v.password });
            if (v.servername) |s| try o.put("servername", .{ .string = s });
            if (v.obfs) |obfs| try o.put("obfs", .{ .string = obfs });
        },
        .tuic => |v| {
            try o.put("uuid", .{ .string = v.uuid });
            try o.put("password", .{ .string = v.password });
            if (v.servername) |s| try o.put("servername", .{ .string = s });
        },
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

// ---------------- tests ----------------

test "render raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]node.Node{
        .{ .trojan = .{
            .name = "香港1",
            .server = "hk1.example.com",
            .port = 443,
            .password = "pass123",
        } },
        .{ .ss = .{
            .name = "新加坡3-SS",
            .server = "sg3.example.com",
            .port = 8388,
            .cipher = "aes-256-gcm",
            .password = "ss-pass",
        } },
    };
    const text = try renderRaw(a, &nodes);
    const v = try std.json.parseFromSliceLeaky(JsonValue, a, text, .{});
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len);
    const t = v.array.items[0].object;
    try std.testing.expectEqualStrings("trojan", t.get("type").?.string);
    try std.testing.expectEqualStrings("香港1", t.get("name").?.string);
    try std.testing.expectEqualStrings("pass123", t.get("password").?.string);
    const s = v.array.items[1].object;
    try std.testing.expectEqualStrings("aes-256-gcm", s.get("cipher").?.string);
}

test "compile-check" {
    _ = &renderRaw;
    _ = &nodeToJson;
    _ = &serverOf;
    _ = &portOf;
}
