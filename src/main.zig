const std = @import("std");
const config_mod = @import("config.zig");
const fetch_mod = @import("fetch.zig");
const parse_mod = @import("parse.zig");
const uri_mod = @import("uri.zig");
const node_mod = @import("node.zig");
const util = @import("util.zig");
const render_mod = @import("render.zig");
const deploy_mod = @import("deploy.zig");

const version = "0.2.0";

/// one -o/--out target: format[:template][=path]
const Out = struct {
    fmt: render_mod.Format,
    /// user template path (stage 3)
    template: ?[]const u8 = null,
    /// output path; null = dry-run only (error in real mode); "-" = stdout
    path: ?[]const u8 = null,
};

const Options = struct {
    config: []const u8 = "subscriptions.zon",
    outs: std.ArrayListUnmanaged(Out) = .empty,
    dry_run: bool = false,
    ua: ?[]const u8 = null,
    /// node name separator between subscription name and node name (ASCII-friendly for filenames)
    sep: []const u8 = "@",
    timeout: ?u32 = null,
    /// 0=normal, 1=-v (bytes + node list)
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

    // validate output formats (default: raw)
    if (opts.outs.items.len == 0) {
        try opts.outs.append(arena, .{ .fmt = .raw });
    }
    for (opts.outs.items) |o| {
        _ = o.fmt;
    }

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
        // anonymous subscription (empty name): full parse pipeline, just no "name@" prefix.
        // fixed "anonymous" label: short, and never leaks the url (may contain a token)
        const sub_label = if (s.name.len == 0) "anonymous" else s.name;
        if (!s.enable) {
            logInfo(sub_label, "skipped (disabled)", .{});
            disabled_cnt += 1;
            continue;
        }
        const ua = s.ua orelse cfg.default_ua orelse opts.ua;
        // CLI --timeout is in seconds, fetchWithTimeout expects milliseconds
        const timeout_ms: ?u32 = if (opts.timeout) |t| t * 1000 else null;
        const body = fetch_mod.fetchWithTimeout(arena, s.url, ua, timeout_ms) catch |e| {
            logWarn(sub_label, "fetch failed: {s}", .{@errorName(e)});
                        fail_cnt += 1;
            continue;
        };
        const info_keywords = cfg.info_node_keywords orelse &node_mod.default_info_keywords;
        const result = parse_mod.parseSubscription(arena, s.name, body, opts.sep, info_keywords) catch |e| {
            logWarn(sub_label, "parse failed ({s})", .{@errorName(e)});
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
        if (result.info > 0) {
            try extras.append(arena, try std.fmt.allocPrint(arena, "{d} info", .{result.info}));
            // verbose: list filtered info (notice) nodes for debugging
            if (opts.verbose > 0) {
                for (result.info_names) |nm| {
                    logVerbose(null, "  ! {s} (info node, filtered)", .{nm});
                }
            }
        }
        try extras.append(arena, try std.fmt.allocPrint(arena, "{d} bytes", .{body.len}));
        msg = try std.fmt.allocPrint(arena, "{s}, {s}", .{ msg, try std.mem.join(arena, ", ", extras.items) });
        logInfo(sub_label, "{s}", .{msg});
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
        const lines = try util.splitUriLines(arena, text);
        for (lines) |l| try opts.nodes.append(arena, l);
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
    // node-name dedupe + reserved-name protection now lives inside render()
    // (renderer layer); raw keeps original names. count unsupported protocols
    // per target for the verbose report.
    const nodes = all_nodes.items;

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

    // render all targets
    const Rendered = struct {
        out: Out,
        files: []const render_mod.File,
    };
    var rendered: std.ArrayListUnmanaged(Rendered) = .empty;
    for (opts.outs.items) |o| {
        // verbose: report nodes skipped due to unsupported protocol (explicit filter)
        if (opts.verbose > 0) {
            var unsupported: usize = 0;
            for (nodes) |n| {
                if (!render_mod.supports(o.fmt, n)) unsupported += 1;
            }
            if (unsupported > 0) {
                logVerbose(null, "[{s}] {d} node(s) skipped (unsupported protocol)", .{ @tagName(o.fmt), unsupported });
            }
        }
        // load user template (clash/singbox only)
        var tpl_text: ?[]const u8 = null;
        if (o.template) |tp| {
            tpl_text = std.fs.cwd().readFileAlloc(arena, tp, 1 << 20) catch |e| {
                logErr(null, "failed to read template {s}: {s}", .{ tp, @errorName(e) });
                std.process.exit(1);
            };
        }
        const files = render_mod.render(arena, o.fmt, nodes, ropts, tpl_text) catch |e| {
            logErr(null, "render {s} failed: {s}", .{ @tagName(o.fmt), @errorName(e) });
            std.process.exit(1);
        };
        try rendered.append(arena, .{ .out = o, .files = files });
    }

    // dry-run: verify all; content only when path == "-"
    if (opts.dry_run) {
        for (rendered.items) |r| {
            if (r.out.path) |p| {
                if (std.mem.eql(u8, p, "-")) {
                    for (r.files) |f| outPrint("{s}", .{f.content});
                }
            }
            try verifyDryRunFiles(arena, r.out.fmt, r.files);
        }
    } else {
        // real mode: verify all first (atomic), then install all
        for (rendered.items) |r| {
            if (r.out.path) |p| {
                if (std.mem.eql(u8, p, "-")) continue; // stdout: nothing to install
                verifyAll(arena, r.out.fmt, r.files, p, opts.no_verify);
            }
        }
        for (rendered.items) |r| {
            if (r.out.path) |p| {
                if (std.mem.eql(u8, p, "-")) {
                    // stdout output
                    for (r.files) |f| try std.fs.File.stdout().writeAll(f.content);
                } else {
                    installAll(arena, r.out.fmt, r.files, p, opts, ropts);
                }
            } else {
                logErr(null, "output path required for {s} (use -o {s}=<path> or --dry-run)", .{ @tagName(r.out.fmt), @tagName(r.out.fmt) });
                std.process.exit(1);
            }
        }
    }

    var summary = try std.fmt.allocPrint(arena, "subscriptions {d}/{d} ok, {d} failed", .{
        ok_cnt, cfg.subscriptions.len, fail_cnt,
    });
    if (disabled_cnt > 0) {
        summary = try std.fmt.allocPrint(arena, "{s}, {d} disabled", .{ summary, disabled_cnt });
    }
    summary = try std.fmt.allocPrint(arena, "{s}, {d} nodes", .{ summary, nodes.len });
    if (opts.outs.items.len == 1) {
        summary = try std.fmt.allocPrint(arena, "{s}, format {s}", .{ summary, @tagName(opts.outs.items[0].fmt) });
    } else {
        var fmts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (opts.outs.items) |o| try fmts.append(arena, @tagName(o.fmt));
        summary = try std.fmt.allocPrint(arena, "{s}, formats {s}", .{ summary, try std.mem.join(arena, ",", fmts.items) });
    }
    logInfo(null, "{s}", .{summary});
    if (opts.secret == null and opts.verbose > 0 and !opts.dry_run) {
        var need_secret = false;
        for (opts.outs.items) |o| {
            if (o.fmt == .clash or o.fmt == .singbox) need_secret = true;
        }
        if (need_secret) logVerbose(null, "api secret: {s}", .{secret});
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

/// Stage A: verify all files of all targets before anything is installed.
/// writes .new temp files next to targets and verifies them; on failure
/// all temp files are removed and nothing is installed (atomic across targets).
/// no-op when --no-verify (install stage writes directly).
fn verifyAll(arena: std.mem.Allocator, fmt: render_mod.Format, files: []const render_mod.File, path: []const u8, no_verify: bool) void {
    if (no_verify) return;
    if (isDirFormat(fmt)) {
        std.fs.cwd().makePath(path) catch |e| {
            logErr(null, "failed to create directory {s}: {s}", .{ path, @errorName(e) });
            std.process.exit(1);
        };
    }
    for (files) |f| {
        const target = if (isDirFormat(fmt))
            std.fs.path.join(arena, &.{ path, f.path }) catch {
                logErr(null, "path join failed", .{});
                std.process.exit(1);
            }
        else
            path;
        // note: xray -test infers format from extension, tmp must end with .json
        const tmp = if (isDirFormat(fmt))
            std.fmt.allocPrint(arena, "{s}.new.json", .{target}) catch {
                logErr(null, "out of memory", .{});
                std.process.exit(1);
            }
        else
            std.fmt.allocPrint(arena, "{s}.new", .{target}) catch {
                logErr(null, "out of memory", .{});
                std.process.exit(1);
            };
        deploy_mod.atomicWrite(arena, tmp, f.content) catch |e| {
            logErr(null, "failed to write {s}: {s}", .{ tmp, @errorName(e) });
            std.process.exit(1);
        };
        const vr = deploy_mod.verifyContent(arena, fmt, f.content, tmp);
        if (vr == .failed) {
            std.fs.cwd().deleteFile(tmp) catch {};
            logErr(null, "verify failed, aborting: {s} (nothing installed)", .{target});
            std.process.exit(1);
        }
    }
}

/// Stage B: install all files (rename verified .new files into place, then reload).
/// called only after verifyAll passed (or --no-verify).
fn installAll(
    arena: std.mem.Allocator,
    fmt: render_mod.Format,
    files: []const render_mod.File,
    path: []const u8,
    opts: Options,
    ropts: render_mod.Options,
) void {
    if (isDirFormat(fmt)) {
        const dir = path;
        std.fs.cwd().makePath(dir) catch |e| {
            logErr(null, "failed to create directory {s}: {s}", .{ dir, @errorName(e) });
            std.process.exit(1);
        };
        for (files) |f| {
            const fpath = std.fs.path.join(arena, &.{ dir, f.path }) catch {
                logErr(null, "path join failed", .{});
                std.process.exit(1);
            };
            if (opts.no_verify) {
                deploy_mod.atomicWrite(arena, fpath, f.content) catch |e| {
                    logErr(null, "failed to write {s}: {s}", .{ fpath, @errorName(e) });
                    std.process.exit(1);
                };
            } else {
                const tmp = std.fmt.allocPrint(arena, "{s}.new.json", .{fpath}) catch {
                    logErr(null, "out of memory", .{});
                    std.process.exit(1);
                };
                // backup existing config (acme.sh style)
                if (fileExists(fpath)) {
                    const bak = std.fmt.allocPrint(arena, "{s}.bak", .{fpath}) catch {
                        logErr(null, "out of memory", .{});
                        std.process.exit(1);
                    };
                    std.fs.cwd().copyFile(fpath, std.fs.cwd(), bak, .{}) catch |e| {
                        logErr(null, "failed to backup {s}: {s}", .{ fpath, @errorName(e) });
                        std.process.exit(1);
                    };
                }
                std.fs.cwd().rename(tmp, fpath) catch |e| {
                    logErr(null, "failed to write {s}: {s}", .{ fpath, @errorName(e) });
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
    } else {
        // single-file format
        const f = files[0];
        if (opts.no_verify) {
            deploy_mod.atomicWrite(arena, path, f.content) catch |e| {
                logErr(null, "failed to write {s}: {s}", .{ path, @errorName(e) });
                std.process.exit(1);
            };
            logInfo(null, "installed {s}", .{path});
        } else {
            const tmp = std.fmt.allocPrint(arena, "{s}.new", .{path}) catch {
                logErr(null, "out of memory", .{});
                std.process.exit(1);
            };
            if (fileExists(path)) {
                const bak = std.fmt.allocPrint(arena, "{s}.bak", .{path}) catch {
                    logErr(null, "out of memory", .{});
                    std.process.exit(1);
                };
                std.fs.cwd().copyFile(path, std.fs.cwd(), bak, .{}) catch |e| {
                    logErr(null, "failed to backup {s}: {s}", .{ path, @errorName(e) });
                    std.process.exit(1);
                };
            }
            std.fs.cwd().rename(tmp, path) catch |e| {
                logErr(null, "failed to write {s}: {s}", .{ path, @errorName(e) });
                std.process.exit(1);
            };
            logInfo(null, "installed {s} (verify passed)", .{path});
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

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// multi-file formats output to a directory; single-file formats output to a file path
fn isDirFormat(fmt: render_mod.Format) bool {
    return switch (fmt) {
        .clash, .singbox, .raw => false,
        .trojan, .hysteria, .hysteria2, .xray, .ss, .ssr => true,
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
            opts.verbose = 1;
        } else if (std.mem.startsWith(u8, a, "-v") and a.len >= 2 and a[1] == 'v') {
            // -v, -vv, -vvv: all mean verbose=1 (no deeper levels since -vv was replaced by -o fmt=-)
            opts.verbose = 1;
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
        } else if (takeValue(&i, args, a, "--out", "-o")) |v| {
            if (v.len == 0) return error.BadArg;
            try opts.outs.append(arena, parseOut(v) catch return error.BadArg);
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

/// parse -o/--out value: format[:template][=path]
fn parseOut(v: []const u8) !Out {
    var path: ?[]const u8 = null;
    var rest = v;
    if (std.mem.indexOfScalar(u8, v, '=')) |eq| {
        path = v[eq + 1 ..];
        rest = v[0..eq];
    }
    var template: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        template = rest[colon + 1 ..];
        rest = rest[0..colon];
    }
    const fmt = render_mod.Format.parse(rest) orelse return error.BadArg;
    return .{ .fmt = fmt, .template = template, .path = path };
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
        \\  -o, --out <fmt>[:<tmpl>][=<path>]  output target (repeatable; default raw)
        \\                          fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw
        \\                          tmpl: template file (clash/singbox; optional)
        \\                          path: output file (single-file) or directory (native); '-' = stdout
        \\      --node <uri>       directly pasted node URI (repeatable)
        \\      --node-file <path> node list file (one URI per line)
        \\      --dry-run          verify only, write nothing
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
        \\  -v, --verbose          verbose output (node list)
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
    // all diagnostics go to stderr (unix convention); stdout is reserved for data
    // (e.g. `-o clash=-` pipe output must be clean for scripts)
    const file = std.fs.File.stderr();
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

test "parseOut grammar" {
    // format only
    const o1 = try parseOut("clash");
    try std.testing.expectEqual(render_mod.Format.clash, o1.fmt);
    try std.testing.expect(o1.template == null);
    try std.testing.expect(o1.path == null);
    // format + template
    const o2 = try parseOut("clash:tmpl.yaml");
    try std.testing.expectEqual(render_mod.Format.clash, o2.fmt);
    try std.testing.expectEqualStrings("tmpl.yaml", o2.template.?);
    try std.testing.expect(o2.path == null);
    // format + path
    const o3 = try parseOut("singbox=/etc/sing-box/config.json");
    try std.testing.expectEqual(render_mod.Format.singbox, o3.fmt);
    try std.testing.expectEqualStrings("/etc/sing-box/config.json", o3.path.?);
    try std.testing.expect(o3.template == null);
    // full: format + template + path
    const o4 = try parseOut("clash:tmpl.yaml=out/c.yaml");
    try std.testing.expectEqual(render_mod.Format.clash, o4.fmt);
    try std.testing.expectEqualStrings("tmpl.yaml", o4.template.?);
    try std.testing.expectEqualStrings("out/c.yaml", o4.path.?);
    // stdout path
    const o5 = try parseOut("raw=-");
    try std.testing.expectEqual(render_mod.Format.raw, o5.fmt);
    try std.testing.expectEqualStrings("-", o5.path.?);
    // unknown format errors
    try std.testing.expectError(error.BadArg, parseOut("bogus"));
    try std.testing.expectError(error.BadArg, parseOut(""));
    // extra '=' belongs to the path (first '=' splits path, then ':' splits template)
    const o6 = try parseOut("clash:tmpl=path=extra");
    try std.testing.expectEqualStrings("tmpl", o6.template.?);
    try std.testing.expectEqualStrings("path=extra", o6.path.?);
}

test "compile-check" {
    _ = &main;
    _ = &parseArgs;
    _ = &parseOut;
    _ = &takeValue;
    _ = &printUsage;
    _ = &outPrint;
    _ = &logInfo;
    _ = &logWarn;
    _ = &logErr;
    _ = &logVerbose;
    _ = &genSecret;
    _ = &verifyDryRunFiles;
    _ = &isDirFormat;
}
