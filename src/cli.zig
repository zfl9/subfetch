const std = @import("std");
const config = @import("config.zig");
const render = @import("render.zig");
const log = @import("log.zig");

const build_options = @import("build_options");
const version = build_options.version;

/// one -o/--output target: format[:template][=path] (shared with .zon outputs)
const Output = config.Output;

pub const Options = struct {
    config: ?[]const u8 = null,
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    dry_run: bool = false,
    /// --reset-state: drop the persisted api secret (next run generates a fresh one)
    reset_state: bool = false,
    ua: ?[]const u8 = null,
    /// node name separator; null = .zon sep or default "@"
    sep: ?[]const u8 = null,
    /// -v/--verbose: node list + api secret (no deeper levels)
    verbose: bool = false,
    nodes: std.ArrayListUnmanaged([]const u8) = .empty,
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
    /// positive flag: v6 tproxy dual-stack in built-in templates (default off)
    tproxy_ipv6: bool = false,
    /// tproxy inbound port (clash + singbox built-in templates; null = off)
    tproxy_port: ?u16 = null,
    /// client log level (built-in templates; null = info)
    log_level: ?render.LogLevel = null,
    no_verify: bool = false,
    no_reload: bool = false,
    /// user-defined reload command (acme.sh --reloadcmd style);
    /// overrides all .zon reload commands and API/systemctl auto-reload
    reload_cmd: ?[]const u8 = null,
};

pub const CliError = error{ CliBadArg, OutOfMemory };

/// parse outcome: .run continues; .help/.version already printed their
/// output and the caller exits 0 (parsing never exits on its own)
pub const Action = enum { run, help, version };

pub fn parseArgs(arena: std.mem.Allocator, args: [][:0]u8, opts: *Options) CliError!Action {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            return .help;
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            log.outPrint("subfetch {f}\n", .{version});
            return .version;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--reset-state")) {
            opts.reset_state = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            // -v/--verbose: single verbose level (node list, api secret). -vv/-vvv
            // were removed: no deeper verbose level exists (strict parsing)
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--singbox-clash-api")) {
            opts.singbox_clash_api = true;
        } else if (std.mem.eql(u8, a, "--allow-lan")) {
            opts.allow_lan = true;
        } else if (std.mem.eql(u8, a, "--tproxy-ipv6")) {
            opts.tproxy_ipv6 = true;
        } else if (std.mem.eql(u8, a, "--no-verify")) {
            opts.no_verify = true;
        } else if (std.mem.eql(u8, a, "--no-reload")) {
            opts.no_reload = true;
        } else if (try takeRequired(&i, args, a, "--reload-cmd", null)) |v| {
            opts.reload_cmd = v;
        } else if (try takeRequired(&i, args, a, "--config", "-c")) |v| {
            opts.config = v;
        } else if (try takeRequired(&i, args, a, "--output", "-o")) |v| {
            const out = parseOutput(v) catch {
                log.err("invalid output target: {s} (fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw)", .{v});
                return error.CliBadArg;
            };
            try opts.outputs.append(arena, out);
        } else if (try takeRequired(&i, args, a, "--node", null)) |v| {
            try opts.nodes.append(arena, v);
        } else if (try takeRequired(&i, args, a, "--url", null)) |v| {
            try opts.urls.append(arena, v);
        } else if (takeValue(&i, args, a, "--info-keyword", null)) |v| {
            // empty value allowed: "" clears all keywords (disables filtering)
            try opts.info_keywords.append(arena, v);
        } else if (try takeRequired(&i, args, a, "--ua", null)) |v| {
            opts.ua = v;
        } else if (try takeRequired(&i, args, a, "--sep", null)) |v| {
            opts.sep = v;
        } else if (try takeRequired(&i, args, a, "--listen", null)) |v| {
            opts.listen = v;
        } else if (takeValue(&i, args, a, "--port", null)) |v| {
            opts.port = std.fmt.parseInt(u16, v, 10) catch {
                log.err("invalid number for {s}: {s}", .{ a, v });
                return error.CliBadArg;
            };
        } else if (try takeRequired(&i, args, a, "--log-level", null)) |v| {
            opts.log_level = std.meta.stringToEnum(render.LogLevel, v) orelse {
                log.err("invalid log level: {s} (debug|info|warn|err)", .{v});
                return error.CliBadArg;
            };
        } else if (takeValue(&i, args, a, "--tproxy-port", null)) |v| {
            opts.tproxy_port = std.fmt.parseInt(u16, v, 10) catch {
                log.err("invalid number for {s}: {s}", .{ a, v });
                return error.CliBadArg;
            };
        } else if (takeValue(&i, args, a, "--mixed-port", null)) |v| {
            opts.mixed_port = std.fmt.parseInt(u16, v, 10) catch {
                log.err("invalid number for {s}: {s}", .{ a, v });
                return error.CliBadArg;
            };
        } else if (try takeRequired(&i, args, a, "--controller", null)) |v| {
            opts.controller = v;
        } else if (try takeRequired(&i, args, a, "--secret", null)) |v| {
            opts.secret = v;
        } else {
            log.err("unknown option: {s}", .{a});
            return error.CliBadArg;
        }
    }
    return .run;
}

/// parse a --url argument: optional [name=] prefix -> subscription name,
/// rest is the subscription url. (--node / .zon .nodes do NOT go through
/// here: they are raw node URIs without name prefixes, see addDirectNode)
pub fn parseUrlArg(arg: []const u8) !struct { name: ?[]const u8, url: []const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |i| {
        if (config.isValidName(arg[0..i])) return .{ .name = arg[0..i], .url = arg[i + 1 ..] };
    }
    return .{ .name = null, .url = arg };
}

/// parse -o/--output value: format[:template][=path]; path is required for
/// real runs (dry-run renders without writing, so it may be omitted). the
/// legacy stdout sentinel "-" is accepted for compatibility but folded into
/// "no path": the stdout mode is gone.
pub fn parseOutput(v: []const u8) !Output {
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
    const fmt = render.Format.parse(rest) orelse return error.CliBadArg;
    // empty and "-" are not real paths: the former is a slip, the latter was
    // the stdout sentinel of the removed stdout mode; fold both into no path
    // (real runs then report "output path required", dry-run verifies)
    if (path) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, "-")) path = null;
    }
    return .{ .fmt = fmt, .tmpl = template, .path = path };
}

/// value-taking argument: match --long value / --long=value / -s value and
/// reject an empty value ("--ua ''" and a missing argument are both errors).
/// null when the argument is not ours.
fn takeRequired(
    i: *usize,
    args: [][:0]u8,
    a: []const u8,
    long: []const u8,
    short: ?[]const u8,
) CliError!?[]const u8 {
    const v = takeValue(i, args, a, long, short) orelse return null;
    if (v.len == 0) {
        log.err("missing value for {s}", .{a});
        return error.CliBadArg;
    }
    return v;
}

/// match --long value / --long=value / -s value, return the value; null if no match.
pub fn takeValue(
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

pub fn printUsage() void {
    log.outPrint("subfetch {f} - subscription fetcher & multi-format config generator\n\nUsage: subfetch [options]\n", .{version});
    for (usage_sections) |sec| {
        log.outPrint("\n{s}:\n", .{sec.title});
        for (sec.options) |o| printUsageOpt(o);
    }
}

/// help entry: option text (no leading indent) + description lines.
/// pure data: all alignment/indent decisions live in printUsageOpt.
const Opt = struct { opt: []const u8, desc: []const []const u8 };
const Section = struct { title: []const u8, options: []const Opt };

/// help sections. descriptions start at column 26; options wider than 24
/// columns (indent included) go on their own line with the description
/// indented below - the renderer computes this, no hand-padded text.
const usage_sections = [_]Section{
    .{ .title = "Config", .options = &.{
        .{ .opt = "-c, --config <path>", .desc = &.{"configuration zon (default ./config.zon)"} },
    } },
    .{ .title = "Input", .options = &.{
        .{ .opt = "--url <[name=]url>", .desc = &.{
            "subscription url (repeatable; omit [name=] for anonymous)",
            "local file paths and file:// urls are read as files",
        } },
        .{ .opt = "--node <uri>", .desc = &.{"directly pasted node URI (repeatable)"} },
    } },
    .{ .title = "Output", .options = &.{
        .{ .opt = "-o, --output <fmt>[:<tmpl>]=<path>", .desc = &.{
            "output target (repeatable; required unless .outputs is set)",
            "fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw",
            "tmpl: custom template file (clash/singbox)",
            "path: output file or directory (required for real runs)",
        } },
    } },
    .{ .title = "Client config (built-in templates only)", .options = &.{
        .{ .opt = "--listen <addr>", .desc = &.{"socks5 listen address (default 127.0.0.1)"} },
        .{ .opt = "--port <n>", .desc = &.{"socks5 listen port (default 1080)"} },
        .{ .opt = "--mixed-port <n>", .desc = &.{"clash mixed-port (default 65500)"} },
        .{ .opt = "--controller <a:p>", .desc = &.{"API address (clash/sing-box; default 127.0.0.1:65501)"} },
        .{ .opt = "--secret <str>", .desc = &.{"API secret (auto-generated UUID if omitted)"} },
        .{ .opt = "--singbox-clash-api", .desc = &.{"add clash_api to sing-box output"} },
        .{ .opt = "--allow-lan", .desc = &.{"clash allow-lan"} },
        .{ .opt = "--tproxy-ipv6", .desc = &.{"v6 tproxy dual-stack (clash + sing-box)"} },
        .{ .opt = "--tproxy-port <n>", .desc = &.{"tproxy inbound port (clash + sing-box)"} },
        .{ .opt = "--log-level <level>", .desc = &.{"client log level: debug|info|warn|err (default info)"} },
    } },
    .{ .title = "Deploy", .options = &.{
        .{ .opt = "--no-verify", .desc = &.{"skip client verify command"} },
        .{ .opt = "--no-reload", .desc = &.{"skip reload after config install"} },
        .{ .opt = "--reload-cmd <cmd>", .desc = &.{"custom reload command (sh -c '<cmd>')"} },
    } },
    .{ .title = "Misc", .options = &.{
        .{ .opt = "--dry-run", .desc = &.{"verify only, write nothing"} },
        .{ .opt = "--ua <str>", .desc = &.{"User-Agent sent to subscription servers"} },
        .{ .opt = "--info-keyword <kw>", .desc = &.{
            "info-node keyword (repeatable; \"\" = no filtering)",
        } },
        .{ .opt = "--sep <str>", .desc = &.{"subscription/node name separator (default @)"} },
        .{ .opt = "--reset-state", .desc = &.{"delete the persisted API secret (regenerated on next run)"} },
        .{ .opt = "-v, --verbose", .desc = &.{"verbose output (node list)"} },
        .{ .opt = "-h, --help", .desc = &.{"show this help"} },
        .{ .opt = "-V, --version", .desc = &.{"show version"} },
    } },
};

/// render one help entry. short options ("-x, ...") get a 2-space indent,
/// long-only options 6 spaces; description lines start at column 26. options
/// wider than 24 columns (indent included) go on their own line.
fn printUsageOpt(o: Opt) void {
    const a = std.heap.page_allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    const w = buf.writer(a);
    const short = o.opt.len > 1 and o.opt[0] == '-' and o.opt[1] != '-';
    const opt_col = o.opt.len + (if (short) @as(usize, 2) else 6);
    if (opt_col > 26) {
        w.print("{s}{s}\n", .{ if (short) "  " else "      ", o.opt }) catch return;
    } else {
        w.print("{s}{s}", .{ if (short) "  " else "      ", o.opt }) catch return;
        var pad: usize = 28 - opt_col;
        while (pad > 0) : (pad -= 1) w.writeByte(' ') catch return;
    }
    for (o.desc, 0..) |l, i| {
        if (i > 0) {
            w.writeByte('\n') catch return;
            w.print("                            ", .{}) catch return;
        } else if (opt_col > 26) {
            w.print("                            ", .{}) catch return;
        }
        w.print("{s}", .{l}) catch return;
    }
    w.writeByte('\n') catch return;
    log.outPrint("{s}", .{buf.items});
}

test "parseOutput grammar" {
    // format only: no path (real runs require one; dry-run renders without writing)
    const o1 = try parseOutput("clash");
    try std.testing.expectEqual(render.Format.clash, o1.fmt);
    try std.testing.expect(o1.tmpl == null);
    try std.testing.expect(o1.path == null);
    // format + template
    const o2 = try parseOutput("clash:tmpl.yaml");
    try std.testing.expectEqual(render.Format.clash, o2.fmt);
    try std.testing.expectEqualStrings("tmpl.yaml", o2.tmpl.?);
    try std.testing.expect(o2.path == null);
    // format + path
    const o3 = try parseOutput("singbox=/etc/sing-box/config.json");
    try std.testing.expectEqual(render.Format.singbox, o3.fmt);
    try std.testing.expectEqualStrings("/etc/sing-box/config.json", o3.path.?);
    try std.testing.expect(o3.tmpl == null);
    // full: format + template + path
    const o4 = try parseOutput("clash:tmpl.yaml=out/c.yaml");
    try std.testing.expectEqual(render.Format.clash, o4.fmt);
    try std.testing.expectEqualStrings("tmpl.yaml", o4.tmpl.?);
    try std.testing.expectEqualStrings("out/c.yaml", o4.path.?);
    // legacy stdout sentinel folds into no path
    const o5 = try parseOutput("raw=-");
    try std.testing.expectEqual(render.Format.raw, o5.fmt);
    try std.testing.expect(o5.path == null);
    // empty path folds into no path too (a slip, not a target)
    const o7 = try parseOutput("clash=");
    try std.testing.expectEqual(render.Format.clash, o7.fmt);
    try std.testing.expect(o7.path == null);
    // unknown format errors
    try std.testing.expectError(error.CliBadArg, parseOutput("bogus"));
    try std.testing.expectError(error.CliBadArg, parseOutput(""));
    // extra '=' belongs to the path (first '=' splits path, then ':' splits template)
    const o6 = try parseOutput("clash:tmpl=path=extra");
    try std.testing.expectEqualStrings("tmpl", o6.tmpl.?);
    try std.testing.expectEqualStrings("path=extra", o6.path.?);
}

test "parseUrlArg name prefix" {
    // [name=] prefix: valid name -> split
    const p1 = try parseUrlArg("sg=ss://aes@host:8388#SG");
    try std.testing.expectEqualStrings("sg", p1.name.?);
    try std.testing.expectEqualStrings("ss://aes@host:8388#SG", p1.url);
    // no prefix -> anonymous
    const p2 = try parseUrlArg("trojan://pass@h:443#n");
    try std.testing.expect(p2.name == null);
    try std.testing.expectEqualStrings("trojan://pass@h:443#n", p2.url);
    // invalid name (contains chars not allowed) -> whole string treated as url
    const p3 = try parseUrlArg("bad name=ss://x");
    try std.testing.expect(p3.name == null);
    try std.testing.expectEqualStrings("bad name=ss://x", p3.url);
}

test "takeRequired rejects missing and empty values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "--ua" at end of argv -> missing value
    var args1 = [_][:0]u8{ try a.dupeZ(u8, "subfetch"), try a.dupeZ(u8, "--ua") };
    var idx1: usize = 1;
    try std.testing.expectError(error.CliBadArg, takeRequired(&idx1, &args1, args1[1], "--ua", null));

    // "--ua ''" -> empty value rejected
    var args2 = [_][:0]u8{ try a.dupeZ(u8, "subfetch"), try a.dupeZ(u8, "--ua"), try a.dupeZ(u8, "") };
    var idx2: usize = 1;
    try std.testing.expectError(error.CliBadArg, takeRequired(&idx2, &args2, args2[1], "--ua", null));

    // "--ua foo" -> value taken, index advanced
    var args3 = [_][:0]u8{ try a.dupeZ(u8, "subfetch"), try a.dupeZ(u8, "--ua"), try a.dupeZ(u8, "foo") };
    var idx3: usize = 1;
    const v3 = (try takeRequired(&idx3, &args3, args3[1], "--ua", null)).?;
    try std.testing.expectEqualStrings("foo", v3);
    try std.testing.expectEqual(@as(usize, 2), idx3);

    // "--ua=foo" equals form
    var args4 = [_][:0]u8{ try a.dupeZ(u8, "subfetch"), try a.dupeZ(u8, "--ua=foo") };
    var idx4: usize = 1;
    const v4 = (try takeRequired(&idx4, &args4, args4[1], "--ua", null)).?;
    try std.testing.expectEqualStrings("foo", v4);
}
