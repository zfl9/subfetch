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

pub fn build(b: *std.Build) void {
    // default to musl static linking (zero external deps, Zig ships its own libc); override with -Dtarget (e.g. RPi: aarch64-linux-musl)
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // strip DWARF in release builds: the zig riscv64 backend emits a bloated .debug_loc (31 MiB+),
        // and release artifacts do not need debug info; Debug mode keeps it for breakpoints
        .strip = (optimize != .Debug),
    });
    addLibyaml(exe_mod);

    const exe = b.addExecutable(.{
        .name = "subfetch",
        .root_module = exe_mod,
    });
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
}
