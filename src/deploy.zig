const std = @import("std");
const builtin = @import("builtin");
const render = @import("render.zig");
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

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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
            const r = std.process.Child.run(.{
                .allocator = arena,
                .argv = &.{ bin, "-t", "-d", dir, "-f", tmp_path },
            }) catch break :blk .failed;
            break :blk if (r.term == .Exited and r.term.Exited == 0) .ok else .failed;
        },
        .singbox => blk: {
            const bin = findBin(arena, "sing-box") orelse break :blk .skipped;
            const r = std.process.Child.run(.{
                .allocator = arena,
                .argv = &.{ bin, "check", "-c", tmp_path },
            }) catch break :blk .failed;
            break :blk if (r.term == .Exited and r.term.Exited == 0) .ok else .failed;
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
            const r = std.process.Child.run(.{
                .allocator = arena,
                .argv = &.{ bin, "-test", "-c", tmp_path },
            }) catch break :blk .failed;
            break :blk if (r.term == .Exited and r.term.Exited == 0) .ok else .failed;
        },
        .hysteria2 => blk: {
            // native config is yaml: validate with libyaml parser
            const yaml = @import("yaml.zig");
            _ = yaml.parse(arena, content) catch break :blk .failed;
            break :blk .ok;
        },
        .raw => .ok,
    };
}

/// atomic single-file install: write .new -> verify -> backup .bak -> rename.
/// on verification failure the old config is untouched; returns error.VerifyFailed.
pub fn installSingle(
    arena: std.mem.Allocator,
    fmt: Format,
    path: []const u8,
    content: []const u8,
) !VerifyResult {
    const tmp = try std.fmt.allocPrint(arena, "{s}.new", .{path});
    try writeFile(tmp, content);

    const vr = verifyContent(arena, fmt, content, tmp);
    if (vr == .failed) {
        std.fs.cwd().deleteFile(tmp) catch {};
        return error.VerifyFailed;
    }
    if (fileExists(path)) {
        const bak = try std.fmt.allocPrint(arena, "{s}.bak", .{path});
        std.fs.cwd().copyFile(path, std.fs.cwd(), bak, .{}) catch |e| {
            std.fs.cwd().deleteFile(tmp) catch {};
            return e;
        };
    }
    try std.fs.cwd().rename(tmp, path);
    return vr;
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

/// run a user-defined reload command (acme.sh --reloadcmd style): /bin/sh -c <cmd>
pub fn reloadCustom(arena: std.mem.Allocator, cmd: []const u8) ReloadResult {
    const r = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "/bin/sh", "-c", cmd },
    }) catch return .failed;
    return if (r.term == .Exited and r.term.Exited == 0) .custom else .failed;
}

fn reloadApi(
    arena: std.mem.Allocator,
    controller: []const u8,
    secret: ?[]const u8,
    path: []const u8,
    service: []const u8,
) ReloadResult {
    const url = std.fmt.allocPrint(arena, "http://{s}/configs?force=true", .{controller}) catch return .failed;
    const body = std.fmt.allocPrint(arena, "{{\"path\": \"{s}\"}}", .{path}) catch return .failed;

    var client: std.http.Client = .{ .allocator = arena };
    defer client.deinit();
    const headers: std.http.Client.Request.Headers = if (secret) |s|
        .{ .authorization = .{ .override = std.fmt.allocPrint(arena, "Bearer {s}", .{s}) catch return .failed } }
    else
        .{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .PUT,
        .headers = headers,
        .payload = body,
    }) catch return .failed;
    if (result.status == .no_content or result.status == .ok) return .api;

    // fallback: systemctl restart. check availability first: OpenWrt and other non-systemd
    // distros lack systemctl; skip (skipped) instead of failing, telling the user to restart
    // manually or use --reload-cmd.
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

test "installSingle atomic with backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const path = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    const cfg = try std.fs.path.join(arena.allocator(), &.{ path, "config.yaml" });
    // first install (no old file)
    const vr1 = try installSingle(arena.allocator(), .raw, cfg, "content-v1");
    try std.testing.expectEqual(VerifyResult.ok, vr1);
    // second install (creates .bak)
    const vr2 = try installSingle(arena.allocator(), .raw, cfg, "content-v2");
    try std.testing.expectEqual(VerifyResult.ok, vr2);
    const cur = try std.fs.cwd().readFileAlloc(arena.allocator(), cfg, 1 << 16);
    try std.testing.expectEqualStrings("content-v2", cur);
    const bak = try std.fs.cwd().readFileAlloc(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{s}.bak", .{cfg}), 1 << 16);
    try std.testing.expectEqualStrings("content-v1", bak);
    // verification failure leaves old config untouched
    try std.testing.expectError(
        error.VerifyFailed,
        installSingle(arena.allocator(), .trojan, cfg, "{bad json"),
    );
    const still = try std.fs.cwd().readFileAlloc(arena.allocator(), cfg, 1 << 16);
    try std.testing.expectEqualStrings("content-v2", still);
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

test "compile-check" {
    _ = &findBin;
    _ = &fileExists;
    _ = &verifyContent;
    _ = &installSingle;
    _ = &atomicWrite;
    _ = &writeFile;
    _ = &reloadClash;
    _ = &reloadSingbox;
    _ = &reloadCustom;
    _ = &reloadApi;
}
