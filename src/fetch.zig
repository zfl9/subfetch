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

const max_sub_size = 16 * 1024 * 1024;

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
};

fn worker(ctx: *ThreadCtx) void {
    defer ctx.done.store(true, .release);
    // use page_allocator inside the thread (thread-safe); the main thread dups the
    // result into the caller's allocator
    const body = fetch(std.heap.page_allocator, ctx.url, ctx.ua) catch |e| {
        ctx.err = e;
        return;
    };
    ctx.result = body;
}

/// fetch with timeout. std.http.Client has no built-in timeout; implemented with a
/// background thread + deadline polling. On timeout: ctx stays in the arena (the thread
/// may still be writing to it) and is reclaimed when the process exits.
pub fn fetchWithTimeout(
    allocator: std.mem.Allocator,
    url: []const u8,
    ua: ?[]const u8,
    timeout_ms: ?u32,
) FetchError![]const u8 {
    if (timeout_ms == null) return fetch(allocator, url, ua);

    const ctx = allocator.create(ThreadCtx) catch return error.OutOfMemory;
    ctx.* = .{ .url = url, .ua = ua };
    const t = std.Thread.spawn(.{}, worker, .{ctx}) catch return error.NetworkError;

    const deadline = std.time.milliTimestamp() + timeout_ms.?;
    while (!ctx.done.load(.acquire)) {
        if (std.time.milliTimestamp() >= deadline) {
            t.detach();
            return error.Timeout;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    t.join();
    if (ctx.err) |e| return e;
    const body = ctx.result orelse return error.NetworkError;
    defer std.heap.page_allocator.free(body);
    return allocator.dupe(u8, body) catch error.OutOfMemory;
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

test "compile-check" {
    _ = &max_sub_size;
    _ = &fetch;
    _ = &readFile;
    _ = &fetchHttp;
    _ = &fetchWithTimeout;
    _ = &worker;
    _ = &ThreadCtx;
}
