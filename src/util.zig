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
    dec.decode(out, cleaned.items) catch {
        allocator.free(out);
        return null;
    };
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

/// shared fields for runWithTimeout contexts (must be embedded as `base`).
/// the ctx must be allocated with std.heap.page_allocator: on timeout the
/// ownership passes to the worker, which frees it (see timeoutDone).
pub const TimeoutBase = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// set by the main thread when it gives up on the deadline; the worker then
    /// destroys the ctx itself (ownership transfer, no use-after-free, no leak)
    abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// generic background-thread timeout helper: std.http.Client has no built-in
/// timeout, so long operations (subscription fetch, reload api put) run in a
/// worker thread while the caller polls a deadline. on success the caller owns
/// the ctx (worker has finished); on error.Timeout the ctx belongs to the
/// worker and must not be touched; on error.ThreadFailed the worker never
/// started and the caller owns the ctx.
pub fn runWithTimeout(
    comptime T: type,
    comptime worker: fn (*T) void,
    ctx: *T,
    timeout_ms: u32,
) error{ OutOfMemory, ThreadFailed, Timeout }!void {
    const t = std.Thread.spawn(.{}, worker, .{ctx}) catch return error.ThreadFailed;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (!ctx.base.done.load(.acquire)) {
        if (std.time.milliTimestamp() >= deadline) {
            ctx.base.abandoned.store(true, .release);
            t.detach();
            return error.Timeout;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    t.join();
}

/// worker-side finish: mark done, then when the main thread abandoned us, free
/// whatever the worker stored (via `cleanup`) and destroy the ctx.
pub fn timeoutDone(ctx: anytype, comptime cleanup: fn (@TypeOf(ctx.*)) void) void {
    ctx.base.done.store(true, .release);
    if (ctx.base.abandoned.load(.acquire)) {
        cleanup(ctx.*);
        std.heap.page_allocator.destroy(ctx);
    }
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
