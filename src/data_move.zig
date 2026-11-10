//! `fyke data move <folder>`: moves the data directory, so that nobody has to do it by
//! hand. `~/.fyke` stays the one address every client uses. After a move it is a link
//! to the chosen folder, which keeps socket paths short, whatever the folder's name,
//! and needs no pointer file for clients to read.
//!
//! Nothing is deleted until the data is verified in its new place, and a failure at
//! any step leaves the old folder as it was.

const std = @import("std");
const client_module = @import("client.zig");
const daemon = @import("daemon.zig");
const autostart = @import("autostart.zig");
const ops = @import("ops.zig");
const platform = @import("platform.zig");

const Io = std.Io;

pub const Error = error{
    /// `FYKE_HOME` names the folder, so there is no `~/.fyke` to repoint.
    HomeIsOverridden,
    NotAbsolute,
    NoData,
    SameFolder,
    InsideCurrentFolder,
    ParentMissing,
    TargetNotEmpty,
    TargetNotFolder,
    VerifyFailed,
    DaemonStillRunning,
};

/// True when `path` is `folder` or lies inside it.
pub fn isInside(path: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

fn trimSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

const Kind = enum { missing, folder, link, other };

fn kindOf(io: Io, path: []const u8, follow: bool) !Kind {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = follow }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    return switch (stat.kind) {
        .directory => .folder,
        .sym_link => .link,
        else => .other,
    };
}

fn isEmptyFolder(io: Io, path: []const u8) !bool {
    var folder = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer folder.close(io);
    var entries = folder.iterate();
    return (try entries.next(io)) == null;
}

const Totals = struct { files: u64 = 0, bytes: u64 = 0 };

fn measure(arena: std.mem.Allocator, io: Io, path: []const u8) !Totals {
    var folder = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer folder.close(io);
    var walker = try folder.walk(arena);
    defer walker.deinit();
    var totals: Totals = .{};
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .file => {
            const stat = try entry.dir.statFile(io, entry.basename, .{});
            totals.files += 1;
            totals.bytes += stat.size;
        },
        // A link is data too: losing one would pass a count that ignored it.
        .sym_link => totals.files += 1,
        else => {},
    };
    return totals;
}

fn copyTree(arena: std.mem.Allocator, io: Io, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, to);
    var source = try cwd.openDir(io, from, .{ .iterate = true });
    defer source.close(io);
    var destination = try cwd.openDir(io, to, .{});
    defer destination.close(io);
    var walker = try source.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try destination.createDirPath(io, entry.path),
        .file => try source.copyFile(entry.path, destination, entry.path, io, .{ .make_path = true }),
        .sym_link => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try source.readLink(io, entry.path, &buffer);
            try destination.symLink(io, buffer[0..length], entry.path, .{});
        },
        // A socket belongs to a daemon that no longer runs.
        else => {},
    };
}

/// Empties a folder this command filled, so that a failed copy leaves nothing behind.
fn clear(io: Io, path: []const u8, remove_folder: bool) void {
    const cwd = Io.Dir.cwd();
    if (remove_folder) {
        cwd.deleteTree(io, path) catch {};
        return;
    }
    var folder = cwd.openDir(io, path, .{ .iterate = true }) catch return;
    defer folder.close(io);
    var entries = folder.iterate();
    while (entries.next(io) catch null) |entry| folder.deleteTree(io, entry.name) catch {};
}

/// Waits for the daemon to let go of the data directory, and holds the same lock the
/// daemon takes, so that no client can start one on a folder that is being moved.
fn holdLock(io: Io, current: []const u8, arena: std.mem.Allocator) !Io.File {
    const path = try std.fmt.allocPrint(arena, "{s}/fyked.lock", .{current});
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    errdefer file.close(io);
    for (0..150) |_| {
        if (try file.tryLock(io, .exclusive)) return file;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.DaemonStillRunning;
}

fn progress(out: *Io.Writer, stage: []const u8) !void {
    try out.print("{s}\n", .{stage});
    try out.flush();
}

const Layout = struct {
    anchor: []const u8,
    current: []const u8,
    target: []const u8,
    anchor_link: bool,
    to_anchor: bool,
    target_existed: bool,
};

/// A name for the old anchor to wait under while the link takes its place.
fn asideName(arena: std.mem.Allocator, io: Io, anchor: []const u8) ![]const u8 {
    for (0..100) |n| {
        const name = if (n == 0) try std.fmt.allocPrint(arena, "{s}.old", .{anchor}) else try std.fmt.allocPrint(arena, "{s}.old{d}", .{ anchor, n });
        if (try kindOf(io, name, false) == .missing) return name;
    }
    return error.TargetNotEmpty;
}

/// Puts the data in its new place and points `~/.fyke` at it. Each step that changes
/// something can be undone, and is, if a later one fails, so that an error leaves the
/// data where it was.
fn relocate(arena: std.mem.Allocator, io: Io, out: *Io.Writer, l: Layout) !void {
    const cwd = Io.Dir.cwd();

    // A link at the anchor stands in the way when moving back to it.
    if (l.to_anchor) try cwd.deleteFile(io, l.anchor);
    errdefer if (l.to_anchor) cwd.symLink(io, l.current, l.anchor, .{ .is_directory = true }) catch {};

    var copied = false;
    Io.Dir.renameAbsolute(l.current, l.target, io) catch |err| switch (err) {
        error.CrossDevice => copied = true,
        else => return err,
    };

    if (!copied) {
        try progress(out, "linking");
        if (l.to_anchor) return;
        errdefer Io.Dir.renameAbsolute(l.target, l.current, io) catch {};
        if (l.anchor_link) try cwd.deleteFile(io, l.anchor);
        cwd.symLink(io, l.target, l.anchor, .{ .is_directory = true }) catch |err| {
            if (l.anchor_link) cwd.symLink(io, l.current, l.anchor, .{ .is_directory = true }) catch {};
            return err;
        };
        return;
    }

    errdefer clear(io, l.target, !l.target_existed);
    try copyTree(arena, io, l.current, l.target);
    try progress(out, "verifying");
    const before = try measure(arena, io, l.current);
    const after = try measure(arena, io, l.target);
    if (before.files != after.files or before.bytes != after.bytes) return error.VerifyFailed;

    try progress(out, "linking");
    if (l.to_anchor) {
        cwd.deleteTree(io, l.current) catch {};
    } else if (l.anchor_link) {
        try cwd.deleteFile(io, l.anchor);
        cwd.symLink(io, l.target, l.anchor, .{ .is_directory = true }) catch |err| {
            cwd.symLink(io, l.current, l.anchor, .{ .is_directory = true }) catch {};
            return err;
        };
        cwd.deleteTree(io, l.current) catch {};
    } else {
        const aside = try asideName(arena, io, l.anchor);
        try Io.Dir.renameAbsolute(l.anchor, aside, io);
        cwd.symLink(io, l.target, l.anchor, .{ .is_directory = true }) catch |err| {
            Io.Dir.renameAbsolute(aside, l.anchor, io) catch {};
            return err;
        };
        // The old folder was the anchor itself, which now holds the link.
        cwd.deleteTree(io, aside) catch {};
    }
}

pub fn run(
    connector: client_module.Connector,
    user_home: []const u8,
    target_arg: []const u8,
    out: *Io.Writer,
) !void {
    const arena = connector.arena;
    const io = connector.io;
    const cwd = Io.Dir.cwd();

    // The move leaves `~/.fyke` as a link, and creating a link on Windows needs a
    // privilege that most accounts do not hold.
    if (comptime platform.is_windows) return error.Unsupported;
    if (connector.environ.get("FYKE_HOME") != null) return error.HomeIsOverridden;
    if (target_arg.len == 0 or target_arg[0] != '/') return error.NotAbsolute;
    const target = trimSlashes(target_arg);
    const anchor = try std.fmt.allocPrint(arena, "{s}/.fyke", .{user_home});

    // Where the data is now, which is the anchor itself or what it links to.
    var current: []const u8 = anchor;
    const anchor_kind = try kindOf(io, anchor, false);
    switch (anchor_kind) {
        .folder => {},
        .link => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = try cwd.readLink(io, anchor, &buffer);
            // A link made by hand may be relative to the folder that holds it.
            current = try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(anchor) orelse "/", buffer[0..length] });
        },
        else => return error.NoData,
    }

    if (std.mem.eql(u8, target, current)) return error.SameFolder;
    if (isInside(target, current)) return error.InsideCurrentFolder;
    const to_anchor = std.mem.eql(u8, target, anchor);
    if (!to_anchor) {
        const parent = std.fs.path.dirname(target) orelse return error.ParentMissing;
        // The parent may be reached through a link, which is fine. Only the target itself must not be one.
        if (try kindOf(io, parent, true) != .folder) return error.ParentMissing;
    }
    const target_kind = if (to_anchor) Kind.missing else try kindOf(io, target, false);
    switch (target_kind) {
        .missing => {},
        .folder => if (!try isEmptyFolder(io, target)) return error.TargetNotEmpty,
        else => return error.TargetNotFolder,
    }

    try progress(out, "stopping");
    var client: client_module.Client = undefined;
    if (connector.connect(&client, false)) {
        _ = client.call(ops.DaemonStop, .{}) catch {};
    } else |_| {}
    const lock = try holdLock(io, current, arena);

    try progress(out, "moving");
    const layout: Layout = .{
        .anchor = anchor,
        .current = current,
        .target = target,
        .anchor_link = anchor_kind == .link,
        .to_anchor = to_anchor,
        .target_existed = target_kind != .missing,
    };
    try relocate(arena, io, out, layout);
    lock.unlock(io);
    lock.close(io);

    try progress(out, "starting");
    if (autostart.isInstalled(connector, user_home) catch false) {
        try autostart.install(connector, user_home);
    } else {
        var started: client_module.Client = undefined;
        try connector.connect(&started, true);
    }
    try progress(out, "done");
}

test "a path is inside a folder only at a name boundary" {
    try std.testing.expect(isInside("/a/b", "/a/b"));
    try std.testing.expect(isInside("/a/b/c", "/a/b"));
    try std.testing.expect(!isInside("/a/bc", "/a/b"));
    try std.testing.expect(!isInside("/a", "/a/b"));
}
