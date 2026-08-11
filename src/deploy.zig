const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const render = @import("render.zig");
const yaml = @import("yaml.zig");
const Format = render.Format;

pub const VerifyResult = enum { ok, skipped, failed };

pub const ReloadResult = enum { api, systemctl, custom, skipped, failed };

/// find an executable in ./bin/, PATH, and common paths (./bin/ first; used by tests)
pub fn findBin(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const local = std.fs.path.join(arena, &.{ "bin", name }) catch return null;
    if (fileExists(local)) return local;

    // Windows is not a target platform (not released); kept only for cross-platform compilability:
    // PATH is WTF-16 there (std.posix.getenv unavailable), so only ./bin/ is checked
    if (builtin.os.tag == .windows) return null;

    const path_env = std.posix.getenv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = std.fs.path.join(arena, &.{ dir, name }) catch continue;
        if (fileExists(p)) return p;
    }
    const common = [_][]const u8{ "/usr/local/bin/", "/usr/bin/", "/bin/" };
    for (common) |dir| {
        const p = std.fs.path.join(arena, &.{ dir, name }) catch continue;
        if (fileExists(p)) return p;
    }
    return null;
}

/// true when `path` exists (regular file or dir; unreadable counts as absent)
pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// verifier subprocess timeout: a hung verifier (broken binary, deadlock) must
/// not stall the whole cron run forever; the process is killed on timeout.
const verify_timeout_ms = 30_000;

const WaitCtx = struct {
    base: util.TimeoutBase,
    child: std.process.Child,
    term: ?std.process.Child.Term = null,
};

fn waitWorker(ctx: *WaitCtx) void {
    ctx.term = ctx.child.wait() catch null;
    util.timeoutDone(ctx, noCleanup);
}

fn noCleanup(_: WaitCtx) void {}

/// run `argv` to completion, exit code only (output discarded); null on spawn
/// failure or timeout (the verifier is SIGKILLed so it cannot linger).
fn runVerifier(arena: std.mem.Allocator, argv: []const []const u8) ?u8 {
    _ = arena;
    return runCommandTimed(argv, verify_timeout_ms);
}

fn runCommandTimed(argv: []const []const u8, timeout_ms: u32) ?u8 {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const ctx = std.heap.page_allocator.create(WaitCtx) catch return null;
    ctx.* = .{ .base = .{}, .child = child };
    util.runWithTimeout(WaitCtx, waitWorker, ctx, timeout_ms) catch |e| switch (e) {
        // timed out: kill the verifier (the worker wakes up from wait() and
        // frees the ctx via timeoutDone); the kill makes wait() return
        error.Timeout => {
            // raw SIGKILL only: Child.kill() would also waitpid() here, racing
            // the worker's reap (worker wait() returns first -> ECHILD -> panic)
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            return null;
        },
        // the worker never started: we own the ctx
        error.OutOfMemory, error.ThreadFailed => {
            std.heap.page_allocator.destroy(ctx);
            return null;
        },
    };
    const t = ctx.term orelse null;
    std.heap.page_allocator.destroy(ctx);
    if (t) |term| {
        if (term == .Exited) return term.Exited;
    }
    return null;
}

/// verify generated content. tmp_path is the written temp file (the verifier reads it).
/// verifier not found -> skipped (does not block install); verification failure -> failed.
pub fn verifyContent(
    arena: std.mem.Allocator,
    fmt: Format,
    content: []const u8,
    tmp_path: []const u8,
) VerifyResult {
    return switch (fmt) {
        .clash => blk: {
            const bin = findBin(arena, "clash") orelse findBin(arena, "mihomo") orelse break :blk .skipped;
            const dir = std.fs.path.dirname(tmp_path) orelse ".";
            const code = runVerifier(arena, &.{ bin, "-t", "-d", dir, "-f", tmp_path });
            break :blk if (code != null and code.? == 0) .ok else .failed;
        },
        .singbox => blk: {
            const bin = findBin(arena, "sing-box") orelse break :blk .skipped;
            const code = runVerifier(arena, &.{ bin, "check", "-c", tmp_path });
            break :blk if (code != null and code.? == 0) .ok else .failed;
        },
        .trojan, .hysteria, .ss, .ssr => blk: {
            // no check mode: JSON syntax validation
            _ = std.json.parseFromSlice(std.json.Value, arena, content, .{}) catch break :blk .failed;
            break :blk .ok;
        },
        .xray => blk: {
            // JSON syntax validation; run xray -test -c when the xray binary is available
            _ = std.json.parseFromSlice(std.json.Value, arena, content, .{}) catch break :blk .failed;
            const bin = findBin(arena, "xray") orelse break :blk .ok;
            const code = runVerifier(arena, &.{ bin, "-test", "-c", tmp_path });
            break :blk if (code != null and code.? == 0) .ok else .failed;
        },
        .hysteria2 => blk: {
            // native config is yaml: validate with libyaml parser
            _ = yaml.parse(arena, content) catch break :blk .failed;
            break :blk .ok;
        },
        .raw => .ok,
    };
}

/// atomic file write (write .new then rename)
pub fn atomicWrite(arena: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const tmp = try std.fmt.allocPrint(arena, "{s}.new", .{path});
    try writeFile(tmp, content);
    try std.fs.cwd().rename(tmp, path);
}

/// whether the on-disk file at `path` differs from `content` (byte comparison).
/// a missing file or a read failure counts as different: conservative, an
/// install is never skipped when the on-disk state is unknown.
pub fn contentDiffers(allocator: std.mem.Allocator, path: []const u8, content: []const u8) bool {
    const cur = std.fs.cwd().readFileAlloc(allocator, path, 1 << 24) catch return true;
    return !std.mem.eql(u8, cur, content);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(content);
}

/// clash/sing-box hot reload: API PUT /configs?force=true, falls back to systemctl restart.
pub fn reloadClash(
    arena: std.mem.Allocator,
    controller: []const u8,
    secret: ?[]const u8,
    path: []const u8,
) ReloadResult {
    return reloadApi(arena, controller, secret, path, "clash");
}

pub fn reloadSingbox(
    arena: std.mem.Allocator,
    controller: []const u8,
    secret: ?[]const u8,
    path: []const u8,
) ReloadResult {
    return reloadApi(arena, controller, secret, path, "sing-box");
}

/// user-defined reload commands get the same timeout policy as the verifier:
/// a hung command (script waiting on a network resource, stuck service tool)
/// must not stall the cron run; it is SIGKILLed at the deadline.
const reload_cmd_timeout_ms = 30_000;

/// run a user-defined reload command (acme.sh --reloadcmd style): /bin/sh -c <cmd>,
/// 30s timeout + SIGKILL (see runCommandTimed)
pub fn reloadCustom(arena: std.mem.Allocator, cmd: []const u8) ReloadResult {
    _ = arena;
    const code = runCommandTimed(&.{ "/bin/sh", "-c", cmd }, reload_cmd_timeout_ms);
    return if (code != null and code.? == 0) .custom else .failed;
}

/// http PUT /configs?force=true with a timeout: std.http.Client has no built-in
/// timeout, and a hung/unreachable controller (misconfigured address, firewall
/// DROP) would otherwise stall the whole cron run for minutes. on timeout or
/// http failure the caller falls back to systemctl restart.
const reload_api_timeout_ms = 5000;

const ReloadCtx = struct {
    base: util.TimeoutBase,
    controller: []const u8,
    secret: ?[]const u8,
    path: []const u8,
    result: ReloadResult = .failed,
};

fn freeReloadCtx(_: ReloadCtx) void {}

fn reloadApiWorker(ctx: *ReloadCtx) void {
    defer util.timeoutDone(ctx, freeReloadCtx);
    const alloc = std.heap.page_allocator;

    const url = std.fmt.allocPrint(alloc, "http://{s}/configs?force=true", .{ctx.controller}) catch return;
    defer alloc.free(url);
    const body = std.fmt.allocPrint(alloc, "{{\"path\": \"{s}\"}}", .{ctx.path}) catch return;
    defer alloc.free(body);

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var auth: ?[]const u8 = null;
    defer if (auth) |a| alloc.free(a);
    if (ctx.secret) |s| {
        auth = std.fmt.allocPrint(alloc, "Bearer {s}", .{s}) catch return;
    }
    const headers: std.http.Client.Request.Headers = if (auth) |a|
        .{ .authorization = .{ .override = a } }
    else
        .{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .PUT,
        .headers = headers,
        .payload = body,
    }) catch return;
    ctx.result = if (result.status == .no_content or result.status == .ok) .api else .failed;
}

fn reloadApi(
    arena: std.mem.Allocator,
    controller: []const u8,
    secret: ?[]const u8,
    path: []const u8,
    service: []const u8,
) ReloadResult {
    // controller/secret/path point into the caller's arena, which outlives the
    // worker (whole process); the ctx itself is page-allocated
    const ctx = std.heap.page_allocator.create(ReloadCtx) catch return .failed;
    ctx.* = .{ .base = .{}, .controller = controller, .secret = secret, .path = path };
    util.runWithTimeout(ReloadCtx, reloadApiWorker, ctx, reload_api_timeout_ms) catch |e| switch (e) {
        // timeout: the worker owns the ctx from now on (see util.timeoutDone)
        error.Timeout => return reloadFallback(arena, service),
        // the worker never started: we own the ctx
        error.OutOfMemory, error.ThreadFailed => {
            std.heap.page_allocator.destroy(ctx);
            return .failed;
        },
    };
    const r = ctx.result;
    std.heap.page_allocator.destroy(ctx);
    if (r == .api) return .api;
    return reloadFallback(arena, service);
}

/// systemctl restart fallback. check availability first: OpenWrt and other
/// non-systemd distros lack systemctl; skip (skipped) instead of failing,
/// telling the user to restart manually or use --reload-cmd.
fn reloadFallback(arena: std.mem.Allocator, service: []const u8) ReloadResult {
    const sysctl = findBin(arena, "systemctl") orelse return .skipped;
    const r = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ sysctl, "restart", service },
    }) catch return .failed;
    return if (r.term == .Exited and r.term.Exited == 0) .systemctl else .failed;
}

// ---------------- tests ----------------

test "findBin local and path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // system command (present in every environment)
    const sh = findBin(a, "sh");
    try std.testing.expect(sh != null);
    // bin/ test clients (gitignored, not committed): must be found when present;
    // not required in clean clones/CI without bin/
    if (std.fs.cwd().access("bin/sing-box", .{})) |_| {
        try std.testing.expect(findBin(a, "sing-box") != null);
    } else |_| {}
    // nonexistent
    try std.testing.expect(findBin(a, "definitely-not-exists-xyz") == null);
}

test "verifyContent trojan json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(
        VerifyResult.ok,
        verifyContent(arena.allocator(), .trojan, "{\"run_type\":\"client\",\"remote_port\":443}", "/tmp/x.json"),
    );
    try std.testing.expectEqual(
        VerifyResult.failed,
        verifyContent(arena.allocator(), .trojan, "{invalid json", "/tmp/x.json"),
    );
}

test "verifyContent hysteria2 yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(
        VerifyResult.ok,
        verifyContent(arena.allocator(), .hysteria2, "server: h:443\nauth: p\n", "/tmp/x.yaml"),
    );
    try std.testing.expectEqual(
        VerifyResult.failed,
        verifyContent(arena.allocator(), .hysteria2, "a: [unclosed\n", "/tmp/x.yaml"),
    );
}

test "contentDiffers missing/same/different" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const cfg = try std.fs.path.join(arena.allocator(), &.{ path, "cfg.txt" });
    // missing file counts as different (first install must not be skipped)
    try std.testing.expect(contentDiffers(arena.allocator(), cfg, "hello"));
    // identical bytes -> same
    try writeFile(cfg, "hello");
    try std.testing.expect(!contentDiffers(arena.allocator(), cfg, "hello"));
    // different bytes -> different
    try std.testing.expect(contentDiffers(arena.allocator(), cfg, "hello!"));
    try std.testing.expect(contentDiffers(arena.allocator(), cfg, ""));
}

test "reloadCustom runs shell command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(ReloadResult.custom, reloadCustom(a, "true"));
    try std.testing.expectEqual(ReloadResult.failed, reloadCustom(a, "false"));
    try std.testing.expectEqual(ReloadResult.failed, reloadCustom(a, "definitely-not-a-command-xyz"));
}

test "reloadCustom exit codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // success / failure exit codes (the hung-command timeout path is the
    // same runCommandTimed code covered by the runVerifier timeout test)
    try std.testing.expectEqual(ReloadResult.custom, reloadCustom(arena.allocator(), "true"));
    try std.testing.expectEqual(ReloadResult.failed, reloadCustom(arena.allocator(), "false"));
    try std.testing.expectEqual(ReloadResult.failed, reloadCustom(arena.allocator(), "definitely-not-a-command-xyz"));
}

test "runVerifier exit code and timeout kill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // success / failure exit codes
    try std.testing.expectEqual(@as(?u8, 0), runVerifier(a, &.{ "sh", "-c", "exit 0" }));
    try std.testing.expectEqual(@as(?u8, 3), runVerifier(a, &.{ "sh", "-c", "exit 3" }));
    // missing binary -> null
    try std.testing.expectEqual(@as(?u8, null), runVerifier(a, &.{"definitely-not-a-command-xyz"}));
    // hung verifier: killed on timeout, runVerifier returns null promptly
    const t0 = std.time.milliTimestamp();
    try std.testing.expectEqual(@as(?u8, null), runCommandTimed(&.{ "sleep", "300" }, 1000));
    const elapsed = std.time.milliTimestamp() - t0;
    try std.testing.expect(elapsed >= 900);
    try std.testing.expect(elapsed < 5000);
}

test "compile-check" {
    _ = &findBin;
    _ = &fileExists;
    _ = &verifyContent;
    _ = &atomicWrite;
    _ = &writeFile;
    _ = &reloadClash;
    _ = &reloadSingbox;
    _ = &reloadCustom;
    _ = &reloadApi;
    _ = &runVerifier;
    _ = &runCommandTimed;
    _ = &waitWorker;
}
