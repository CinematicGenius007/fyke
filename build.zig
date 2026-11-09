const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "core", .module = core }},
    });
    app.addAnonymousImport("schema", .{ .root_source_file = b.path("schema/0001_init.sql") });
    app.addAnonymousImport("schema2", .{ .root_source_file = b.path("schema/0002_full_text.sql") });
    app.addAnonymousImport("schema3", .{ .root_source_file = b.path("schema/0003_skip_hints.sql") });
    app.addAnonymousImport("schema4", .{ .root_source_file = b.path("schema/0004_raw_index.sql") });
    app.addAnonymousImport("schema5", .{ .root_source_file = b.path("schema/0005_full_text_retries.sql") });
    app.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_ENABLE_FTS5", "-DSQLITE_ENABLE_DBSTAT_VTAB", "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=2", "-O3", "-fno-sanitize=undefined" },
    });

    b.installArtifact(b.addExecutable(.{ .name = "fyke", .root_module = app }));

    const feedcheck = b.addExecutable(.{
        .name = "feedcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/feedcheck.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "core", .module = core }},
        }),
    });
    b.installArtifact(feedcheck);

    const test_step = b.step("test", "Run unit and fuzz tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app })).step);
}
