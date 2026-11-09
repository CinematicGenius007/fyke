//! `fyke service` on Linux: runs the daemon as a `systemd` user unit, so that feeds
//! keep polling from login with no client open. Like `launchd.zig`, it only writes a
//! unit file and asks the service manager to load it. Everything else stays the
//! daemon's business.
//!
//! A user unit starts when the person's first session starts and stops with their
//! last one. Starting at boot, without a login, needs `loginctl enable-linger`,
//! which changes the machine and so is left to the person.

const std = @import("std");
const builtin = @import("builtin");
const client_module = @import("client.zig");
const data_home = @import("data_home.zig");
const ops = @import("ops.zig");

const Io = std.Io;

const unit_name = "fyke.service";

/// Writes the unit. A clean `fyke daemon stop` is respected, and `systemd` restarts
/// the daemon only after a crash, as `launchd.zig` does with `KeepAlive`.
pub fn writeUnit(w: *Io.Writer, program: []const u8, home: []const u8) !void {
    try w.writeAll(
        \\[Unit]
        \\Description=Fyke feed reader daemon
        \\
        \\[Service]
        \\ExecStart="
    );
    try writeEscaped(w, program, true);
    try w.writeAll(
        \\" daemon --log
        \\Environment="FYKE_HOME=
    );
    try writeEscaped(w, home, false);
    try w.writeAll(
        \\"
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    );
}

/// Escapes text for a double-quoted `systemd` value. `%` starts a specifier in any
/// value, and `$` starts a variable in a command line only.
fn writeEscaped(w: *Io.Writer, text: []const u8, command_line: bool) !void {
    for (text) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '%' => try w.writeAll("%%"),
        '$' => try w.writeAll(if (command_line) "$$" else "$"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
}

fn unitPath(arena: std.mem.Allocator, environ: *const std.process.Environ.Map, user_home: []const u8) ![]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |config| if (config.len > 0 and config[0] == '/') {
        return std.fmt.allocPrint(arena, "{s}/systemd/user/{s}", .{ config, unit_name });
    };
    return std.fmt.allocPrint(arena, "{s}/.config/systemd/user/{s}", .{ user_home, unit_name });
}

fn systemctl(io: Io, argv: []const []const u8) !bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.SystemdMissing,
        else => return err,
    };
    return (try child.wait(io)).success();
}

fn user(io: Io, args: []const []const u8) !bool {
    var argv: [8][]const u8 = undefined;
    argv[0] = "systemctl";
    argv[1] = "--user";
    for (args, 0..) |a, i| argv[2 + i] = a;
    return systemctl(io, argv[0 .. 2 + args.len]);
}

/// Replaces any daemon a client started, since two cannot share a data directory.
pub fn install(connector: client_module.Connector, user_home: []const u8) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const arena = connector.arena;
    const io = connector.io;
    const path = try unitPath(arena, connector.environ, user_home);

    var client: client_module.Client = undefined;
    if (connector.connect(&client, false)) |_| {
        _ = client.call(ops.DaemonStop, .{}) catch {};
        client.stream.close(io);
    } else |_| {}

    var out: Io.Writer.Allocating = .init(arena);
    try writeUnit(&out.writer, try std.process.executablePathAlloc(io, arena), connector.home_path);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(path).?);
    try data_home.ensure(io, connector.home_path);
    try cwd.writeFile(io, .{ .sub_path = path, .data = out.written() });

    if (!try user(io, &.{"daemon-reload"})) return error.SystemctlFailed;
    if (!try user(io, &.{ "enable", unit_name })) return error.SystemctlFailed;
    // Restart rather than start, so that a unit already running picks up the new file.
    if (!try user(io, &.{ "restart", unit_name })) return error.SystemctlFailed;
}

pub fn uninstall(connector: client_module.Connector, user_home: []const u8) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const io = connector.io;
    const path = try unitPath(connector.arena, connector.environ, user_home);
    _ = try user(io, &.{ "disable", "--now", unit_name });
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    _ = try user(io, &.{"daemon-reload"});
}

pub fn isInstalled(connector: client_module.Connector, user_home: []const u8) !bool {
    _ = user_home;
    if (builtin.os.tag != .linux) return error.Unsupported;
    return user(connector.io, &.{ "is-enabled", "--quiet", unit_name });
}

test "the unit escapes paths and keeps the daemon's arguments" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeUnit(&out.writer, "/Apps/a b\"$%/fyke", "/home/me/100%/\"data\"");
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "ExecStart=\"/Apps/a b\\\"$$%%/fyke\" daemon --log\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Environment=\"FYKE_HOME=/home/me/100%%/\\\"data\\\"\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Restart=on-failure\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WantedBy=default.target\n") != null);
}
