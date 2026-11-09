//! `fyke service`: runs the daemon as a macOS launch agent, so that feeds keep
//! polling from login, with no client open. It only writes a property list and
//! asks `launchctl` to load it, and everything else stays the daemon's business.

const std = @import("std");
const builtin = @import("builtin");
const client_module = @import("client.zig");
const data_home = @import("data_home.zig");
const ops = @import("ops.zig");

const Io = std.Io;

const label = "local.fyke.daemon";

/// The label builds before the project's name used. A person who installed that agent
/// would otherwise keep a second daemon that `service uninstall` never finds.
const legacy_label = "local.rss_.daemon";

/// Writes the agent's property list. A clean `fyke daemon stop` is respected, and
/// launchd restarts the daemon only after a crash.
pub fn writePlist(w: *Io.Writer, program: []const u8, home: []const u8) !void {
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key><string>
    );
    try w.writeAll(label);
    try w.writeAll(
        \\</string>
        \\  <key>ProgramArguments</key>
        \\  <array><string>
    );
    try writeEscaped(w, program);
    try w.writeAll(
        \\</string><string>daemon</string><string>--log</string></array>
        \\  <key>EnvironmentVariables</key>
        \\  <dict><key>FYKE_HOME</key><string>
    );
    try writeEscaped(w, home);
    try w.writeAll(
        \\</string></dict>
        \\  <key>RunAtLoad</key><true/>
        \\  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        \\  <key>ProcessType</key><string>Background</string>
        \\</dict>
        \\</plist>
        \\
    );
}

fn writeEscaped(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

const Paths = struct { plist: []const u8, target: []const u8, domain: []const u8 };

fn paths(arena: std.mem.Allocator, user_home: []const u8) !Paths {
    const uid = std.c.getuid();
    return .{
        .plist = try std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents/{s}.plist", .{ user_home, label }),
        .target = try std.fmt.allocPrint(arena, "gui/{d}/{s}", .{ uid, label }),
        .domain = try std.fmt.allocPrint(arena, "gui/{d}", .{uid}),
    };
}

/// Unloads and deletes an agent of the earlier label, if there is one.
fn removeLegacy(io: Io, arena: std.mem.Allocator, user_home: []const u8) !void {
    const target = try std.fmt.allocPrint(arena, "gui/{d}/{s}", .{ std.c.getuid(), legacy_label });
    const plist = try std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents/{s}.plist", .{ user_home, legacy_label });
    Io.Dir.cwd().access(io, plist, .{}) catch return;
    _ = try launchctl(io, &.{ "launchctl", "bootout", target });
    Io.Dir.cwd().deleteFile(io, plist) catch {};
}

fn launchctl(io: Io, argv: []const []const u8) !bool {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    return (try child.wait(io)).success();
}

/// Replaces any daemon a client started, since two cannot share a data directory.
pub fn install(connector: client_module.Connector, user_home: []const u8) !void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const arena = connector.arena;
    const io = connector.io;
    const where = try paths(arena, user_home);

    try removeLegacy(io, arena, user_home);

    var client: client_module.Client = undefined;
    if (connector.connect(&client, false)) |_| {
        _ = client.call(ops.DaemonStop, .{}) catch {};
        client.stream.close(io);
    } else |_| {}

    var out: Io.Writer.Allocating = .init(arena);
    try writePlist(&out.writer, try std.process.executablePathAlloc(io, arena), connector.home_path);
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(where.plist).?);
    try data_home.ensure(io, connector.home_path);
    try cwd.writeFile(io, .{ .sub_path = where.plist, .data = out.written() });

    _ = try launchctl(io, &.{ "launchctl", "bootout", where.target });
    if (!try launchctl(io, &.{ "launchctl", "bootstrap", where.domain, where.plist })) return error.LaunchctlFailed;
}

pub fn uninstall(connector: client_module.Connector, user_home: []const u8) !void {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const where = try paths(connector.arena, user_home);
    try removeLegacy(connector.io, connector.arena, user_home);
    _ = try launchctl(connector.io, &.{ "launchctl", "bootout", where.target });
    Io.Dir.cwd().deleteFile(connector.io, where.plist) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn isInstalled(connector: client_module.Connector, user_home: []const u8) !bool {
    if (builtin.os.tag != .macos) return error.Unsupported;
    const where = try paths(connector.arena, user_home);
    return launchctl(connector.io, &.{ "launchctl", "print", where.target });
}

test "the property list escapes paths and keeps the daemon's arguments" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writePlist(&out.writer, "/Apps/a&b/rss", "/Users/me/<data>");
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>/Apps/a&amp;b/rss</string><string>daemon</string><string>--log</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<string>/Users/me/&lt;data&gt;</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<key>Label</key><string>local.fyke.daemon</string>") != null);
}
