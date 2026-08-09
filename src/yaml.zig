const std = @import("std");

const c = @cImport({
    @cInclude("yaml.h");
});

// libyaml yaml_node_type_e (cImport enum translation is unstable under musl; use stable integer values)
const yaml_no_node: c_uint = 0;
const yaml_scalar_node: c_uint = 1;
const yaml_sequence_node: c_uint = 2;
const yaml_mapping_node: c_uint = 3;
const yaml_alias_node: c_uint = 4;

/// simplified YAML value tree (built from the libyaml document API)
pub const YamlValue = union(enum) {
    scalar: []const u8,
    sequence: []const YamlValue,
    mapping: []const MappingEntry,
    null_value: void,
};

pub const MappingEntry = struct {
    key: []const u8,
    value: YamlValue,
};

pub const ParseError = error{
    OutOfMemory,
    InitFailed,
    ParseFailed,
};

/// max nesting depth of the value tree (libyaml parses flat; our recursive
/// buildValue is the only recursion, guard it against malicious deep YAML)
const max_depth = 64;

/// parse YAML text into a value tree. strings are duped into the allocator (arena recommended).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!YamlValue {
    var parser: c.yaml_parser_t = undefined;
    if (c.yaml_parser_initialize(&parser) == 0) return error.InitFailed;
    defer c.yaml_parser_delete(&parser);
    c.yaml_parser_set_input_string(&parser, source.ptr, source.len);

    var doc: c.yaml_document_t = undefined;
    if (c.yaml_parser_load(&parser, &doc) == 0) return error.ParseFailed;
    defer c.yaml_document_delete(&doc);

    const root = c.yaml_document_get_root_node(&doc) orelse return error.ParseFailed;
    return buildValueDepth(allocator, &doc, root, 0);
}

fn buildValue(
    allocator: std.mem.Allocator,
    doc: *c.yaml_document_t,
    node: [*c]c.yaml_node_t,
) ParseError!YamlValue {
    return buildValueDepth(allocator, doc, node, 0);
}

fn buildValueDepth(
    allocator: std.mem.Allocator,
    doc: *c.yaml_document_t,
    node: [*c]c.yaml_node_t,
    depth: usize,
) ParseError!YamlValue {
    if (depth > max_depth) return error.ParseFailed;
    return switch (node.*.type) {
        yaml_scalar_node => blk: {
            const ptr: [*c]const u8 = node.*.data.scalar.value;
            const len: usize = @intCast(node.*.data.scalar.length);
            break :blk .{ .scalar = try allocator.dupe(u8, ptr[0..len]) };
        },
        yaml_sequence_node => blk: {
            var items: std.ArrayListUnmanaged(YamlValue) = .empty;
            errdefer items.deinit(allocator);
            const start = node.*.data.sequence.items.start;
            const top = node.*.data.sequence.items.top;
            var it = start;
            while (it != top) : (it += 1) {
                const child = c.yaml_document_get_node(doc, it.*) orelse return error.ParseFailed;
                try items.append(allocator, try buildValueDepth(allocator, doc, child, depth + 1));
            }
            break :blk .{ .sequence = try items.toOwnedSlice(allocator) };
        },
        yaml_mapping_node => blk: {
            var entries: std.ArrayListUnmanaged(MappingEntry) = .empty;
            errdefer entries.deinit(allocator);
            const start = node.*.data.mapping.pairs.start;
            const top = node.*.data.mapping.pairs.top;
            var it = start;
            while (it != top) : (it += 1) {
                const key_node = c.yaml_document_get_node(doc, it.*.key) orelse return error.ParseFailed;
                const val_node = c.yaml_document_get_node(doc, it.*.value) orelse return error.ParseFailed;
                if (key_node.*.type != yaml_scalar_node) return error.ParseFailed;
                const kptr: [*c]const u8 = key_node.*.data.scalar.value;
                const klen: usize = @intCast(key_node.*.data.scalar.length);
                try entries.append(allocator, .{
                    .key = try allocator.dupe(u8, kptr[0..klen]),
                    .value = try buildValueDepth(allocator, doc, val_node, depth + 1),
                });
            }
            break :blk .{ .mapping = try entries.toOwnedSlice(allocator) };
        },
        yaml_alias_node => .null_value, // libyaml alias nodes are rare in subscriptions; ignore them
        else => .null_value,
    };
}

// ---------------- query helpers ----------------

pub fn mappingOf(v: YamlValue) ?[]const MappingEntry {
    return switch (v) {
        .mapping => |m| m,
        else => null,
    };
}

pub fn sequenceOf(v: YamlValue) ?[]const YamlValue {
    return switch (v) {
        .sequence => |s| s,
        else => null,
    };
}

pub fn scalarOf(v: YamlValue) ?[]const u8 {
    return switch (v) {
        .scalar => |s| s,
        else => null,
    };
}

/// look up a key in a mapping; null when absent.
pub fn mappingGet(entries: []const MappingEntry, key: []const u8) ?YamlValue {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

/// look up a key's scalar value in a mapping.
pub fn mappingGetScalar(entries: []const MappingEntry, key: []const u8) ?[]const u8 {
    const v = mappingGet(entries, key) orelse return null;
    return scalarOf(v);
}

// ---------------- tests ----------------

const clash_sample =
    \\proxies:
    \\  - name: TW-01
    \\    type: trojan
    \\    server: tw1.example.com
    \\    port: 443
    \\    password: tw-pass-123
    \\    sni: tw1.example.com
    \\    udp: true
    \\  - name: SG-01
    \\    type: ss
    \\    server: sg1.example.com
    \\    port: 8388
    \\    cipher: aes-256-gcm
    \\    password: ss-pass-456
    \\    udp: true
    \\  - name: DE-01
    \\    type: vmess
    \\    server: de1.example.com
    \\    port: 443
    \\    uuid: 11111111-2222-3333-4444-555555555555
    \\    alterId: 0
    \\    cipher: auto
    \\    tls: true
    \\    servername: de1.example.com
    \\    network: ws
    \\    ws-opts:
    \\      path: /vmess
    \\      headers:
    \\        Host: de1.example.com
    \\rules:
    \\  - MATCH,PROXY
;

test "parse simple yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), "a: 1\nb:\n  - x\n  - y\nc: true\n");
    const m = mappingOf(v) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", mappingGetScalar(m, "a").?);
    try std.testing.expectEqualStrings("true", mappingGetScalar(m, "c").?);
    const seq = sequenceOf(mappingGet(m, "b").?).?;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqualStrings("x", scalarOf(seq[0]).?);
    try std.testing.expectEqualStrings("y", scalarOf(seq[1]).?);
}

test "parse clash subscription yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parse(arena.allocator(), clash_sample);
    const m = mappingOf(v) orelse return error.TestUnexpectedResult;
    const proxies = sequenceOf(mappingGet(m, "proxies").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), proxies.len);

    // trojan node
    const p0 = mappingOf(proxies[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("TW-01", mappingGetScalar(p0, "name").?);
    try std.testing.expectEqualStrings("trojan", mappingGetScalar(p0, "type").?);
    try std.testing.expectEqualStrings("443", mappingGetScalar(p0, "port").?);
    try std.testing.expectEqualStrings("true", mappingGetScalar(p0, "udp").?);

    // vmess node (nested ws-opts)
    const p2 = mappingOf(proxies[2]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ws", mappingGetScalar(p2, "network").?);
    const ws = mappingOf(mappingGet(p2, "ws-opts").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/vmess", mappingGetScalar(ws, "path").?);
    const headers = mappingOf(mappingGet(ws, "headers").?) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("de1.example.com", mappingGetScalar(headers, "Host").?);
}

test "parse error on invalid yaml" {
    try std.testing.expectError(
        error.ParseFailed,
        parse(std.testing.allocator, "a: [unclosed\n"),
    );
}

test "reject deeply nested yaml" {
    // 200 levels of flow-style nesting: must be rejected (not a stack overflow)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deep = try std.fmt.allocPrint(arena.allocator(), "{s}x{s}", .{
        "a: {" ** 200, "}" ** 200,
    });
    try std.testing.expectError(error.ParseFailed, parse(arena.allocator(), deep));
    // sane nesting depth still parses
    const ok = "a: {b: {c: x}}";
    _ = try parse(arena.allocator(), ok);
}

test "compile-check" {
    _ = &parse;
    _ = &buildValue;
    _ = &buildValueDepth;
    _ = &mappingOf;
    _ = &sequenceOf;
    _ = &scalarOf;
    _ = &mappingGet;
    _ = &mappingGetScalar;
}
