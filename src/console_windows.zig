//! The Windows console in virtual-terminal mode, with a thread reading standard input.
//! See `console.zig`.

const std = @import("std");
const console = @import("console.zig");

const Size = console.Size;
const Wait = console.Wait;

const windows = std.os.windows;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;

const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ScreenBufferInfo = extern struct {
    size: Coord,
    cursor: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
};

const k32 = struct {
    extern "kernel32" fn GetStdHandle(id: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetConsoleMode(h: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(h: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *ScreenBufferInfo) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(cp: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(h: HANDLE, buffer: [*]u8, len: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(h: HANDLE, buffer: [*]const u8, len: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn ResetEvent(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
    extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
};

/// Documented values: (DWORD)-10 and (DWORD)-11.
const std_input: DWORD = @bitCast(@as(i32, -10));
const std_output: DWORD = @bitCast(@as(i32, -11));

const in_processed: DWORD = 0x0001;
const in_line: DWORD = 0x0002;
const in_echo: DWORD = 0x0004;
const in_quick_edit: DWORD = 0x0040;
const in_extended: DWORD = 0x0080;
const in_virtual_terminal: DWORD = 0x0200;
const out_processed: DWORD = 0x0001;
const out_virtual_terminal: DWORD = 0x0004;
const out_no_auto_return: DWORD = 0x0008;

const wait_object_0: DWORD = 0;
const infinite: DWORD = 0xFFFFFFFF;
const utf8: u32 = 65001;

const queue_size = 4096;

/// The thread reading standard input and the main loop share this, guarded by a
/// spin lock that is held only to copy a few bytes.
var locked = std.atomic.Value(bool).init(false);
var input_bytes: [queue_size]u8 = undefined;
var input_len: usize = 0;
var input_closed = false;
var reasons: [256]u8 = undefined;
var reasons_len: usize = 0;
var event: ?HANDLE = null;

var saved_input_mode: ?DWORD = null;
var saved_output_mode: ?DWORD = null;
var saved_input_cp: u32 = 0;
var saved_output_cp: u32 = 0;
var last_size: Size = .{ .columns = 0, .rows = 0 };

fn lock() void {
    while (locked.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock() void {
    locked.store(false, .release);
}

fn stdHandle(id: DWORD) ?HANDLE {
    const h = k32.GetStdHandle(id) orelse return null;
    if (h == windows.INVALID_HANDLE_VALUE) return null;
    return h;
}

pub fn start() !void {
    event = k32.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.NoEvent;
}

fn signal() void {
    if (event) |e| _ = k32.SetEvent(e);
}

pub fn wake(reason: u8) void {
    lock();
    if (reasons_len < reasons.len) {
        reasons[reasons_len] = reason;
        reasons_len += 1;
    }
    unlock();
    signal();
}

pub fn size() Size {
    const out = stdHandle(std_output) orelse return .{ .columns = 80, .rows = 24 };
    var info: ScreenBufferInfo = undefined;
    if (k32.GetConsoleScreenBufferInfo(out, &info) == .FALSE) return .{ .columns = 80, .rows = 24 };
    const columns = info.window.right - info.window.left + 1;
    const rows = info.window.bottom - info.window.top + 1;
    if (columns <= 0 or rows <= 0) return .{ .columns = 80, .rows = 24 };
    return .{ .columns = @intCast(columns), .rows = @intCast(rows) };
}

pub fn enterRaw() !void {
    const in = stdHandle(std_input) orelse return error.NotATerminal;
    const out = stdHandle(std_output) orelse return error.NotATerminal;
    var in_mode: DWORD = undefined;
    var out_mode: DWORD = undefined;
    if (k32.GetConsoleMode(in, &in_mode) == .FALSE) return error.NotATerminal;
    if (k32.GetConsoleMode(out, &out_mode) == .FALSE) return error.NotATerminal;
    saved_input_mode = in_mode;
    saved_output_mode = out_mode;
    saved_input_cp = k32.GetConsoleCP();
    saved_output_cp = k32.GetConsoleOutputCP();

    // Keys and mouse reports must arrive as escape sequences, and the text of the
    // screen must be read as UTF-8. Quick edit would take mouse clicks for itself.
    const raw_in = (in_mode & ~(in_processed | in_line | in_echo | in_quick_edit)) | in_extended | in_virtual_terminal;
    if (k32.SetConsoleMode(in, raw_in) == .FALSE) return error.NotATerminal;
    const raw_out = out_mode | out_processed | out_virtual_terminal | out_no_auto_return;
    if (k32.SetConsoleMode(out, raw_out) == .FALSE) {
        _ = k32.SetConsoleMode(in, in_mode);
        return error.NotATerminal;
    }
    _ = k32.SetConsoleCP(utf8);
    _ = k32.SetConsoleOutputCP(utf8);
    _ = write(console.enter_sequence);

    last_size = size();
    (try std.Thread.spawn(.{}, readerThread, .{})).detach();
    (try std.Thread.spawn(.{}, sizeThread, .{})).detach();
}

pub fn restore() void {
    const in_mode = saved_input_mode orelse return;
    saved_input_mode = null;
    _ = write(console.leave_sequence);
    if (stdHandle(std_input)) |in| _ = k32.SetConsoleMode(in, in_mode);
    if (saved_output_mode) |m| if (stdHandle(std_output)) |out| {
        _ = k32.SetConsoleMode(out, m);
    };
    saved_output_mode = null;
    if (saved_input_cp != 0) _ = k32.SetConsoleCP(saved_input_cp);
    if (saved_output_cp != 0) _ = k32.SetConsoleOutputCP(saved_output_cp);
}

/// Reads standard input for as long as the process lives. Blocking here is fine,
/// since nothing else needs this thread.
fn readerThread() void {
    const in = stdHandle(std_input) orelse return;
    var chunk: [512]u8 = undefined;
    while (true) {
        var got: DWORD = 0;
        const ok = k32.ReadFile(in, &chunk, chunk.len, &got, null);
        lock();
        if (ok == .FALSE or got == 0) {
            input_closed = true;
        } else {
            const room = queue_size - input_len;
            const take = @min(room, got);
            @memcpy(input_bytes[input_len..][0..take], chunk[0..take]);
            input_len += take;
        }
        const done = input_closed;
        unlock();
        signal();
        if (done) return;
        // The queue is full: let the main loop catch up before reading more.
        while (true) {
            lock();
            const space = input_len < queue_size / 2;
            unlock();
            if (space) break;
            k32.Sleep(5);
        }
    }
}

/// Windows has no signal for a resized window, so the size is checked on a timer.
fn sizeThread() void {
    while (saved_input_mode != null) {
        k32.Sleep(250);
        const now = size();
        if (now.columns != last_size.columns or now.rows != last_size.rows) {
            last_size = now;
            wake('w');
        }
    }
}

fn ctrlHandler(kind: DWORD) callconv(.winapi) BOOL {
    _ = kind;
    restore();
    k32.ExitProcess(1);
}

pub fn installHandlers() void {
    _ = k32.SetConsoleCtrlHandler(ctrlHandler, .TRUE);
}

fn pending() bool {
    lock();
    defer unlock();
    return input_len != 0 or input_closed or reasons_len != 0;
}

pub fn wait(timeout_ms: i32) Wait {
    const e = event orelse return .{};
    var timed_out = false;
    if (!pending()) {
        const result = k32.WaitForSingleObject(e, if (timeout_ms < 0) infinite else @intCast(timeout_ms));
        timed_out = result != wait_object_0;
    }
    lock();
    defer unlock();
    const found: Wait = .{
        .input = input_len != 0 or input_closed,
        .woke = reasons_len != 0,
        .timed_out = timed_out and input_len == 0 and !input_closed and reasons_len == 0,
    };
    if (input_len == 0 and !input_closed and reasons_len == 0) _ = k32.ResetEvent(e);
    return found;
}

pub fn readInput(out: []u8) isize {
    lock();
    defer unlock();
    if (input_len == 0) return if (input_closed) 0 else -1;
    const take = @min(out.len, input_len);
    @memcpy(out[0..take], input_bytes[0..take]);
    std.mem.copyForwards(u8, input_bytes[0 .. input_len - take], input_bytes[take..input_len]);
    input_len -= take;
    if (input_len == 0 and reasons_len == 0) if (event) |e| {
        _ = k32.ResetEvent(e);
    };
    return @intCast(take);
}

pub fn drainWake(out: []u8) usize {
    lock();
    defer unlock();
    const take = @min(out.len, reasons_len);
    @memcpy(out[0..take], reasons[0..take]);
    std.mem.copyForwards(u8, reasons[0 .. reasons_len - take], reasons[take..reasons_len]);
    reasons_len -= take;
    if (input_len == 0 and !input_closed and reasons_len == 0) if (event) |e| {
        _ = k32.ResetEvent(e);
    };
    return take;
}

pub fn write(bytes: []const u8) isize {
    const out = stdHandle(std_output) orelse return -1;
    var written: DWORD = 0;
    if (k32.WriteFile(out, bytes.ptr, @intCast(bytes.len), &written, null) == .FALSE) return -1;
    return @intCast(written);
}
