const std = @import("std");
const log = @import("log.zig");

pub fn genSecret(arena: std.mem.Allocator) ![]const u8 {
    var b: [16]u8 = undefined;
    std.crypto.random.bytes(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var out: [36]u8 = undefined;
    var oi: usize = 0;
    for (b, 0..) |byte, bi| {
        if (bi == 4 or bi == 6 or bi == 8 or bi == 10) {
            out[oi] = '-';
            oi += 1;
        }
        out[oi] = hex[byte >> 4];
        oi += 1;
        out[oi] = hex[byte & 0xf];
        oi += 1;
    }
    return arena.dupe(u8, &out);
}

/// API secret resolution: explicit --secret / .zon secret wins; otherwise reuse
/// the persisted secret (stable across runs -> stable rendered bytes -> install
/// diff stays quiet). first run generates + persists a UUID. with persist=false
/// (dry-run) the state dir is only read, never written (side-effect free).
pub fn resolveSecret(arena: std.mem.Allocator, explicit: ?[]const u8, persist: bool) ![]const u8 {
    if (explicit) |s| return s;
    const path = stateSecretPath(arena) catch return genSecret(arena); // no HOME: per-run random (degraded)
    if (!persist) {
        if (readPersistedSecret(arena, path)) |s| return s;
        return genSecret(arena);
    }
    return loadOrCreateSecret(arena, path);
}

/// read the persisted secret at `path` (null when absent/unreadable)
pub fn readPersistedSecret(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (std.fs.cwd().readFileAlloc(arena, path, 4096)) |content| {
        return std.mem.trimRight(u8, content, "\r\n");
    } else |_| return null;
}

/// read the persisted secret at `path`; generate + persist a fresh UUID when absent.
pub fn loadOrCreateSecret(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (readPersistedSecret(arena, path)) |s| return s;
    const s = try genSecret(arena);
    writeStateSecret(arena, path, s) catch |e| {
        log.logWarn(null, "failed to persist api secret to {s}: {s}", .{ path, @errorName(e) });
    };
    return s;
}

/// XDG state dir: $XDG_STATE_HOME or ~/.local/state (default per XDG spec)
pub fn stateDir(arena: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |base| {
        return std.fs.path.join(arena, &.{ base, "subfetch" });
    }
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".local", "state", "subfetch" });
}

/// XDG state path: $XDG_STATE_HOME or ~/.local/state (default per XDG spec)
pub fn stateSecretPath(arena: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(arena, &.{ try stateDir(arena), "secret" });
}

pub fn writeStateSecret(arena: std.mem.Allocator, path: []const u8, secret: []const u8) !void {
    _ = arena;
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    try std.fs.cwd().makePath(dir);
    const f = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer f.close();
    try f.writeAll(secret);
    try f.sync();
}

/// held until process exit; the kernel releases the flock no matter how the
/// process exits (normal return, panic, signal) - no explicit cleanup needed
var run_lock: ?std.fs.File = null;

/// advisory run lock: serialize concurrent runs (cron overlaps). probe
/// non-blocking first so we can log a waiting message, then block until the
/// other instance finishes (every phase is bounded by timeouts, so the wait
/// is finite). no state dir -> degraded, no lock.
pub fn acquireRunLock(arena: std.mem.Allocator) void {
    const dir = stateDir(arena) catch return;
    // first run on a fresh machine: the state dir does not exist yet; without
    // this the lock would be silently skipped (createFile fails -> return),
    // leaving the first installs without concurrency protection
    std.fs.cwd().makePath(dir) catch return;
    const path = std.fs.path.join(arena, &.{ dir, "lock" }) catch return;
    var flags = std.fs.File.CreateFlags{
        .read = true,
        .truncate = false,
        .mode = 0o600,
        .lock = .exclusive,
        .lock_nonblocking = true,
    };
    const f = std.fs.cwd().createFile(path, flags) catch |e| switch (e) {
        error.WouldBlock => blk: {
            log.logWarn(null, "another subfetch instance is running, waiting...", .{});
            flags.lock_nonblocking = false;
            break :blk std.fs.cwd().createFile(path, flags) catch return;
        },
        else => return,
    };
    // the lock fd must not leak into child processes (verifiers, reload
    // commands): a long-running background child would keep the lock forever
    _ = std.posix.fcntl(f.handle, std.posix.F.SETFD, std.posix.FD_CLOEXEC) catch {};
    run_lock = f;
}

pub fn releaseRunLock() void {
    if (run_lock) |f| {
        f.unlock();
        f.close();
        run_lock = null;
    }
}

/// --reset-state: drop the persisted api secret so the next run generates a
/// fresh one. only the secret file is removed; the flock lock file is kept
/// (unlinking it would break the lock held on the old inode by a running
/// instance, opening a concurrency window).
pub fn resetStateSecret(arena: std.mem.Allocator) void {
    const path = stateSecretPath(arena) catch {
        log.logErr(null, "no state dir, nothing to reset", .{});
        std.process.exit(1);
    };
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {
            log.logInfo(null, "no persisted secret, nothing to reset ({s})", .{path});
            return;
        },
        else => {
            log.logErr(null, "failed to delete {s}: {s}", .{ path, @errorName(e) });
            std.process.exit(1);
        },
    };
    log.logInfo(null, "reset api secret (next run generates a fresh one): {s}", .{path});
}

test "secret persistence: create + reuse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmp.dir.realpathAlloc(a, ".");
    const secret_file = try std.fs.path.join(a, &.{ path, "state", "secret" });
    // first call: generates + persists
    const s1 = try loadOrCreateSecret(a, secret_file);
    try std.testing.expectEqual(@as(usize, 36), s1.len);
    // second call: reuses the persisted value
    const s2 = try loadOrCreateSecret(a, secret_file);
    try std.testing.expectEqualStrings(s1, s2);
    // file contains exactly the secret
    const on_disk = try std.fs.cwd().readFileAlloc(a, secret_file, 4096);
    try std.testing.expectEqualStrings(s1, on_disk);
}

test "run lock: exclusive flock blocks second fd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmp.dir.realpathAlloc(a, ".");
    const lock_path = try std.fs.path.join(a, &.{ path, "lock" });
    // first fd acquires the exclusive lock
    const f1 = try std.fs.cwd().createFile(lock_path, .{ .read = true, .truncate = false });
    defer f1.close();
    try std.testing.expect(try f1.tryLock(.exclusive));
    // second fd is blocked
    const f2 = try std.fs.cwd().createFile(lock_path, .{ .read = true, .truncate = false });
    defer f2.close();
    try std.testing.expect(!try f2.tryLock(.exclusive));
    // release -> second fd can acquire
    f1.unlock();
    try std.testing.expect(try f2.tryLock(.exclusive));
}

test "readPersistedSecret absent/present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = try tmp.dir.realpathAlloc(a, ".");
    const secret_file = try std.fs.path.join(a, &.{ path, "secret" });
    // absent -> null
    try std.testing.expect(readPersistedSecret(a, secret_file) == null);
    // present -> content (trimmed)
    try writeStateSecret(a, secret_file, "abc");
    try std.testing.expectEqualStrings("abc", readPersistedSecret(a, secret_file).?);
}
