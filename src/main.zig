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

/// one -o/--output target: format[:template][=path] (shared with .zon outputs)
const Output = config_mod.Output;

const Options = struct {
    config: []const u8 = "subscriptions.zon",
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    dry_run: bool = false,
    ua: ?[]const u8 = null,
    /// node name separator; null = .zon sep or default "@"
    sep: ?[]const u8 = null,
    timeout: ?u32 = null,
    /// 0=normal, 1=-v (bytes + node list)
    verbose: u8 = 0,
    nodes: std.ArrayListUnmanaged([]const u8) = .empty,
    node_files: std.ArrayListUnmanaged([]const u8) = .empty,
    /// CLI subscriptions (--url [name=]url), same semantics as .zon subscriptions
    urls: std.ArrayListUnmanaged([]const u8) = .empty,
    /// info-node keyword overrides (--info-keyword, repeatable; "" clears);
    /// provided = override, else .zon info_keywords, else built-in defaults
    info_keywords: std.ArrayListUnmanaged([]const u8) = .empty,
    // render customization fields (null = use .zon or defaults)
    listen: ?[]const u8 = null,
    port: ?u16 = null,
    mixed_port: ?u16 = null,
    controller: ?[]const u8 = null,
    secret: ?[]const u8 = null,
    /// positive flag: add clash_api to sing-box output (default off)
    singbox_clash_api: bool = false,
    /// positive flag: clash allow-lan in built-in template (default off)
    allow_lan: bool = false,
    /// positive flag: clash ipv6 in built-in template (default off)
    ipv6: bool = false,
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
        logErr(null, "failed to parse arguments: {s}", .{@errorName(e)});
        printUsage();
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
    opts.timeout = opts.timeout orelse cfg.timeout;
    const listen = opts.listen orelse cfg.listen orelse "127.0.0.1";
    const port = opts.port orelse cfg.port orelse 1080;
    const mixed_port = opts.mixed_port orelse cfg.mixed_port orelse 65500;
    const controller = opts.controller orelse cfg.controller orelse "127.0.0.1:65501";
    opts.reload_cmd = opts.reload_cmd orelse cfg.reload_cmd;
    opts.singbox_clash_api = opts.singbox_clash_api or (cfg.singbox_clash_api orelse false);
    opts.allow_lan = opts.allow_lan or (cfg.allow_lan orelse false);
    opts.ipv6 = opts.ipv6 or (cfg.ipv6 orelse false);

    // output targets: CLI -o/--output > .zon outputs > default raw (replace, never merge)
    if (opts.outputs.items.len == 0) {
        if (cfg.outputs) |os| {
            for (os) |o| try opts.outputs.append(arena, .{ .fmt = o.fmt, .tmpl = o.tmpl, .path = o.path });
        } else {
            try opts.outputs.append(arena, .{ .fmt = .raw });
        }
    }
    for (opts.outputs.items) |o| {
        _ = o.fmt;
    }

    // collect all nodes: direct nodes first, then node files, then subscriptions
    // (within each category: CLI first, then .zon)
    var all_nodes: std.ArrayListUnmanaged(node_mod.Node) = .empty;
    var ok_cnt: usize = 0;
    var fail_cnt: usize = 0;
    var disabled_cnt: usize = 0;

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
            std.process.exit(1);
        }
        try used_names.put(arena, n, {});
    }
    for (subs.items) |s| {
        try processSubscription(arena, sep, info_keywords, &opts, &cfg, &all_nodes, &ok_cnt, &fail_cnt, &disabled_cnt, s);
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
        .listen = listen,
        .port = port,
        .mixed_port = mixed_port,
        .controller = controller,
        .secret = secret,
        .enable_clash_api = opts.singbox_clash_api,
        .allow_lan = opts.allow_lan,
        .ipv6 = opts.ipv6,
    };

    // render all targets
    const Rendered = struct {
        out: Output,
        files: []const render_mod.File,
    };
    var rendered: std.ArrayListUnmanaged(Rendered) = .empty;
    for (opts.outputs.items) |o| {
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
        if (o.tmpl) |tp| {
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
    if (opts.outputs.items.len == 1) {
        summary = try std.fmt.allocPrint(arena, "{s}, format {s}", .{ summary, @tagName(opts.outputs.items[0].fmt) });
    } else {
        var fmts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (opts.outputs.items) |o| try fmts.append(arena, @tagName(o.fmt));
        summary = try std.fmt.allocPrint(arena, "{s}, formats {s}", .{ summary, try std.mem.join(arena, ",", fmts.items) });
    }
    logInfo(null, "{s}", .{summary});
    if (opts.secret == null and opts.verbose > 0 and !opts.dry_run) {
        var need_secret = false;
        for (opts.outputs.items) |o| {
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
        } else if (std.mem.eql(u8, a, "--singbox-clash-api")) {
            opts.singbox_clash_api = true;
        } else if (std.mem.eql(u8, a, "--allow-lan")) {
            opts.allow_lan = true;
        } else if (std.mem.eql(u8, a, "--ipv6")) {
            opts.ipv6 = true;
        } else if (std.mem.eql(u8, a, "--no-verify")) {
            opts.no_verify = true;
        } else if (std.mem.eql(u8, a, "--no-reload")) {
            opts.no_reload = true;
        } else if (takeValue(&i, args, a, "--reload-cmd", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.reload_cmd = v;
        } else if (takeValue(&i, args, a, "--config", "-c")) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.config = v;
        } else if (takeValue(&i, args, a, "--output", "-o")) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            const out = parseOutput(v) catch {
                logErr(null, "invalid output target: {s} (fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw)", .{v});
                return error.BadArg;
            };
            try opts.outputs.append(arena, out);
        } else if (takeValue(&i, args, a, "--node", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            try opts.nodes.append(arena, v);
        } else if (takeValue(&i, args, a, "--node-file", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            try opts.node_files.append(arena, v);
        } else if (takeValue(&i, args, a, "--url", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            try opts.urls.append(arena, v);
        } else if (takeValue(&i, args, a, "--info-keyword", null)) |v| {
            // empty value allowed: "" clears all keywords (disables filtering)
            try opts.info_keywords.append(arena, v);
        } else if (takeValue(&i, args, a, "--ua", null)) |v| {
            opts.ua = v;
        } else if (takeValue(&i, args, a, "--sep", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.sep = v;
        } else if (takeValue(&i, args, a, "--timeout", null)) |v| {
            opts.timeout = std.fmt.parseInt(u32, v, 10) catch {
                logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--listen", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.listen = v;
        } else if (takeValue(&i, args, a, "--port", null)) |v| {
            opts.port = std.fmt.parseInt(u16, v, 10) catch {
                logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--mixed-port", null)) |v| {
            opts.mixed_port = std.fmt.parseInt(u16, v, 10) catch {
                logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--controller", null)) |v| {
            if (v.len == 0) {
                logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.controller = v;
        } else if (takeValue(&i, args, a, "--secret", null)) |v| {
            opts.secret = v;
        } else {
            logErr(null, "unknown argument: {s}", .{a});
            return error.BadArg;
        }
    }
}

/// add a directly-pasted node URI (--node / .zon .nodes): no sniff, no info filtering, no prefix
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
    disabled_cnt: *usize,
    s: config_mod.Subscription,
) !void {
    // anonymous subscription (omitted name): full parse pipeline, just no "name@" prefix.
    // fixed "anonymous" label: short, and never leaks the url (may contain a token)
    const sub_label = if (s.name) |n| n else "anonymous";
    if (!s.enable) {
        logInfo(sub_label, "skipped (disabled)", .{});
        disabled_cnt.* += 1;
        return;
    }
    const ua = s.ua orelse cfg.ua orelse opts.ua;
    // CLI --timeout is in seconds, fetchWithTimeout expects milliseconds
    const timeout_ms: ?u32 = if (opts.timeout) |t| t * 1000 else null;
    const body = fetch_mod.fetchWithTimeout(arena, s.url, ua, timeout_ms) catch |e| {
        logWarn(sub_label, "fetch failed: {s}", .{@errorName(e)});
        fail_cnt.* += 1;
        return;
    };
    const result = parse_mod.parseSubscription(arena, s.name orelse "", body, sep, info_keywords) catch |e| {
        logWarn(sub_label, "parse failed ({s})", .{@errorName(e)});
        fail_cnt.* += 1;
        return;
    };
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

/// --url [name=]url: "name=" prefix is used only when it is a valid subscription name;
/// otherwise the whole argument is the url (anonymous subscription)
fn parseUrlArg(arg: []const u8) !struct { name: ?[]const u8, url: []const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |i| {
        if (config_mod.isValidName(arg[0..i])) return .{ .name = arg[0..i], .url = arg[i + 1 ..] };
    }
    return .{ .name = null, .url = arg };
}

/// parse -o/--output value: format[:template][=path]
fn parseOutput(v: []const u8) !Output {
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
    return .{ .fmt = fmt, .tmpl = template, .path = path };
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
        \\  -c, --config <path>     subscription list zon (default ./subscriptions.zon)
        \\
        \\Output targets:
        \\  -o, --output <fmt>[:<tmpl>][=<path>]  output target (repeatable; default raw)
        \\                          fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw
        \\                          tmpl: template file (clash/singbox; optional)
        \\                          path: output file (single-file) or directory (native); '-' = stdout
        \\
        \\Input sources:
        \\      --url [name=]<url> subscription url on the CLI (repeatable; same semantics
        \\                          as .zon subscriptions; omit "name=" for anonymous)
        \\      --node <uri>       directly pasted node URI (repeatable)
        \\      --node-file <path> node list file (one URI per line)
        \\
        \\Filtering & naming:
        \\      --info-keyword <kw> info-node keyword override (repeatable; "" clears all,
        \\                          i.e. disables filtering; overrides .zon info_keywords)
        \\      --sep <str>        node name separator between sub and node names (default @)
        \\
        \\Run behavior:
        \\      --dry-run          verify only, write nothing
        \\      --ua <str>         default User-Agent
        \\      --timeout <sec>    per-subscription fetch timeout in seconds
        \\
        \\Output config:
        \\      --listen <addr>    native client listen address (default 127.0.0.1)
        \\      --port <n>         native client listen port (default 1080)
        \\      --mixed-port <n>   clash mixed-port (default 65500)
        \\      --controller <a:p> clash/singbox external-controller (default 127.0.0.1:65501)
        \\      --secret <str>     API secret (auto-generated UUID if omitted)
        \\      --singbox-clash-api add clash_api to sing-box output (default off)
        \\      --allow-lan        clash allow-lan in built-in template (default off)
        \\      --ipv6             clash ipv6 in built-in template (default off)
        \\
        \\Deploy:
        \\      --no-verify        skip verification
        \\      --no-reload        skip reload after install
        \\      --reload-cmd <cmd> custom reload command after install (sh -c, overrides auto reload; acme.sh style)
        \\
        \\Misc:
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

test "parseOutput grammar" {
    // format only
    const o1 = try parseOutput("clash");
    try std.testing.expectEqual(render_mod.Format.clash, o1.fmt);
    try std.testing.expect(o1.tmpl == null);
    try std.testing.expect(o1.path == null);
    // format + template
    const o2 = try parseOutput("clash:tmpl.yaml");
    try std.testing.expectEqual(render_mod.Format.clash, o2.fmt);
    try std.testing.expectEqualStrings("tmpl.yaml", o2.tmpl.?);
    try std.testing.expect(o2.path == null);
    // format + path
    const o3 = try parseOutput("singbox=/etc/sing-box/config.json");
    try std.testing.expectEqual(render_mod.Format.singbox, o3.fmt);
    try std.testing.expectEqualStrings("/etc/sing-box/config.json", o3.path.?);
    try std.testing.expect(o3.tmpl == null);
    // full: format + template + path
    const o4 = try parseOutput("clash:tmpl.yaml=out/c.yaml");
    try std.testing.expectEqual(render_mod.Format.clash, o4.fmt);
    try std.testing.expectEqualStrings("tmpl.yaml", o4.tmpl.?);
    try std.testing.expectEqualStrings("out/c.yaml", o4.path.?);
    // stdout path
    const o5 = try parseOutput("raw=-");
    try std.testing.expectEqual(render_mod.Format.raw, o5.fmt);
    try std.testing.expectEqualStrings("-", o5.path.?);
    // unknown format errors
    try std.testing.expectError(error.BadArg, parseOutput("bogus"));
    try std.testing.expectError(error.BadArg, parseOutput(""));
    // extra '=' belongs to the path (first '=' splits path, then ':' splits template)
    const o6 = try parseOutput("clash:tmpl=path=extra");
    try std.testing.expectEqualStrings("tmpl", o6.tmpl.?);
    try std.testing.expectEqualStrings("path=extra", o6.path.?);
}

test "compile-check" {
    _ = &main;
    _ = &parseArgs;
    _ = &parseOutput;
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
