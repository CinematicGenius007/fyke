//! `fyke daemon --supervise`: keeps the daemon running after a crash, as launchd and
//! systemd do on macOS and Linux. Windows has no per-user service manager, so the `Run`
//! key starts this instead of the daemon itself (`windows_startup.zig`).
//!
//! It runs the daemon as its child and waits. A clean exit (`fyke daemon stop`, a data
//! move) ends supervision, as does finding another daemon already on the folder: that one
//! has an owner. Any other end is a crash, and the daemon starts again after a delay that
//! doubles with each quick crash, so a daemon that cannot start does not spin.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const Io = std.Io;

/// The exit code of a daemon that found another one holding the folder's lock.
pub const exit_already_running: u8 = 3;

pub const Exit = enum { clean, already_running, crashed };

pub fn classify(term: std.process.Child.Term) Exit {
    return switch (term) {
        .exited => |code| if (code == 0) .clean else if (code == exit_already_running) .already_running else .crashed,
        else => .crashed,
    };
}

pub const Policy = struct {
    first_delay_ms: i64 = 1_000,
    longest_delay_ms: i64 = 60_000,
    /// A daemon that ran this long was healthy, and its crash starts the delays over.
    healthy_ms: i64 = 60_000,
    /// Quick crashes in a row before supervision gives up: something is wrong that a
    /// restart will not fix, and the next client will say what.
    most_quick_crashes: u32 = 10,
};

pub const State = struct {
    delay_ms: i64 = 0,
    quick_crashes: u32 = 0,
};

pub const Decision = union(enum) {
    stop,
    restart_after_ms: i64,
};

/// What to do after the daemon ended with `exit` having run for `ran_ms`.
pub fn next(policy: Policy, state: *State, exit: Exit, ran_ms: i64) Decision {
    if (exit != .crashed) return .stop;
    if (ran_ms >= policy.healthy_ms) state.* = .{};
    state.quick_crashes += 1;
    if (state.quick_crashes > policy.most_quick_crashes) return .stop;
    state.delay_ms = if (state.delay_ms == 0)
        policy.first_delay_ms
    else
        @min(state.delay_ms * 2, policy.longest_delay_ms);
    return .{ .restart_after_ms = state.delay_ms };
}

pub fn run(io: Io, arena: std.mem.Allocator, home_path: []const u8, log: bool) !void {
    platform.leaveConsole();
    platform.keepStdHandlesFromChildren();
    const self = try std.process.executablePathAlloc(io, arena);
    const argv: []const []const u8 = if (log)
        &.{ self, "daemon", "--log", "--home", home_path }
    else
        &.{ self, "daemon", "--home", home_path };

    const policy: Policy = .{};
    var state: State = .{};
    while (true) {
        const started = Io.Clock.awake.now(io).toMilliseconds();
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });
        const term = try child.wait(io);
        const ran = Io.Clock.awake.now(io).toMilliseconds() - started;
        switch (next(policy, &state, classify(term), ran)) {
            .stop => return,
            .restart_after_ms => |ms| try io.sleep(.fromMilliseconds(ms), .awake),
        }
    }
}

test "a clean stop or another owner ends supervision" {
    var state: State = .{};
    try std.testing.expectEqual(Decision.stop, next(.{}, &state, .clean, 10));
    try std.testing.expectEqual(Decision.stop, next(.{}, &state, .already_running, 10));
}

test "quick crashes wait longer each time, up to a limit, then give up" {
    const policy: Policy = .{ .first_delay_ms = 1_000, .longest_delay_ms = 4_000, .most_quick_crashes = 4 };
    var state: State = .{};
    try std.testing.expectEqual(Decision{ .restart_after_ms = 1_000 }, next(policy, &state, .crashed, 10));
    try std.testing.expectEqual(Decision{ .restart_after_ms = 2_000 }, next(policy, &state, .crashed, 10));
    try std.testing.expectEqual(Decision{ .restart_after_ms = 4_000 }, next(policy, &state, .crashed, 10));
    try std.testing.expectEqual(Decision{ .restart_after_ms = 4_000 }, next(policy, &state, .crashed, 10));
    try std.testing.expectEqual(Decision.stop, next(policy, &state, .crashed, 10));
}

test "a crash after a healthy run starts the delays over" {
    const policy: Policy = .{};
    var state: State = .{ .delay_ms = 32_000, .quick_crashes = 6 };
    try std.testing.expectEqual(Decision{ .restart_after_ms = 1_000 }, next(policy, &state, .crashed, policy.healthy_ms));
    try std.testing.expectEqual(@as(u32, 1), state.quick_crashes);
}

test "exit codes read as clean, owned elsewhere or crashed" {
    try std.testing.expectEqual(Exit.clean, classify(.{ .exited = 0 }));
    try std.testing.expectEqual(Exit.already_running, classify(.{ .exited = exit_already_running }));
    try std.testing.expectEqual(Exit.crashed, classify(.{ .exited = 1 }));
    try std.testing.expectEqual(Exit.crashed, classify(.{ .unknown = 0xC0000005 }));
}
