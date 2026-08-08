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

/// bundled libyaml (MIT): C sources are compiled directly into the module, @cImport consumes the headers.
fn addLibyaml(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(.{ .cwd_relative = "vendor/libyaml/include" });
    mod.addIncludePath(.{ .cwd_relative = "vendor/libyaml/src" });
    mod.addIncludePath(.{ .cwd_relative = "vendor/libyaml" });
    mod.addCSourceFiles(.{
        .files = libyaml_sources,
        // HAVE_CONFIG_H: use the static config.h (version macros); _GNU_SOURCE: strdup and other POSIX functions
        .flags = &.{ "-std=c99", "-DHAVE_CONFIG_H=1", "-D_GNU_SOURCE=1" },
    });
}

/// multi-target release matrix: triple + explicit cpu model (static, not the moving 'baseline' keyword)
const release_targets = [_]struct { triple: []const u8, cpu: []const u8 }{
    .{ .triple = "x86_64-linux-musl", .cpu = "x86_64" },
    .{ .triple = "aarch64-linux-musl", .cpu = "generic" },
    .{ .triple = "arm-linux-musleabi", .cpu = "generic+v6" },
    .{ .triple = "riscv64-linux-musl", .cpu = "baseline_rv64" },
    .{ .triple = "mipsel-linux-musleabi", .cpu = "mips32+soft_float" },
    .{ .triple = "mips-linux-musleabi", .cpu = "mips32+soft_float" },
    .{ .triple = "mips64el-linux-muslabi64", .cpu = "mips64" },
    .{ .triple = "mips64-linux-muslabi64", .cpu = "mips64" },
    .{ .triple = "loongarch64-linux-musl", .cpu = "loongarch64" },
};

/// qemu user-mode emulators with exact CPU models matching the -Dcpu above (for fixtures smoke test)
const smoke_qemu = [_]struct { triple: []const u8, qemu: []const u8, cpu: []const u8 }{
    .{ .triple = "aarch64-linux-musl", .qemu = "qemu-aarch64-static", .cpu = "cortex-a57" },
    .{ .triple = "arm-linux-musleabi", .qemu = "qemu-arm-static", .cpu = "arm1136" },
    .{ .triple = "riscv64-linux-musl", .qemu = "qemu-riscv64-static", .cpu = "thead-c906" },
    .{ .triple = "mipsel-linux-musleabi", .qemu = "qemu-mipsel-static", .cpu = "4Kc" },
    .{ .triple = "mips-linux-musleabi", .qemu = "qemu-mips-static", .cpu = "4Kc" },
    .{ .triple = "mips64el-linux-muslabi64", .qemu = "qemu-mips64el-static", .cpu = "5Kf" },
    .{ .triple = "mips64-linux-muslabi64", .qemu = "qemu-mips64-static", .cpu = "5Kf" },
    .{ .triple = "loongarch64-linux-musl", .qemu = "qemu-loongarch64-static", .cpu = "la464" },
};

fn createExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // strip DWARF in release builds: the zig riscv64 backend emits a bloated .debug_loc (31 MiB+),
        // and release artifacts do not need debug info; Debug mode keeps it for breakpoints
        .strip = (optimize != .Debug),
    });
    addLibyaml(exe_mod);
    return b.addExecutable(.{ .name = name, .root_module = exe_mod });
}

pub fn build(b: *std.Build) !void {
    // ===== conventional single-target path (same as any other zig project) =====
    // default to musl static linking (zero external deps, Zig ships its own libc); override with -Dtarget (e.g. RPi: aarch64-linux-musl)
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const exe = createExe(b, target, optimize, "subfetch");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "run subfetch");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addLibyaml(test_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);

    // ===== multi-target release: zig build release / release-test =====
    // cross-target run/test steps automatically execute under qemu (found on PATH),
    // the native x86_64 target runs directly
    b.enable_qemu = true;

    const release_step = b.step("release", "build all release targets (zig-out/bin/subfetch-<triple>)");
    var release_exes: [release_targets.len]*std.Build.Step.Compile = undefined;
    for (release_targets, &release_exes) |rt, *rel_exe| {
        const query = try std.Target.Query.parse(.{ .arch_os_abi = rt.triple, .cpu_features = rt.cpu });
        const rt_target = b.resolveTargetQuery(query);
        rel_exe.* = createExe(b, rt_target, optimize, b.fmt("subfetch-{s}", .{rt.triple}));
        // addInstallArtifact: installs to zig-out/bin/ without attaching to the default install step
        release_step.dependOn(&b.addInstallArtifact(rel_exe.*, .{}).step);
    }

    const release_test_step = b.step("release-test", "build + unit-test + fixtures smoke-test all release targets (qemu for cross)");
    release_test_step.dependOn(release_step);

    for (release_targets, release_exes) |rt, rel_exe| {
        // unit tests (zig test); cross targets run under qemu automatically
        const rt_test_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = rel_exe.root_module.resolved_target.?,
            .optimize = optimize,
        });
        addLibyaml(rt_test_mod);
        const rt_tests = b.addTest(.{ .root_module = rt_test_mod });
        const rt_run_tests = b.addRunArtifact(rt_tests);
        release_test_step.dependOn(&rt_run_tests.step);

        // fixtures smoke test with exact qemu -cpu models
        release_test_step.dependOn(smokeStep(b, rt.triple, rel_exe));
    }
}

const smoke_cases = [_]struct { fmt: []const u8, pattern: []const u8, allow_fail: bool }{
    .{ .fmt = "clash", .pattern = "OK:|done", .allow_fail = false },
    .{ .fmt = "singbox", .pattern = "done", .allow_fail = false },
    // xray: "dry-run verify passed" is best-effort (some subscriptions have no xray mapping)
    .{ .fmt = "xray", .pattern = "dry-run verify passed", .allow_fail = true },
};

/// fixtures smoke test: run the release binary against fixtures/subscriptions.zon for each
/// output format; cross targets run under qemu with an exact CPU model (see smoke_qemu).
fn smokeStep(
    b: *std.Build,
    triple: []const u8,
    exe: *std.Build.Step.Compile,
) *std.Build.Step {
    const smoke_step = b.step(b.fmt("smoke {s}", .{triple}), "fixtures smoke test");

    const qemu_entry = for (smoke_qemu) |qe| {
        if (std.mem.eql(u8, qe.triple, triple)) break qe;
    } else null;

    for (smoke_cases) |c| {
        const cmd = if (qemu_entry) |qe| blk: {
            // argv: bash -c SCRIPT qemu cpu fmt pattern EXE  =>  $0=qemu $1=cpu $2=fmt $3=pattern $4=exe
            const script = if (c.allow_fail)
                "set -o pipefail; \"$0\" -cpu \"$1\" \"$4\" --config fixtures/subscriptions.zon --out \"$2\" --dry-run | grep -E \"$3\" | tail -9 || true"
            else
                "set -o pipefail; \"$0\" -cpu \"$1\" \"$4\" --config fixtures/subscriptions.zon --out \"$2\" --dry-run | grep -E \"$3\" | tail -9";
            var run = b.addSystemCommand(&.{ "bash", "-c", script, qe.qemu, qe.cpu, c.fmt, c.pattern });
            run.addArtifactArg(exe);
            break :blk run;
        } else blk: {
            // argv: bash -c SCRIPT fmt pattern EXE  =>  $0=fmt $1=pattern $2=exe
            const script = if (c.allow_fail)
                "set -o pipefail; \"$2\" --config fixtures/subscriptions.zon --out \"$0\" --dry-run | grep -E \"$1\" | tail -9 || true"
            else
                "set -o pipefail; \"$2\" --config fixtures/subscriptions.zon --out \"$0\" --dry-run | grep -E \"$1\" | tail -9";
            var run = b.addSystemCommand(&.{ "bash", "-c", script, c.fmt, c.pattern });
            run.addArtifactArg(exe);
            break :blk run;
        };
        smoke_step.dependOn(&cmd.step);
    }
    return smoke_step;
}
