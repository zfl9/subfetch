//! transport layer: subscription URL -> content bytes.
//! (parse.zig consumes these bytes: content -> node list; uri.zig parses
//! single node URIs like ss:// trojan://. fetch never interprets payloads.)
const std = @import("std");
const util = @import("util.zig");

pub const FetchError = error{
    OutOfMemory,
    FetchFileNotFound,
    FetchBodyTooLarge,
    FetchHttpError,
    FetchNetworkError,
    FetchTimeout,
};

/// subscription content is plain text (URI lists / yaml / json); even full
/// configs with rules stay well under 1MB. larger responses are malicious or
/// broken (CDN error pages etc.) and get rejected.
const max_sub_size = 1024 * 1024;

/// fetch subscription content.
/// url supports https://, http://, file://, and local file paths.
/// the returned body is allocated with the given allocator (arena recommended).
pub fn fetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
) FetchError![]const u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        return readFile(allocator, url["file://".len..]);
    }
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        return fetchHttp(allocator, url, ua);
    }
    // local file path: direct read, same error semantics as file:// (a missing
    // file is FetchFileNotFound, not "invalid url")
    return readFile(allocator, url);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) FetchError![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_sub_size) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooBig => error.FetchBodyTooLarge,
        error.FileNotFound => error.FetchFileNotFound,
        else => error.FetchNetworkError,
    };
}

fn fetchHttp(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
) FetchError![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // bounded writer: stops storing past max_sub_size (the connection keeps
    // draining); oversized bodies are malicious or broken, reject them
    var body_writer = try util.BoundedWriter.init(allocator, max_sub_size);
    defer body_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = if (ua) |u| .{ .override = u } else .default },
        .response_writer = &body_writer.writer,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FetchNetworkError,
    };

    if (result.status != .ok) return error.FetchHttpError;
    if (body_writer.exceeded) return error.FetchBodyTooLarge;
    return allocator.dupe(u8, body_writer.toSlice()) catch error.OutOfMemory;
}

const ThreadCtx = struct {
    base: util.TimeoutBase,
    url: []const u8,
    ua: ?[]const u8,
    result: ?[]const u8 = null,
    err: ?FetchError = null,
};

/// abandoned-path cleanup: free the stored body before the ctx is destroyed
/// (tiny race window between the main thread timing out and the worker
/// finishing; without this the body would leak on page_allocator)
fn freeResult(ct: ThreadCtx) void {
    if (ct.result) |b| std.heap.page_allocator.free(b);
}

fn worker(ctx: *ThreadCtx) void {
    // use page_allocator inside the thread (thread-safe); the main thread dups the
    // result into the caller's allocator
    const body = fetch(std.heap.page_allocator, ctx.url, ctx.ua) catch |e| {
        ctx.err = e;
        util.timeoutDone(ctx, freeResult);
        return;
    };
    ctx.result = body;
    util.timeoutDone(ctx, freeResult);
}

/// fetch with timeout. std.http.Client has no built-in timeout; implemented with
/// a background thread + deadline polling (see util.runWithTimeout).
pub fn fetchWithTimeout(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
    timeout_ms: ?u32,
) FetchError![]const u8 {
    if (timeout_ms == null) return fetch(allocator, url, ua);

    const ctx = std.heap.page_allocator.create(ThreadCtx) catch return error.OutOfMemory;
    ctx.* = .{ .base = .{}, .url = url, .ua = ua };
    // keep the default 16MB thread stack: zig std TLS performs post-quantum
    // Kyber ML-KEM key generation during the handshake, whose stack frames
    // exceed 8MB (verified: 512KB/1MB/8MB all segfault on https + timeout).
    util.runWithTimeout(ThreadCtx, worker, ctx, timeout_ms.?) catch |e| switch (e) {
        // timeout: the worker owns the ctx from now on (see util.timeoutDone)
        error.Timeout => return error.FetchTimeout,
        // the worker never started: we own the ctx
        error.OutOfMemory, error.ThreadFailed => {
            std.heap.page_allocator.destroy(ctx);
            return error.FetchNetworkError;
        },
    };
    const err = ctx.err;
    const body = ctx.result;
    std.heap.page_allocator.destroy(ctx);
    if (err) |e| return e;
    const b = body orelse return error.FetchNetworkError;
    defer std.heap.page_allocator.free(b);
    return allocator.dupe(u8, b) catch error.OutOfMemory;
}

/// fetch with one retry on transient network failures (http error status /
/// network error / timeout): cron environments see flaky links, and a single
/// retry converts most spurious failures. non-transient errors (missing file,
/// oversized body, bad url) fail immediately - retrying cannot help them.
/// fixed per-subscription fetch timeout (the user-tunable --timeout/.timeout
/// option was removed: verify/reload timeouts are fixed too, and 5s + one
/// retry is the settled policy for a 1MB-bounded subscription body)
const fetch_timeout_ms = 5_000;

pub fn fetchWithRetry(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
) FetchError![]const u8 {
    return fetchWithTimeout(allocator, url, ua, fetch_timeout_ms) catch |e| switch (e) {
        error.FetchHttpError, error.FetchNetworkError, error.FetchTimeout => fetchWithTimeout(allocator, url, ua, fetch_timeout_ms),
        else => e,
    };
}

// ---------------- tests ----------------

test "fetch file:// and local path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "sub.txt", .data = "ss://hello" });
    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, "sub.txt");
    defer std.testing.allocator.free(abs);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const b1 = try fetch(a, abs, null);
    try std.testing.expectEqualStrings("ss://hello", b1);
    const file_url = try std.fmt.allocPrint(a, "file://{s}", .{abs});
    const b2 = try fetch(a, file_url, null);
    try std.testing.expectEqualStrings("ss://hello", b2);
}

test "fetch missing file" {
    try std.testing.expectError(
        error.FetchFileNotFound,
        fetch(std.testing.allocator, "/nonexistent/xyz/sub.txt", null),
    );
}

test "fetch rejects oversized body" {
    // local server sends > max_sub_size; must return error.FetchBodyTooLarge while
    // the writer kept memory bounded (drops past the limit)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const listener = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            // read the request first: responding without reading leaves the
            // request unread in the receive buffer, and close() then sends
            // RST instead of FIN (client would see ConnectionResetByPeer)
            var reqbuf: [4096]u8 = undefined;
            _ = conn.stream.read(&reqbuf) catch return;
            const header = "HTTP/1.1 200 OK\r\nContent-Length: 1049600\r\nConnection: close\r\n\r\n";
            conn.stream.writeAll(header) catch return;
            const chunk = "x" ** 65536;
            var left: usize = 1049600;
            while (left > 0) {
                const n = @min(left, chunk.len);
                conn.stream.writeAll(chunk[0..n]) catch return;
                left -= n;
            }
        }
    }.run, .{&server});
    defer server_thread.join();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/big", .{port});
    try std.testing.expectError(error.FetchBodyTooLarge, fetch(a, url, null));
}

test "fetchWithTimeout times out on slow server" {
    // local server that accepts but never responds; timeout must fire
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const listener = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *std.net.Server) void {
            // accept one connection, then sleep forever (never respond)
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            std.Thread.sleep(std.time.ns_per_s); // hold the connection past the 500ms timeout
        }
    }.run, .{&server});
    defer server_thread.join();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/slow", .{port});
    // 500ms timeout: worker hits the dead server, main thread times out
    try std.testing.expectError(error.FetchTimeout, fetchWithTimeout(a, url, null, 500));
    // normal path (file) still works
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "s.txt", .data = "ok" });
    const p = try tmp.dir.realpathAlloc(a, "s.txt");
    const b = try fetchWithTimeout(a, p, null, 1000);
    try std.testing.expectEqualStrings("ok", b);
}

test "fetchWithRetry retries once on http error" {
    // local server: first request returns 500, second returns 200
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const listener = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *std.net.Server) void {
            var reqs: usize = 0;
            while (reqs < 2) : (reqs += 1) {
                const conn = srv.accept() catch return;
                defer conn.stream.close();
                var reqbuf: [4096]u8 = undefined;
                _ = conn.stream.read(&reqbuf) catch return;
                if (reqs == 0) {
                    conn.stream.writeAll("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
                } else {
                    conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch return;
                }
            }
        }
    }.run, .{&server});
    defer server_thread.join();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/flaky", .{port});
    const body = try fetchWithRetry(a, url, null);
    try std.testing.expectEqualStrings("ok", body);
}

test "fetchWithRetry no retry on missing file" {
    // non-transient: missing local file fails immediately (no retry attempt)
    try std.testing.expectError(
        error.FetchFileNotFound,
        fetchWithRetry(std.testing.allocator, "/nonexistent/xyz/retry.txt", null),
    );
}

test "compile-check" {
    _ = &fetch;
    _ = &readFile;
    _ = &fetchHttp;
    _ = &fetchWithTimeout;
    _ = &fetchWithRetry;
    _ = &worker;
}
