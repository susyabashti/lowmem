const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    // One module per architecture zone: core knows nothing of the CLI, and
    // cli never reaches into core's files by relative path (test/structure.py
    // enforces the layering; docs/map.md maps the graph).
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = mode,
    });
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli/cli.zig"),
        .target = target,
        .optimize = mode,
        .imports = &.{.{ .name = "core", .module = core_module }},
    });

    const exe = b.addExecutable(.{
        .name = "lowmem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "core", .module = core_module },
                .{ .name = "cli", .module = cli_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run lowmem");
    run_step.dependOn(&run_cmd.step);

    const fmt_step = b.addFmt(.{ .paths = b.pathList(&.{ "src", "build.zig" }) });
    b.step("fmt", "Run the formatter").dependOn(&fmt_step.step);
    const fmt_check = b.addFmt(.{
        .paths = b.pathList(&.{ "src", "build.zig" }),
        .check = true,
    });
    b.step("fmt-check", "Check formatting").dependOn(&fmt_check.step);

    // Test discovery is root-file only: one artifact per file that declares
    // tests, so a new file's tests are always run (see zig-gotchas #1).
    // Files that declare tests, one artifact each (zig build test runs all
    // of them). Add a file here when its tests are written; remove it when
    // a file loses its tests, so the list never names a missing file.
    const test_files = [_][]const u8{
        "src/core/blocks.zig",
        "src/core/cover.zig",
        "src/core/config.zig",
        "src/core/date.zig",
        "src/core/entry.zig",
        "src/core/ingest.zig",
        "src/core/nap.zig",
        "src/core/optmem.zig",
        "src/core/regex.zig",
        "src/core/store.zig",
        "src/core/text.zig",
        "src/cli/args.zig",
        "src/cli/context.zig",
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_files) |path| {
        const module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "core", .module = core_module }},
        });
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
