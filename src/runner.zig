//! Subprocess boundary for installed writers. No database SQL lives here.
//! The subprocess boundary bounds resource use and keeps writer tools away from daemon state.

const std = @import("std");
const Service = @import("service.zig").Service;
const store = @import("store.zig");
const contract = @import("writer.zig");
const Io = std.Io;

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

fn probe(s: *Service, a: std.mem.Allocator, name: []const u8) !std.json.Value {
    try validateName(name);
    const result = std.process.run(
        a,
        s.io,
        .{
            .argv = &.{
                name,
                "--version",
            },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{
                .raw = .fromSeconds(5),
                .clock = .awake,
            } },
        },
    ) catch |err| return store.object(
        a,
        .{
            .writer = name,
            .available = false,
            .error_name = @errorName(err),
        },
    );
    return store.object(
        a,
        .{
            .writer = name,
            .available = result.term.success(),
            .version = std.mem.trim(u8, result.stdout, " \r\n"),
        },
    );
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
    var env = try std.process.Environ.createMap(s.environ, a);
    defer env.deinit();
    _ = env.swapRemove("FYKE_HOME");
    _ = env.swapRemove("FYKE_WRITER_CMD");
    var argv: []const []const u8 = undefined;
    if (std.process.Environ.getAlloc(s.environ, a, "FYKE_WRITER_CMD") catch null) |override| {
        // The override is an owner-supplied executable command, never feed data.
        argv = if (@import("builtin").os.tag == .windows) &.{
            "cmd",
            "/c",
            override,
        } else &.{
            "/bin/sh",
            "-c",
            try std.fmt.allocPrint(
                a,
                "exec {s}",
                .{override},
            ),
        };
    } else if (std.mem.eql(u8, name, "codex")) {
        argv = &.{
            "codex",
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
        };
    } else {
        argv = &.{
            "claude",
            "-p",
            "--output-format",
            "json",
            "--tools",
            "",
            "--strict-mcp-config",
            "--mcp-config",
            "{\"mcpServers\":{}}",
        };
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
        },
    );
    defer child.kill(s.io);
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(a, s.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
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
