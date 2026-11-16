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
// The C runtime owns timezone rules. Windows struct tm has only the nine ISO C
// fields; POSIX adds the UTC offset and zone pointer. Keep the ABI here so callers
// cannot accidentally pass the POSIX layout to a Windows runtime function.
const LocalTm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
};
const PosixTm = extern struct {
    fields: LocalTm,
    offset: c_long,
    zone: ?[*:0]const u8,
};
extern fn localtime_r(*const i64, *PosixTm) ?*PosixTm;
extern fn _localtime64_s(*LocalTm, *const i64) c_int;
extern fn _mkgmtime64(*LocalTm) i64;

/// Converts an epoch millisecond timestamp to the machine's local Gregorian date.
/// Both scheduling and dry-run day boundaries use this conversion, including DST.
/// Timestamps must be in the C runtime's supported range (1970 through 3000 on Windows).
pub fn localCivil(ms: i64) @import("schedule.zig").Civil {
    const seconds = @divFloor(ms, 1000);
    var fields: LocalTm = undefined;
    var offset: i64 = undefined;
    if (comptime is_windows) {
        const result = _localtime64_s(&fields, &seconds);
        std.debug.assert(result == 0);
        var utc_fields = fields;
        offset = _mkgmtime64(&utc_fields) - seconds;
    } else {
        var tm: PosixTm = undefined;
        const result = localtime_r(&seconds, &tm);
        std.debug.assert(result != null);
        fields = tm.fields;
        offset = tm.offset;
    }
    return .{
        .year = @as(i64, fields.year) + 1900,
        .month = @intCast(fields.mon + 1),
        .day = fields.mday,
        .weekday = @intCast(fields.wday),
        .minute = @intCast(fields.hour * 60 + fields.min),
        .utc_offset = offset,
    };
}
