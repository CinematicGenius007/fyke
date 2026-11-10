//! The few places where Fyke must ask the operating system for something that
//! differs between POSIX systems and Windows. Each function says what it promises,
//! and the rest of the program calls these instead of branching on the system.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

pub const is_windows = builtin.os.tag == .windows;

const windows = std.os.windows;

const win = struct {
    extern "kernel32" fn GetStdHandle(handle_id: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetHandleInformation(handle: windows.HANDLE, mask: windows.DWORD, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
    const handle_flag_inherit: windows.DWORD = 1;
    const std_ids = [_]i32{ -10, -11, -12 };
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

/// Stops the standard handles of this process from reaching a child it starts. Windows
/// children inherit every inheritable handle, so a daemon started by a client that was
/// run with its output captured would hold the capturing pipe open for as long as it
/// lives, and whoever reads that pipe would never see the end. POSIX children get only
/// what the spawn call gives them, so nothing is needed there.
pub fn keepStdHandlesFromChildren() void {
    if (comptime !is_windows) return;
    for (win.std_ids) |id| {
        const h = win.GetStdHandle(@bitCast(id)) orelse continue;
        if (h == windows.INVALID_HANDLE_VALUE) continue;
        _ = win.SetHandleInformation(h, win.handle_flag_inherit, 0);
    }
}
