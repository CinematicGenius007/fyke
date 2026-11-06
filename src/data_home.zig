//! Finds the data directory when `RSS_HOME` does not name one, and moves data out
//! of the location earlier versions used.

const std = @import("std");

const Io = std.Io;

const folder = ".rss_";
const legacy_folder = ".local/share/rss_";

/// The data directory for this user, after moving any data left at the legacy path.
pub fn resolve(arena: std.mem.Allocator, io: Io, user_home: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ user_home, folder });
    const legacy = try std.fmt.allocPrint(arena, "{s}/{s}", .{ user_home, legacy_folder });
    try moveLegacy(io, legacy, path);
    return path;
}

/// One rename moves everything without copying, so it cannot leave half a database
/// behind. A daemon already running keeps its open files, and its socket moves with
/// the folder, so clients at the new path reach it. The link left behind serves
/// older binaries and launch agents that still name the legacy path.
fn moveLegacy(io: Io, legacy: []const u8, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const stat = cwd.statFile(io, legacy, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    if (stat.kind != .directory) return;

    Io.Dir.renameAbsolute(legacy, path, io) catch |err| switch (err) {
        // Another process moved it first.
        error.FileNotFound => return,
        // Both locations hold data. The new one wins, and the old one stays untouched.
        error.DirNotEmpty => return,
        // A rename cannot cross volumes. Data stays put, and the new path points at it.
        error.CrossDevice => {
            cwd.deleteDir(io, path) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            return Io.Dir.symLinkAbsolute(io, legacy, path, .{});
        },
        else => return err,
    };
    try Io.Dir.symLinkAbsolute(io, path, legacy, .{});
}
