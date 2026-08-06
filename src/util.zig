const std = @import("std");

/// lenient base64 decode: strips whitespace, converts url-safe charset, pads.
/// returns null (not an error) for invalid base64 input.
pub fn b64Decode(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    var cleaned: std.ArrayListUnmanaged(u8) = .empty;
    defer cleaned.deinit(allocator);
    for (input) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => continue,
            '-' => try cleaned.append(allocator, '+'),
            '_' => try cleaned.append(allocator, '/'),
            else => try cleaned.append(allocator, ch),
        }
    }
    if (cleaned.items.len < 4) return null;
    const pad = (4 - cleaned.items.len % 4) % 4;
    var i: usize = 0;
    while (i < pad) : (i += 1) try cleaned.append(allocator, '=');

    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(cleaned.items) catch return null;
    const out = try allocator.alloc(u8, size);
    dec.decode(out, cleaned.items) catch return null;
    return out;
}

/// percent decode; returns the original slice zero-copy when no % is present.
pub fn urlDecode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    const buf = try allocator.dupe(u8, s);
    return std.Uri.percentDecodeInPlace(buf);
}

// ---------------- tests ----------------

test "b64Decode standard with padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = (try b64Decode(arena.allocator(), "aGVsbG8=")).?;
    try std.testing.expectEqualStrings("hello", out);
}

test "b64Decode urlsafe no padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // urlsafe no-padding encoding of "SSR-测试节点"
    const out = (try b64Decode(arena.allocator(), "U1NSLea1i-ivleiKgueCuQ")).?;
    try std.testing.expectEqualStrings("SSR-测试节点", out);
}

test "b64Decode rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try b64Decode(arena.allocator(), "not-base64-!!!") == null);
    try std.testing.expect(try b64Decode(arena.allocator(), "abc") == null);
}

test "urlDecode passthrough and decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("plain", try urlDecode(a, "plain"));
    try std.testing.expectEqualStrings("/ws path", try urlDecode(a, "/ws%20path"));
    try std.testing.expectEqualStrings("a+b", try urlDecode(a, "a%2Bb"));
}

test "compile-check" {
    // Zig compiler is lazy: explicitly reference every fn/var in this file (including private ones) to surface compile errors early
    _ = &b64Decode;
    _ = &urlDecode;
}
