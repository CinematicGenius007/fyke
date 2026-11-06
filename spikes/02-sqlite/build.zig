const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const mod = b.createModule(.{
        .root_source_file = b.path("bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-DSQLITE_ENABLE_FTS5", "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=2", "-O3", "-fno-sanitize=undefined" },
    });
    b.installArtifact(b.addExecutable(.{ .name = "bench", .root_module = mod }));
}
