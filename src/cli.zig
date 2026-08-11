const std = @import("std");
const config = @import("config.zig");
const render = @import("render.zig");
const log = @import("log.zig");

const build_options = @import("build_options");
const version = build_options.version;

/// one -o/--output target: format[:template][=path] (shared with .zon outputs)
const Output = config.Output;

pub const Options = struct {
    config: []const u8 = "config.zon",
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    dry_run: bool = false,
    /// --reset-state: drop the persisted api secret (next run generates a fresh one)
    reset_state: bool = false,
    ua: ?[]const u8 = null,
    /// node name separator; null = .zon sep or default "@"
    sep: ?[]const u8 = null,
    timeout: ?u32 = null,
    /// -v/--verbose: node list + api secret (no deeper levels)
    verbose: bool = false,
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

pub const CliError = error{ BadArg, OutOfMemory };
pub fn parseArgs(arena: std.mem.Allocator, args: [][:0]u8, opts: *Options) CliError!void {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--version")) {
            log.outPrint("subfetch {f}\n", .{version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--reset-state")) {
            opts.reset_state = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            // -v/--verbose: single verbose level (node list, api secret). -vv/-vvv
            // were removed: their old stdout semantics were replaced by -o fmt=-,
            // and no deeper verbose level exists (strict parsing, no -verbose)
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
                log.err(null, "invalid output target: {s} (fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw)", .{v});
                return error.BadArg;
            };
            try opts.outputs.append(arena, out);
        } else if (try takeRequired(&i, args, a, "--node", null)) |v| {
            try opts.nodes.append(arena, v);
        } else if (try takeRequired(&i, args, a, "--node-file", null)) |v| {
            try opts.node_files.append(arena, v);
        } else if (try takeRequired(&i, args, a, "--url", null)) |v| {
            try opts.urls.append(arena, v);
        } else if (takeValue(&i, args, a, "--info-keyword", null)) |v| {
            // empty value allowed: "" clears all keywords (disables filtering)
            try opts.info_keywords.append(arena, v);
        } else if (try takeRequired(&i, args, a, "--ua", null)) |v| {
            opts.ua = v;
        } else if (try takeRequired(&i, args, a, "--sep", null)) |v| {
            opts.sep = v;
        } else if (takeValue(&i, args, a, "--timeout", null)) |v| {
            opts.timeout = std.fmt.parseInt(u32, v, 10) catch {
                log.err(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (try takeRequired(&i, args, a, "--listen", null)) |v| {
            opts.listen = v;
        } else if (takeValue(&i, args, a, "--port", null)) |v| {
            opts.port = std.fmt.parseInt(u16, v, 10) catch {
                log.err(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (try takeRequired(&i, args, a, "--log-level", null)) |v| {
            opts.log_level = std.meta.stringToEnum(render.LogLevel, v) orelse {
                log.err(null, "invalid log level: {s} (debug|info|warn|err)", .{v});
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--tproxy-port", null)) |v| {
            opts.tproxy_port = std.fmt.parseInt(u16, v, 10) catch {
                log.err(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--mixed-port", null)) |v| {
            opts.mixed_port = std.fmt.parseInt(u16, v, 10) catch {
                log.err(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (try takeRequired(&i, args, a, "--controller", null)) |v| {
            opts.controller = v;
        } else if (try takeRequired(&i, args, a, "--secret", null)) |v| {
            opts.secret = v;
        } else {
            log.err(null, "unknown argument: {s}", .{a});
            return error.BadArg;
        }
    }
}

/// add a directly-pasted node URI (--node / .zon .nodes): no sniff, no info filtering, no prefix
pub fn parseUrlArg(arg: []const u8) !struct { name: ?[]const u8, url: []const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |i| {
        if (config.isValidName(arg[0..i])) return .{ .name = arg[0..i], .url = arg[i + 1 ..] };
    }
    return .{ .name = null, .url = arg };
}

/// parse -o/--output value: format[:template][=path]
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
    const fmt = render.Format.parse(rest) orelse return error.BadArg;
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
        log.err(null, "missing value for {s}", .{a});
        return error.BadArg;
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
    .{ .title = "Options", .options = &.{
        .{ .opt = "-c, --config <path>", .desc = &.{"configuration zon (default ./config.zon)"} },
    } },
    .{ .title = "Output targets", .options = &.{
        .{ .opt = "-o, --output <fmt>[:<tmpl>][=<path>]", .desc = &.{
            "output target (repeatable; default raw)",
            "fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw",
            "tmpl: template file (clash/singbox; optional)",
            "path: output file (single-file) or directory (native); '-' = stdout",
        } },
    } },
    .{ .title = "Input sources", .options = &.{
        .{ .opt = "--url <url>", .desc = &.{
            "subscription url (repeatable; [name=] prefix names the",
            "subscription, same semantics as .zon; omit for anonymous)",
        } },
        .{ .opt = "--node <uri>", .desc = &.{"directly pasted node URI (repeatable)"} },
        .{ .opt = "--node-file <path>", .desc = &.{"node list file (one URI per line)"} },
    } },
    .{ .title = "Filtering & naming", .options = &.{
        .{ .opt = "--info-keyword <kw>", .desc = &.{
            "info-node keyword override (repeatable; \"\" clears all,",
            "i.e. disables filtering; overrides .zon info_keywords)",
        } },
        .{ .opt = "--sep <str>", .desc = &.{"node name separator between sub and node names (default @)"} },
    } },
    .{ .title = "Run behavior", .options = &.{
        .{ .opt = "--dry-run", .desc = &.{"verify only, write nothing"} },
        .{ .opt = "--ua <str>", .desc = &.{"default User-Agent"} },
        .{ .opt = "--timeout <sec>", .desc = &.{"per-subscription fetch timeout in seconds (default 5)"} },
    } },
    .{ .title = "Output config", .options = &.{
        .{ .opt = "--listen <addr>", .desc = &.{"native client listen address (default 127.0.0.1)"} },
        .{ .opt = "--port <n>", .desc = &.{"native client listen port (default 1080)"} },
        .{ .opt = "--mixed-port <n>", .desc = &.{"clash mixed-port (default 65500)"} },
        .{ .opt = "--controller <a:p>", .desc = &.{"clash/singbox external-controller (default 127.0.0.1:65501)"} },
        .{ .opt = "--secret <str>", .desc = &.{"API secret (auto-generated UUID if omitted)"} },
        .{ .opt = "--singbox-clash-api", .desc = &.{"add clash_api to sing-box output (default off)"} },
        .{ .opt = "--allow-lan", .desc = &.{"clash allow-lan in built-in template (default off)"} },
        .{ .opt = "--tproxy-ipv6", .desc = &.{
            "v6 tproxy dual-stack in built-in templates:",
            "clash ipv6 flag + sing-box tproxy-in-v6",
            "inbound (default off)",
        } },
        .{ .opt = "--tproxy-port <n>", .desc = &.{
            "tproxy inbound port (clash + sing-box built-in",
            "templates; socks inbound stays; default off)",
        } },
        .{ .opt = "--log-level <level>", .desc = &.{
            "client log level: debug|info|warn|err",
            "(built-in templates; default info)",
        } },
    } },
    .{ .title = "Deploy", .options = &.{
        .{ .opt = "--no-verify", .desc = &.{"skip verification"} },
        .{ .opt = "--no-reload", .desc = &.{"skip reload after install"} },
        .{ .opt = "--reload-cmd <cmd>", .desc = &.{
            "custom reload command after install (sh -c, overrides",
            "auto reload; acme.sh style)",
        } },
    } },
    .{ .title = "Misc", .options = &.{
        .{ .opt = "--reset-state", .desc = &.{
            "delete the persisted api secret (state dir",
            "$XDG_STATE_HOME or ~/.local/state/subfetch);",
            "next run generates a fresh one (lock file kept)",
        } },
        .{ .opt = "-v, --verbose", .desc = &.{"verbose output (node list)"} },
        .{ .opt = "-h, --help", .desc = &.{"show this help"} },
        .{ .opt = "--version", .desc = &.{"show version"} },
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
    if (opt_col > 24) {
        w.print("{s}{s}\n", .{ if (short) "  " else "      ", o.opt }) catch return;
    } else {
        w.print("{s}{s}", .{ if (short) "  " else "      ", o.opt }) catch return;
        var pad: usize = 26 - opt_col;
        while (pad > 0) : (pad -= 1) w.writeByte(' ') catch return;
    }
    for (o.desc, 0..) |l, i| {
        if (i > 0) {
            w.writeByte('\n') catch return;
            w.print("                          ", .{}) catch return;
        } else if (opt_col > 24) {
            w.print("                          ", .{}) catch return;
        }
        w.print("{s}", .{l}) catch return;
    }
    w.writeByte('\n') catch return;
    log.outPrint("{s}", .{buf.items});
}

test "parseOutput grammar" {
    // format only
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
    // stdout path
    const o5 = try parseOutput("raw=-");
    try std.testing.expectEqual(render.Format.raw, o5.fmt);
    try std.testing.expectEqualStrings("-", o5.path.?);
    // unknown format errors
    try std.testing.expectError(error.BadArg, parseOutput("bogus"));
    try std.testing.expectError(error.BadArg, parseOutput(""));
    // extra '=' belongs to the path (first '=' splits path, then ':' splits template)
    const o6 = try parseOutput("clash:tmpl=path=extra");
    try std.testing.expectEqualStrings("tmpl", o6.tmpl.?);
    try std.testing.expectEqualStrings("path=extra", o6.path.?);
}
