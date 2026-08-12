const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const fetch = @import("fetch.zig");
const parse = @import("parse.zig");
const uri = @import("uri.zig");
const node = @import("node.zig");
const util = @import("util.zig");
const render = @import("render.zig");
const deploy = @import("deploy.zig");
const cli = @import("cli.zig");
const runstate = @import("runstate.zig");
const log = @import("log.zig");

const build_options = @import("build_options");
const version = build_options.version;

/// one -o/--output target: format[:template][=path] (shared with .zon outputs)
const Output = config.Output;

pub fn main() u8 {
    // single exit: run() returns an ExitCode for every outcome, and errors
    // no call site handled (OOM in helpers, stdio) are mapped to the runtime
    // code here; the runtime turns the returned u8 into the exit status.
    // the only direct exit() in this file is oom(): a degenerate state with
    // no return path (see below).
    const code = run() catch |e| abort(.runtime_err, "fatal: {s}", .{@errorName(e)});
    return code.value();
}

/// the real program. returns the exit code for every outcome: .ok on
/// success, the failing stage's code via return abort(), and partial
/// success (some sources failed) as .partial_ok. errors no call site
/// handled (OOM in helpers, stdio) propagate to main().
fn run() !ExitCode {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    var opts = cli.Options{};
    const action = cli.parseArgs(arena, args, &opts) catch |e| {
        // BadArg already logged its specific reason inside parseArgs
        // (unknown option / invalid value / missing value ...); the usage text
        // below is the last word, so abort logs nothing further
        if (e == error.OutOfMemory) log.err("out of memory", .{});
        log.outPrint("\n", .{});
        cli.printUsage();
        return abort(.usage_err, "", .{});
    };
    // --help/--version already printed by cli
    if (action != .run) return .ok;

    // serialize concurrent runs (cron overlaps); dry-run is read-only, no lock
    if (!opts.dry_run) runstate.acquireRunLock(arena);

    // --dry-run promises zero side effects; reset-state deletes the persisted
    // secret, so the combination is a contradiction (reject it as a usage error)
    if (opts.reset_state and opts.dry_run) {
        return abort(.usage_err, "--dry-run cannot be combined with --reset-state", .{});
    }

    // --reset-state: drop the persisted secret and stop (nothing else to do)
    if (opts.reset_state) {
        runstate.resetStateSecret(arena) catch |e| {
            return abort(.runtime_err, "failed to reset state: {s}", .{@errorName(e)});
        };
        runstate.releaseRunLock();
        return .ok;
    }

    // read config (optional): missing default config.zon -> pure CLI usage with
    // defaults; an explicitly passed -c path that does not exist is a user error
    // (an explicit "-c config.zon" is not the default: it must exist)
    const cfg_path = opts.config orelse "config.zon";
    const cfg: config.Config = blk: {
        const text = std.fs.cwd().readFileAlloc(arena, cfg_path, 1 << 20) catch |e| {
            if (e == error.FileNotFound and opts.config == null) {
                log.info("config: none, using defaults", .{});
                break :blk .{};
            }
            return abort(.config_err, "failed to read config {s}: {s}", .{ cfg_path, @errorName(e) });
        };
        const parsed = config.parse(arena, text) catch |e| {
            return abort(.config_err, "failed to parse config {s}: {s}", .{ cfg_path, @errorName(e) });
        };
        log.info("config: {s}", .{cfg_path});
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
    } else if (cfg.info_keywords) |k| k else &node.default_info_keywords;

    // merge CLI > .zon > defaults for render/deploy/behavior fields
    const listen = opts.listen orelse cfg.listen orelse "127.0.0.1";
    const port = opts.port orelse cfg.port orelse 1080;
    const mixed_port = opts.mixed_port orelse cfg.mixed_port orelse 65500;
    const controller = opts.controller orelse cfg.controller orelse "127.0.0.1:65501";
    opts.singbox_clash_api = opts.singbox_clash_api or (cfg.singbox_clash_api orelse false);
    opts.allow_lan = opts.allow_lan or (cfg.allow_lan orelse false);
    opts.tproxy_ipv6 = opts.tproxy_ipv6 or (cfg.tproxy_ipv6 orelse false);
    opts.tproxy_port = opts.tproxy_port orelse cfg.tproxy_port;
    opts.log_level = opts.log_level orelse cfg.log_level;

    // output targets: CLI -o/--output > .zon outputs (replace, never merge).
    // checked before any fetch: a run without a usable target is a usage
    // error, and it must fail fast (no wasted network requests).
    if (opts.outputs.items.len == 0) {
        if (cfg.outputs) |os| {
            for (os) |o| try opts.outputs.append(arena, o);
        }
    }
    if (!opts.dry_run) {
        if (opts.outputs.items.len == 0) {
            return abort(.usage_err, "no output target (use -o <fmt>=<path> or .outputs in the config)", .{});
        }
        for (opts.outputs.items) |o| {
            if (o.path == null) {
                return abort(.usage_err, "output path required for {s} (use -o {s}=<path>)", .{ @tagName(o.fmt), @tagName(o.fmt) });
            }
        }
    }

    // collect all nodes: direct nodes first, then node files, then subscriptions
    // (within each category: CLI first, then .zon)
    var all_nodes: std.ArrayListUnmanaged(node.Node) = .empty;
    var ok_cnt: usize = 0;
    var fail_cnt: usize = 0;

    // 1. direct node URIs: --node, then .zon .nodes (no sniff, no info filtering, no prefix)
    for (opts.nodes.items) |n| try addDirectNode(arena, &all_nodes, &fail_cnt, sep, n);
    for (cfg.nodes) |n| try addDirectNode(arena, &all_nodes, &fail_cnt, sep, n);

    // 2. subscriptions: --url first, then .zon subscriptions (full pipeline:
    //    sniff + info filtering + "name@" prefix; anonymous = no prefix). local
    //    file paths and file:// urls are read as files by fetch (node list
    //    files were folded into this: --url /path/to/nodes.txt works).
    var subs: std.ArrayListUnmanaged(config.Subscription) = .empty;
    for (opts.urls.items) |arg| {
        const p = cli.parseUrlArg(arg) catch {
            return abort(.usage_err, "invalid --url: {s}", .{arg});
        };
        if (p.url.len == 0) {
            return abort(.usage_err, "invalid --url: missing url ({s})", .{arg});
        }
        try subs.append(arena, .{ .name = p.name, .url = p.url });
    }
    for (cfg.subscriptions) |s| try subs.append(arena, s);
    // duplicate subscription name check across CLI and .zon (anonymous may repeat)
    var used_names: std.StringHashMapUnmanaged(void) = .empty;
    for (subs.items) |s| {
        const n = s.name orelse continue;
        if (used_names.contains(n)) {
            return abort(.config_err, "duplicate subscription name: {s}", .{n});
        }
        try used_names.put(arena, n, {});
    }
    for (subs.items) |s| {
        try processSubscription(.{
            .arena = arena,
            .sep = sep,
            .info_keywords = info_keywords,
            .opts = &opts,
            .cfg = &cfg,
            .all_nodes = &all_nodes,
            .ok_cnt = &ok_cnt,
            .fail_cnt = &fail_cnt,
        }, s);
    }

    if (all_nodes.items.len == 0) {
        if (fail_cnt > 0) {
            return abort(.partial_ok, "no usable nodes, aborting ({d} source(s) failed)", .{fail_cnt});
        }
        return abort(.config_err, "no usable nodes, aborting", .{});
    }
    // node-name dedupe + reserved-name protection now lives inside render()
    // (renderer layer); raw keeps original names. count unsupported protocols
    // per target for the verbose report.
    const nodes = all_nodes.items;

    // render options (dry-run: read-only secret, state dir untouched)
    const secret = try runstate.resolveSecret(arena, opts.secret, !opts.dry_run);
    const ropts: render.Options = .{
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
        files: []const render.File,
    };
    var rendered: std.ArrayListUnmanaged(Rendered) = .empty;
    for (opts.outputs.items) |o| {
        // verbose: report nodes skipped due to unsupported protocol (explicit filter)
        if (opts.verbose) {
            var unsupported: usize = 0;
            for (nodes) |n| {
                if (!render.supports(o.fmt, n)) {
                    unsupported += 1;
                    log.verbose("  ! {s} (unsupported protocol)", .{n.name()});
                }
            }
            if (unsupported > 0) {
                log.verbose("[{s}] {d} node(s) skipped (unsupported protocol)", .{ @tagName(o.fmt), unsupported });
            }
        }
        // load user template (clash/singbox only)
        var tpl_text: ?[]const u8 = null;
        if (o.tmpl) |tp| {
            tpl_text = std.fs.cwd().readFileAlloc(arena, tp, 1 << 20) catch |e| {
                return abort(.config_err, "failed to read template {s}: {s}", .{ tp, @errorName(e) });
            };
        }
        const files = render.render(arena, o.fmt, nodes, ropts, tpl_text) catch |e| {
            return abort(.config_err, "render {s} failed: {s}", .{ @tagName(o.fmt), @errorName(e) });
        };
        try rendered.append(arena, .{ .out = o, .files = files });
    }

    // dry-run: verify all outputs, write nothing (same checks as install:
    // same per-output verify=false / --no-verify switch)
    if (opts.dry_run) {
        for (rendered.items) |r| {
            const code = verifyDryRunFiles(arena, r.out.fmt, r.files, !(r.out.verify orelse !opts.no_verify));
            if (code != .ok) return code;
        }
    } else {
        // real mode: verify all first (atomic), then install all
        for (rendered.items) |r| {
            // path is non-null: enforced by the early output check above
            const p = r.out.path.?;
            const code = verifyAll(arena, r.out.fmt, r.files, p, !(r.out.verify orelse !opts.no_verify));
            if (code != .ok) return code;
        }
        // any source failure -> keep the last good configs: installing a
        // "slimmed" set would delete the failed subscription's nodes from the
        // running configs (a temporarily down subscription is not a deletion).
        // verify still ran above (healthy sources must stay sound); the verify
        // temps are dropped, nothing is installed, exit 4 tells cron to retry.
        if (fail_cnt > 0) {
            cleanupVerifyTmps();
            log.warn("{d} source(s) failed, skip install (configs unchanged)", .{fail_cnt});
        } else {
            for (rendered.items) |r| {
                const p = r.out.path.?;
                const code = installAll(arena, r.out.fmt, r.files, p, ropts, r.out.verify orelse !opts.no_verify, r.out.reload orelse !opts.no_reload, opts.reload_cmd orelse r.out.reload_cmd orelse cfg.reload_cmd);
                if (code != .ok) return code;
            }
        }
    }

    const fmt_part: []const u8 = switch (opts.outputs.items.len) {
        0 => "",
        1 => try std.fmt.allocPrint(arena, ", format {s}", .{@tagName(opts.outputs.items[0].fmt)}),
        else => blk: {
            var fmts: std.ArrayListUnmanaged([]const u8) = .empty;
            for (opts.outputs.items) |o| try fmts.append(arena, @tagName(o.fmt));
            break :blk try std.fmt.allocPrint(arena, ", formats {s}", .{try std.mem.join(arena, ",", fmts.items)});
        },
    };
    log.info("subscriptions {d}/{d} ok, {d} failed, {d} nodes{s}", .{
        ok_cnt, subs.items.len, fail_cnt, nodes.len, fmt_part,
    });
    if (opts.secret == null and opts.verbose and !opts.dry_run) {
        var need_secret = false;
        for (opts.outputs.items) |o| {
            if (o.fmt == .clash or o.fmt == .singbox) need_secret = true;
        }
        if (need_secret) log.verbose("api secret: {s}", .{secret});
    }
    cleanupVerifyTmps();
    runstate.releaseRunLock();
    // partial success: the run itself completed (healthy sources verified,
    // nothing installed), but some source(s) failed. return 4 so cron
    // retries the failed subscriptions. every failure was already warned at
    // its source; this is a non-ok outcome, not an error.
    if (fail_cnt > 0) return .partial_ok;
    return .ok;
}

/// dry-run verification: same checks as the install path but against a
/// throwaway /tmp file, and failure returns the exit code (honest:
/// "verify passed" is never printed after a failed check or temp write).
/// internal failures go through return abort() like everywhere else; OOM
/// (allocPrint()) is fatal (see oom()).
fn verifyDryRunFiles(arena: std.mem.Allocator, fmt: render.Format, files: []const render.File, no_verify: bool) ExitCode {
    for (files) |f| {
        // --no-verify / verify=false: mandatory syntax layer only, no temp file
        if (no_verify) {
            deploy.syntaxCheck(arena, fmt, f.content) catch |e| {
                return abort(.config_err, "dry-run syntax check failed ({s}): {s}", .{ @errorName(e), f.path });
            };
            continue;
        }
        const ext = switch (fmt) {
            .hysteria2 => "yaml",
            else => "json",
        };
        // pid in the name: dry-run takes no run lock, concurrent dry-runs must
        // not race on a shared temp file (interleaved atomicWrite -> wrong bytes)
        const tmp = allocPrint(arena, "/tmp/subfetch-dryrun.{d}.{s}", .{ log.getPid(), ext });
        // a write failure here must not silently degrade into "verify passed":
        // same abort as the install path (verifyAll), honest over pretending.
        // the temp is not registered in verify_tmps yet, so remove it first
        // (abort cleans only the verify list; no debris, dry-run promises
        // zero side effects)
        deploy.atomicWrite(arena, tmp, f.content) catch |e| {
            std.fs.cwd().deleteFile(tmp) catch {};
            return abort(.runtime_err, "failed to write {s}: {s}", .{ tmp, @errorName(e) });
        };
        // verified: the temp file has served its purpose, leave no debris
        // (dry-run promises zero side effects; /tmp is cleaned by the system,
        // but the pid-suffixed names would otherwise pile up per run)
        defer std.fs.cwd().deleteFile(tmp) catch {};
        deploy.verifyContent(arena, fmt, f.content, tmp) catch |e| {
            return abort(.config_err, "dry-run verify failed ({s}): {s}", .{ @errorName(e), f.path });
        };
    }
    const fnoun = if (files.len == 1) "file" else "files";
    log.info("dry-run verify passed ({d} {s})", .{ files.len, fnoun });
    return .ok;
}

/// verify-created temp files (.new/.new.json), written during the verify
/// phase; removed on abort or normal end so a failed run leaves no debris
var verify_tmps: std.ArrayListUnmanaged([]const u8) = .empty;

fn cleanupVerifyTmps() void {
    for (verify_tmps.items) |t| std.fs.cwd().deleteFile(t) catch {};
    verify_tmps.clearRetainingCapacity();
}

/// process exit codes (the public contract; semantics are fixed, do not
/// reuse a value for a new meaning). run() returns these and main() maps
/// the final code to the process exit status; the only direct exit() in
/// this file is oom(), a degenerate state with no return path.
const ExitCode = enum(u8) {
    /// success — the run completed as requested
    ok = 0,
    /// runtime failure: oom, io, stdio — the process could not complete
    runtime_err = 1,
    /// usage error: bad arguments, invalid --url, missing output path
    usage_err = 2,
    /// config/template/render/verify/syntax failure — the local config
    /// pipeline (reading, generating, validating) could not complete
    config_err = 3,
    /// partial success — the run completed (healthy sources processed,
    /// nothing installed), but some source(s) failed; cron treats the run
    /// as failed and retries. also used when all sources failed
    /// (no usable nodes): same retry semantics.
    partial_ok = 4,

    /// raw exit status value for std.process.exit
    fn value(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

/// unified failure path: clean up verify temps, optionally log an error
/// message, then return the exit code (every caller returns it up the
/// chain; main() turns the final code into the exit status). an empty
/// message is allowed for paths that already reported the problem (cli
/// usage errors print the specific reason plus the usage text before
/// aborting).
fn abort(exit_code: ExitCode, comptime fmt: []const u8, args: anytype) ExitCode {
    cleanupVerifyTmps();
    if (fmt.len > 0) log.err(fmt, args);
    return exit_code;
}

/// allocation-failure shorthand: the arena is page-backed, so OOM is a
/// degenerate state; failing fast beats threading an error union through.
/// noreturn so it works in expression position (catch oom()); OOM is the
/// one path that exits directly instead of returning a code — at that point
/// even building an error message may fail and no return path exists.
fn oom() noreturn {
    cleanupVerifyTmps();
    log.err("out of memory", .{});
    std.process.exit(ExitCode.runtime_err.value());
}

/// ".new"/".new.json" sibling path for a target (json suffix for dir
/// formats: xray -test infers the format from the file extension)
fn tmpName(arena: std.mem.Allocator, target: []const u8, is_dir: bool) []const u8 {
    return if (is_dir)
        allocPrint(arena, "{s}.new.json", .{target})
    else
        allocPrint(arena, "{s}.new", .{target});
}

/// allocPrint that treats OOM as fatal (the arena is page-backed, so OOM is
/// a degenerate state with no return path, see oom()): std.fmt.allocPrint
/// with the catch oom() noise folded in, build.zig b.fmt style.
fn allocPrint(arena: std.mem.Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, f, args) catch oom();
}

/// path join that treats OOM as fatal (build.zig style: b.pathJoin)
fn pathJoin(arena: std.mem.Allocator, parts: []const []const u8) []const u8 {
    return std.fs.path.join(arena, parts) catch oom();
}

/// install a verified temp file into place: back up the existing config
/// (acme.sh style) then rename
fn installVerified(arena: std.mem.Allocator, target: []const u8, tmp: []const u8) ExitCode {
    if (deploy.fileExists(target)) {
        const bak = allocPrint(arena, "{s}.bak", .{target});
        std.fs.cwd().copyFile(target, std.fs.cwd(), bak, .{}) catch |e| {
            return abort(.runtime_err, "failed to backup {s}: {s}", .{ target, @errorName(e) });
        };
    }
    std.fs.cwd().rename(tmp, target) catch |e| {
        return abort(.runtime_err, "failed to write {s}: {s}", .{ target, @errorName(e) });
    };
    return .ok;
}

/// verify phase: verify all files of all targets before anything is installed.
/// writes .new temp files next to targets and verifies them; on failure
/// all temp files are removed and nothing is installed (atomic across targets).
/// no-op when --no-verify (install phase writes directly).
fn verifyAll(arena: std.mem.Allocator, fmt: render.Format, files: []const render.File, path: []const u8, no_verify: bool) ExitCode {
    if (no_verify) {
        // syntax self-check always runs: it guards the generator/template
        // output (millisecond work), while only the client command is skipped
        for (files) |f| {
            deploy.syntaxCheck(arena, fmt, f.content) catch |e| {
                return abort(.config_err, "syntax check failed ({s}), aborting: {s} (nothing installed)", .{ @errorName(e), path });
            };
        }
        return .ok;
    }
    if (isDirFormat(fmt)) {
        std.fs.cwd().makePath(path) catch |e| {
            return abort(.runtime_err, "failed to create directory {s}: {s}", .{ path, @errorName(e) });
        };
    }
    for (files) |f| {
        const target = if (isDirFormat(fmt)) pathJoin(arena, &.{ path, f.path }) else path;
        // note: xray -test infers format from extension, tmp must end with .json
        const tmp = tmpName(arena, target, isDirFormat(fmt));
        deploy.atomicWrite(arena, tmp, f.content) catch |e| {
            // not registered in verify_tmps yet: remove it explicitly so an
            // abort leaves no .new debris (the registration below is skipped)
            std.fs.cwd().deleteFile(tmp) catch {};
            return abort(.runtime_err, "failed to write {s}: {s}", .{ tmp, @errorName(e) });
        };
        // OOM is unlikely (arena over page_allocator), but if the path cannot be
        // recorded the file must still not survive an abort: delete it right away
        verify_tmps.append(arena, tmp) catch {
            std.fs.cwd().deleteFile(tmp) catch {};
        };
        deploy.verifyContent(arena, fmt, f.content, tmp) catch |e| {
            return abort(.config_err, "verify failed ({s}), aborting: {s} (nothing installed)", .{ @errorName(e), target });
        };
    }
    return .ok;
}

/// install phase: install all files (rename verified .new files into place, then reload).
/// called only after verifyAll passed (or --no-verify).
fn installAll(
    arena: std.mem.Allocator,
    fmt: render.Format,
    files: []const render.File,
    path: []const u8,
    ropts: render.Options,
    verify: bool,
    reload: bool,
    reload_cmd: ?[]const u8,
) ExitCode {
    if (isDirFormat(fmt)) {
        const dir = path;
        std.fs.cwd().makePath(dir) catch |e| {
            return abort(.runtime_err, "failed to create directory {s}: {s}", .{ dir, @errorName(e) });
        };
        // change detection: install only files whose content actually changed;
        // every file unchanged -> skip install & reload entirely
        var installed: usize = 0;
        for (files) |f| {
            const fpath = pathJoin(arena, &.{ dir, f.path });
            if (!deploy.contentDiffers(arena, fpath, f.content)) continue;
            installed += 1;
            if (!verify) {
                deploy.atomicWrite(arena, fpath, f.content) catch |e| {
                    return abort(.runtime_err, "failed to write {s}: {s}", .{ fpath, @errorName(e) });
                };
            } else {
                // verify wrote tmpName(...) already; rename it into place with
                // a backup of the existing config (acme.sh style)
                const code = installVerified(arena, fpath, tmpName(arena, fpath, true));
                if (code != .ok) return code;
            }
        }
        // drop the verify .new.json artifacts that were not renamed into place
        // (renamed ones are already gone; deleteFile is a no-op for them).
        // cleanup is best-effort: join/alloc failures are skipped (catch),
        // unlike pathJoin/allocPrint which treat OOM as fatal
        for (files) |f| {
            const fpath = std.fs.path.join(arena, &.{ dir, f.path }) catch continue;
            const tmp = std.fmt.allocPrint(arena, "{s}.new.json", .{fpath}) catch continue;
            std.fs.cwd().deleteFile(tmp) catch {};
        }
        if (installed == 0) {
            log.info("config unchanged, skip install & reload: {s}", .{dir});
            return .ok;
        }
        const fnoun = if (installed == 1) "file" else "files";
        log.info("wrote {d} {s} to {s} ({d} unchanged)", .{ installed, fnoun, dir, files.len - installed });
        if (reload) reloadAfterInstall(arena, fmt, ropts, path, reload_cmd);
        return .ok;
    } else {
        // single-file format
        const f = files[0];
        if (!deploy.contentDiffers(arena, path, f.content)) {
            // drop the verify .new temp; nothing installed, nothing reloaded
            std.fs.cwd().deleteFile(tmpName(arena, path, false)) catch {};
            log.info("config unchanged, skip install & reload: {s}", .{path});
            return .ok;
        }
        if (!verify) {
            deploy.atomicWrite(arena, path, f.content) catch |e| {
                return abort(.runtime_err, "failed to write {s}: {s}", .{ path, @errorName(e) });
            };
            log.info("installed {s}", .{path});
        } else {
            const code = installVerified(arena, path, tmpName(arena, path, false));
            if (code != .ok) return code;
            log.info("installed {s} (verify passed)", .{path});
        }
        if (reload) reloadAfterInstall(arena, fmt, ropts, path, reload_cmd);
    }
    return .ok;
}

/// reload after install: custom reload command takes priority (acme.sh
/// --reloadcmd style); without one, clash/sing-box fall back to API +
/// systemctl restart, other formats have no auto-reload.
fn reloadAfterInstall(
    arena: std.mem.Allocator,
    fmt: render.Format,
    ropts: render.Options,
    path: []const u8,
    reload_cmd: ?[]const u8,
) void {
    if (reload_cmd) |cmd| {
        switch (deploy.reloadCustom(arena, cmd)) {
            .custom => log.info("custom reload command executed", .{}),
            else => log.warn("custom reload command failed (exit != 0)", .{}),
        }
        return;
    }
    const rr = switch (fmt) {
        .clash => deploy.reloadClash(arena, ropts.controller, ropts.secret, path),
        .singbox => deploy.reloadSingbox(arena, ropts.controller, ropts.secret, path),
        else => deploy.ReloadResult.skipped,
    };
    switch (rr) {
        .api => log.info("reloaded via API", .{}),
        .systemctl => log.info("restarted via systemctl", .{}),
        .custom => unreachable,
        .skipped => log.info("no auto-reload for this format; restart manually (or use --reload-cmd)", .{}),
        .failed => log.warn("reload failed; restart manually", .{}),
    }
}

/// multi-file formats output to a directory; single-file formats output to a file path
fn isDirFormat(fmt: render.Format) bool {
    return switch (fmt) {
        .clash, .singbox, .raw => false,
        .trojan, .hysteria, .hysteria2, .xray, .ss, .ssr => true,
    };
}

/// add a direct node URI (--node / .zon .nodes): no sniff, no info filtering,
/// no subscription-name prefix; parse failure counts as a failed source.
fn addDirectNode(
    arena: std.mem.Allocator,
    all_nodes: *std.ArrayListUnmanaged(node.Node),
    fail_cnt: *usize,
    sep: []const u8,
    n: []const u8,
) !void {
    const parsed = uri.parseUri(arena, n, "", sep) catch |e| {
        log.warn("[node] parse failed: {s} ({s})", .{ n, @errorName(e) });
        fail_cnt.* += 1;
        return;
    };
    try all_nodes.append(arena, parsed);
}

/// subscription-internal sort key: display name (byte order, deterministic across runs)
fn nodeLessThan(_: void, a: node.Node, b: node.Node) bool {
    return std.mem.lessThan(u8, a.name(), b.name());
}

/// per-subscription processing state (named-field args, see processSubscription)
const SubscriptionCtx = struct {
    arena: std.mem.Allocator,
    /// node name separator
    sep: []const u8,
    /// info-node keyword overrides (CLI > .zon > defaults)
    info_keywords: []const []const u8,
    opts: *const cli.Options,
    cfg: *const config.Config,
    all_nodes: *std.ArrayListUnmanaged(node.Node),
    ok_cnt: *usize,
    fail_cnt: *usize,
};

/// process one subscription (--url or .zon): fetch + full parse pipeline + logging
fn processSubscription(ctx: SubscriptionCtx, s: config.Subscription) !void {
    const a = ctx.arena;
    // anonymous subscription (omitted name): full parse pipeline, just no "name@" prefix.
    // fixed "anonymous" label: short, and never leaks the url (may contain a token)
    const sub_label = if (s.name) |n| n else "anonymous";
    const ua = s.ua orelse ctx.cfg.ua orelse ctx.opts.ua;
    const body = fetch.fetchWithRetry(a, s.url, ua) catch |e| {
        log.warn("[{s}] fetch failed: {s}", .{ sub_label, @errorName(e) });
        ctx.fail_cnt.* += 1;
        return;
    };
    const result = parse.parseSubscription(a, s.name orelse "", body, ctx.sep, ctx.info_keywords) catch |e| {
        log.warn("[{s}] parse failed ({s})", .{ sub_label, @errorName(e) });
        ctx.fail_cnt.* += 1;
        return;
    };
    // stable-sort within the subscription: upstream node order is not stable
    // between fetches, deterministic bytes keep the install diff quiet
    std.mem.sort(node.Node, @constCast(result.nodes), {}, nodeLessThan);
    for (result.nodes) |n| {
        try ctx.all_nodes.append(a, n);
    }
    ctx.ok_cnt.* += 1;
    // summary line is identical in normal and verbose mode: "N nodes (M skipped, B bytes)"
    const noun = if (result.nodes.len == 1) "node" else "nodes";
    var msg = try std.fmt.allocPrint(a, "{d} {s}", .{ result.nodes.len, noun });
    var extras: std.ArrayListUnmanaged([]const u8) = .empty;
    if (result.skipped > 0) {
        try extras.append(a, try std.fmt.allocPrint(a, "{d} skipped", .{result.skipped}));
        // warn: skipped entries with their failure reason. a subscription
        // containing bad lines is a data problem worth seeing by default;
        // the summary line above still gives the total count.
        for (result.skipped_lines) |l| {
            if (l.text.len == 0) continue;
            if (l.reason.len == 0) {
                log.warn("[{s}] {s} (parse failed)", .{ sub_label, l.text });
            } else {
                log.warn("[{s}] {s} (parse failed: {s})", .{ sub_label, l.text, l.reason });
            }
        }
    }
    if (result.info > 0) {
        try extras.append(a, try std.fmt.allocPrint(a, "{d} info", .{result.info}));
        // verbose: list filtered info (notice) nodes for debugging
        if (ctx.opts.verbose) {
            for (result.info_names) |nm| {
                log.verbose("  ! {s} (info node, filtered)", .{nm});
            }
        }
    }
    try extras.append(a, try std.fmt.allocPrint(a, "{d} bytes", .{body.len}));
    msg = try std.fmt.allocPrint(a, "{s}, {s}", .{ msg, try std.mem.join(a, ", ", extras.items) });
    log.info("[{s}] {s}", .{ sub_label, msg });
    // verbose: short node list (strip the "sub-name<sep>" prefix), indented under the summary
    if (ctx.opts.verbose) {
        const prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ s.name orelse "", ctx.sep });
        for (result.nodes) |n| {
            const short = if (std.mem.startsWith(u8, n.name(), prefix))
                n.name()[prefix.len..]
            else
                n.name();
            log.verbose("  - {s} ({s})", .{ short, n.typeName() });
        }
    }
}

test "compile-check" {
    _ = &main;
    _ = &addDirectNode;
    _ = &processSubscription;
    _ = &verifyDryRunFiles;
    _ = &verifyAll;
    _ = &installAll;
    _ = &reloadAfterInstall;
    _ = &isDirFormat;
}
