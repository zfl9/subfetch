const std = @import("std");
const config_mod = @import("config.zig");
const render_mod = @import("render.zig");
const log = @import("log.zig");

const build_options = @import("build_options");
const version = build_options.version;

/// one -o/--output target: format[:template][=path] (shared with .zon outputs)
const Output = config_mod.Output;

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
    /// positive flag: v6 tproxy dual-stack in built-in templates (default off)
    tproxy_ipv6: bool = false,
    /// tproxy inbound port (clash + singbox built-in templates; null = off)
    tproxy_port: ?u16 = null,
    /// client log level (built-in templates; null = info)
    log_level: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--reset-state")) {
            opts.reset_state = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = 1;
        } else if (std.mem.eql(u8, a, "-v")) {
            // -v/--verbose: single verbose level (node list, api secret). -vv/-vvv
            // were removed: their old stdout semantics were replaced by -o fmt=-,
            // and no deeper verbose level exists (strict parsing, no -verbose)
            opts.verbose = 1;
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
        } else if (takeValue(&i, args, a, "--reload-cmd", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.reload_cmd = v;
        } else if (takeValue(&i, args, a, "--config", "-c")) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.config = v;
        } else if (takeValue(&i, args, a, "--output", "-o")) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            const out = parseOutput(v) catch {
                log.logErr(null, "invalid output target: {s} (fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw)", .{v});
                return error.BadArg;
            };
            try opts.outputs.append(arena, out);
        } else if (takeValue(&i, args, a, "--node", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            try opts.nodes.append(arena, v);
        } else if (takeValue(&i, args, a, "--node-file", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            try opts.node_files.append(arena, v);
        } else if (takeValue(&i, args, a, "--url", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
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
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.sep = v;
        } else if (takeValue(&i, args, a, "--timeout", null)) |v| {
            opts.timeout = std.fmt.parseInt(u32, v, 10) catch {
                log.logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--listen", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.listen = v;
        } else if (takeValue(&i, args, a, "--port", null)) |v| {
            opts.port = std.fmt.parseInt(u16, v, 10) catch {
                log.logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--log-level", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.log_level = v;
        } else if (takeValue(&i, args, a, "--tproxy-port", null)) |v| {
            opts.tproxy_port = std.fmt.parseInt(u16, v, 10) catch {
                log.logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--mixed-port", null)) |v| {
            opts.mixed_port = std.fmt.parseInt(u16, v, 10) catch {
                log.logErr(null, "invalid number for {s}: {s}", .{ a, v });
                return error.BadArg;
            };
        } else if (takeValue(&i, args, a, "--controller", null)) |v| {
            if (v.len == 0) {
                log.logErr(null, "missing value for {s}", .{a});
                return error.BadArg;
            }
            opts.controller = v;
        } else if (takeValue(&i, args, a, "--secret", null)) |v| {
            opts.secret = v;
        } else {
            log.logErr(null, "unknown argument: {s}", .{a});
            return error.BadArg;
        }
    }
}

/// add a directly-pasted node URI (--node / .zon .nodes): no sniff, no info filtering, no prefix
pub fn parseUrlArg(arg: []const u8) !struct { name: ?[]const u8, url: []const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |i| {
        if (config_mod.isValidName(arg[0..i])) return .{ .name = arg[0..i], .url = arg[i + 1 ..] };
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
    const fmt = render_mod.Format.parse(rest) orelse return error.BadArg;
    return .{ .fmt = fmt, .tmpl = template, .path = path };
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
    log.outPrint(
        \\subfetch {f} - subscription fetcher & multi-format config generator
        \\
        \\Usage: subfetch [options]
        \\
        \\Options:
        \\  -c, --config <path>     configuration zon (default ./config.zon)
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
        \\      --timeout <sec>    per-subscription fetch timeout in seconds (default 15)
        \\
        \\Output config:
        \\      --listen <addr>    native client listen address (default 127.0.0.1)
        \\      --port <n>         native client listen port (default 1080)
        \\      --mixed-port <n>   clash mixed-port (default 65500)
        \\      --controller <a:p> clash/singbox external-controller (default 127.0.0.1:65501)
        \\      --secret <str>     API secret (auto-generated UUID if omitted)
        \\      --singbox-clash-api add clash_api to sing-box output (default off)
        \\      --allow-lan        clash allow-lan in built-in template (default off)
        \\      --tproxy-ipv6     v6 tproxy dual-stack in built-in templates:
        \\                          clash ipv6 flag + sing-box tproxy-in-v6
        \\                          inbound (default off)
        \\      --tproxy-port <n>  tproxy inbound port (clash + sing-box built-in
        \\                          templates; socks inbound stays; default off)
        \\      --log-level <lvl>  client log level: debug|info|warning|error
        \\                          (built-in templates; default info)
        \\
        \\Deploy:
        \\      --no-verify        skip verification
        \\      --no-reload        skip reload after install
        \\      --reload-cmd <cmd> custom reload command after install (sh -c, overrides auto reload; acme.sh style)
        \\
        \\Misc:
        \\      --reset-state     delete the persisted api secret (state dir
        \\                        $XDG_STATE_HOME or ~/.local/state/subfetch);
        \\                        next run generates a fresh one (lock file kept)
        \\  -v, --verbose          verbose output (node list)
        \\  -h, --help             show this help
        \\
    , .{version});
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
