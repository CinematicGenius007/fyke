//! The `fyke` command: a thin client of the daemon's socket. See docs/api.md.
//! Nothing here touches the database, which is what keeps the daemon its only writer.

const std = @import("std");
const core = @import("core");
const client_module = @import("client.zig");
const daemon = @import("daemon.zig");
const data_home = @import("data_home.zig");
const data_move = @import("data_move.zig");
const autostart = @import("autostart.zig");
const mcp = @import("mcp.zig");
const ops = @import("ops.zig");
const tui = @import("tui.zig");

const Io = std.Io;
const Client = client_module.Client;

const usage =
    \\usage: fyke <command>
    \\
    \\  add <url> [--allow-private]    subscribe to a feed or a site
    \\  refresh [feed-id]              fetch one feed now, or queue all of them
    \\  remove <feed-id>               unsubscribe
    \\  feeds [--json]                 list subscriptions
    \\  list [--feed N] [--unread] [--starred] [--limit N] [--before CURSOR] [--json]
    \\  show <id> [--format markdown|text|blocks] [--json]
    \\  search <words> [--limit N] [--json]
    \\  mark <id> [--read] [--unread] [--star] [--unstar] [--hide] [--unhide]
    \\  import <file.opml> [--allow-private]
    \\  export                         print subscriptions as OPML
    \\  query <sql>                    run one read-only SQL statement
    \\  schema                         print the annotated database schema
    \\  status [--json]                counts, queue and uptime
    \\  ops                            list every operation
    \\  tui                            read in the terminal
    \\  mcp [--tier read|annotate|manage]   MCP server on stdio, for agents
    \\  daemon [stop]                  run in the foreground, or stop it
    \\  service install|uninstall|status   run the daemon from login, on macOS
    \\  data move <folder>             move the data folder, then restart
    \\
    \\Clients start the daemon when needed.
    \\Data lives in $FYKE_HOME, by default ~/.fyke
    \\
;

const Args = struct {
    items: []const []const u8,

    fn has(a: Args, flag: []const u8) bool {
        for (a.items) |item| {
            if (std.mem.eql(u8, item, flag)) return true;
        }
        return false;
    }

    fn value(a: Args, flag: []const u8) ?[]const u8 {
        for (a.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, flag) and i + 1 < a.items.len) return a.items[i + 1];
        }
        return null;
    }

    fn int(a: Args, flag: []const u8) !?i64 {
        const text = a.value(flag) orelse return null;
        return std.fmt.parseInt(i64, text, 10) catch error.Usage;
    }

    /// The first argument that is neither a flag nor a flag's value.
    fn positional(a: Args) ?[]const u8 {
        var i: usize = 0;
        while (i < a.items.len) : (i += 1) {
            const item = a.items[i];
            if (!std.mem.startsWith(u8, item, "--")) return item;
            if (takesValue(item)) i += 1;
        }
        return null;
    }

    fn positionalId(a: Args) !i64 {
        return std.fmt.parseInt(i64, a.positional() orelse return error.Usage, 10) catch error.Usage;
    }
};

fn takesValue(flag: []const u8) bool {
    const flags = [_][]const u8{ "--feed", "--limit", "--before", "--format", "--tier" };
    for (flags) |candidate| {
        if (std.mem.eql(u8, flag, candidate)) return true;
    }
    return false;
}

const App = struct {
    arena: std.mem.Allocator,
    io: Io,
    client: *Client,
    out: *Io.Writer,

    fn raw(app: App, comptime Op: type, params: Op.Params) !void {
        try app.out.print("{s}\n", .{try app.client.callRaw(Op, params)});
    }
};

/// A crash must not leave the terminal in raw mode on the alternate screen.
pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(message: []const u8, return_address: ?usize) noreturn {
    tui.restoreTerminal();
    std.debug.defaultPanic(message, return_address);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (argv.len < 2) {
        try out.writeAll(usage);
        return 2;
    }

    const home_path = try homeDirectory(arena, io, init.environ_map);
    const command = argv[1];
    const args: Args = .{ .items = argv[2..] };

    if (std.mem.eql(u8, command, "daemon") and args.positional() == null) {
        daemon.run(init.gpa, io, home_path, arena, .{ .log_to_file = args.has("--log") }) catch |err| {
            std.debug.print("fyke: daemon: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    const connector: client_module.Connector = .{ .arena = arena, .io = io, .environ = init.environ_map, .home_path = home_path };

    if (std.mem.eql(u8, command, "tui")) {
        tui.run(init.gpa, connector) catch |err| {
            tui.restoreTerminal();
            std.debug.print("fyke: tui: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "mcp")) {
        const tier = std.meta.stringToEnum(ops.Tier, args.value("--tier") orelse "read") orelse {
            try out.writeAll(usage);
            return 2;
        };
        mcp.run(connector, tier) catch |err| {
            std.debug.print("fyke: mcp: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    if (std.mem.eql(u8, command, "data")) {
        return dataCommand(connector, init.environ_map, args, out) catch |err| {
            try out.flush();
            std.debug.print("fyke: data: {s}\n", .{@errorName(err)});
            return 1;
        };
    }

    if (std.mem.eql(u8, command, "service")) {
        return serviceCommand(connector, init.environ_map, args, out) catch |err| {
            std.debug.print("fyke: service: {s}\n", .{@errorName(err)});
            return 1;
        };
    }

    const commands = [_]struct { []const u8, *const fn (App, Args) anyerror!void }{
        .{ "add", add },           .{ "refresh", refresh }, .{ "remove", remove },
        .{ "feeds", feeds },       .{ "list", list },       .{ "show", show },
        .{ "search", search },     .{ "mark", mark },       .{ "import", import },
        .{ "export", exportOpml }, .{ "query", query },     .{ "schema", schema },
        .{ "status", status },     .{ "ops", listOps },     .{ "daemon", daemonCommand },
    };
    for (commands) |entry| {
        if (!std.mem.eql(u8, command, entry[0])) continue;

        var client: Client = undefined;
        connector.connect(&client, !std.mem.eql(u8, command, "daemon")) catch |err| {
            std.debug.print("fyke: cannot reach the daemon: {s}\n", .{@errorName(err)});
            return 1;
        };
        const app: App = .{ .arena = arena, .io = io, .client = &client, .out = out };
        entry[1](app, args) catch |err| switch (err) {
            error.Usage => {
                try out.writeAll(usage);
                return 2;
            },
            error.Reported => {
                try out.flush();
                std.debug.print("fyke: {s}\n", .{client.last_error});
                return 1;
            },
            else => {
                try out.flush();
                std.debug.print("fyke: {s}: {s}\n", .{ command, @errorName(err) });
                return 1;
            },
        };
        return 0;
    }
    try out.writeAll(usage);
    return 2;
}

fn dataCommand(connector: client_module.Connector, environ: *const std.process.Environ.Map, args: Args, out: *Io.Writer) !u8 {
    const user_home = environ.get("HOME") orelse return error.NoHomeDirectory;
    const action = args.positional() orelse "";
    if (!std.mem.eql(u8, action, "move")) {
        try out.writeAll(usage);
        return 2;
    }
    const target = if (args.items.len > 1) args.items[1] else {
        try out.writeAll(usage);
        return 2;
    };
    try data_move.run(connector, user_home, target, out);
    return 0;
}

fn serviceCommand(connector: client_module.Connector, environ: *const std.process.Environ.Map, args: Args, out: *Io.Writer) !u8 {
    const user_home = environ.get("HOME") orelse return error.NoHomeDirectory;
    const action = args.positional() orelse "";
    if (std.mem.eql(u8, action, "install")) {
        try autostart.install(connector, user_home);
        try out.writeAll("installed: the daemon now runs from login\n");
    } else if (std.mem.eql(u8, action, "uninstall")) {
        try autostart.uninstall(connector, user_home);
        try out.writeAll("uninstalled\n");
    } else if (std.mem.eql(u8, action, "status")) {
        try out.writeAll(if (try autostart.isInstalled(connector, user_home)) "installed\n" else "not installed\n");
    } else {
        try out.writeAll(usage);
        return 2;
    }
    return 0;
}

fn homeDirectory(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("FYKE_HOME")) |path| return path;
    const user_home = environ.get("HOME") orelse return error.NoHomeDirectory;
    return data_home.resolve(arena, io, user_home);
}

fn printOutcome(app: App, result: ops.RefreshResult) !void {
    const id = result.id;
    if (std.mem.eql(u8, result.status, "updated")) {
        try app.out.print("feed {d}: {d} new, {d} updated\n", .{ id, result.new, result.updated });
    } else if (std.mem.eql(u8, result.status, "not_modified")) {
        try app.out.print("feed {d}: not modified\n", .{id});
    } else if (std.mem.eql(u8, result.status, "unchanged_body")) {
        try app.out.print("feed {d}: unchanged\n", .{id});
    } else if (std.mem.eql(u8, result.status, "gone")) {
        try app.out.print("feed {d}: gone, polling stopped\n", .{id});
    } else if (std.mem.eql(u8, result.status, "busy")) {
        try app.out.print("feed {d}: already being fetched\n", .{id});
    } else {
        try app.out.print("feed {d}: failed: {s}\n", .{ id, result.message orelse "unknown" });
    }
}

fn add(app: App, args: Args) !void {
    const target = args.positional() orelse return error.Usage;
    try printOutcome(app, try app.client.call(ops.FeedsAdd, .{ .url = target, .allow_private_network = args.has("--allow-private") }));
}

fn refresh(app: App, args: Args) !void {
    if (args.positional() != null) {
        return printOutcome(app, try app.client.call(ops.FeedsRefresh, .{ .id = try args.positionalId() }));
    }
    const result = try app.client.call(ops.FeedsRefreshAll, .{});
    try app.out.print("queued {d} feeds\n", .{result.queued});
}

fn remove(app: App, args: Args) !void {
    _ = try app.client.call(ops.FeedsRemove, .{ .id = try args.positionalId() });
}

fn feeds(app: App, args: Args) !void {
    if (args.has("--json")) return app.raw(ops.FeedsList, .{});
    const result = try app.client.call(ops.FeedsList, .{});
    for (result.items) |row| {
        try app.out.print("{d:>4}  {d:>5}/{d:<5}  {s}", .{ @as(u64, @intCast(row.id)), @as(u64, @intCast(row.unread)), @as(u64, @intCast(row.entries)), row.title orelse row.url });
        if (!std.mem.eql(u8, row.status, "active")) try app.out.print("  [{s}]", .{row.status});
        if (row.last_error) |message| try app.out.print("  [{s}]", .{message});
        try app.out.writeByte('\n');
    }
}

fn list(app: App, args: Args) !void {
    const limit = try args.int("--limit") orelse 30;
    if (limit < 1) return error.Usage;
    const params: ops.EntriesList.Params = .{
        .feed_id = try args.int("--feed"),
        .unread_only = args.has("--unread"),
        .starred_only = args.has("--starred"),
        .limit = limit,
        .before = args.value("--before"),
    };
    if (args.has("--json")) return app.raw(ops.EntriesList, params);
    const result = try app.client.call(ops.EntriesList, params);
    try printSummaries(app, result.items);
    if (result.next_cursor) |text| try app.out.print("more: --before {s}\n", .{text});
}

fn printSummaries(app: App, rows: anytype) !void {
    for (rows) |row| {
        const marker: u8 = if (row.starred) '*' else if (row.read) ' ' else '+';
        try app.out.print("{d:>7} {c} {s}  ({s})\n", .{ @as(u64, @intCast(row.id)), marker, row.title orelse "(untitled)", row.feed_title orelse "?" });
    }
}

fn show(app: App, args: Args) !void {
    const params: ops.EntriesGet.Params = .{ .id = try args.positionalId(), .format = args.value("--format") orelse "markdown" };
    if (args.has("--json")) return app.raw(ops.EntriesGet, params);
    const entry = try app.client.call(ops.EntriesGet, params);
    try app.out.print("{s}\n{s}", .{ entry.title orelse "(untitled)", entry.feed_title orelse "?" });
    if (entry.author) |author| try app.out.print(" - {s}", .{author});
    try app.out.writeByte('\n');
    if (entry.url) |link| try app.out.print("{s}\n", .{link});
    try app.out.print("\n{s}\n", .{entry.body});
}

fn search(app: App, args: Args) !void {
    var words: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < args.items.len) : (i += 1) {
        const item = args.items[i];
        if (std.mem.startsWith(u8, item, "--")) {
            if (takesValue(item)) i += 1;
            continue;
        }
        try words.appendSlice(app.arena, item);
        try words.append(app.arena, ' ');
    }
    if (words.items.len == 0) return error.Usage;
    const params: ops.EntriesSearch.Params = .{ .query = words.items, .limit = try args.int("--limit") orelse 30 };
    if (args.has("--json")) return app.raw(ops.EntriesSearch, params);
    try printSummaries(app, (try app.client.call(ops.EntriesSearch, params)).items);
}

fn mark(app: App, args: Args) !void {
    var params: ops.EntriesMark.Params = .{ .id = try args.positionalId() };
    if (args.has("--read")) params.read = true;
    if (args.has("--unread")) params.read = false;
    if (args.has("--star")) params.starred = true;
    if (args.has("--unstar")) params.starred = false;
    if (args.has("--hide")) params.hidden = true;
    if (args.has("--unhide")) params.hidden = false;
    if (params.read == null and params.starred == null and params.hidden == null) return error.Usage;
    _ = try app.client.call(ops.EntriesMark, params);
}

fn import(app: App, args: Args) !void {
    const path = args.positional() orelse return error.Usage;
    // The daemon may run in another directory, so the path must be absolute.
    const absolute = try Io.Dir.cwd().realPathFileAlloc(app.io, path, app.arena);
    const result = try app.client.call(ops.OpmlImport, .{ .path = absolute, .allow_private_network = args.has("--allow-private") });
    try app.out.print("{d} added, {d} already subscribed\n", .{ result.added, result.existing });
}

fn exportOpml(app: App, _: Args) !void {
    try app.out.writeAll((try app.client.call(ops.OpmlExport, .{})).opml);
}

fn query(app: App, args: Args) !void {
    try app.raw(ops.DbQuery, .{ .sql = args.positional() orelse return error.Usage });
}

fn schema(app: App, _: Args) !void {
    try app.out.writeAll((try app.client.call(ops.SchemaDescribe, .{})).schema);
}

fn status(app: App, args: Args) !void {
    if (args.has("--json")) return app.raw(ops.StatsGet, .{});
    const s = try app.client.call(ops.StatsGet, .{});
    try app.out.print("{d} feeds, {d} entries, {d} unread\n{d} due, {d} fetching, {d} failing\nup {d} s\n", .{
        @as(u64, @intCast(s.feeds)),          @as(u64, @intCast(s.entries)), @as(u64, @intCast(s.unread)),
        @as(u64, @intCast(s.due)),            s.in_flight,                   @as(u64, @intCast(s.failing)),
        @as(u64, @intCast(s.uptime_seconds)),
    });
}

fn listOps(app: App, _: Args) !void {
    for ((try app.client.call(ops.OpsList, .{})).items) |item| {
        try app.out.print("{s:<20} {s:<9} {s}\n", .{ item.name, item.tier, item.description });
    }
}

fn daemonCommand(app: App, args: Args) !void {
    const action = args.positional() orelse return error.Usage;
    if (!std.mem.eql(u8, action, "stop")) return error.Usage;
    _ = try app.client.call(ops.DaemonStop, .{});
}

test {
    _ = autostart;
    _ = @import("launchd.zig");
    _ = @import("systemd.zig");
    _ = data_move;
    _ = @import("pipeline.zig");
    _ = @import("store.zig");
    _ = mcp;
    _ = tui;
    _ = ops;
}
