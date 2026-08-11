const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const fetch_mod = @import("fetch.zig");
const parse_mod = @import("parse.zig");
const uri_mod = @import("uri.zig");
const node_mod = @import("node.zig");
const util = @import("util.zig");
const render_mod = @import("render.zig");
const deploy_mod = @import("deploy.zig");
const cli_mod = @import("cli.zig");
const state_mod = @import("state.zig");
const log_mod = @import("log.zig");

// log/state/cli entry points (aliases keep call sites unchanged)
const logInfo = log_mod.logInfo;
const logWarn = log_mod.logWarn;
const logErr = log_mod.logErr;
const logVerbose = log_mod.logVerbose;
const outPrint = log_mod.outPrint;
const Options = cli_mod.Options;
const parseArgs = cli_mod.parseArgs;
const printUsage = cli_mod.printUsage;
const parseUrlArg = cli_mod.parseUrlArg;
const getPid = log_mod.getPid;
const acquireRunLock = state_mod.acquireRunLock;
const releaseRunLock = state_mod.releaseRunLock;
const resetStateSecret = state_mod.resetStateSecret;
const resolveSecret = state_mod.resolveSecret;

const build_options = @import("build_options");
const version = build_options.version;

/// one -o/--output target: format[:template][=path] (shared with .zon outputs)
const Output = config_mod.Output;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    var opts = Options{};
    parseArgs(arena, args, &opts) catch |e| {
        logErr(null, "failed to parse arguments: {s}", .{@errorName(e)});
        printUsage();
        std.process.exit(2);
    };

    // serialize concurrent runs (cron overlaps); dry-run is read-only, no lock
    if (!opts.dry_run) acquireRunLock(arena);

    // --dry-run promises zero side effects; reset-state deletes the persisted
    // secret, so the combination is a contradiction (reject it as a usage error)
    if (opts.reset_state and opts.dry_run) {
        logErr(null, "--dry-run cannot be combined with --reset-state", .{});
        std.process.exit(2);
    }

    // --reset-state: drop the persisted secret and stop (nothing else to do)
    if (opts.reset_state) {
        resetStateSecret(arena);
        releaseRunLock();
        return;
    }

    // read config (optional): missing default config.zon -> pure CLI usage with
    // defaults; an explicitly passed -c path that does not exist is a user error
    const cfg = blk: {
        const text = std.fs.cwd().readFileAlloc(arena, opts.config, 1 << 20) catch |e| {
            switch (e) {
                error.FileNotFound => {
                    if (std.mem.eql(u8, opts.config, "config.zon")) {
                        logInfo(null, "config: none, using defaults", .{});
                        break :blk config_mod.Config{};
                    }
                    logErr(null, "failed to read config {s}: FileNotFound", .{opts.config});
                    std.process.exit(3);
                },
                else => {
                    logErr(null, "failed to read config {s}: {s}", .{ opts.config, @errorName(e) });
                    std.process.exit(3);
                },
            }
        };
        const cfg_src = arena.dupeZ(u8, text) catch {
            logErr(null, "out of memory", .{});
            std.process.exit(1);
        };
        const parsed = config_mod.parse(arena, cfg_src) catch |e| {
            logErr(null, "failed to parse config {s}: {s}", .{ opts.config, @errorName(e) });
            std.process.exit(3);
        };
        logInfo(null, "config: {s}", .{opts.config});
        break :blk parsed;
    };

    // merge CLI > .zon config: node name separator, API secret, info-node keywords
    // (CLI --sep wins over .zon sep; default "@"; secret: CLI > .zon > auto-generated UUID;
    //  info keywords: --info-keyword provided > .zon info_keywords > built-in defaults)
    const sep = opts.sep orelse cfg.sep orelse "@";
    opts.secret = opts.secret orelse cfg.secret;
    const info_keywords: []const []const u8 = if (opts.info_keywords.items.len > 0) blk: {
        // "" entries mean "clear": drop them, an all-empty set disables filtering
        var kws: std.ArrayListUnmanaged([]const u8) = .empty;
        for (opts.info_keywords.items) |kw| {
            if (kw.len > 0) try kws.append(arena, kw);
        }
        break :blk kws.items;
    } else if (cfg.info_keywords) |k| k else &node_mod.default_info_keywords;

    // merge CLI > .zon > defaults for render/deploy/behavior fields
    opts.timeout = opts.timeout orelse cfg.timeout orelse 5; // per-subscription default
    const listen = opts.listen orelse cfg.listen orelse "127.0.0.1";
    const port = opts.port orelse cfg.port orelse 1080;
    const mixed_port = opts.mixed_port orelse cfg.mixed_port orelse 65500;
    const controller = opts.controller orelse cfg.controller orelse "127.0.0.1:65501";
    opts.singbox_clash_api = opts.singbox_clash_api or (cfg.singbox_clash_api orelse false);
    opts.allow_lan = opts.allow_lan or (cfg.allow_lan orelse false);
    opts.tproxy_ipv6 = opts.tproxy_ipv6 or (cfg.tproxy_ipv6 orelse false);
    opts.tproxy_port = opts.tproxy_port orelse cfg.tproxy_port;
    opts.log_level = opts.log_level orelse cfg.log_level;

    // output targets: CLI -o/--output > .zon outputs > default raw (replace, never merge)
    if (opts.outputs.items.len == 0) {
        if (cfg.outputs) |os| {
            for (os) |o| try opts.outputs.append(arena, o);
        } else {
            try opts.outputs.append(arena, .{ .fmt = .raw });
        }
    }
    // collect all nodes: direct nodes first, then node files, then subscriptions
    // (within each category: CLI first, then .zon)
    var all_nodes: std.ArrayListUnmanaged(node_mod.Node) = .empty;
    var ok_cnt: usize = 0;
    var fail_cnt: usize = 0;

    // 1. direct node URIs: --node, then .zon .nodes (no sniff, no info filtering, no prefix)
    for (opts.nodes.items) |n| try addDirectNode(arena, &all_nodes, &fail_cnt, sep, n);
    for (cfg.nodes) |n| try addDirectNode(arena, &all_nodes, &fail_cnt, sep, n);

    // 2. node list files: --node-file, then .zon .node_files
    for (opts.node_files.items) |f| try addNodeFile(arena, &all_nodes, &fail_cnt, sep, f);
    for (cfg.node_files) |f| try addNodeFile(arena, &all_nodes, &fail_cnt, sep, f);

    // 3. subscriptions: --url first, then .zon subscriptions (full pipeline:
    //    sniff + info filtering + "name@" prefix; anonymous = no prefix)
    var subs: std.ArrayListUnmanaged(config_mod.Subscription) = .empty;
    for (opts.urls.items) |arg| {
        const p = parseUrlArg(arg) catch {
            logErr(null, "invalid --url: {s}", .{arg});
            std.process.exit(2);
        };
        if (p.url.len == 0) {
            logErr(null, "invalid --url: missing url ({s})", .{arg});
            std.process.exit(2);
        }
        try subs.append(arena, .{ .name = p.name, .url = p.url });
    }
    for (cfg.subscriptions) |s| try subs.append(arena, s);
    // duplicate subscription name check across CLI and .zon (anonymous may repeat)
    var used_names: std.StringHashMapUnmanaged(void) = .empty;
    for (subs.items) |s| {
        const n = s.name orelse continue;
        if (used_names.contains(n)) {
            logErr(null, "duplicate subscription name: {s}", .{n});
            std.process.exit(3);
        }
        try used_names.put(arena, n, {});
    }
    for (subs.items) |s| {
        try processSubscription(arena, sep, info_keywords, &opts, &cfg, &all_nodes, &ok_cnt, &fail_cnt, s);
    }

    if (all_nodes.items.len == 0) {
        if (fail_cnt > 0) {
            logErr(null, "no usable nodes, aborting ({d} source(s) failed)", .{fail_cnt});
            std.process.exit(4);
        }
        logErr(null, "no usable nodes, aborting", .{});
        std.process.exit(3);
    }
    // node-name dedupe + reserved-name protection now lives inside render()
    // (renderer layer); raw keeps original names. count unsupported protocols
    // per target for the verbose report.
    const nodes = all_nodes.items;

    // render options (dry-run: read-only secret, state dir untouched)
    const secret = if (opts.dry_run)
        try resolveSecret(arena, opts.secret, false)
    else
        try resolveSecret(arena, opts.secret, true);
    const ropts: render_mod.Options = .{
        .listen = listen,
        .port = port,
        .mixed_port = mixed_port,
        .controller = controller,
        .secret = secret,
        .singbox_clash_api = opts.singbox_clash_api,
        .allow_lan = opts.allow_lan,
        .tproxy_ipv6 = opts.tproxy_ipv6,
        .tproxy_port = opts.tproxy_port,
        .log_level = opts.log_level,
    };

    // render all targets
    const Rendered = struct {
        out: Output,
        files: []const render_mod.File,
    };
    var rendered: std.ArrayListUnmanaged(Rendered) = .empty;
    for (opts.outputs.items) |o| {
        // verbose: report nodes skipped due to unsupported protocol (explicit filter)
        if (opts.verbose) {
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
        if (o.tmpl) |tp| {
            tpl_text = std.fs.cwd().readFileAlloc(arena, tp, 1 << 20) catch |e| {
                logErr(null, "failed to read template {s}: {s}", .{ tp, @errorName(e) });
                std.process.exit(3);
            };
        }
        const files = render_mod.render(arena, o.fmt, nodes, ropts, tpl_text) catch |e| {
            logErr(null, "render {s} failed: {s}", .{ @tagName(o.fmt), @errorName(e) });
            std.process.exit(3);
        };
        try rendered.append(arena, .{ .out = o, .files = files });
    }

    // dry-run: verify all; content only when path == "-"
    if (opts.dry_run) {
        for (rendered.items) |r| {
            if (r.out.path) |p| {
                if (std.mem.eql(u8, p, "-")) {
                    for (r.files) |f| try std.fs.File.stdout().writeAll(f.content);
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
        // any source failure -> keep the last good configs: installing a
        // "slimmed" set would delete the failed subscription's nodes from the
        // running configs (a temporarily down subscription is not a deletion).
        // verify still ran above (healthy sources must stay sound); the Stage A
        // temps are dropped, nothing is installed, exit 4 tells cron to retry.
        if (fail_cnt > 0) {
            cleanupStageATmps();
            logWarn(null, "{d} source(s) failed, skip install (configs unchanged)", .{fail_cnt});
        } else {
            for (rendered.items) |r| {
                if (r.out.path) |p| {
                    if (std.mem.eql(u8, p, "-")) {
                        // stdout output
                        for (r.files) |f| try std.fs.File.stdout().writeAll(f.content);
                    } else {
                        installAll(arena, r.out.fmt, r.files, p, opts, ropts, opts.reload_cmd orelse r.out.reload_cmd orelse cfg.reload_cmd);
                    }
                } else {
                    logErr(null, "output path required for {s} (use -o {s}=<path> or --dry-run)", .{ @tagName(r.out.fmt), @tagName(r.out.fmt) });
                    std.process.exit(2);
                }
            }
        }
    }

    const fmt_part = if (opts.outputs.items.len == 1)
        try std.fmt.allocPrint(arena, "format {s}", .{@tagName(opts.outputs.items[0].fmt)})
    else blk: {
        var fmts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (opts.outputs.items) |o| try fmts.append(arena, @tagName(o.fmt));
        break :blk try std.fmt.allocPrint(arena, "formats {s}", .{try std.mem.join(arena, ",", fmts.items)});
    };
    logInfo(null, "subscriptions {d}/{d} ok, {d} failed, {d} nodes, {s}", .{
        ok_cnt, subs.items.len, fail_cnt, nodes.len, fmt_part,
    });
    if (opts.secret == null and opts.verbose and !opts.dry_run) {
        var need_secret = false;
        for (opts.outputs.items) |o| {
            if (o.fmt == .clash or o.fmt == .singbox) need_secret = true;
        }
        if (need_secret) logVerbose(null, "api secret: {s}", .{secret});
    }
    cleanupStageATmps();
    releaseRunLock();
    // source failures must not look like success to cron: any failed
    // subscription/node-file makes the whole run exit 4 (configs already
    // generated and installed from the healthy sources are kept)
    if (fail_cnt > 0) std.process.exit(4);
}

fn verifyDryRunFiles(arena: std.mem.Allocator, fmt: render_mod.Format, files: []const render_mod.File) !void {
    for (files) |f| {
        const ext = switch (fmt) {
            .hysteria2 => "yaml",
            else => "json",
        };
        // pid in the name: dry-run takes no run lock, concurrent dry-runs must
        // not race on a shared temp file (interleaved atomicWrite -> wrong bytes)
        const tmp = try std.fmt.allocPrint(arena, "/tmp/subfetch-dryrun.{d}.{s}", .{ getPid(), ext });
        deploy_mod.atomicWrite(arena, tmp, f.content) catch |e| {
            logWarn(null, "failed to write {s}: {s} (verification skipped for this file)", .{ tmp, @errorName(e) });
            continue;
        };
        // verified: the temp file has served its purpose, leave no debris
        // (dry-run promises zero side effects; /tmp is cleaned by the system,
        // but the pid-suffixed names would otherwise pile up per run)
        defer std.fs.cwd().deleteFile(tmp) catch {};
        const vr = deploy_mod.verifyContent(arena, fmt, f.content, tmp);
        if (vr == .failed) {
            logErr(null, "dry-run verify failed: {s}", .{f.path});
            std.process.exit(3);
        }
    }
    logInfo(null, "dry-run verify passed ({d} files)", .{files.len});
}

/// Stage A temp files written so far; removed on abort so a failed run leaves
/// no .new/.new.json debris (covers all targets and both stages)
var stage_a_tmps: std.ArrayListUnmanaged([]const u8) = .empty;

fn cleanupStageATmps() void {
    for (stage_a_tmps.items) |t| std.fs.cwd().deleteFile(t) catch {};
    stage_a_tmps.clearRetainingCapacity();
}

/// unified failure exit: clean up Stage A temps, log, and exit(1)
fn abort(arena: std.mem.Allocator, exit_code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    _ = arena;
    cleanupStageATmps();
    logErr(null, fmt, args);
    std.process.exit(exit_code);
}

/// Stage A: verify all files of all targets before anything is installed.
/// writes .new temp files next to targets and verifies them; on failure
/// all temp files are removed and nothing is installed (atomic across targets).
/// no-op when --no-verify (install stage writes directly).
fn verifyAll(arena: std.mem.Allocator, fmt: render_mod.Format, files: []const render_mod.File, path: []const u8, no_verify: bool) void {
    if (no_verify) return;
    if (isDirFormat(fmt)) {
        std.fs.cwd().makePath(path) catch |e| {
            abort(arena, 1, "failed to create directory {s}: {s}", .{ path, @errorName(e) });
        };
    }
    for (files) |f| {
        const target = if (isDirFormat(fmt))
            std.fs.path.join(arena, &.{ path, f.path }) catch {
                abort(arena, 1, "path join failed", .{});
            }
        else
            path;
        // note: xray -test infers format from extension, tmp must end with .json
        const tmp = if (isDirFormat(fmt))
            std.fmt.allocPrint(arena, "{s}.new.json", .{target}) catch {
                abort(arena, 1, "out of memory", .{});
            }
        else
            std.fmt.allocPrint(arena, "{s}.new", .{target}) catch {
                abort(arena, 1, "out of memory", .{});
            };
        deploy_mod.atomicWrite(arena, tmp, f.content) catch |e| {
            abort(arena, 1, "failed to write {s}: {s}", .{ tmp, @errorName(e) });
        };
        // OOM is unlikely (arena over page_allocator), but if the path cannot be
        // recorded the file must still not survive an abort: delete it right away
        stage_a_tmps.append(arena, tmp) catch {
            std.fs.cwd().deleteFile(tmp) catch {};
        };
        const vr = deploy_mod.verifyContent(arena, fmt, f.content, tmp);
        if (vr == .failed) {
            abort(arena, 3, "verify failed, aborting: {s} (nothing installed)", .{target});
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
    reload_cmd: ?[]const u8,
) void {
    if (isDirFormat(fmt)) {
        const dir = path;
        std.fs.cwd().makePath(dir) catch |e| {
            abort(arena, 1, "failed to create directory {s}: {s}", .{ dir, @errorName(e) });
        };
        // change detection: install only files whose content actually changed;
        // every file unchanged -> skip install & reload entirely
        var installed: usize = 0;
        for (files) |f| {
            const fpath = std.fs.path.join(arena, &.{ dir, f.path }) catch {
                abort(arena, 1, "path join failed", .{});
            };
            if (!deploy_mod.contentDiffers(arena, fpath, f.content)) continue;
            installed += 1;
            if (opts.no_verify) {
                deploy_mod.atomicWrite(arena, fpath, f.content) catch |e| {
                    abort(arena, 1, "failed to write {s}: {s}", .{ fpath, @errorName(e) });
                };
            } else {
                const tmp = std.fmt.allocPrint(arena, "{s}.new.json", .{fpath}) catch {
                    abort(arena, 1, "out of memory", .{});
                };
                // backup existing config (acme.sh style)
                if (deploy_mod.fileExists(fpath)) {
                    const bak = std.fmt.allocPrint(arena, "{s}.bak", .{fpath}) catch {
                        abort(arena, 1, "out of memory", .{});
                    };
                    std.fs.cwd().copyFile(fpath, std.fs.cwd(), bak, .{}) catch |e| {
                        abort(arena, 1, "failed to backup {s}: {s}", .{ fpath, @errorName(e) });
                    };
                }
                std.fs.cwd().rename(tmp, fpath) catch |e| {
                    abort(arena, 1, "failed to write {s}: {s}", .{ fpath, @errorName(e) });
                };
            }
        }
        // drop the Stage A .new.json artifacts that were not renamed into place
        // (renamed ones are already gone; deleteFile is a no-op for them)
        for (files) |f| {
            const fpath = std.fs.path.join(arena, &.{ dir, f.path }) catch continue;
            const tmp = std.fmt.allocPrint(arena, "{s}.new.json", .{fpath}) catch continue;
            std.fs.cwd().deleteFile(tmp) catch {};
        }
        if (installed == 0) {
            logInfo(null, "config unchanged, skip install & reload: {s}", .{dir});
            return;
        }
        logInfo(null, "wrote {d} files to {s} ({d} unchanged)", .{ installed, dir, files.len - installed });
        if (!opts.no_reload) {
            if (reload_cmd) |cmd| {
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
        if (!deploy_mod.contentDiffers(arena, path, f.content)) {
            // drop the Stage A .new temp; nothing installed, nothing reloaded
            const tmp = std.fmt.allocPrint(arena, "{s}.new", .{path}) catch {
                abort(arena, 1, "out of memory", .{});
            };
            std.fs.cwd().deleteFile(tmp) catch {};
            logInfo(null, "config unchanged, skip install & reload: {s}", .{path});
            return;
        }
        if (opts.no_verify) {
            deploy_mod.atomicWrite(arena, path, f.content) catch |e| {
                abort(arena, 1, "failed to write {s}: {s}", .{ path, @errorName(e) });
            };
            logInfo(null, "installed {s}", .{path});
        } else {
            const tmp = std.fmt.allocPrint(arena, "{s}.new", .{path}) catch {
                abort(arena, 1, "out of memory", .{});
            };
            if (deploy_mod.fileExists(path)) {
                const bak = std.fmt.allocPrint(arena, "{s}.bak", .{path}) catch {
                    abort(arena, 1, "out of memory", .{});
                };
                std.fs.cwd().copyFile(path, std.fs.cwd(), bak, .{}) catch |e| {
                    abort(arena, 1, "failed to backup {s}: {s}", .{ path, @errorName(e) });
                };
            }
            std.fs.cwd().rename(tmp, path) catch |e| {
                abort(arena, 1, "failed to write {s}: {s}", .{ path, @errorName(e) });
            };
            logInfo(null, "installed {s} (verify passed)", .{path});
        }
        if (!opts.no_reload) {
            if (reload_cmd) |cmd| {
                // custom reload command takes priority (acme.sh --reloadcmd style)
                switch (deploy_mod.reloadCustom(arena, cmd)) {
                    .custom => logInfo(null, "custom reload command executed", .{}),
                    else => logWarn(null, "custom reload command failed (exit != 0)", .{}),
                }
            } else {
                const rr = switch (fmt) {
                    .clash => deploy_mod.reloadClash(arena, ropts.controller, ropts.secret, path),
                    .singbox => deploy_mod.reloadSingbox(arena, ropts.controller, ropts.secret, path),
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

/// multi-file formats output to a directory; single-file formats output to a file path
fn isDirFormat(fmt: render_mod.Format) bool {
    return switch (fmt) {
        .clash, .singbox, .raw => false,
        .trojan, .hysteria, .hysteria2, .xray, .ss, .ssr => true,
    };
}

/// generate UUID v4 as API secret
fn addDirectNode(
    arena: std.mem.Allocator,
    all_nodes: *std.ArrayListUnmanaged(node_mod.Node),
    fail_cnt: *usize,
    sep: []const u8,
    n: []const u8,
) !void {
    const parsed = uri_mod.parseUri(arena, n, "", sep) catch |e| {
        logWarn("node", "parse failed: {s} ({s})", .{ n, @errorName(e) });
        fail_cnt.* += 1;
        return;
    };
    try all_nodes.append(arena, parsed);
}

/// add a node list file (--node-file / .zon .node_files): shared line splitting
fn addNodeFile(
    arena: std.mem.Allocator,
    all_nodes: *std.ArrayListUnmanaged(node_mod.Node),
    fail_cnt: *usize,
    sep: []const u8,
    f: []const u8,
) !void {
    const text = std.fs.cwd().readFileAlloc(arena, f, 1 << 20) catch |e| {
        logWarn(f, "read failed: {s}", .{@errorName(e)});
        fail_cnt.* += 1;
        return;
    };
    const lines = util.splitUriLines(arena, text) catch |e| {
        logWarn(f, "parse failed ({s})", .{@errorName(e)});
        fail_cnt.* += 1;
        return;
    };
    for (lines) |l| try addDirectNode(arena, all_nodes, fail_cnt, sep, l);
}

/// subscription-internal sort key: display name (byte order, deterministic across runs)
fn nodeLessThan(_: void, a: node_mod.Node, b: node_mod.Node) bool {
    return std.mem.lessThan(u8, a.name(), b.name());
}

/// process one subscription (--url or .zon): fetch + full parse pipeline + logging
fn processSubscription(
    arena: std.mem.Allocator,
    sep: []const u8,
    info_keywords: []const []const u8,
    opts: *const Options,
    cfg: *const config_mod.Config,
    all_nodes: *std.ArrayListUnmanaged(node_mod.Node),
    ok_cnt: *usize,
    fail_cnt: *usize,
    s: config_mod.Subscription,
) !void {
    // anonymous subscription (omitted name): full parse pipeline, just no "name@" prefix.
    // fixed "anonymous" label: short, and never leaks the url (may contain a token)
    const sub_label = if (s.name) |n| n else "anonymous";
    const ua = s.ua orelse cfg.ua orelse opts.ua;
    // CLI --timeout is in seconds, fetchWithTimeout expects milliseconds
    const timeout_ms: ?u32 = if (opts.timeout) |t| t * 1000 else null;
    const body = fetch_mod.fetchWithRetry(arena, s.url, ua, timeout_ms) catch |e| {
        logWarn(sub_label, "fetch failed: {s}", .{@errorName(e)});
        fail_cnt.* += 1;
        return;
    };
    const result = parse_mod.parseSubscription(arena, s.name orelse "", body, sep, info_keywords) catch |e| {
        logWarn(sub_label, "parse failed ({s})", .{@errorName(e)});
        fail_cnt.* += 1;
        return;
    };
    // stable-sort within the subscription: upstream node order is not stable
    // between fetches, deterministic bytes keep the install diff quiet
    std.mem.sort(node_mod.Node, @constCast(result.nodes), {}, nodeLessThan);
    for (result.nodes) |n| {
        try all_nodes.append(arena, n);
    }
    ok_cnt.* += 1;
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
        if (opts.verbose) {
            for (result.info_names) |nm| {
                logVerbose(null, "  ! {s} (info node, filtered)", .{nm});
            }
        }
    }
    try extras.append(arena, try std.fmt.allocPrint(arena, "{d} bytes", .{body.len}));
    msg = try std.fmt.allocPrint(arena, "{s}, {s}", .{ msg, try std.mem.join(arena, ", ", extras.items) });
    logInfo(sub_label, "{s}", .{msg});
    // verbose: short node list (strip the "sub-name<sep>" prefix), indented under the summary
    if (opts.verbose) {
        const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ s.name orelse "", sep });
        for (result.nodes) |n| {
            const short = if (std.mem.startsWith(u8, n.name(), prefix))
                n.name()[prefix.len..]
            else
                n.name();
            logVerbose(null, "  - {s} ({s})", .{ short, n.typeName() });
        }
    }
}

test "compile-check" {
    _ = &main;
    _ = &addDirectNode;
    _ = &addNodeFile;
    _ = &processSubscription;
    _ = &verifyDryRunFiles;
    _ = &verifyAll;
    _ = &installAll;
    _ = &isDirFormat;
}
