//! The POSIX terminal: `poll(2)` over standard input and a wake pipe. See `console.zig`.

const std = @import("std");
const console = @import("console.zig");

const Size = console.Size;
const Wait = console.Wait;

const c = std.c;

var original_termios: ?std.posix.termios = null;
var wake_read_fd: c.fd_t = -1;
var wake_write_fd: c.fd_t = -1;

pub fn start() !void {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.NoPipe;
    wake_read_fd = fds[0];
    wake_write_fd = fds[1];
    // A full pipe must drop wake-ups rather than block a signal handler.
    _ = c.fcntl(fds[1], c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
}

pub fn wake(reason: u8) void {
    const byte = [1]u8{reason};
    _ = c.write(wake_write_fd, &byte, 1);
}

pub fn size() Size {
    var ws: std.posix.winsize = undefined;
    if (c.ioctl(1, std.posix.T.IOCGWINSZ, &ws) != 0 or ws.col == 0) return .{ .columns = 80, .rows = 24 };
    return .{ .columns = ws.col, .rows = ws.row };
}

pub fn enterRaw() !void {
    if (c.isatty(0) == 0 or c.isatty(1) == 0) return error.NotATerminal;
    var raw: std.posix.termios = undefined;
    if (c.tcgetattr(0, &raw) != 0) return error.NotATerminal;
    original_termios = raw;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.iflag.BRKINT = false;
    raw.iflag.ISTRIP = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    if (c.tcsetattr(0, .FLUSH, &raw) != 0) return error.NotATerminal;
    _ = c.write(1, console.enter_sequence.ptr, console.enter_sequence.len);
}

pub fn restore() void {
    const saved = original_termios orelse return;
    original_termios = null;
    _ = c.write(1, console.leave_sequence.ptr, console.leave_sequence.len);
    // NOW, not FLUSH: FLUSH waits for output to drain, which would hang here if the
    // terminal had stopped reading, and this code runs inside signal handlers.
    _ = c.tcsetattr(0, .NOW, &saved);
}

/// Signal handlers may do almost nothing, so they write one byte to a pipe, which
/// turns the signal into an ordinary readable event for the main loop.
fn onWinch(_: std.posix.SIG) callconv(.c) void {
    wake('w');
}

fn onTerminate(sig: std.posix.SIG) callconv(.c) void {
    restore();
    c._exit(128 + @as(c_int, @intCast(@backingInt(sig))));
}

pub fn installHandlers() void {
    const winch: std.posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.WINCH, &winch, null);
    const terminate: std.posix.Sigaction = .{ .handler = .{ .handler = onTerminate }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &terminate, null);
    std.posix.sigaction(.HUP, &terminate, null);
    std.posix.sigaction(.INT, &terminate, null);
}

pub fn wait(timeout_ms: i32) Wait {
    var fds = [_]c.pollfd{
        .{ .fd = 0, .events = c.POLL.IN, .revents = 0 },
        .{ .fd = wake_read_fd, .events = c.POLL.IN, .revents = 0 },
    };
    const ready = c.poll(&fds, fds.len, timeout_ms);
    if (ready < 0) return .{};
    return .{ .input = fds[0].revents != 0, .woke = fds[1].revents != 0, .timed_out = ready == 0 };
}

pub fn readInput(out: []u8) isize {
    return c.read(0, out.ptr, out.len);
}

pub fn drainWake(out: []u8) usize {
    const count = c.read(wake_read_fd, out.ptr, out.len);
    return @intCast(@max(count, 0));
}

pub fn write(bytes: []const u8) isize {
    return c.write(1, bytes.ptr, bytes.len);
}
