//! The few places where Fyke must ask the operating system for something that
//! differs between POSIX systems and Windows. Each function says what it promises,
//! and the rest of the program calls these instead of branching on the system.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

pub const is_windows = builtin.os.tag == .windows;

const windows = std.os.windows;

const win = struct {
    extern "kernel32" fn SetStdHandle(handle_id: windows.DWORD, handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    /// The documented value is (DWORD)-12.
    const std_error_handle: windows.DWORD = @bitCast(@as(i32, -12));
};

/// Makes a file or folder private to its owner. POSIX systems get the given mode. On
/// Windows nothing is changed: a folder under the user's profile already inherits an
/// access list that admits only that user, the system and administrators, and the
/// permission bits of a POSIX mode have no meaning there.
pub fn makePrivate(io: Io, dir: Io.Dir, sub_path: []const u8, mode: u32) !void {
    if (comptime is_windows) return;
    try dir.setFilePermissions(io, sub_path, .fromMode(@intCast(mode)), .{});
}

/// Sends this process's standard error to `file`, so that what `std.debug.print`
/// writes lands in the daemon's log.
pub fn redirectStderr(file: Io.File) !void {
    if (comptime is_windows) {
        if (win.SetStdHandle(win.std_error_handle, file.handle) == .FALSE) return error.LogUnavailable;
        return;
    }
    if (std.c.dup2(file.handle, std.posix.STDERR_FILENO) < 0) return error.LogUnavailable;
}
