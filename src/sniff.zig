const std = @import("std");
const util = @import("util.zig");
const yaml = @import("yaml.zig");

pub const SniffError = error{
    OutOfMemory,
    EmptyContent,
    HtmlContent,
    UnknownFormat,
    TooDeep,
};

pub const Sniffed = union(enum) {
    /// one node URI per line (slices point into the source text)
    uris: []const []const u8,
    /// JSON data (v2rayN array / object)
    json: std.json.Value,
    /// clash YAML top level (mapping containing proxies)
    clash: yaml.YamlValue,
};

const max_depth = 3;
const uri_schemes = [_][]const u8{
    "ss://",     "ssr://",      "vmess://",     "vless://",
    "trojan://", "hysteria://", "hysteria2://", "hy2://",
    "tuic://",
};

/// auto-detect the subscription format.
pub fn sniff(arena: std.mem.Allocator, text: []const u8) SniffError!Sniffed {
    return sniffDepth(arena, text, 0);
}

fn sniffDepth(arena: std.mem.Allocator, text: []const u8, depth: usize) SniffError!Sniffed {
    if (depth > max_depth) return error.TooDeep;
    const t = std.mem.trimLeft(u8, text, "\u{feff} \t\r\n");
    if (t.len == 0) return error.EmptyContent;

    const head_len = @min(t.len, 2048);
    const head = t[0..head_len];
    if (std.mem.indexOf(u8, head, "<html") != null or
        std.mem.indexOf(u8, head, "<!doctype") != null or
        std.mem.indexOf(u8, head, "<head") != null)
    {
        return error.HtmlContent;
    }

    // clash YAML: top level has a proxies key
    if (hasTopLevelProxies(t)) {
        const root = yaml.parse(arena, t) catch return error.UnknownFormat;
        const m = yaml.mappingOf(root) orelse return error.UnknownFormat;
        const pv = yaml.mappingGet(m, "proxies") orelse return error.UnknownFormat;
        if (yaml.sequenceOf(pv) == null) return error.UnknownFormat;
        return .{ .clash = root };
    }

    // JSON
    if (t[0] == '{' or t[0] == '[') {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{})) |value| {
            return .{ .json = value };
        } else |_| {}
    }

    // plain-text URI line list
    var all_uris = true;
    var uri_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, t, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!looksLikeUri(line)) {
            all_uris = false;
            break;
        }
        try uri_lines.append(arena, line);
    }
    if (all_uris and uri_lines.items.len > 0) {
        return .{ .uris = try uri_lines.toOwnedSlice(arena) };
    }

    // base64 recursion
    if (looksB64(t)) {
        if (try util.b64Decode(arena, t)) |dec| {
            if (isMostlyPrintable(dec)) {
                if (sniffDepth(arena, dec, depth + 1)) |s| {
                    return s;
                } else |_| {}
            }
        }
    }
    return error.UnknownFormat;
}

fn hasTopLevelProxies(t: []const u8) bool {
    var lines = std.mem.splitScalar(u8, t, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "proxies:")) return true;
    }
    return false;
}

fn looksLikeUri(line: []const u8) bool {
    for (uri_schemes) |s| {
        if (std.mem.startsWith(u8, line, s)) return true;
    }
    return false;
}

fn looksB64(t: []const u8) bool {
    var n: usize = 0;
    for (t) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => continue,
            'A'...'Z', 'a'...'z', '0'...'9', '+', '/', '=', '-', '_' => n += 1,
            else => return false,
        }
    }
    return n >= 16;
}

fn isMostlyPrintable(s: []const u8) bool {
    if (s.len == 0) return false;
    var printable: usize = 0;
    for (s) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t' or (ch >= 0x20 and ch != 0x7f)) {
            printable += 1;
        }
    }
    return printable * 10 >= s.len * 9;
}

// ---------------- tests ----------------

test "sniff uris list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try sniff(arena.allocator(),
        \\trojan://a@h1:443#n1
        \\vless://b@h2:443?security=tls#n2
    );
    try std.testing.expectEqual(@as(usize, 2), s.uris.len);
}

test "sniff base64 uris" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "trojan://a@h1:443#n1\nss://b@h2:8388#n2";
    const enc_buf = try a.alloc(u8, std.base64.standard.Encoder.calcSize(plain.len));
    _ = std.base64.standard.Encoder.encode(enc_buf, plain);
    const s = try sniff(a, enc_buf);
    try std.testing.expectEqual(@as(usize, 2), s.uris.len);
}

test "sniff rejects html" {
    try std.testing.expectError(
        error.HtmlContent,
        sniff(std.testing.allocator, "<!DOCTYPE html><html><body>502</body></html>"),
    );
}

test "sniff rejects empty" {
    try std.testing.expectError(
        error.EmptyContent,
        sniff(std.testing.allocator, "  \n\t "),
    );
}

test "sniff rejects garbage" {
    // error paths (failed base64 recursion) may leak intermediate allocations; use an arena
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnknownFormat,
        sniff(arena.allocator(), "just some random text without structure"),
    );
}

test "sniff clash yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try sniff(arena.allocator(),
        \\proxies:
        \\  - name: a
        \\    type: trojan
        \\    server: h
        \\    port: 443
        \\    password: p
    );
    const m = yaml.mappingOf(s.clash).?;
    const pv = yaml.mappingGet(m, "proxies").?;
    try std.testing.expectEqual(@as(usize, 1), yaml.sequenceOf(pv).?.len);
}

test "sniff json array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try sniff(arena.allocator(), "[{\"ps\":\"a\",\"add\":\"h\",\"port\":\"443\"}]");
    try std.testing.expectEqual(@as(usize, 1), s.json.array.items.len);
}

test "sniff nested base64 too deep" {
    // deeply nested base64: intermediate allocations on failed recursion paths are freed by the arena
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cur: []const u8 = "trojan://a@h:443#n";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const enc = std.base64.standard.Encoder;
        const out = try a.alloc(u8, enc.calcSize(cur.len));
        _ = enc.encode(out, cur);
        cur = out;
    }
    try std.testing.expectError(error.UnknownFormat, sniff(a, cur));
}

test "compile-check" {
    // reference every fn/var in this file (including private ones)
    _ = &sniff;
    _ = &sniffDepth;
    _ = &hasTopLevelProxies;
    _ = &looksLikeUri;
    _ = &looksB64;
    _ = &isMostlyPrintable;
    _ = &uri_schemes;
    _ = &max_depth;
}
