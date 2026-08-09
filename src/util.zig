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

/// split text into URI lines: trim whitespace, skip empty lines and '#' comment lines.
/// shared by --node-file (main) and subscription sniffing, so both behave identically.
pub fn splitUriLines(arena: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try out.append(arena, line);
    }
    return out.toOwnedSlice(arena);
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
    // urlsafe no-padding encoding of "SSR-test-node"
    const out = (try b64Decode(arena.allocator(), "U1NSLXRlc3Qtbm9kZQ")).?;
    try std.testing.expectEqualStrings("SSR-test-node", out);
}

test "b64Decode rejects garbage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try b64Decode(arena.allocator(), "not-base64-!!!") == null);
    try std.testing.expect(try b64Decode(arena.allocator(), "abc") == null);
}

test "splitUriLines skips empty and comment lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try splitUriLines(arena.allocator(), "trojan://a@h1:443#hk1\n\n# comment line\n   \ntrojan://b@h2:443#hk2\r\n");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("trojan://a@h1:443#hk1", lines[0]);
    try std.testing.expectEqualStrings("trojan://b@h2:443#hk2", lines[1]);
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
    _ = &b64Decode;
    _ = &urlDecode;
    _ = &splitUriLines;
}
