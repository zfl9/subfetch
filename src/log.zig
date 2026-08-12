const std = @import("std");
const builtin = @import("builtin");

const c_time = @cImport({
    @cInclude("time.h");
});

pub const LogLevel = enum { info, warn, err, verbose };

fn levelChar(level: LogLevel) u8 {
    return switch (level) {
        .info => 'I',
        .warn => 'W',
        .err => 'E',
        .verbose => 'V',
    };
}

fn levelColor(level: LogLevel) []const u8 {
    return switch (level) {
        .info => "\x1b[36m", // cyan
        .warn => "\x1b[33m", // yellow
        .err => "\x1b[31m", // red
        .verbose => "\x1b[90m", // gray
    };
}

/// Format local time as "YYYY-MM-DD HH:MM:SS" (libc localtime_r + strftime; musl is linked anyway).
fn localTimestamp(buf: []u8) []const u8 {
    const now: c_time.time_t = @intCast(std.time.timestamp());
    var tm: c_time.struct_tm = undefined;
    _ = c_time.localtime_r(&now, &tm);
    const n = c_time.strftime(buf.ptr, buf.len, "%Y-%m-%d %H:%M:%S", &tm);
    return buf[0..n];
}

pub fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    // silent under zig build test: unit tests assert on return values, not
    // on log noise (same pattern as config.zig diagnostics)
    if (builtin.is_test) return;
    // logs go to stdout: no data output occupies it anymore (the stdout
    // output mode was removed), and errors are carried by exit codes
    const a = std.heap.page_allocator;
    const file = std.fs.File.stdout();
    const text = std.fmt.allocPrint(a, fmt, args) catch return;
    defer a.free(text);
    const color = file.isTty() and std.posix.getenv("NO_COLOR") == null;

    // assemble the whole line in memory, then one writeAll (single syscall):
    // "<time> (pid) L <body>\n"; time/pid/level share the level color so the
    // prefix stays uniform (pid tells overlapping runs apart, flock)
    const lc = levelColor(level);
    var tbuf: [32]u8 = undefined;
    var pbuf: [18]u8 = undefined;
    const ts = localTimestamp(&tbuf);
    const pid = std.fmt.bufPrint(&pbuf, "({d})", .{getPid()}) catch unreachable;
    const lv = levelChar(level);
    const line = if (color)
        std.fmt.allocPrint(a, "{s}{s}\x1b[0m {s}{s}\x1b[0m {s}{c}\x1b[0m {s}\n", .{ lc, ts, lc, pid, lc, lv, text }) catch return
    else
        std.fmt.allocPrint(a, "{s} {s} {c} {s}\n", .{ ts, pid, lv, text }) catch return;
    defer a.free(line);
    file.writeAll(line) catch {};
}

/// process id for the log line; libc getpid (musl already linked, POSIX-wide);
/// windows is not a target platform but stays compilable
pub fn getPid() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn verbose(comptime fmt: []const u8, args: anytype) void {
    log(.verbose, fmt, args);
}

/// plain output for usage/version text (--help/--version) - no log prefix
pub fn outPrint(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(text);
    std.fs.File.stdout().writeAll(text) catch {};
}
