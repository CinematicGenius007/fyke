//! The terminal under the terminal reader: raw input, the window size, a way for other
//! threads and signal handlers to wake the main loop, and a wait for either.
//!
//! The reader asks one question, "is there input, or was I woken, within this long?",
//! and the two systems answer it differently. POSIX systems wait on standard input and
//! a pipe with one `poll(2)`. Windows cannot wait on a console handle that also reports
//! mouse, focus and size events the reader does not want, so a thread reads standard
//! input and hands bytes to the main loop. In both, the console is put in a mode where
//! keys and mouse reports arrive as the same escape sequences, so `terminal.zig` is the
//! only parser.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const Size = struct { columns: usize, rows: usize };

/// What `wait` found. A signal can end the wait with none of these set.
pub const Wait = struct {
    input: bool = false,
    woke: bool = false,
    timed_out: bool = false,
};

const impl = if (is_windows) @import("console_windows.zig") else @import("console_posix.zig");

/// Creates the channel that `wake` writes to. Call once, before anything else.
pub const start = impl.start;
/// Ends a `wait` from any thread, or from a signal handler on POSIX systems. `reason`
/// is handed back by `drainWake`. A full channel drops wake-ups instead of blocking.
pub const wake = impl.wake;
pub const size = impl.size;
/// Puts the terminal in raw mode and writes `enter` to it. Fails when standard input or
/// output is not a terminal.
pub const enterRaw = impl.enterRaw;
/// Writes `leave` and restores the modes `enterRaw` changed. Safe to call twice, and
/// from a signal handler on POSIX systems: it makes only system calls.
pub const restore = impl.restore;
/// Makes termination and window changes wake the loop, and restore the terminal first.
pub const installHandlers = impl.installHandlers;
/// Waits up to `timeout_ms` (negative waits forever) for input or a wake.
pub const wait = impl.wait;
/// Reads input bytes. Zero or less means the terminal went away.
pub const readInput = impl.readInput;
/// Copies the reasons given to `wake` since the last call.
pub const drainWake = impl.drainWake;
/// Writes bytes to the terminal and returns how many were taken, or less than zero.
pub const write = impl.write;

/// Set by the reader before `enterRaw`.
pub var enter_sequence: []const u8 = "";
pub var leave_sequence: []const u8 = "";
