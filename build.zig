const std = @import("std");
const builtin = @import("builtin");

// Zig breaks its API frequently between versions: pin exactly 0.15.2, fail at compile time otherwise
comptime {
    const v = builtin.zig_version;
    const ok = v.major == 0 and v.minor == 15 and v.patch == 2;
    if (!ok) {
        @compileError("subfetch requires exactly Zig 0.15.2 (Zig breaks its API between versions); current version is " ++ v.toString());
    }
}

const libyaml_sources = &.{
    "vendor/libyaml/src/api.c",
    "vendor/libyaml/src/reader.c",
    "vendor/libyaml/src/scanner.c",
    "vendor/libyaml/src/parser.c",
    "vendor/libyaml/src/loader.c",
    "vendor/libyaml/src/writer.c",
    "vendor/libyaml/src/emitter.c",
    "vendor/libyaml/src/dumper.c",
};

/// single source of truth for the version: build.zig.zon (zon is valid Zig source, importable directly)
const app_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

/// bundled libyaml (MIT): C sources are compiled directly into the module, @cImport consumes the headers.
/// single include path: yaml.h (public header) and config.h (moved from the
/// repo root) both live in include/; yaml_private.h resolves via same-dir quotes.
fn linkLibYaml(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor/libyaml/include"));
    mod.addCSourceFiles(.{
        .files = libyaml_sources,
        // version macros inlined into yaml_private.h (no config.h); _GNU_SOURCE: strdup and other POSIX functions
        .flags = &.{ "-std=c99", "-D_GNU_SOURCE=1" },
    });
}

fn createMod(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", app_version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = (optimize != .Debug),
    });
    mod.addOptions("build_options", build_options);
    linkLibYaml(b, mod);
    return mod;
}

fn addSmokeTest(b: *std.Build, exe: *std.Build.Step.Compile, arg_output: []const u8, matrix: ?ReleaseMatrix, prev: ?*std.Build.Step.Run) *std.Build.Step.Run {
    const name = if (matrix) |m| b.fmt("smoke {s}", .{m.triple}) else "smoke";

    // visible separator before each run: subscription output is identical across
    // formats, only the trailing summary line differs. chained after prev so
    // parallel builds keep the runs ordered
    const sep = b.addSystemCommand(&.{ "echo", b.fmt("=== smoke {s} ===", .{arg_output}) });
    sep.stdio = .inherit;
    if (prev) |p| sep.step.dependOn(&p.step);

    const smoke_test = std.Build.Step.Run.create(b, name);
    smoke_test.stdio = .inherit;
    smoke_test.producer = exe;

    if (matrix) |m| smoke_test.addArgs(&.{ m.qemu, "-cpu", m.qemu_cpu });
    smoke_test.addArtifactArg(exe);
    smoke_test.addArgs(&.{ "-c", "fixtures/config.zon", "-o", arg_output, "--dry-run" });

    smoke_test.step.dependOn(&sep.step);
    return smoke_test;
}

/// all output formats: aggregate first (clash/singbox cover all 8 protocols and
/// both serializer paths - yaml + json), then per-node native formats
const all_formats = [_][]const u8{
    "clash", "singbox", "trojan", "hysteria", "hysteria2", "xray", "ss", "ssr", "raw",
};

/// chain all format smoke runs serially (shared separator keeps the output
/// ordered); returns the last run so callers can chain follow-up steps.
fn addAllSmokeTests(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    matrix: ?ReleaseMatrix,
    prev: ?*std.Build.Step.Run,
) *std.Build.Step.Run {
    var last = prev;
    for (all_formats) |fmt| {
        last = addSmokeTest(b, exe, fmt, matrix, last);
    }
    return last.?;
}

const ReleaseMatrix = struct {
    triple: []const u8,
    cpu: []const u8,
    qemu: []const u8,
    qemu_cpu: []const u8,
};

/// multi-target release matrix: triple + explicit cpu model (static, not the moving 'baseline' keyword)
const release_matrix = [_]ReleaseMatrix{
    .{ .triple = "x86_64-linux-musl", .cpu = "x86_64", .qemu = "qemu-x86_64-static", .qemu_cpu = "kvm64" },
    .{ .triple = "aarch64-linux-musl", .cpu = "generic", .qemu = "qemu-aarch64-static", .qemu_cpu = "cortex-a57" },
    .{ .triple = "arm-linux-musleabi", .cpu = "generic+v6", .qemu = "qemu-arm-static", .qemu_cpu = "arm1136" },
    .{ .triple = "mips-linux-musleabi", .cpu = "mips32+soft_float", .qemu = "qemu-mips-static", .qemu_cpu = "4Kc" },
    .{ .triple = "mipsel-linux-musleabi", .cpu = "mips32+soft_float", .qemu = "qemu-mipsel-static", .qemu_cpu = "4Kc" },
    .{ .triple = "mips64-linux-muslabi64", .cpu = "mips64", .qemu = "qemu-mips64-static", .qemu_cpu = "5Kf" },
    .{ .triple = "mips64el-linux-muslabi64", .cpu = "mips64", .qemu = "qemu-mips64el-static", .qemu_cpu = "5Kf" },
    .{ .triple = "riscv64-linux-musl", .cpu = "baseline_rv64", .qemu = "qemu-riscv64-static", .qemu_cpu = "thead-c906" },
};

/// Linux hosts default to musl (zig-bundled libc; host glibc/gcc is often too new for zig's linker, e.g. gcc16 .sframe); non-Linux hosts keep native; -Dtarget always overrides.
const default_target: std.Target.Query = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    // build exe
    const exe = b.addExecutable(.{
        .name = "subfetch",
        .root_module = createMod(b, target, optimize),
    });
    b.installArtifact(exe);

    // run exe
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "run subfetch").dependOn(&run_exe.step);

    // unit test
    const tests = b.addTest(.{
        .root_module = createMod(b, target, optimize),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "run unit tests").dependOn(&run_tests.step);

    // smoke: all output formats (native multi-file formats run too).
    // chained serially: the runs share identical output and the separator
    // lines must stay ordered
    const smoke_step = b.step("smoke", "run smoke tests");
    const last_smoke = addAllSmokeTests(b, exe, null, null);
    smoke_step.dependOn(&last_smoke.step);

    // integration suites: real processes/fs/locks - install path (first install
    // -> unchanged skip -> partial rewrite), exit-code semantics + reset-state,
    // and flock concurrency. isolated dirs + --no-reload + isolated XDG_STATE_HOME:
    // never touches real configs, services, or state. native host only (CI's
    // cross-arch release-check depends on addSmokeTest directly, unaffected).
    // suites are data + a single step: run all by default, or filter with
    // -Dintegration_filter=<substring> (same pattern as -Drelease_filter).
    const integration_suites = [_]struct {
        name: []const u8,
        script: []const u8,
        dir: []const u8,
    }{
        .{ .name = "install", .script = "test/integration_install.sh", .dir = ".zig-cache/integration-install" },
        .{ .name = "exitcodes", .script = "test/integration_exitcodes.sh", .dir = ".zig-cache/integration-exitcodes" },
        .{ .name = "lock", .script = "test/integration_lock.sh", .dir = ".zig-cache/integration-lock" },
    };
    const integration_filter = b.option([]const u8, "integration_filter",
        "only run integration suites whose name contains this substring");
    const integration_step = b.step("integration", "run integration test suites");
    var integration_matched = false;
    var prev_install: ?*std.Build.Step.Run = null;
    for (integration_suites) |suite| {
        if (integration_filter) |f| {
            if (std.mem.indexOf(u8, suite.name, f) == null) continue;
            integration_matched = true;
        }
        const run = b.addSystemCommand(&.{ "sh", suite.script });
        run.addArtifactArg(exe);
        run.addArg(b.pathFromRoot(suite.dir));
        run.stdio = .inherit;
        // suites run serially (shared exe, ordered output); they do NOT
        // depend on the smoke step: smoke and integration are independent
        // entry points (the exe artifact is built via producer)
        if (prev_install) |p| run.step.dependOn(&p.step);
        prev_install = run;
        integration_step.dependOn(&run.step);
    }
    if (integration_filter != null and !integration_matched) {
        @panic("integration_filter matches no suite (install|exitcodes|lock)");
    }

    // release filter
    const release_filter_raw = b.option([]const u8, "release_filter", "only build/check release targets for this arch");
    const release_filter = if (release_filter_raw) |filter| b.fmt("{s}-", .{filter}) else null;

    const release_step = b.step("release", "build exe for all release targets");
    var release_exes: [release_matrix.len]*std.Build.Step.Compile = undefined;
    for (release_matrix, &release_exes) |r_matrix, *r_exe| {
        if (release_filter) |filter| if (!std.mem.startsWith(u8, r_matrix.triple, filter)) continue;
        const r_target = b.resolveTargetQuery(try std.Target.Query.parse(.{
            .arch_os_abi = r_matrix.triple,
            .cpu_features = r_matrix.cpu,
        }));
        r_exe.* = b.addExecutable(.{
            .name = b.fmt("subfetch-{s}", .{r_matrix.triple}),
            .root_module = createMod(b, r_target, optimize),
        });
        const r_install = b.addInstallArtifact(r_exe.*, .{});
        release_step.dependOn(&r_install.step);
    }

    const release_check_step = b.step("release-check", "unit tests + smokes for all release targets");
    release_check_step.dependOn(release_step);
    for (release_matrix, release_exes) |r_matrix, r_exe| {
        if (release_filter) |filter| if (!std.mem.startsWith(u8, r_matrix.triple, filter)) continue;
        // unit test
        const r_target = r_exe.root_module.resolved_target.?;
        const r_tests = b.addTest(.{
            .root_module = createMod(b, r_target, optimize),
        });
        const r_run_tests = b.addSystemCommand(&.{
            r_matrix.qemu,
            "-cpu",
            r_matrix.qemu_cpu,
        });
        r_run_tests.addArtifactArg(r_tests);
        r_run_tests.setName(b.fmt("unit-test {s}", .{r_matrix.triple}));
        r_run_tests.producer = r_tests;
        r_run_tests.stdio = .inherit;
        release_check_step.dependOn(&r_run_tests.step);

        // smoke: all formats (full protocol + serializer coverage per arch)
        release_check_step.dependOn(&addAllSmokeTests(b, r_exe, r_matrix, null).step);
    }
}
