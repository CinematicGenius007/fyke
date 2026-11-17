//! Subprocess boundary for installed writers. No database SQL lives here.
//! The subprocess boundary bounds resource use and keeps writer tools away from daemon state.

const std = @import("std");
const Service = @import("service.zig").Service;
const store = @import("store.zig");
const contract = @import("writer.zig");
const Io = std.Io;
const builtin = @import("builtin");
const platform = @import("platform.zig");

/// Accepts only installed writer adapters known to the fixed command builder.
pub fn validateName(name: []const u8) !void {
    if (!std.mem.eql(u8, name, "codex") and !std.mem.eql(u8, name, "claude")) return error.UnknownWriter;
}

/// Reads the owner-selected adapter, defaulting to Codex when no choice is stored.
pub fn selected(s: *Service, a: std.mem.Allocator) ![]const u8 {
    const text = try @import("service.zig").readConfigFile(s, a);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    if (root == .object) {
        if (root.object.get("ai")) |ai| {
            if (ai == .object) {
                if (ai.object.get("writer")) |w| {
                    if (w == .string) {
                        try validateName(w.string);
                        return w.string;
                    }
                }
            }
        }
    }
    return "codex";
}

/// The directories searched for a writer, in order: the daemon's own `PATH`, then the
/// `PATH` the owner's login shell sets up, then the usual install folders. A daemon
/// started by the app or by launchd inherits only the system folders, so without the
/// login shell's `PATH` a writer installed with Homebrew, npm or a per-user installer
/// would not be found, and a Node-based writer could not find `node` either.
fn searchPath(s: *Service, a: std.mem.Allocator) ![]const u8 {
    const separator = if (builtin.os.tag == .windows) ";" else ":";
    var parts: std.ArrayList([]const u8) = .empty;
    if (std.process.Environ.getAlloc(s.environ, a, "PATH") catch null) |own| try parts.append(a, own);
    if (builtin.os.tag != .windows) {
        if (loginShellPath(s, a)) |login| try parts.append(a, login);
        if (std.process.Environ.getAlloc(s.environ, a, "HOME") catch null) |home| {
            try parts.append(a, try std.fmt.allocPrint(a, "{s}/.local/bin", .{home}));
        }
        try parts.append(a, "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin");
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var joined: std.ArrayList(u8) = .empty;
    for (parts.items) |part| {
        var dirs = std.mem.tokenizeAny(u8, part, separator);
        while (dirs.next()) |dir| {
            if ((try seen.getOrPut(a, dir)).found_existing) continue;
            if (joined.items.len != 0) try joined.appendSlice(a, separator);
            try joined.appendSlice(a, dir);
        }
    }
    return joined.items;
}

/// Asks the owner's login shell for its `PATH`. A marker separates it from anything
/// the shell's startup files print. Returns null when the shell fails or takes longer
/// than three seconds.
fn loginShellPath(s: *Service, a: std.mem.Allocator) ?[]const u8 {
    const shell = std.process.Environ.getAlloc(s.environ, a, "SHELL") catch null;
    const marker = "__fyke_path__";
    const result = std.process.run(a, s.io, .{
        .argv = &.{ shell orelse "/bin/sh", "-l", "-c", "printf '" ++ marker ++ "%s' \"$PATH\"" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } },
    }) catch return null;
    if (!result.term.success()) return null;
    const start = std.mem.lastIndexOf(u8, result.stdout, marker) orelse return null;
    return result.stdout[start + marker.len ..];
}

/// Finds `name` as an executable file in `path`, so the writer runs from where the
/// owner installed it. Falls back to the bare name, which the system then looks up.
fn locate(s: *Service, a: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    const separator = if (builtin.os.tag == .windows) ";" else ":";
    if (builtin.os.tag == .windows) return name;
    var dirs = std.mem.tokenizeAny(u8, path, separator);
    while (dirs.next()) |dir| {
        const candidate = try std.fs.path.join(a, &.{ dir, name });
        Io.Dir.cwd().access(s.io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return name;
}

/// The Claude Code profile folder the owner chose under `ai.claude_profile`, or null
/// for Claude Code's own default. Claude Code keeps a sign-in per profile folder.
fn claudeProfile(s: *Service, a: std.mem.Allocator) !?[]const u8 {
    const text = try @import("service.zig").readConfigFile(s, a);
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return null;
    if (root != .object) return null;
    const ai = root.object.get("ai") orelse return null;
    if (ai != .object) return null;
    const profile = ai.object.get("claude_profile") orelse return null;
    if (profile != .string or profile.string.len == 0) return null;
    return profile.string;
}

/// The environment a writer runs with: the daemon's own, without Fyke's private
/// variables, with the writer search path, and with the chosen Claude Code profile.
fn writerEnvironment(s: *Service, a: std.mem.Allocator, name: []const u8, path: []const u8) !std.process.Environ.Map {
    var env = try std.process.Environ.createMap(s.environ, a);
    _ = env.swapRemove("FYKE_HOME");
    _ = env.swapRemove("FYKE_WRITER_CMD");
    try env.put("PATH", path);
    if (std.mem.eql(u8, name, "claude")) {
        if (try claudeProfile(s, a)) |profile| try env.put("CLAUDE_CONFIG_DIR", profile);
    }
    return env;
}

/// Reads `loggedIn` from the JSON that `claude auth status` prints. Null when the
/// output is not that JSON.
pub fn claudeSignedIn(a: std.mem.Allocator, output: []const u8) ?bool {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, output, .{}) catch return null;
    if (root != .object) return null;
    const value = root.object.get("loggedIn") orelse return null;
    return if (value == .bool) value.bool else null;
}

test claudeSignedIn {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?bool, true), claudeSignedIn(a, "{\"loggedIn\": true, \"authMethod\": \"claude.ai\"}"));
    try std.testing.expectEqual(@as(?bool, false), claudeSignedIn(a, "{\"loggedIn\": false}"));
    try std.testing.expectEqual(@as(?bool, null), claudeSignedIn(a, "Not a status"));
    try std.testing.expectEqual(@as(?bool, null), claudeSignedIn(a, "{\"loggedIn\": \"yes\"}"));
}

fn runQuick(s: *Service, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.Environ.Map) !std.process.RunResult {
    return std.process.run(a, s.io, .{
        .argv = argv,
        .environ_map = env,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
}

/// Finds a writer, reads its version, then asks it whether it is signed in, so that
/// "available" means a brief can actually be written. `problem` says in words what
/// stands in the way.
fn probe(s: *Service, a: std.mem.Allocator, name: []const u8) !std.json.Value {
    try validateName(name);
    const path = try searchPath(s, a);
    var env = try writerEnvironment(s, a, name, path);
    defer env.deinit();
    const exe = try locate(s, a, name, path);
    const profile = if (std.mem.eql(u8, name, "claude")) try claudeProfile(s, a) else null;
    const version = runQuick(s, a, &.{ exe, "--version" }, &env) catch |err| return store.object(a, .{
        .writer = name,
        .available = false,
        .installed = false,
        .error_name = @errorName(err),
        .problem = "Not found on this Mac",
        .profile = profile,
    });
    if (!version.term.success()) return store.object(a, .{
        .writer = name,
        .available = false,
        .installed = false,
        .error_name = "WriterFailed",
        .problem = "Found, but its version check failed",
        .profile = profile,
    });
    const status_argv: []const []const u8 = if (std.mem.eql(u8, name, "claude"))
        &.{ exe, "auth", "status" }
    else
        &.{ exe, "login", "status" };
    const signed_in: bool = if (runQuick(s, a, status_argv, &env)) |status|
        if (std.mem.eql(u8, name, "claude"))
            claudeSignedIn(a, status.stdout) orelse status.term.success()
        else
            status.term.success()
    else |_|
        false;
    const sign_in_hint = if (std.mem.eql(u8, name, "claude"))
        (if (profile != null) "Not signed in with this profile. Run claude, then /login." else "Not signed in. Run claude, then /login, or choose the profile folder you use.")
    else
        "Not signed in. Run codex login.";
    return store.object(a, .{
        .writer = name,
        .available = signed_in,
        .installed = true,
        .signed_in = signed_in,
        .version = std.mem.trim(u8, version.stdout, " \r\n"),
        .path = exe,
        .problem = if (signed_in) null else sign_in_hint,
        .profile = profile,
    });
}

/// Drops a cached probe so the next list runs it again, after a setting it depends on
/// changed.
pub fn forget(s: *Service, name: []const u8) void {
    s.writer_probes_lock.lockUncancelable(s.io);
    defer s.writer_probes_lock.unlock(s.io);
    s.writer_probes[if (std.mem.eql(u8, name, "codex")) @as(usize, 0) else 1].len = 0;
}

// Hold one lock through a probe: concurrent first reads must not spawn the same
// command twice. Request arenas only receive parsed copies of daemon-owned JSON.
fn cachedProbe(s: *Service, a: std.mem.Allocator, name: []const u8, refresh: bool) !std.json.Value {
    try validateName(name);
    s.writer_probes_lock.lockUncancelable(s.io);
    defer s.writer_probes_lock.unlock(s.io);
    const cache = &s.writer_probes[if (std.mem.eql(u8, name, "codex")) @as(usize, 0) else 1];
    if (refresh or cache.len == 0) {
        var result = try probe(s, a, name);
        try result.object.put(a, "checked_at", .{ .integer = s.now() });
        const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(result, .{})});
        if (json.len > cache.json.len) return error.OutputTooLarge;
        @memcpy(cache.json[0..json.len], json);
        cache.len = json.len;
    }
    return std.json.parseFromSliceLeaky(std.json.Value, a, cache.json[0..cache.len], .{});
}

/// Returns cached probe results and marks the adapter selected in configuration.
pub fn list(s: *Service, a: std.mem.Allocator) !std.json.Value {
    const chosen = try selected(s, a);
    var items: std.ArrayList(std.json.Value) = .empty;
    for ([_][]const u8{ "codex", "claude" }) |name| {
        var item = try cachedProbe(s, a, name, false);
        try item.object.put(a, "selected", .{ .bool = std.mem.eql(u8, name, chosen) });
        try items.append(a, item);
    }
    return store.object(a, .{ .items = items.items });
}

/// Runs a bounded writer process in an empty scratch directory and honors cancellation.
pub fn execute(
    s: *Service,
    a: std.mem.Allocator,
    job_id: i64,
    name: []const u8,
    prompt: []const u8,
    seconds: i64,
) ![]const u8 {
    const dirname = try std.fmt.allocPrint(a, "writer-{d}-{d}", .{ job_id, Io.Clock.real.now(s.io).toNanoseconds() });
    try s.home.createDir(s.io, dirname, .default_dir);
    defer s.home.deleteTree(s.io, dirname) catch {};
    var dir = try s.home.openDir(s.io, dirname, .{});
    defer dir.close(s.io);
    try dir.writeFile(s.io, .{ .sub_path = "input", .data = prompt });
    var input = try dir.openFile(s.io, "input", .{});
    defer input.close(s.io);
    try dir.writeFile(s.io, .{ .sub_path = "schema.json", .data = contract.schema });
    const path = try searchPath(s, a);
    var env = try writerEnvironment(s, a, name, path);
    defer env.deinit();
    var argv: []const []const u8 = undefined;
    if (std.process.Environ.getAlloc(s.environ, a, "FYKE_WRITER_CMD") catch null) |override| {
        // The override is an owner-supplied executable command, never feed data.
        argv = if (builtin.os.tag == .windows) try a.dupe([]const u8, &.{
            "cmd",
            "/c",
            override,
        }) else try a.dupe([]const u8, &.{
            "/bin/sh",
            "-c",
            try std.fmt.allocPrint(a, "exec {s}", .{override}),
        });
    } else if (std.mem.eql(u8, name, "codex")) {
        argv = try a.dupe([]const u8, &.{
            try locate(s, a, "codex", path),
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-user-config",
            "--sandbox",
            "read-only",
            "--output-schema",
            "schema.json",
            "--output-last-message",
            "result.json",
            "-",
        });
    } else {
        argv = try a.dupe([]const u8, &.{
            try locate(s, a, "claude", path),
            "-p",
            "--output-format",
            "json",
            "--tools",
            "",
            "--strict-mcp-config",
            "--mcp-config",
            "{\"mcpServers\":{}}",
        });
    }
    var child = try std.process.spawn(
        s.io,
        .{
            .argv = argv,
            .cwd = .{ .dir = dir },
            .environ_map = &env,
            .stdin = .{ .file = input },
            .stdout = .pipe,
            .stderr = .pipe,
            .start_suspended = platform.is_windows,
        },
    );
    defer child.kill(s.io);
    var tree = platform.ProcessTree.adopt(&child);
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(a, s.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    // Declared after the reader so that it runs first: once the whole tree has ended,
    // its pipes close and the pending reads finish.
    defer tree.end();
    const deadline = s.now() + seconds * 1000;
    while (true) {
        {
            const db = s.lockReader();
            defer s.unlockReader();
            if (try db.jobStatus(job_id) == .cancelled) return error.JobCancelled;
        }
        if (s.now() >= deadline) return error.WriterTimeout;
        multi.fill(
            4096,
            .{ .duration = .{
                .raw = .fromMilliseconds(100),
                .clock = .awake,
            } },
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => continue,
            else => return err,
        };
        if (multi.reader(0).buffered().len + multi.reader(1).buffered().len > 1 << 20) return error.OutputTooLarge;
    }
    try multi.checkAnyError();
    const Race = union(enum) { finished: std.process.Child.WaitError!std.process.Child.Term, stopped: anyerror!void };
    var race_buffer: [2]Race = undefined;
    var race: Io.Select(Race) = .init(s.io, &race_buffer);
    defer race.cancelDiscard();
    try race.concurrent(.finished, std.process.Child.wait, .{ &child, s.io });
    try race.concurrent(.stopped, watch, .{ s, job_id, deadline });
    const term = switch (try race.await()) {
        .finished => |result| try result,
        .stopped => |result| {
            try result;
            return error.WriterTimeout;
        },
    };
    if (!term.success()) return error.WriterFailed;
    var result: []const u8 = multi.reader(0).buffered();
    if (dir.readFileAlloc(s.io, "result.json", a, .limited(1 << 20))) |last| {
        result = last;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (std.mem.eql(u8, name, "claude")) {
        const root = std.json.parseFromSliceLeaky(std.json.Value, a, result, .{}) catch return result;
        if (root == .object) if (root.object.get("result")) |v| {
            if (v == .string) return v.string;
        };
    }
    return a.dupe(u8, result);
}

fn watch(s: *Service, id: i64, deadline: i64) !void {
    while (true) {
        {
            const db = s.lockReader();
            defer s.unlockReader();
            if (try db.jobStatus(id) == .cancelled) return error.JobCancelled;
        }
        if (s.now() >= deadline) return error.WriterTimeout;
        try s.io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Refreshes one cached probe and persists its timestamped result in configuration.
pub fn check(s: *Service, a: std.mem.Allocator, name: []const u8) !std.json.Value {
    const result = try cachedProbe(s, a, name, true);
    s.config_lock.lockUncancelable(s.io);
    defer s.config_lock.unlock(s.io);
    const config_text = s.home.readFileAlloc(s.io, "config.json", a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "{}",
        else => return err,
    };
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a, config_text, .{});
    if (root != .object) return error.InvalidConfig;
    var ai = root.object.get("ai") orelse std.json.Value{ .object = .empty };
    if (ai != .object) return error.InvalidConfig;
    var checks = ai.object.get("checks") orelse std.json.Value{ .object = .empty };
    if (checks != .object) return error.InvalidConfig;
    try checks.object.put(a, name, result);
    try ai.object.put(a, "checks", checks);
    try root.object.put(a, "ai", ai);
    try s.home.writeFile(
        s.io,
        .{
            .sub_path = "config.json.tmp",
            .data = try std.fmt.allocPrint(
                a,
                "{f}\n",
                .{std.json.fmt(
                    root,
                    .{ .whitespace = .indent_2 },
                )},
            ),
        },
    );
    try s.home.rename("config.json.tmp", s.home, "config.json", s.io);
    return result;
}

/// A crashed daemon cannot remove its scratch directories. Only names produced
/// by execute are eligible, so unrelated owner files remain untouched.
pub fn cleanup(s: *Service) !void {
    var home = try s.home.openDir(s.io, ".", .{ .iterate = true });
    defer home.close(s.io);
    var iterator = home.iterate();
    while (try iterator.next(s.io)) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "writer-")) continue;
        const suffix = entry.name[7..];
        if (suffix.len == 0) continue;
        const own = for (suffix) |c| {
            if (!std.ascii.isDigit(c) and c != '-') break false;
        } else true;
        if (own) try home.deleteTree(s.io, entry.name);
    }
}
