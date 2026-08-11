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

/// Colorize summary keywords (ok/OK/failed/skipped) in the message body, with word boundaries.
fn colorizeKeywords(file: std.fs.File, text: []const u8) void {
    const Keyword = struct { word: []const u8, color: []const u8 };
    const keywords = [_]Keyword{
        .{ .word = "OK", .color = "\x1b[32m" },
        .{ .word = "ok", .color = "\x1b[32m" },
        .{ .word = "failed", .color = "\x1b[31m" },
        .{ .word = "skipped", .color = "\x1b[33m" },
    };
    var pos: usize = 0;
    while (pos < text.len) {
        var best: ?Keyword = null;
        var best_idx: usize = text.len;
        for (keywords) |kw| {
            if (std.mem.indexOfPos(u8, text, pos, kw.word)) |idx| {
                // word boundary: not glued to alphanumeric characters
                if (idx > 0 and std.ascii.isAlphanumeric(text[idx - 1])) continue;
                if (idx + kw.word.len < text.len and std.ascii.isAlphanumeric(text[idx + kw.word.len])) continue;
                if (idx < best_idx) {
                    best = kw;
                    best_idx = idx;
                }
            }
        }
        if (best) |kw| {
            file.writeAll(text[pos..best_idx]) catch {};
            file.writeAll(kw.color) catch {};
            file.writeAll(kw.word) catch {};
            file.writeAll("\x1b[0m") catch {};
            pos = best_idx + kw.word.len;
        } else {
            file.writeAll(text[pos..]) catch {};
            break;
        }
    }
}

pub fn log(level: LogLevel, source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    // silent under zig build test: unit tests assert on return values, not
    // on stderr noise (same pattern as config.zig diagnostics)
    if (builtin.is_test) return;
    // all diagnostics go to stderr (unix convention); stdout is reserved for data
    // (e.g. `-o clash=-` pipe output must be clean for scripts)
    const file = std.fs.File.stderr();
    const text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(text);
    const color = file.isTty() and std.posix.getenv("NO_COLOR") == null;
    const lc = levelColor(level);

    // prefix: <time> (pid) L [source] - time/pid/level share the level color
    // so the prefix stays uniform; pid tells overlapping runs apart (flock)
    var tbuf: [32]u8 = undefined;
    writeColored(file, color, lc, localTimestamp(&tbuf));
    file.writeAll(" ") catch {};
    var pbuf: [18]u8 = undefined;
    writeColored(file, color, lc, std.fmt.bufPrint(&pbuf, "({d})", .{getPid()}) catch unreachable);
    file.writeAll(" ") catch {};
    writeColored(file, color, lc, &.{levelChar(level)});
    file.writeAll(" ") catch {};
    if (source) |s| {
        var hbuf: [256]u8 = undefined;
        writeColored(file, color, "\x1b[1m", std.fmt.bufPrint(&hbuf, "[{s}] ", .{s}) catch s);
    }
    if (color) {
        colorizeKeywords(file, text);
    } else {
        file.writeAll(text) catch {};
    }
    file.writeAll("\n") catch {};
}

/// write `text` wrapped in color code `code` (no-op coloring when !color)
fn writeColored(file: std.fs.File, color: bool, code: []const u8, text: []const u8) void {
    if (color) file.writeAll(code) catch {};
    file.writeAll(text) catch {};
    if (color) file.writeAll("\x1b[0m") catch {};
}

/// process id for the log line; libc getpid (musl already linked, POSIX-wide);
/// windows is not a target platform but stays compilable
pub fn getPid() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

pub fn info(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.info, source, fmt, args);
}

pub fn warn(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.warn, source, fmt, args);
}

pub fn err(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.err, source, fmt, args);
}

pub fn verbose(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.verbose, source, fmt, args);
}

/// plain output for generated content (dry-run config text, usage) - no log prefix
pub fn outPrint(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(text);
    std.fs.File.stdout().writeAll(text) catch {};
}
