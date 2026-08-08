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
fn linkLibYaml(mod: *std.Build.Module) void {
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

fn createMod(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = (optimize != .Debug),
    });
    linkLibYaml(mod);
    return mod;
}

fn addSmokeTest(b: *std.Build, exe: *std.Build.Step.Compile, arg_out: []const u8, matrix: ?ReleaseMatrix) *std.Build.Step.Run {
    const name = if (matrix) |m| b.fmt("smoke-test-{s}", .{m.triple}) else "smoke-test";

    const smoke_test = std.Build.Step.Run.create(b, name);
    smoke_test.stdio = .inherit;
    smoke_test.producer = exe;

    if (matrix) |m| smoke_test.addArgs(&.{ m.qemu, "-cpu", m.qemu_cpu });
    smoke_test.addArtifactArg(exe);
    smoke_test.addArgs(&.{ "--config", "fixtures/subscriptions.zon", "-o", arg_out, "--dry-run" });

    return smoke_test;
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

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
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

    // smoke test: all 9 output formats (native multi-file formats run too)
    const smoke_test_step = b.step("smoke-test", "run smoke tests");
    for ([_][]const u8{ "clash", "singbox", "trojan", "hysteria", "hysteria2", "xray", "ss", "ssr", "raw" }) |fmt| {
        smoke_test_step.dependOn(&addSmokeTest(b, exe, fmt, null).step);
    }

    // release filter
    const release_filter_raw = b.option([]const u8, "release_filter", "only build/test release targets for this arch");
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

    const release_test_step = b.step("release-test", "unit-test & smoke-test for all release targets");
    release_test_step.dependOn(release_step);
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
        release_test_step.dependOn(&r_run_tests.step);

        // smoke test
        release_test_step.dependOn(&addSmokeTest(b, r_exe, "clash", r_matrix).step);
        release_test_step.dependOn(&addSmokeTest(b, r_exe, "singbox", r_matrix).step);
    }
}
