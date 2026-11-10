//! Finds the data directory when `FYKE_HOME` does not name one, and moves data out
//! of the location and the file names that builds before the project's name used.

const std = @import("std");

const Io = std.Io;

const folder = ".fyke";
const legacy_folder = ".rss_";

/// The data directory for this user, after moving any data left at the legacy path.
pub fn resolve(arena: std.mem.Allocator, io: Io, user_home: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ user_home, folder });
    const legacy = try std.fmt.allocPrint(arena, "{s}/{s}", .{ user_home, legacy_folder });
    try moveLegacy(io, legacy, path);
    try renameLegacyFiles(arena, io, path);
    return path;
}

/// The file in the default Windows data folder that names the folder `fyke data move`
/// chose. A link would do the same on other systems, but making one on Windows needs a
/// privilege most accounts lack, and a folder cannot be renamed while the daemon's lock
/// file is open in it. A pointer needs neither.
pub const location_file = "location";

/// Where the data is, if `anchor` holds a pointer to somewhere else.
pub fn readLocation(arena: std.mem.Allocator, io: Io, anchor: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ anchor, location_file });
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Writes the pointer whole or not at all, since a half-written one would send every
/// client to the wrong folder.
pub fn writeLocation(arena: std.mem.Allocator, io: Io, anchor: []const u8, target: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const path = try std.fmt.allocPrint(arena, "{s}\\{s}", .{ anchor, location_file });
    const temporary = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = target });
    try Io.Dir.renameAbsolute(temporary, path, io);
}

/// Files an earlier build named for the working name. A pair is renamed only when the
/// new name is free, so data that was already migrated is never replaced.
const legacy_files = [_][2][]const u8{
    .{ "rss.db", "fyke.db" },
    .{ "rss.db-wal", "fyke.db-wal" },
    .{ "rss.db-shm", "fyke.db-shm" },
};

/// An earlier daemon keeps its database open under the old names, so renaming
/// beneath it would leave two daemons on one database. Its lock proves whether it is
/// running: the kernel drops the lock when the process dies.
fn renameLegacyFiles(arena: std.mem.Allocator, io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const old_db = try std.fmt.allocPrint(arena, "{s}/rss.db", .{path});
    cwd.access(io, old_db, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const lock_path = try std.fmt.allocPrint(arena, "{s}/rssd.lock", .{path});
    if (cwd.openFile(io, lock_path, .{ .mode = .read_write })) |lock_file| {
        defer lock_file.close(io);
        if (!try lock_file.tryLock(io, .exclusive)) return error.EarlierDaemonRunning;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    for (legacy_files) |pair| {
        const from = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, pair[0] });
        const to = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, pair[1] });
        cwd.access(io, to, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                Io.Dir.renameAbsolute(from, to, io) catch |rename_err| switch (rename_err) {
                    error.FileNotFound => {},
                    else => return rename_err,
                };
                continue;
            },
            else => return err,
        };
    }
    // Leftovers of a daemon that is gone: its socket and lock name a process that no
    // longer exists, and its log is replaced at each start.
    for ([_][]const u8{ "rssd.sock", "rssd.lock", "rssd.log" }) |name| {
        const leftover = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, name });
        cwd.deleteFile(io, leftover) catch {};
    }
}

/// Makes sure the data directory exists. Creating a path refuses one that is a link,
/// and the legacy path is a link after a move, so a directory is looked for first.
pub fn ensure(io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return cwd.createDirPath(io, path),
        else => return err,
    };
    if (stat.kind != .directory) return error.NotDir;
}

/// One rename moves everything without copying, so it cannot leave half a database
/// behind. A daemon already running keeps its open files, and its socket moves with
/// the folder, so clients at the new path reach it. The link left behind serves
/// older binaries and launch agents that still name the legacy path.
///
/// A legacy path that is already a link was made by `data move`, which points the
/// anchor at a folder somewhere else. The link itself is renamed, so that the data
/// stays where the person put it and the new anchor reaches it.
fn moveLegacy(io: Io, legacy: []const u8, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, legacy, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    // Data on another volume stays there, and this link was made on an earlier run.
    const target = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch null;
    if (target != null and target.?.kind == .sym_link) return;
    if (stat.kind == .sym_link) {
        if (target != null) return;
        Io.Dir.renameAbsolute(legacy, path, io) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return Io.Dir.symLinkAbsolute(io, path, legacy, .{});
    }
    if (stat.kind != .directory) return;

    Io.Dir.renameAbsolute(legacy, path, io) catch |err| switch (err) {
        // Another process moved it first, leaving nothing here or a link to the new folder.
        error.FileNotFound, error.IsDir => return,
        // Both locations hold data. The new one wins, and the old one stays untouched.
        error.DirNotEmpty => return,
        // A rename cannot cross volumes. Data stays put, and the new path points at it.
        error.CrossDevice => {
            cwd.deleteDir(io, path) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                // Both locations hold data, which the case above settles the same way.
                error.DirNotEmpty => return,
                else => return delete_err,
            };
            return Io.Dir.symLinkAbsolute(io, legacy, path, .{});
        },
        else => return err,
    };
    try Io.Dir.symLinkAbsolute(io, path, legacy, .{});
}
