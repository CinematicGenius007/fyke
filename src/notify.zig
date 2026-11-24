//! Notifications from routines when no window is open.
//!
//! A routine's notify action writes a `routine.notify` event. A running app that
//! subscribes with `notifies: true` posts the notification itself, and the daemon notes
//! each such event it delivered to one. If none took the event within a short wait, the
//! daemon starts the app in a mode that posts one notification and exits:
//! `Fyke.App.exe --notify` beside `fyke.exe` on Windows, `fyke-app --notify` beside
//! `fyke` on Linux, and the bundle that holds the daemon, through `open`, on macOS. Clicking the notification opens Fyke.
//!
//! Only an app that is installed with the daemon is started, so a daemon built for
//! development or run by a test starts nothing. `FYKE_HEADLESS` turns this off, and
//! `FYKE_NOTIFIER` names another program, which tests use to see the call.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const service = @import("service.zig");

const Io = std.Io;

pub const event_type = "routine.notify";

/// How long a running app has to take the event before the daemon posts it.
const claim_wait_ms = 2_000;
/// Events this close together post once, as `RoutineNotices` does in the app.
const quiet_ms = 10_000;

pub const Os = enum { windows, macos, linux, other };

/// The command that posts one notification for the daemon at `self`, or null when no
/// app is installed with it. `exists` answers whether a file is there.
pub fn command(
    arena: std.mem.Allocator,
    os: Os,
    self: []const u8,
    override: ?[]const u8,
    context: anytype,
    comptime exists: fn (@TypeOf(context), []const u8) bool,
) !?[]const []const u8 {
    if (override) |program| {
        if (program.len == 0) return null;
        return try arena.dupe([]const u8, &.{ program, "--notify" });
    }
    switch (os) {
        .windows => {
            const dir = std.fs.path.dirnameWindows(self) orelse return null;
            const app = try std.fmt.allocPrint(arena, "{s}\\Fyke.App.exe", .{dir});
            if (!exists(context, app)) return null;
            return try arena.dupe([]const u8, &.{ app, "--notify" });
        },
        .linux => {
            const dir = std.fs.path.dirnamePosix(self) orelse return null;
            const app = try std.fmt.allocPrint(arena, "{s}/fyke-app", .{dir});
            if (!exists(context, app)) return null;
            return try arena.dupe([]const u8, &.{ app, "--notify" });
        },
        .macos => {
            const bundle = bundleOf(self) orelse return null;
            // A new instance, in the background and hidden, so that it neither takes
            // focus nor opens a window, and posts even if a stuck copy is running.
            return try arena.dupe([]const u8, &.{ "/usr/bin/open", "-n", "-g", "-j", bundle, "--args", "--notify" });
        },
        .other => return null,
    }
}

/// The app bundle that holds a daemon at `Something.app/Contents/MacOS/fyke`.
pub fn bundleOf(self: []const u8) ?[]const u8 {
    const macos = std.fs.path.dirnamePosix(self) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basenamePosix(macos), "MacOS")) return null;
    const contents = std.fs.path.dirnamePosix(macos) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basenamePosix(contents), "Contents")) return null;
    const bundle = std.fs.path.dirnamePosix(contents) orelse return null;
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return bundle;
}

/// Called by a subscriber that asked to post notifications, once it has sent events up
/// to `seq`, of which the last notify event is `notify_seq`.
pub fn delivered(s: *service.Service, notify_seq: i64) void {
    _ = s.notify_delivered_seq.fetchMax(notify_seq, .monotonic);
}

/// Called after the notify event `seq` is written and announced. Returns once a running
/// app took it, or once the daemon has started the app to post it.
pub fn post(s: *service.Service, arena: std.mem.Allocator, seq: i64) void {
    var waited: i64 = 0;
    while (waited < claim_wait_ms) : (waited += 100) {
        if (s.notify_delivered_seq.load(.monotonic) >= seq) return;
        s.io.sleep(.fromMilliseconds(100), .awake) catch return;
    }
    if (s.notify_delivered_seq.load(.monotonic) >= seq) return;

    const now = s.now();
    const last = s.notify_posted_at.load(.monotonic);
    if (last != 0 and now - last < quiet_ms) return;
    s.notify_posted_at.store(now, .monotonic);

    start(s, arena) catch |err| std.debug.print("fyked: notify: {s}\n", .{@errorName(err)});
}

fn start(s: *service.Service, arena: std.mem.Allocator) !void {
    const headless = std.process.Environ.getAlloc(s.environ, arena, "FYKE_HEADLESS") catch null;
    if (headless != null) return;
    const override = std.process.Environ.getAlloc(s.environ, arena, "FYKE_NOTIFIER") catch null;
    const self = try std.process.executablePathAlloc(s.io, arena);
    const os: Os = switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        else => .other,
    };
    const argv = try command(arena, os, self, override, s.io, fileExists) orelse return;
    platform.keepStdHandlesFromChildren();
    var child = try std.process.spawn(s.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // `open` returns at once, and the Windows and Linux apps hand over to a copy of
    // themselves and exit (desktop/src-tauri/src/notify.rs); neither is left as
    // a zombie for long, and waiting keeps it from becoming one at all.
    _ = child.wait(s.io) catch {};
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn present(_: void, _: []const u8) bool {
    return true;
}

fn absent(_: void, _: []const u8) bool {
    return false;
}

test "macOS posts through the bundle that holds the daemon" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const argv = (try command(arena.allocator(), .macos, "/Applications/Fyke.app/Contents/MacOS/fyke", null, {}, present)).?;
    try std.testing.expectEqualStrings("/Applications/Fyke.app", argv[4]);
    try std.testing.expectEqualStrings("--notify", argv[6]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), try command(arena.allocator(), .macos, "/usr/local/bin/fyke", null, {}, present));
    try std.testing.expectEqual(@as(?[]const u8, null), bundleOf("/x/Contents/MacOS/fyke"));
}

test "Windows posts through the app beside the daemon, when it is there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = (try command(arena.allocator(), .windows, "C:\\Program Files\\Fyke\\fyke.exe", null, {}, present)).?;
    try std.testing.expectEqualStrings("C:\\Program Files\\Fyke\\Fyke.App.exe", argv[0]);
    try std.testing.expectEqualStrings("--notify", argv[1]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), try command(arena.allocator(), .windows, "C:\\dev\\fyke.exe", null, {}, absent));
}

test "Linux posts through the desktop app beside the daemon, when it is there" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = (try command(arena.allocator(), .linux, "/usr/bin/fyke", null, {}, present)).?;
    try std.testing.expectEqualStrings("/usr/bin/fyke-app", argv[0]);
    try std.testing.expectEqualStrings("--notify", argv[1]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), try command(arena.allocator(), .linux, "/home/me/src/zig-out/bin/fyke", null, {}, absent));
}

test "an override wins, and an empty one turns posting off" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const argv = (try command(arena.allocator(), .other, "/bin/fyke", "/tmp/record", {}, absent)).?;
    try std.testing.expectEqualStrings("/tmp/record", argv[0]);
    try std.testing.expectEqual(@as(?[]const []const u8, null), try command(arena.allocator(), .macos, "/A.app/Contents/MacOS/fyke", "", {}, present));
}
