const std = @import("std");
const config_mod = @import("config.zig");
const fetch_mod = @import("fetch.zig");
const parse_mod = @import("parse.zig");
const uri_mod = @import("uri.zig");
const node_mod = @import("node.zig");
const render_mod = @import("render.zig");
const deploy_mod = @import("deploy.zig");

const version = "0.1.0";

const Options = struct {
    config: []const u8 = "subscriptions.zon",
    out_fmt: []const u8 = "clash",
    output: ?[]const u8 = null,
    dry_run: bool = false,
    ua: ?[]const u8 = null,
    /// node name separator between subscription name and node name (ASCII-friendly for filenames)
    sep: []const u8 = "@",
    timeout: ?u32 = null,
    /// 0=normal, 1=-v (bytes + node list), 2=-vv (also dump generated config in dry-run)
    verbose: u8 = 0,
    nodes: std.ArrayListUnmanaged([]const u8) = .empty,
    node_files: std.ArrayListUnmanaged([]const u8) = .empty,
    // render customization fields
    listen: []const u8 = "127.0.0.1",
    port: u16 = 1080,
    mixed_port: u16 = 65500,
    controller: []const u8 = "127.0.0.1:65501",
    secret: ?[]const u8 = null,
    no_clash_api: bool = false,
    no_verify: bool = false,
    no_reload: bool = false,
    /// user-defined reload command (acme.sh --reloadcmd style); overrides API/systemctl auto-reload
    reload_cmd: ?[]const u8 = null,
};

const CliError = error{ BadArg, OutOfMemory };

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    var opts = Options{};
    parseArgs(arena, args, &opts) catch |e| {
        logErr(null, "failed to parse arguments: {s}\n", .{@errorName(e)});
        printUsage();
        std.process.exit(2);
    };

    // validate output format
    const fmt = render_mod.Format.parse(opts.out_fmt) orelse {
        logErr(null, "unknown output format: {s} (supported: clash/singbox/trojan/hysteria/hysteria2/xray/ss/ssr/raw)\n", .{opts.out_fmt});
        std.process.exit(2);
    };

    // read subscription list
    const cfg_text = std.fs.cwd().readFileAlloc(arena, opts.config, 1 << 20) catch |e| {
        logErr(null, "failed to read subscription list {s}: {s}\n", .{ opts.config, @errorName(e) });
        std.process.exit(1);
    };
    const cfg_src = arena.dupeZ(u8, cfg_text) catch {
        logErr(null, "out of memory\n", .{});
        std.process.exit(1);
    };
    const cfg = config_mod.parse(arena, cfg_src) catch |e| {
        logErr(null, "failed to parse subscription list {s}: {s}\n", .{ opts.config, @errorName(e) });
        std.process.exit(1);
    };

    // collect all nodes
    var all_nodes: std.ArrayListUnmanaged(node_mod.Node) = .empty;
    var ok_cnt: usize = 0;
    var fail_cnt: usize = 0;
    var disabled_cnt: usize = 0;
    for (cfg.subscriptions) |s| {
        if (!s.enable) {
            logInfo(s.name, "skipped (disabled)", .{});
            disabled_cnt += 1;
            continue;
        }
        const ua = s.ua orelse cfg.default_ua orelse opts.ua;
        // CLI --timeout is in seconds, fetchWithTimeout expects milliseconds
        const timeout_ms: ?u32 = if (opts.timeout) |t| t * 1000 else null;
        const body = fetch_mod.fetchWithTimeout(arena, s.url, ua, timeout_ms) catch |e| {
            logWarn(s.name, "fetch failed: {s}", .{@errorName(e)});
                        fail_cnt += 1;
            continue;
        };
        const result = parse_mod.parseSubscription(arena, s.name, body, opts.sep) catch |e| {
            logWarn(s.name, "parse failed ({s})", .{@errorName(e)});
                        fail_cnt += 1;
            continue;
        };
        for (result.nodes) |n| {
            try all_nodes.append(arena, n);
        }
        ok_cnt += 1;
        // summary line is identical in normal and verbose mode: "OK, N nodes (M skipped, B bytes)"
        const noun = if (result.nodes.len == 1) "node" else "nodes";
        var msg = try std.fmt.allocPrint(arena, "OK, {d} {s}", .{ result.nodes.len, noun });
        var extras: std.ArrayListUnmanaged([]const u8) = .empty;
        if (result.skipped > 0) {
            try extras.append(arena, try std.fmt.allocPrint(arena, "{d} skipped", .{result.skipped}));
        }
        try extras.append(arena, try std.fmt.allocPrint(arena, "{d} bytes", .{body.len}));
        msg = try std.fmt.allocPrint(arena, "{s}, {s}", .{ msg, try std.mem.join(arena, ", ", extras.items) });
        logInfo(s.name, "{s}", .{msg});
        // verbose: short node list (strip the "sub-name<sep>" prefix), indented under the summary
        if (opts.verbose > 0) {
            const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ s.name, opts.sep });
            for (result.nodes) |n| {
                const short = if (std.mem.startsWith(u8, n.name(), prefix))
                    n.name()[prefix.len..]
                else
                    n.name();
                logVerbose(null, "  - {s} ({s})", .{ short, n.typeName() });
            }
        }
    }

    // --node-file node list
    for (opts.node_files.items) |f| {
        const text = std.fs.cwd().readFileAlloc(arena, f, 1 << 20) catch |e| {
            logWarn(f, "read failed: {s}", .{@errorName(e)});
                        fail_cnt += 1;
            continue;
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const l = std.mem.trim(u8, line, " \t\r");
            if (l.len == 0 or l[0] == '#') continue;
            try opts.nodes.append(arena, l);
        }
    }
    // --node directly pasted URIs (no subscription prefix)
    for (opts.nodes.items) |n| {
        const parsed = uri_mod.parseUri(arena, n, "", opts.sep) catch |e| {
            logWarn("node", "parse failed: {s} ({s})", .{ n, @errorName(e) });
                        fail_cnt += 1;
            continue;
        };
        try all_nodes.append(arena, parsed);
    }

    if (all_nodes.items.len == 0) {
        logErr(null, "no usable nodes, aborting", .{});
        std.process.exit(1);
    }
    // dedupe names + protect reserved names
    const nodes = try render_mod.uniqueNames(arena, all_nodes.items);

    // render options
    const secret = opts.secret orelse try genSecret(arena);
    const ropts: render_mod.Options = .{
        .listen = opts.listen,
        .port = opts.port,
        .mixed_port = opts.mixed_port,
        .controller = opts.controller,
        .secret = secret,
        .enable_clash_api = !opts.no_clash_api,
    };

    const output = render_mod.render(arena, fmt, nodes, ropts) catch |e| {
        logErr(null, "render failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    switch (output) {
        .single => |text| {
            if (opts.dry_run) {
                // generated config content only in verbose mode; normal/quiet just show the log lines
                if (opts.verbose > 1) outPrint("{s}", .{text});
                try verifyDryRun(arena, fmt, text);
            } else {
                const path = opts.output orelse defaultSinglePath(fmt);
                if (std.mem.eql(u8, path, "-")) {
                    // raw output goes to stdout
                    try std.fs.File.stdout().writeAll(text);
                } else {
                    const vr = deploy_mod.installSingle(arena, fmt, path, text) catch |e| {
                        logErr(null, "install {s} failed: {s} (old config untouched)", .{ path, @errorName(e) });
                        std.process.exit(1);
                    };
                    switch (vr) {
                        .ok => logInfo(null, "installed {s} (verify passed)", .{path}),
                        .skipped => logInfo(null, "installed {s} (verify skipped: verifier not found)", .{path}),
                        .failed => unreachable,
                    }
                    if (!opts.no_reload) {
                        if (opts.reload_cmd) |cmd| {
                            // custom reload command takes priority (acme.sh --reloadcmd style)
                            switch (deploy_mod.reloadCustom(arena, cmd)) {
                                .custom => logInfo(null, "custom reload command executed", .{}),
                                else => logWarn(null, "custom reload command failed (exit != 0)", .{}),
                            }
                        } else {
                            const rr = switch (fmt) {
                                .clash => deploy_mod.reloadClash(arena, opts.controller, ropts.secret, path),
                                .singbox => deploy_mod.reloadSingbox(arena, opts.controller, ropts.secret, path),
                                else => deploy_mod.ReloadResult.skipped,
                            };
                            switch (rr) {
                                .api => logInfo(null, "reloaded via API", .{}),
                                .systemctl => logInfo(null, "restarted via systemctl", .{}),
                                .custom => unreachable,
                                .skipped => logInfo(null, "no auto-reload for this format; restart manually (or use --reload-cmd)", .{}),
                                .failed => logWarn(null, "reload failed; restart manually", .{}),
                            }
                        }
                    }
                }
            }
        },
        .files => |files| {
            if (opts.dry_run) {
                if (opts.verbose > 1) {
                    for (files) |f| {
                        outPrint("===== {s} =====\n{s}\n", .{ f.path, f.content });
                    }
                }
                try verifyDryRunFiles(arena, fmt, files);
            } else {
                const dir = opts.output orelse defaultDirPath(fmt);
                std.fs.cwd().makePath(dir) catch |e| {
                    logErr(null, "failed to create directory {s}: {s}", .{ dir, @errorName(e) });
                    std.process.exit(1);
                };
                for (files) |f| {
                    const path = std.fs.path.join(arena, &.{ dir, f.path }) catch {
                        logErr(null, "path join failed", .{});
                        std.process.exit(1);
                    };
                    if (opts.no_verify) {
                        deploy_mod.atomicWrite(arena, path, f.content) catch |e| {
                            logErr(null, "failed to write {s}: {s}", .{ path, @errorName(e) });
                            std.process.exit(1);
                        };
                    } else {
                        // write .new first, verify, then rename (existing config untouched on failure).
                        // note: xray -test infers format from extension, tmp must end with .json
                        const tmp = std.fmt.allocPrint(arena, "{s}.new.json", .{path}) catch {
                            logErr(null, "out of memory", .{});
                            std.process.exit(1);
                        };
                        deploy_mod.atomicWrite(arena, tmp, f.content) catch |e| {
                            logErr(null, "failed to write {s}: {s}", .{ path, @errorName(e) });
                            std.process.exit(1);
                        };
                        const vr = deploy_mod.verifyContent(arena, fmt, f.content, tmp);
                        if (vr == .failed) {
                            std.fs.cwd().deleteFile(tmp) catch {};
                            logErr(null, "verify failed, aborting: {s}", .{path});
                            std.process.exit(1);
                        }
                        std.fs.cwd().rename(tmp, path) catch |e| {
                            logErr(null, "failed to write {s}: {s}", .{ path, @errorName(e) });
                            std.process.exit(1);
                        };
                    }
                }
                logInfo(null, "wrote {d} files to {s}", .{ files.len, dir });
                if (!opts.no_reload) {
                    if (opts.reload_cmd) |cmd| {
                        switch (deploy_mod.reloadCustom(arena, cmd)) {
                            .custom => logInfo(null, "custom reload command executed", .{}),
                            else => logWarn(null, "custom reload command failed (exit != 0)", .{}),
                        }
                    } else {
                        logInfo(null, "no auto-reload for this format; restart manually (or use --reload-cmd)", .{});
                    }
                }
            }
        },
    }

    var summary = try std.fmt.allocPrint(arena, "subscriptions {d}/{d} ok, {d} failed", .{
        ok_cnt, cfg.subscriptions.len, fail_cnt,
    });
    if (disabled_cnt > 0) {
        summary = try std.fmt.allocPrint(arena, "{s}, {d} disabled", .{ summary, disabled_cnt });
    }
    summary = try std.fmt.allocPrint(arena, "{s}, {d} nodes, format {s}", .{ summary, nodes.len, opts.out_fmt });
    logInfo(null, "{s}", .{summary});
    if (opts.secret == null and (fmt == .clash or fmt == .singbox) and !opts.dry_run and opts.verbose > 0) {
        logVerbose(null, "api secret: {s}", .{secret});
    }
}

fn verifyDryRun(arena: std.mem.Allocator, fmt: render_mod.Format, content: []const u8) !void {
    const ext = switch (fmt) {
        .clash => "yaml",
        .singbox => "json",
        .trojan, .hysteria, .xray, .ss, .ssr => "json",
        .hysteria2 => "yaml",
        .raw => "json",
    };
    const tmp = try std.fmt.allocPrint(arena, "/tmp/subfetch-dryrun.{s}", .{ext});
    deploy_mod.atomicWrite(arena, tmp, content) catch return;
    const vr = deploy_mod.verifyContent(arena, fmt, content, tmp);
    switch (vr) {
        .ok => logInfo(null, "dry-run verify passed", .{}),
        .skipped => logInfo(null, "dry-run verify skipped (verifier not found)", .{}),
        .failed => {
            logErr(null, "dry-run verify failed! generated content may be invalid", .{});
            std.process.exit(1);
        },
    }
}

fn verifyDryRunFiles(arena: std.mem.Allocator, fmt: render_mod.Format, files: []const render_mod.File) !void {
    for (files) |f| {
        const ext = switch (fmt) {
            .hysteria2 => "yaml",
            else => "json",
        };
        const tmp = try std.fmt.allocPrint(arena, "/tmp/subfetch-dryrun.{s}", .{ext});
        deploy_mod.atomicWrite(arena, tmp, f.content) catch continue;
        const vr = deploy_mod.verifyContent(arena, fmt, f.content, tmp);
        if (vr == .failed) {
            logErr(null, "dry-run verify failed: {s}", .{f.path});
            std.process.exit(1);
        }
    }
    logInfo(null, "dry-run verify passed ({d} files)", .{files.len});
}

fn defaultSinglePath(fmt: render_mod.Format) []const u8 {
    return switch (fmt) {
        .clash => "/etc/clash/config.yaml",
        .singbox => "/etc/sing-box/config.json",
        .raw => "-",
        else => "-",
    };
}

fn defaultDirPath(fmt: render_mod.Format) []const u8 {
    return switch (fmt) {
        .trojan => "./out-trojan",
        .hysteria => "./out-hysteria",
        .hysteria2 => "./out-hysteria2",
        .xray => "./out-xray",
        .ss => "./out-ss",
        .ssr => "./out-ssr",
        else => "./out",
    };
}

/// generate UUID v4 as API secret
fn genSecret(arena: std.mem.Allocator) ![]const u8 {
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

fn parseArgs(arena: std.mem.Allocator, args: [][:0]u8, opts: *Options) CliError!void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose += 1;
        } else if (std.mem.startsWith(u8, a, "-v") and a.len >= 2 and a[1] == 'v') {
            // -v, -vv, -vvv
            opts.verbose += @intCast(a.len - 1);
        } else if (std.mem.eql(u8, a, "--no-clash-api")) {
            opts.no_clash_api = true;
        } else if (std.mem.eql(u8, a, "--no-verify")) {
            opts.no_verify = true;
        } else if (std.mem.eql(u8, a, "--no-reload")) {
            opts.no_reload = true;
        } else if (takeValue(&i, args, a, "--reload-cmd", null)) |v| {
            if (v.len == 0) return error.BadArg;
            opts.reload_cmd = v;
        } else if (takeValue(&i, args, a, "--config", "-c")) |v| {
            if (v.len == 0) return error.BadArg;
            opts.config = v;
        } else if (takeValue(&i, args, a, "--output-format", "--out")) |v| {
            if (v.len == 0) return error.BadArg;
            opts.out_fmt = v;
        } else if (takeValue(&i, args, a, "--output", "-o")) |v| {
            if (v.len == 0) return error.BadArg;
            opts.output = v;
        } else if (takeValue(&i, args, a, "--node", null)) |v| {
            if (v.len == 0) return error.BadArg;
            try opts.nodes.append(arena, v);
        } else if (takeValue(&i, args, a, "--node-file", null)) |v| {
            if (v.len == 0) return error.BadArg;
            try opts.node_files.append(arena, v);
        } else if (takeValue(&i, args, a, "--ua", null)) |v| {
            opts.ua = v;
        } else if (takeValue(&i, args, a, "--sep", null)) |v| {
            if (v.len == 0) return error.BadArg;
            opts.sep = v;
        } else if (takeValue(&i, args, a, "--timeout", null)) |v| {
            opts.timeout = std.fmt.parseInt(u32, v, 10) catch return error.BadArg;
        } else if (takeValue(&i, args, a, "--listen", null)) |v| {
            if (v.len == 0) return error.BadArg;
            opts.listen = v;
        } else if (takeValue(&i, args, a, "--port", null)) |v| {
            opts.port = std.fmt.parseInt(u16, v, 10) catch return error.BadArg;
        } else if (takeValue(&i, args, a, "--mixed-port", null)) |v| {
            opts.mixed_port = std.fmt.parseInt(u16, v, 10) catch return error.BadArg;
        } else if (takeValue(&i, args, a, "--controller", null)) |v| {
            if (v.len == 0) return error.BadArg;
            opts.controller = v;
        } else if (takeValue(&i, args, a, "--secret", null)) |v| {
            opts.secret = v;
        } else {
            logErr(null, "unknown argument: {s}", .{a});
            return error.BadArg;
        }
    }
}

/// match --long value / --long=value / -s value, return the value; null if no match.
fn takeValue(
    i: *usize,
    args: [][:0]u8,
    a: []const u8,
    long: []const u8,
    short: ?[]const u8,
) ?[]const u8 {
    if (std.mem.eql(u8, a, long) or (short != null and std.mem.eql(u8, a, short.?))) {
        if (i.* + 1 >= args.len) return "";
        i.* += 1;
        return args[i.*];
    }
    if (std.mem.startsWith(u8, a, long) and a.len > long.len and a[long.len] == '=') {
        return a[long.len + 1 ..];
    }
    return null;
}

fn printUsage() void {
    outPrint(
        \\subfetch {s} - subscription fetcher & multi-format config generator
        \\
        \\Usage: subfetch [options]
        \\
        \\Options:
        \\  -c, --config <path>    subscription list zon (default ./subscriptions.zon)
        \\      --output-format <fmt>  output format: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw (default clash; alias: --out)
        \\  -o, --output <path>    output file (clash/singbox/raw) or directory (native formats)
        \\      --node <uri>       directly pasted node URI (repeatable)
        \\      --node-file <path> node list file (one URI per line)
        \\      --dry-run          print generated config only, write nothing
        \\      --ua <str>         default User-Agent
        \\      --sep <str>        node name separator between sub and node names (default @)
        \\      --timeout <sec>    per-subscription fetch timeout in seconds
        \\      --listen <addr>    native client listen address (default 127.0.0.1)
        \\      --port <n>         native client listen port (default 1080)
        \\      --mixed-port <n>   clash mixed-port (default 65500)
        \\      --controller <a:p> clash/singbox external-controller (default 127.0.0.1:65501)
        \\      --secret <str>     API secret (auto-generated UUID if omitted)
        \\      --no-clash-api     disable clash_api in sing-box
        \\      --no-verify        skip verification
        \\      --no-reload        skip reload after install
        \\      --reload-cmd <cmd> custom reload command after install (sh -c, overrides auto reload; acme.sh style)
        \\  -v, --verbose          verbose output (repeat -vv to also dump generated config in dry-run)
        \\  -h, --help             show this help
        \\
    , .{version});
}

/// Log line format: "<YYYY-MM-DD HH:MM:SS> <L> [source]: message".
/// Local time via libc localtime_r (musl is already linked for libyaml).
/// Level letters: I=info, W=warn, E=error, V=verbose. Colors (TTY + !NO_COLOR only):
/// time gray, I cyan, W yellow, E red, V gray; summary keywords in the message body
/// (ok/OK green, failed red, skipped yellow).
const c_time = @cImport({
    @cInclude("time.h");
});

const LogLevel = enum { info, warn, err, verbose };

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

fn log(level: LogLevel, source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const file = if (level == .err or level == .warn) std.fs.File.stderr() else std.fs.File.stdout();
    const text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(text);
    const color = file.isTty() and std.posix.getenv("NO_COLOR") == null;

    if (color) file.writeAll(levelColor(level)) catch {};
    var tbuf: [32]u8 = undefined;
    file.writeAll(localTimestamp(&tbuf)) catch {};
    if (color) file.writeAll("\x1b[0m") catch {};
    file.writeAll(" ") catch {};

    if (color) file.writeAll(levelColor(level)) catch {};
    file.writeAll(&.{levelChar(level)}) catch {};
    if (color) file.writeAll("\x1b[0m") catch {};
    file.writeAll(" ") catch {};

    if (source) |s| {
        if (color) file.writeAll("\x1b[1m") catch {};
        const head = std.fmt.allocPrint(std.heap.page_allocator, "[{s}] ", .{s}) catch return;
        defer std.heap.page_allocator.free(head);
        file.writeAll(head) catch {};
        if (color) file.writeAll("\x1b[0m") catch {};
    }
    if (color) {
        colorizeKeywords(file, text);
    } else {
        file.writeAll(text) catch {};
    }
    file.writeAll("\n") catch {};
}

fn logInfo(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.info, source, fmt, args);
}

fn logWarn(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.warn, source, fmt, args);
}

fn logErr(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.err, source, fmt, args);
}

fn logVerbose(source: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    log(.verbose, source, fmt, args);
}

/// plain output for generated content (dry-run config text, usage) - no log prefix
fn outPrint(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(text);
    std.fs.File.stdout().writeAll(text) catch {};
}

test "compile-check" {
    _ = &main;
    _ = &parseArgs;
    _ = &takeValue;
    _ = &printUsage;
    _ = &outPrint;
    _ = &logInfo;
    _ = &logWarn;
    _ = &logErr;
    _ = &logVerbose;
    _ = &genSecret;
    _ = &verifyDryRun;
    _ = &verifyDryRunFiles;
    _ = &defaultSinglePath;
    _ = &defaultDirPath;
}
