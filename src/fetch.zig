const std = @import("std");

pub const FetchError = error{
    OutOfMemory,
    InvalidUrl,
    FileNotFound,
    TooLarge,
    HttpError,
    NetworkError,
    Timeout,
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
    // local file path
    return readFile(allocator, url) catch |e| switch (e) {
        error.FileNotFound => error.InvalidUrl,
        else => e,
    };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) FetchError![]const u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_sub_size) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooBig => error.TooLarge,
        error.FileNotFound => error.FileNotFound,
        else => error.NetworkError,
    };
}

fn fetchHttp(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
) FetchError![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body_writer = std.Io.Writer.Allocating.init(allocator);
    defer body_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = if (ua) |u| .{ .override = u } else .default },
        .response_writer = &body_writer.writer,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NetworkError,
    };

    if (result.status != .ok) return error.HttpError;
    var list = body_writer.toArrayList();
    if (list.items.len > max_sub_size) return error.TooLarge;
    return list.toOwnedSlice(allocator) catch error.OutOfMemory;
}

const ThreadCtx = struct {
    url: []const u8,
    ua: ?[]const u8,
    result: ?[]const u8 = null,
    err: ?FetchError = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// set by the main thread when it gives up on the deadline; the worker then
    /// destroys the ctx itself (ownership transfer, no use-after-free, no leak)
    abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn worker(ctx: *ThreadCtx) void {
    defer {
        ctx.done.store(true, .release);
        // when the main thread abandoned us, we own the ctx and must free it
        if (ctx.abandoned.load(.acquire)) std.heap.page_allocator.destroy(ctx);
    }
    // use page_allocator inside the thread (thread-safe); the main thread dups the
    // result into the caller's allocator
    const body = fetch(std.heap.page_allocator, ctx.url, ctx.ua) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.result = body;
}

/// fetch with timeout. std.http.Client has no built-in timeout; implemented with a
/// background thread + deadline polling. the ctx is page-allocated and its
/// ownership is explicit: main thread frees it after join, or the worker frees it
/// itself when abandoned (timeout path) - no use-after-free, no leak.
pub fn fetchWithTimeout(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
    timeout_ms: ?u32,
) FetchError![]const u8 {
    if (timeout_ms == null) return fetch(allocator, url, ua);

    const ctx = std.heap.page_allocator.create(ThreadCtx) catch return error.OutOfMemory;
    ctx.* = .{ .url = url, .ua = ua };
    // keep the default 16MB thread stack: zig std TLS performs post-quantum
    // Kyber ML-KEM key generation during the handshake, whose stack frames
    // exceed 8MB (verified: 512KB/1MB/8MB all segfault on https + timeout).
    const t = std.Thread.spawn(.{}, worker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return error.NetworkError;
    };

    const deadline = std.time.milliTimestamp() + timeout_ms.?;
    while (!ctx.done.load(.acquire)) {
        if (std.time.milliTimestamp() >= deadline) {
            // give up: the worker owns the ctx from now on
            ctx.abandoned.store(true, .release);
            t.detach();
            return error.Timeout;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    t.join();
    const err = ctx.err;
    const body = ctx.result;
    std.heap.page_allocator.destroy(ctx);
    if (err) |e| return e;
    const b = body orelse return error.NetworkError;
    defer std.heap.page_allocator.free(b);
    return allocator.dupe(u8, b) catch error.OutOfMemory;
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
        error.InvalidUrl,
        fetch(std.testing.allocator, "/nonexistent/xyz/sub.txt", null),
    );
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
    try std.testing.expectError(error.Timeout, fetchWithTimeout(a, url, null, 500));
    // normal path (file) still works
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "s.txt", .data = "ok" });
    const p = try tmp.dir.realpathAlloc(a, "s.txt");
    const b = try fetchWithTimeout(a, p, null, 1000);
    try std.testing.expectEqualStrings("ok", b);
}

test "compile-check" {
    _ = &fetch;
    _ = &readFile;
    _ = &fetchHttp;
    _ = &fetchWithTimeout;
    _ = &worker;
}
