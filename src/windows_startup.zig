//! `fyke service` on Windows: starts the daemon when the person signs in, by adding a
//! value to their `Run` key. Windows has no per-user service manager to hand the daemon
//! to, so unlike `launchd.zig` and `systemd.zig` nothing restarts it after a crash. The
//! next client starts it again on demand, as it does on any system.
//!
//! The key is the person's own (`HKEY_CURRENT_USER`), so no administrator is needed, and
//! the registry is read and written through `reg.exe`, which ships with Windows.

const std = @import("std");
const builtin = @import("builtin");
const client_module = @import("client.zig");
const data_home = @import("data_home.zig");
const ops = @import("ops.zig");

const Io = std.Io;

const run_key = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const value_name = "Fyke";

/// Quotes one argument for a Windows command line: wrapped in double quotes, with a
/// quote escaped by a backslash, and the backslashes before a quote (or before the closing
/// one) doubled so that they are not taken as an escape.
fn writeQuoted(w: *Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    var backslashes: usize = 0;
    for (text) |c| {
        switch (c) {
            '\\' => backslashes += 1,
            '"' => {
                try w.splatByteAll('\\', backslashes * 2 + 1);
                backslashes = 0;
                try w.writeByte('"');
            },
            else => {
                try w.splatByteAll('\\', backslashes);
                backslashes = 0;
                try w.writeByte(c);
            },
        }
    }
    try w.splatByteAll('\\', backslashes * 2);
    try w.writeByte('"');
}

/// The command the `Run` value holds. The data folder is passed explicitly, since a
/// value there has no environment of its own.
pub fn writeCommand(w: *Io.Writer, program: []const u8, home: []const u8) !void {
    try writeQuoted(w, program);
    try w.writeAll(" daemon --log --home ");
    try writeQuoted(w, home);
}

fn reg(io: Io, argv: []const []const u8) !bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.RegistryToolMissing,
        else => return err,
    };
    return (try child.wait(io)).success();
}

/// Replaces any daemon a client started, since two cannot share a data directory.
pub fn install(connector: client_module.Connector, user_home: []const u8) !void {
    _ = user_home;
    if (builtin.os.tag != .windows) return error.Unsupported;
    const arena = connector.arena;
    const io = connector.io;

    try stopRunning(connector);

    var out: Io.Writer.Allocating = .init(arena);
    try writeCommand(&out.writer, try std.process.executablePathAlloc(io, arena), connector.home_path);
    try data_home.ensure(io, connector.home_path);
    if (!try reg(io, &.{ "reg", "add", run_key, "/v", value_name, "/t", "REG_SZ", "/d", out.written(), "/f" })) return error.RegistryFailed;

    // Nothing starts the daemon until the next sign-in, so start it now.
    var client: client_module.Client = undefined;
    try connector.connect(&client, true);
    client.stream.close(io);
}

pub fn uninstall(connector: client_module.Connector, user_home: []const u8) !void {
    _ = user_home;
    if (builtin.os.tag != .windows) return error.Unsupported;
    const present = try reg(connector.io, &.{ "reg", "query", run_key, "/v", value_name });
    // Deleting a value that was never added fails, and that is fine. Failing to delete
    // one that is there would leave the daemon starting at every sign-in.
    if (!try reg(connector.io, &.{ "reg", "delete", run_key, "/v", value_name, "/f" }) and present) return error.RegistryFailed;
    try stopRunning(connector);
}

pub fn isInstalled(connector: client_module.Connector, user_home: []const u8) !bool {
    _ = user_home;
    if (builtin.os.tag != .windows) return error.Unsupported;
    return reg(connector.io, &.{ "reg", "query", run_key, "/v", value_name });
}

fn stopRunning(connector: client_module.Connector) !void {
    var client: client_module.Client = undefined;
    if (connector.connect(&client, false)) |_| {
        _ = client.call(ops.DaemonStop, .{}) catch {};
        client.stream.close(connector.io);
    } else |_| {}
}

test "the command quotes paths and passes the daemon's arguments" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCommand(&out.writer, "C:\\Program Files\\Fyke\\fyke.exe", "D:\\My Data\\");
    try std.testing.expectEqualStrings(
        "\"C:\\Program Files\\Fyke\\fyke.exe\" daemon --log --home \"D:\\My Data\\\\\"",
        out.written(),
    );
}

test "a quote in a path is escaped" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeQuoted(&out.writer, "a\\\"b");
    try std.testing.expectEqualStrings("\"a\\\\\\\"b\"", out.written());
}
