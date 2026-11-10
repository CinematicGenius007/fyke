//! `fyke tui`: a terminal reader, and a client of the socket like any other.
//!
//! The drawing model is simple on purpose: each frame draws everything into a
//! cell grid, and `Screen.render` sends only what changed. Nothing tracks what is
//! on the terminal, so the display cannot drift out of step with the state.
//!
//! The main thread owns all state. Input, resizes and daemon events all arrive as
//! readable file descriptors, so a single poll() loop serves them with no locks.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const client_module = @import("client.zig");
const ops = @import("ops.zig");
const store = @import("store.zig");

const Io = std.Io;
const Client = client_module.Client;
const terminal = core.terminal;
const Screen = terminal.Screen;
const Style = terminal.Style;
const Key = terminal.Key;
const console = @import("console.zig");

const page_size = 100;
/// A lone ESC byte could be the Escape key or the start of a sequence.
const escape_wait_ms = 30;
const live_refresh_ms = 400;
const fetch_watch_ms = 700;
const max_reader_columns = 72;
/// Each entry takes a title line and a detail line.
const row_height = 2;
/// Wheel steps, in rows, for a list and for an article.
const wheel_list_rows = 1;
const wheel_reader_lines = 3;
const no_hit = std.math.maxInt(usize);
const max_screen_rows = 512;
const min_columns = 20;
const min_rows = 6;

// 1000 asks for clicks and the wheel, and 1006 for reports that work at any size.
// Terminals keep text selection available with a modifier, usually Shift or Option.
const enter_sequence = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h";
const leave_sequence = "\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[0m\x1b[?1049l";

/// Puts the terminal back. Safe from a signal handler on POSIX systems.
pub fn restoreTerminal() void {
    console.restore();
}

const wake = console.wake;

const Pane = enum { feeds, entries, reader };

const Source = union(enum) {
    all,
    starred,
    feed: i64,
};

const Reader = struct {
    entry: ops.EntriesGet.Result,
    nodes: []const core.blocks.Node,
    article: core.layout.Article = .{ .lines = &.{}, .links = &.{} },
    laid_out_for: usize = 0,
    scroll: usize = 0,
};

const PromptKind = enum { search, add };
const max_prompt = 1024;

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    connector: client_module.Connector,
    client: Client = undefined,
    connected: bool = false,

    screen: Screen,
    previous: Screen,
    first_frame: bool = true,

    focus: Pane = .feeds,
    show_help: bool = false,
    unread_only: bool = false,
    message: []const u8 = "",
    message_buffer: [256]u8 = undefined,

    feeds_arena: std.heap.ArenaAllocator,
    feeds: []const store.Feed = &.{},
    side_index: usize = 0,
    side_top: usize = 0,

    entries_arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(store.EntrySummary) = .empty,
    entry_index: usize = 0,
    entry_top: usize = 0,
    next_cursor: ?[]const u8 = null,
    search: ?[]const u8 = null,

    reader_arena: std.heap.ArenaAllocator,
    layout_arena: std.heap.ArenaAllocator,
    reader: ?Reader = null,

    scratch: std.heap.ArenaAllocator,
    prompt: ?PromptKind = null,
    prompt_text: std.ArrayList(u8) = .empty,

    /// Adding a feed can take as long as a slow site does, so it runs on a thread of
    /// its own. That thread owns the buffers below while `adding` is true.
    adding: std.atomic.Value(bool) = .init(false),
    add_url: [max_prompt]u8 = undefined,
    add_url_len: usize = 0,
    add_result: [256]u8 = undefined,
    add_result_len: usize = 0,

    stats: ?ops.StatsGet.Result = null,
    watching_fetches: bool = false,
    live_pending: bool = false,
    last_seq: std.atomic.Value(i64) = .init(0),

    running: bool = true,

    /// Where the last frame drew, so that a click can find what it hit.
    side_range: [2]usize = .{ 0, 0 },
    list_range: [2]usize = .{ 0, 0 },
    reader_range: [2]usize = .{ 0, 0 },
    side_hits: [max_screen_rows]usize = @splat(no_hit),
    list_hits: [max_screen_rows]usize = @splat(no_hit),

    /// Command for the terminal browser. See `readConfig`.
    terminal_browser: []const u8 = "terminal-browser",

    fn deinit(app: *App) void {
        app.screen.deinit(app.gpa);
        app.previous.deinit(app.gpa);
        app.feeds_arena.deinit();
        app.entries_arena.deinit();
        app.reader_arena.deinit();
        app.layout_arena.deinit();
        app.scratch.deinit();
        app.prompt_text.deinit(app.gpa);
    }

    fn say(app: *App, comptime format: []const u8, args: anytype) void {
        app.message = std.fmt.bufPrint(&app.message_buffer, format, args) catch "";
    }

    fn connect(app: *App) !void {
        try app.connector.connect(&app.client, true);
        app.connected = true;
    }

    /// Calls the daemon, reconnecting once if it restarted. Failures become a
    /// message on the status line, because a reader should not die with its daemon.
    fn call(app: *App, comptime Op: type, arena: std.mem.Allocator, params: Op.Params) ?Op.Result {
        for (0..2) |_| {
            if (!app.connected) app.connect() catch |err| {
                app.say("Cannot reach the daemon: {s}", .{@errorName(err)});
                return null;
            };
            app.client.arena = arena;
            return app.client.call(Op, params) catch |err| switch (err) {
                error.Reported => {
                    app.say("{s}", .{app.client.last_error});
                    return null;
                },
                else => {
                    app.client.stream.close(app.io);
                    app.connected = false;
                    continue;
                },
            };
        }
        app.say("The daemon is not responding", .{});
        return null;
    }

    /// Reads the settings that belong to this client from config.json.
    fn readConfig(app: *App) void {
        const arena = app.connector.arena;
        const path = std.fmt.allocPrint(arena, "{s}/config.json", .{app.connector.home_path}) catch return;
        const text = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(1 << 20)) catch return;
        const Settings = struct { terminal_browser: ?[]const u8 = null };
        const settings = std.json.parseFromSliceLeaky(Settings, arena, text, .{ .ignore_unknown_fields = true }) catch return;
        if (settings.terminal_browser) |command| app.terminal_browser = command;
    }

    fn sideCount(app: *const App) usize {
        return 2 + app.feeds.len;
    }

    fn source(app: *const App) Source {
        return switch (app.side_index) {
            0 => .all,
            1 => .starred,
            else => .{ .feed = app.feeds[app.side_index - 2].id },
        };
    }

    fn loadFeeds(app: *App) void {
        var fresh: std.heap.ArenaAllocator = .init(app.gpa);
        const result = app.call(ops.FeedsList, fresh.allocator(), .{}) orelse {
            fresh.deinit();
            return;
        };
        app.feeds_arena.deinit();
        app.feeds_arena = fresh;
        app.feeds = result.items;
        app.side_index = @min(app.side_index, app.sideCount() - 1);
    }

    fn loadStats(app: *App) void {
        app.stats = app.call(ops.StatsGet, app.scratch.allocator(), .{});
    }

    /// Reloads the list, keeping the selection on the same entry if it still exists.
    fn loadEntries(app: *App) void {
        const selected: ?i64 = if (app.entry_index < app.entries.items.len) app.entries.items[app.entry_index].id else null;
        const wanted: i64 = @intCast(@max(page_size, app.entries.items.len));

        var fresh: std.heap.ArenaAllocator = .init(app.gpa);
        const arena = fresh.allocator();
        var rows: []const store.EntrySummary = undefined;
        var cursor: ?[]const u8 = null;
        if (app.search) |query| {
            const result = app.call(ops.EntriesSearch, arena, .{ .query = query, .limit = 200, .unread_only = app.unread_only }) orelse {
                fresh.deinit();
                return;
            };
            rows = result.items;
        } else {
            const result = app.call(ops.EntriesList, arena, app.listParams(wanted, null)) orelse {
                fresh.deinit();
                return;
            };
            rows = result.items;
            cursor = result.next_cursor;
        }

        var list: std.ArrayList(store.EntrySummary) = .empty;
        list.appendSlice(arena, rows) catch {
            fresh.deinit();
            return;
        };
        const query_copy = if (app.search) |query| arena.dupe(u8, query) catch query else null;
        app.entries_arena.deinit();
        app.entries_arena = fresh;
        app.entries = list;
        app.next_cursor = cursor;
        app.search = query_copy;

        app.entry_index = 0;
        if (selected) |id| {
            for (app.entries.items, 0..) |row, i| {
                if (row.id == id) app.entry_index = i;
            }
        }
    }

    fn listParams(app: *const App, limit: i64, before: ?[]const u8) ops.EntriesList.Params {
        const current = app.source();
        return .{
            .feed_id = if (current == .feed) current.feed else null,
            .starred_only = current == .starred,
            .unread_only = app.unread_only,
            .limit = limit,
            .before = before,
        };
    }

    /// Fetches the next page when the selection nears the end of what is loaded.
    fn loadMore(app: *App) void {
        const cursor = app.next_cursor orelse return;
        if (app.search != null or app.entry_index + 20 < app.entries.items.len) return;
        const arena = app.entries_arena.allocator();
        const result = app.call(ops.EntriesList, arena, app.listParams(page_size, cursor)) orelse return;
        app.entries.appendSlice(arena, result.items) catch return;
        app.next_cursor = result.next_cursor;
    }

    fn resetList(app: *App) void {
        app.entries.clearRetainingCapacity();
        app.entry_index = 0;
        app.entry_top = 0;
        app.loadEntries();
    }

    fn selectedEntry(app: *App) ?*store.EntrySummary {
        if (app.entry_index >= app.entries.items.len) return null;
        return &app.entries.items[app.entry_index];
    }

    fn openEntry(app: *App) void {
        const row = app.selectedEntry() orelse return;
        const id = row.id;
        var fresh: std.heap.ArenaAllocator = .init(app.gpa);
        const arena = fresh.allocator();
        const entry = app.call(ops.EntriesGet, arena, .{ .id = id, .format = "blocks" }) orelse {
            fresh.deinit();
            return;
        };
        const nodes = core.blocks.parseJson(arena, entry.body) catch &.{};

        app.reader_arena.deinit();
        app.reader_arena = fresh;
        app.reader = .{ .entry = entry, .nodes = nodes };
        app.focus = .reader;

        if (!row.read) {
            row.read = true;
            _ = app.call(ops.EntriesMark, app.scratch.allocator(), .{ .id = id, .read = true });
            app.loadFeeds();
        }
    }

    fn toggleRead(app: *App) void {
        const row = app.selectedEntry() orelse return;
        row.read = !row.read;
        _ = app.call(ops.EntriesMark, app.scratch.allocator(), .{ .id = row.id, .read = row.read });
        app.loadFeeds();
    }

    fn toggleStar(app: *App) void {
        const row = app.selectedEntry() orelse return;
        row.starred = !row.starred;
        _ = app.call(ops.EntriesMark, app.scratch.allocator(), .{ .id = row.id, .starred = row.starred });
    }

    fn nextUnread(app: *App) void {
        var i = app.entry_index + 1;
        while (i < app.entries.items.len) : (i += 1) {
            if (!app.entries.items[i].read) {
                app.entry_index = i;
                app.loadMore();
                app.openEntry();
                return;
            }
        }
        app.say("No more unread entries here", .{});
    }

    /// Hands a link to the system. The URL is one argument to a fixed program, with
    /// no shell involved, and only web links qualify.
    fn openUrl(app: *App, url: []const u8) void {
        if (!core.url.isHttp(url)) {
            app.say("Not a web link", .{});
            return;
        }
        // rundll32 takes the address as one argument and does not parse it as a command.
        const argv: []const []const u8 = switch (builtin.os.tag) {
            .macos => &.{ "open", url },
            .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
            else => &.{ "xdg-open", url },
        };
        _ = std.process.spawn(app.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {
            app.say("Could not open a browser", .{});
            return;
        };
        app.say("Opened in browser", .{});
    }

    /// Fetches the whole article for the open entry, then shows it.
    fn fetchFull(app: *App) void {
        const reader = app.reader orelse return;
        app.say("Fetching the article...", .{});
        app.draw() catch {};
        const result = app.call(ops.EntriesFetchFull, app.scratch.allocator(), .{ .id = reader.entry.id }) orelse return;
        if (std.mem.eql(u8, result.status, "done")) {
            app.openEntry();
            app.say("Full article loaded", .{});
        } else if (std.mem.eql(u8, result.status, "later")) {
            app.say("Could not reach the page. It will be tried again", .{});
        } else {
            app.say("No fuller article found ({s})", .{result.status});
        }
    }

    /// Opens a link beside this window, in a browser that runs in the terminal. It
    /// needs a terminal that can split, so it is a separate key, not the default.
    fn openInTerminal(app: *App, url: []const u8) void {
        if (!core.url.isHttp(url)) {
            app.say("Not a web link", .{});
            return;
        }
        const argv = [_][]const u8{ app.terminal_browser, "open", url, "--split", "right", "--size", "0.6" };
        _ = std.process.spawn(app.io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {
            app.say("{s} is not available", .{app.terminal_browser});
            return;
        };
        app.say("Opened in terminal browser", .{});
    }

    fn inRange(range: [2]usize, x: usize) bool {
        return x >= range[0] and x < range[1];
    }

    fn handleMouse(app: *App, mouse: terminal.Mouse) void {
        if (app.prompt != null or !mouse.pressed) return;
        if (app.show_help) {
            app.show_help = false;
            return;
        }
        const in_side = inRange(app.side_range, mouse.x);
        const in_list = inRange(app.list_range, mouse.x);
        const in_reader = inRange(app.reader_range, mouse.x);
        switch (mouse.button) {
            .wheel_up, .wheel_down => {
                const up = mouse.button == .wheel_up;
                if (in_reader) {
                    if (app.reader) |*reader| {
                        reader.scroll = if (up) reader.scroll -| wheel_reader_lines else reader.scroll + wheel_reader_lines;
                    }
                } else if (in_list) {
                    moveBy(&app.entry_index, app.entries.items.len, if (up) -wheel_list_rows else wheel_list_rows);
                    app.loadMore();
                } else if (in_side) {
                    const before = app.side_index;
                    moveBy(&app.side_index, app.sideCount(), if (up) -1 else 1);
                    if (app.side_index != before) {
                        app.search = null;
                        app.resetList();
                    }
                }
            },
            .left => {
                const row = @min(mouse.y, max_screen_rows - 1);
                if (in_side) {
                    app.focus = .feeds;
                    const index = app.side_hits[row];
                    if (index != no_hit and index != app.side_index) {
                        app.side_index = index;
                        app.search = null;
                        app.resetList();
                    }
                } else if (in_list) {
                    const index = app.list_hits[row];
                    if (index == no_hit) {
                        app.focus = .entries;
                        return;
                    }
                    app.entry_index = index;
                    app.loadMore();
                    app.openEntry();
                } else if (in_reader and app.reader != null) {
                    app.focus = .reader;
                }
            },
            else => {},
        }
    }

    fn refreshSelected(app: *App) void {
        const current = app.source();
        if (current != .feed) return app.refreshAll();
        if (app.call(ops.FeedsQueue, app.scratch.allocator(), .{ .id = current.feed }) == null) return;
        app.watching_fetches = true;
        app.say("Refreshing", .{});
    }

    fn refreshAll(app: *App) void {
        const result = app.call(ops.FeedsRefreshAll, app.scratch.allocator(), .{}) orelse return;
        app.watching_fetches = true;
        app.say("Refreshing {d} feeds", .{result.queued});
    }

    fn handleKey(app: *App, key: Key) void {
        app.message = "";
        if (key == .ctrl and key.ctrl == 'c') {
            app.running = false;
            return;
        }
        if (key == .ctrl and key.ctrl == 'l') {
            app.first_frame = true;
            return;
        }
        if (key == .mouse) return app.handleMouse(key.mouse);
        if (app.prompt != null) return app.promptKey(key);
        if (app.show_help) {
            app.show_help = false;
            return;
        }

        switch (key) {
            .char => |ch| switch (ch) {
                '?' => return {
                    app.show_help = true;
                },
                '/' => return app.startPrompt(.search),
                'a' => return app.startPrompt(.add),
                'R' => return app.refreshAll(),
                'r' => return app.refreshSelected(),
                'u' => {
                    app.unread_only = !app.unread_only;
                    app.say("{s}", .{if (app.unread_only) "Showing unread only" else "Showing everything"});
                    return app.resetList();
                },
                else => {},
            },
            else => {},
        }
        switch (app.focus) {
            .feeds => app.feedsKey(key),
            .entries => app.entriesKey(key),
            .reader => app.readerKey(key),
        }
    }

    fn moveBy(index: *usize, count: usize, delta: isize) void {
        if (count == 0) return;
        const moved = @as(isize, @intCast(index.*)) + delta;
        index.* = @intCast(std.math.clamp(moved, 0, @as(isize, @intCast(count - 1))));
    }

    /// Reads movement keys common to every list. Returns a row delta, if any.
    fn listDelta(app: *const App, key: Key) ?isize {
        const page: isize = @intCast(@max(app.screen.height / 2, 1));
        return switch (key) {
            .down => 1,
            .up => -1,
            .page_down => page,
            .page_up => -page,
            .home => -std.math.maxInt(i32),
            .end => std.math.maxInt(i32),
            .ctrl => |ch| switch (ch) {
                'd' => page,
                'u' => -page,
                else => null,
            },
            .char => |ch| switch (ch) {
                'j' => 1,
                'k' => -1,
                'g' => -std.math.maxInt(i32),
                'G' => std.math.maxInt(i32),
                else => null,
            },
            else => null,
        };
    }

    fn feedsKey(app: *App, key: Key) void {
        if (app.listDelta(key)) |delta| {
            const before = app.side_index;
            moveBy(&app.side_index, app.sideCount(), delta);
            if (app.side_index != before) {
                app.search = null;
                app.resetList();
            }
            return;
        }
        switch (key) {
            .enter, .right, .tab => app.focus = .entries,
            .char => |ch| switch (ch) {
                'l' => app.focus = .entries,
                'q' => app.running = false,
                else => {},
            },
            else => {},
        }
    }

    fn entriesKey(app: *App, key: Key) void {
        if (app.listDelta(key)) |delta| {
            moveBy(&app.entry_index, app.entries.items.len, delta);
            app.loadMore();
            return;
        }
        switch (key) {
            .enter, .right => app.openEntry(),
            .left, .backtab, .tab => app.focus = .feeds,
            .escape => if (app.search != null) app.clearSearch(),
            .char => |ch| switch (ch) {
                'l' => app.openEntry(),
                'h' => app.focus = .feeds,
                'm' => app.toggleRead(),
                's' => app.toggleStar(),
                'n' => app.nextUnread(),
                'o' => if (app.selectedEntry()) |row| {
                    if (row.url) |link| app.openUrl(link);
                },
                'O' => if (app.selectedEntry()) |row| {
                    if (row.url) |link| app.openInTerminal(link);
                },
                'q' => if (app.search != null) app.clearSearch() else {
                    app.running = false;
                },
                else => {},
            },
            else => {},
        }
    }

    fn clearSearch(app: *App) void {
        app.search = null;
        app.resetList();
    }

    fn readerKey(app: *App, key: Key) void {
        const reader = &(app.reader orelse {
            app.focus = .entries;
            return;
        });
        const page = @max(app.screen.height -| 3, 1);
        switch (key) {
            .left, .escape, .backtab, .tab => app.focus = .entries,
            .down => reader.scroll += 1,
            .up => reader.scroll -|= 1,
            .page_down => reader.scroll += page,
            .page_up => reader.scroll -|= page,
            .home => reader.scroll = 0,
            .end => reader.scroll = reader.article.lines.len,
            .ctrl => |ch| switch (ch) {
                'd' => reader.scroll += page / 2,
                'u' => reader.scroll -|= page / 2,
                else => {},
            },
            .char => |ch| switch (ch) {
                'j' => reader.scroll += 1,
                'k' => reader.scroll -|= 1,
                ' ' => reader.scroll += page,
                'b' => reader.scroll -|= page,
                'g' => reader.scroll = 0,
                'G' => reader.scroll = reader.article.lines.len,
                'h', 'q' => app.focus = .entries,
                'n' => app.nextUnread(),
                's' => app.toggleStar(),
                'm' => app.toggleRead(),
                'o' => if (reader.entry.url) |link| app.openUrl(link),
                'O' => if (reader.entry.url) |link| app.openInTerminal(link),
                'f' => app.fetchFull(),
                '1'...'9' => {
                    const number: usize = ch - '0';
                    if (number <= reader.article.links.len) {
                        app.openUrl(reader.article.links[number - 1]);
                    } else app.say("No link {d}", .{number});
                },
                else => {},
            },
            else => {},
        }
    }

    fn startPrompt(app: *App, kind: PromptKind) void {
        app.prompt = kind;
        app.prompt_text.clearRetainingCapacity();
    }

    fn promptKey(app: *App, key: Key) void {
        switch (key) {
            .escape => app.prompt = null,
            .enter => app.submitPrompt(),
            .backspace => {
                const text = app.prompt_text.items;
                var end = text.len;
                while (end > 0) {
                    end -= 1;
                    if (text[end] & 0xC0 != 0x80) break;
                }
                app.prompt_text.shrinkRetainingCapacity(end);
            },
            .char => |ch| {
                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(ch, &buffer) catch return;
                if (app.prompt_text.items.len + length <= max_prompt) app.prompt_text.appendSlice(app.gpa, buffer[0..length]) catch {};
            },
            else => {},
        }
    }

    fn submitPrompt(app: *App) void {
        const kind = app.prompt.?;
        app.prompt = null;
        const text = std.mem.trim(u8, app.prompt_text.items, " ");
        if (text.len == 0) return;
        switch (kind) {
            .search => {
                app.search = text;
                app.entry_index = 0;
                app.entry_top = 0;
                app.entries.clearRetainingCapacity();
                app.loadEntries();
                app.focus = .entries;
                app.say("{d} results", .{app.entries.items.len});
            },
            .add => app.startAdd(text),
        }
    }

    fn startAdd(app: *App, url: []const u8) void {
        if (app.adding.load(.acquire)) {
            app.say("Still adding the last feed", .{});
            return;
        }
        @memcpy(app.add_url[0..url.len], url);
        app.add_url_len = url.len;
        app.adding.store(true, .release);
        const thread = std.Thread.spawn(.{}, addThread, .{app}) catch {
            app.adding.store(false, .release);
            app.say("Could not start adding the feed", .{});
            return;
        };
        thread.detach();
        app.say("Adding...", .{});
    }

    fn finishAdd(app: *App) void {
        app.say("{s}", .{app.add_result[0..app.add_result_len]});
        app.loadFeeds();
        app.loadEntries();
    }

    /// Applies what the daemon reported. Search results stay put, since a list that
    /// changes under a query would be confusing.
    fn liveRefresh(app: *App) void {
        app.live_pending = false;
        app.loadFeeds();
        if (app.search == null) app.loadEntries();
        app.loadStats();
    }

    fn draw(app: *App) !void {
        const size = console.size();
        if (size.columns != app.screen.width or size.rows != app.screen.height) {
            app.screen.deinit(app.gpa);
            app.previous.deinit(app.gpa);
            app.screen = try .init(app.gpa, size.columns, size.rows);
            app.previous = try .init(app.gpa, size.columns, size.rows);
            app.first_frame = true;
        }
        app.screen.clear();

        if (size.columns < min_columns or size.rows < min_rows) {
            _ = app.screen.put(0, 0, size.columns, "Window too small", .{});
        } else {
            app.drawPanes();
            app.drawStatus();
            if (app.show_help) app.drawHelp();
        }

        var out: Io.Writer.Allocating = .init(app.scratch.allocator());
        try app.screen.render(if (app.first_frame) null else &app.previous, &out.writer);
        writeAll(out.written());
        app.first_frame = false;
        @memcpy(app.previous.cells, app.screen.cells);
    }

    fn drawPanes(app: *App) void {
        const width = app.screen.width;
        const height = app.screen.height - 1;
        const border: Style = .{ .fg = .gray, .dim = true };
        app.side_range = .{ 0, 0 };
        app.list_range = .{ 0, 0 };
        app.reader_range = .{ 0, 0 };
        @memset(&app.side_hits, no_hit);
        @memset(&app.list_hits, no_hit);

        // Show as many panes as fit, always including the focused one.
        const side_width: usize = @min(30, width / 4);
        if (width >= 110) {
            const list_width = (width - side_width) * 2 / 5;
            app.drawSide(0, side_width, height);
            drawLine(&app.screen, side_width, height, border);
            app.drawList(side_width + 1, side_width + 1 + list_width, height);
            drawLine(&app.screen, side_width + 1 + list_width, height, border);
            app.drawReader(side_width + 2 + list_width, width, height);
        } else if (width >= 70) {
            if (app.focus == .reader) {
                const list_width = width * 2 / 5;
                app.drawList(0, list_width, height);
                drawLine(&app.screen, list_width, height, border);
                app.drawReader(list_width + 1, width, height);
            } else {
                app.drawSide(0, side_width, height);
                drawLine(&app.screen, side_width, height, border);
                app.drawList(side_width + 1, width, height);
            }
        } else switch (app.focus) {
            .feeds => app.drawSide(0, width, height),
            .entries => app.drawList(0, width, height),
            .reader => app.drawReader(0, width, height),
        }
    }

    /// The bar that marks a selection. It keeps its color on any theme, unlike a
    /// filled row, and it stays visible, dimmer, when the pane loses focus.
    fn drawBar(app: *App, x: usize, y: usize, limit: usize, focused: bool) void {
        _ = app.screen.put(x, y, limit, "▌", .{ .fg = if (focused) .cyan else .gray });
    }

    fn drawSide(app: *App, x: usize, limit: usize, height: usize) void {
        app.side_range = .{ x, limit };
        const focused = app.focus == .feeds;
        _ = app.screen.put(x + 2, 0, limit, "fyke", .{ .bold = true, .fg = .cyan });

        // Rows are All and Starred, a labeled gap, then the feeds.
        const first_row: usize = 2;
        const feed_label_row = first_row + 3;
        const feed_top = feed_label_row + 1;
        const rows = height -| feed_top;
        if (app.side_index >= 2) scrollInto(&app.side_top, app.side_index - 2, rows);

        for (0..2) |i| app.drawSideRow(x, limit, first_row + i, i, focused);
        _ = app.screen.put(x + 2, feed_label_row, limit, "FEEDS", .{ .fg = .gray, .dim = true });

        var y = feed_top;
        var feed = app.side_top;
        while (feed < app.feeds.len and y < height) : ({
            feed += 1;
            y += 1;
        }) app.drawSideRow(x, limit, y, feed + 2, focused);
    }

    fn drawSideRow(app: *App, x: usize, limit: usize, y: usize, index: usize, focused: bool) void {
        var unread: i64 = 0;
        var failing = false;
        const name: []const u8 = switch (index) {
            0 => blk: {
                for (app.feeds) |feed| unread += feed.unread;
                break :blk "All";
            },
            1 => "Starred",
            else => blk: {
                const feed = app.feeds[index - 2];
                unread = feed.unread;
                failing = feed.last_error != null;
                break :blk feed.title orelse feed.url;
            },
        };
        if (y < app.side_hits.len) app.side_hits[y] = index;
        const selected = index == app.side_index;
        if (selected) app.drawBar(x, y, limit, focused);

        var style: Style = .{ .bold = selected or unread > 0, .fg = if (failing) .red else .default, .dim = !selected and unread == 0 };
        if (selected and focused) style.fg = .cyan;

        var count_buffer: [16]u8 = undefined;
        const count = if (unread > 0) std.fmt.bufPrint(&count_buffer, "{d}", .{unread}) catch "" else "";
        const right = limit -| 1;
        putClipped(&app.screen, x + 2, y, right -| (count.len + 1), name, style);
        if (count.len != 0) _ = app.screen.put(right - count.len, y, right, count, .{ .fg = .gray });
    }

    fn drawList(app: *App, x: usize, limit: usize, height: usize) void {
        app.list_range = .{ x, limit };
        const focused = app.focus == .entries;
        var title_buffer: [160]u8 = undefined;
        const name: []const u8 = if (app.search) |query|
            std.fmt.bufPrint(&title_buffer, "Search: {s}", .{query}) catch "Search"
        else switch (app.source()) {
            .all => "All",
            .starred => "Starred",
            .feed => app.feeds[app.side_index - 2].title orelse "Feed",
        };
        var count_buffer: [24]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buffer, "{d}{s}", .{ app.entries.items.len, if (app.next_cursor != null) "+" else "" }) catch "";
        const right = limit -| 1;
        putClipped(&app.screen, x + 2, 0, right -| (count.len + 1), name, .{ .bold = true, .fg = if (focused) .cyan else .default });
        _ = app.screen.put(right -| count.len, 0, right, count, .{ .fg = .gray });

        const top_row: usize = 2;
        const slots = (height -| top_row) / row_height;
        scrollInto(&app.entry_top, app.entry_index, slots);
        if (app.entries.items.len == 0) {
            _ = app.screen.put(x + 2, top_row, limit, if (app.search != null) "Nothing found" else "Nothing here yet", .{ .fg = .gray });
            return;
        }

        const now_ms = Io.Clock.real.now(app.io).toMilliseconds();
        const show_feed = app.search != null or app.source() != .feed;
        var y = top_row;
        var index = app.entry_top;
        while (index < app.entries.items.len and y + 1 < height) : ({
            index += 1;
            y += row_height;
        }) {
            const row = app.entries.items[index];
            const selected = index == app.entry_index;
            for (0..2) |line| {
                if (y + line < app.list_hits.len) app.list_hits[y + line] = index;
                if (selected) app.drawBar(x, y + line, limit, focused);
            }

            var style: Style = .{ .bold = !row.read, .dim = row.read and !selected };
            if (selected and focused) style.fg = .cyan;
            if (row.starred) {
                _ = app.screen.put(right -| 1, y, right, "★", .{ .fg = .yellow });
            }
            putClipped(&app.screen, x + 2, y, right -| 2, row.title orelse "(untitled)", style);

            var when_buffer: [16]u8 = undefined;
            const when = relativeDate(&when_buffer, now_ms, row.sort_at);
            var detail: Io.Writer.Allocating = .init(app.scratch.allocator());
            detail.writer.writeAll(when) catch {};
            if (show_feed) {
                if (row.feed_title) |feed| detail.writer.print("  {s}", .{feed}) catch {};
            }
            if (row.snippet) |snippet| detail.writer.print("  {s}", .{snippet}) catch {};
            putClipped(&app.screen, x + 2, y + 1, right, detail.written(), .{ .fg = .gray, .dim = row.read });
        }
    }

    fn drawReader(app: *App, x: usize, limit: usize, height: usize) void {
        app.reader_range = .{ x, limit };
        const reader = &(app.reader orelse {
            _ = app.screen.put(x + 3, 2, limit, "Press Enter to read", .{ .fg = .gray });
            return;
        });
        // A measured column, centered, with margins. Long lines are hard to read.
        const pane = limit -| x;
        const margin: usize = if (pane >= 40) 3 else 1;
        const columns = @min(pane -| (margin * 2), max_reader_columns);
        if (reader.laid_out_for != columns) {
            app.layoutReader(reader, columns);
        }
        const left = x + @max((pane -| columns) / 2, margin);

        const lines = reader.article.lines;
        const top: usize = if (height >= 12) 1 else 0;
        const visible = height -| top;
        reader.scroll = @min(reader.scroll, lines.len -| visible);
        var y: usize = 0;
        while (y < visible and reader.scroll + y < lines.len) : (y += 1) {
            var column = left;
            for (lines[reader.scroll + y].spans) |span| {
                column = app.screen.put(column, y + top, limit, span.text, span.style);
            }
        }
    }

    /// The title and details are laid out as part of the article, so they wrap and
    /// scroll with it.
    fn layoutReader(app: *App, reader: *Reader, columns: usize) void {
        _ = app.layout_arena.reset(.retain_capacity);
        const arena = app.layout_arena.allocator();
        const Node = core.blocks.Node;
        const entry = reader.entry;

        var details: std.Io.Writer.Allocating = .init(arena);
        details.writer.writeAll(entry.feed_title orelse "") catch {};
        if (entry.author) |author| details.writer.print(" · {s}", .{author}) catch {};
        if (entry.published_at) |at| {
            var buffer: [20]u8 = undefined;
            details.writer.print(" · {s}", .{core.dates.formatIso(&buffer, at)[0..10]}) catch {};
        }

        const nodes = arena.alloc(Node, reader.nodes.len + 2) catch return;
        const title_text = arena.dupe(Node, &.{.{ .kind = .text, .value = entry.title orelse "(untitled)" }}) catch return;
        const detail_text = arena.dupe(Node, &.{.{ .kind = .text, .value = details.written() }}) catch return;
        nodes[0] = .{ .kind = .h, .level = 1, .children = title_text };
        nodes[1] = .{ .kind = .p, .children = detail_text };
        @memcpy(nodes[2..], reader.nodes);

        reader.article = core.layout.lay(arena, nodes, columns) catch return;
        reader.laid_out_for = columns;
    }

    fn drawStatus(app: *App) void {
        const y = app.screen.height - 1;
        const width = app.screen.width;
        const quiet: Style = .{ .fg = .gray };

        if (app.prompt) |kind| {
            const label = if (kind == .search) " / " else " Add feed: ";
            const after_label = app.screen.put(0, y, width, label, .{ .fg = .cyan, .bold = true });
            const end = app.screen.put(after_label, y, width -| 1, app.prompt_text.items, .{});
            app.screen.cursor = .{ .x = end, .y = y };
            return;
        }

        var right_buffer: [64]u8 = undefined;
        var right: []const u8 = "";
        if (app.focus == .reader and app.reader != null) {
            const reader = app.reader.?;
            const total = @max(reader.article.lines.len, 1);
            const shown = @min(reader.scroll + app.screen.height - 1, total);
            right = std.fmt.bufPrint(&right_buffer, "{d}% ", .{shown * 100 / total}) catch "";
        } else if (app.stats) |stats| {
            if (stats.in_flight != 0 or stats.due != 0) {
                right = std.fmt.bufPrint(&right_buffer, "fetching {d} ", .{stats.in_flight + @as(usize, @intCast(stats.due))}) catch "";
            } else {
                right = std.fmt.bufPrint(&right_buffer, "{d} unread{s} ", .{ stats.unread, if (app.unread_only) " · filtered" else "" }) catch "";
            }
        }
        const right_width = terminal.displayWidth(right);
        if (right_width < width) _ = app.screen.put(width - right_width, y, width, right, quiet);

        if (app.message.len != 0) {
            _ = app.screen.put(1, y, width -| right_width, app.message, .{ .fg = .yellow });
            return;
        }
        const hints: []const u8 = switch (app.focus) {
            .feeds => "Enter open  / search  r refresh  a add  ? help",
            .entries => "Enter read  n next  s star  m read  u unread  / search  ? help",
            .reader => "Space page  n next  o browser  O terminal browser  1-9 links  ? help",
        };
        _ = app.screen.put(1, y, width -| right_width, hints, quiet);
    }

    fn drawHelp(app: *App) void {
        const lines = [_][]const u8{
            "j k  arrows      move",
            "Enter l          open",
            "h q  Esc         back",
            "Tab              switch pane",
            "n                next unread",
            "m                read or unread",
            "s                star",
            "u                unread only",
            "/                search",
            "o                open in browser",
            "O                open in terminal browser",
            "f                fetch the full article",
            "1-9              open a numbered link",
            "r R              refresh one, or all",
            "a                add a feed",
            "Mouse            click, and wheel to scroll",
            "Ctrl-C           quit",
        };
        const box_width: usize = 46;
        const box_height = lines.len + 2;
        const width = app.screen.width;
        const height = app.screen.height;
        if (box_width > width or box_height > height) return;
        const x = (width - box_width) / 2;
        const top = (height - box_height) / 2;
        const style: Style = .{ .reverse = true };
        for (0..box_height) |row| app.screen.fill(x, top + row, x + box_width, style);
        for (lines, 0..) |line, i| _ = app.screen.put(x + 2, top + 1 + i, x + box_width, line, style);
    }
};

/// A compact age, such as "5m", "3h" or "2d", and a date once that stops helping.
fn relativeDate(buffer: *[16]u8, now_ms: i64, then_ms: i64) []const u8 {
    const seconds = @divTrunc(now_ms - then_ms, 1000);
    if (seconds < 60) return "now";
    if (seconds < 3600) return std.fmt.bufPrint(buffer, "{d}m", .{@as(u64, @intCast(@divTrunc(seconds, 60)))}) catch "";
    if (seconds < 86400) return std.fmt.bufPrint(buffer, "{d}h", .{@as(u64, @intCast(@divTrunc(seconds, 3600)))}) catch "";
    if (seconds < 7 * 86400) return std.fmt.bufPrint(buffer, "{d}d", .{@as(u64, @intCast(@divTrunc(seconds, 86400)))}) catch "";
    var iso: [20]u8 = undefined;
    const date = core.dates.formatIso(&iso, then_ms);
    @memcpy(buffer[0..10], date[0..10]);
    return buffer[0..10];
}

fn drawLine(screen: *Screen, x: usize, height: usize, style: Style) void {
    for (0..height) |y| _ = screen.put(x, y, x + 1, "│", style);
}

/// Writes text, ending in an ellipsis if it does not fit.
fn putClipped(screen: *Screen, x: usize, y: usize, limit: usize, text: []const u8, style: Style) void {
    if (limit <= x) return;
    if (x + terminal.displayWidth(text) <= limit) {
        _ = screen.put(x, y, limit, text, style);
        return;
    }
    const end = screen.put(x, y, limit -| 1, text, style);
    _ = screen.put(end, y, limit, "…", style);
}

/// Adjusts a scroll position so that `index` is visible.
fn scrollInto(top: *usize, index: usize, rows: usize) void {
    if (rows == 0) return;
    if (index < top.*) top.* = index;
    if (index >= top.* + rows) top.* = index + 1 - rows;
}

fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len != 0) {
        const written = console.write(rest);
        if (written <= 0) return;
        rest = rest[@intCast(written)..];
    }
}

/// Subscribes on a connection of its own, since `App.client` belongs to the main
/// thread, then hands the outcome to the main loop.
fn addThread(app: *App) void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const text = addFeed(app, scratch.allocator()) catch |err| @errorName(err);
    const length = @min(text.len, app.add_result.len);
    @memcpy(app.add_result[0..length], text[0..length]);
    app.add_result_len = length;
    app.adding.store(false, .release);
    wake('a');
}

fn addFeed(app: *App, arena: std.mem.Allocator) ![]const u8 {
    var connector = app.connector;
    connector.arena = arena;
    const client = try arena.create(Client);
    try connector.connect(client, true);
    defer client.stream.close(app.io);
    const result = client.call(ops.FeedsAdd, .{ .url = app.add_url[0..app.add_url_len] }) catch |err| {
        return if (err == error.Reported) client.last_error else err;
    };
    return std.fmt.allocPrint(arena, "Feed {d}: {d} new entries", .{ result.id, result.new });
}

/// Holds a subscription open, and wakes the main loop when an event arrives. It
/// shares nothing with the main thread except the sequence number.
fn eventThread(app: *App) void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    while (true) {
        _ = scratch.reset(.retain_capacity);
        var connector = app.connector;
        connector.arena = scratch.allocator();
        const client = scratch.allocator().create(Client) catch return;
        connector.connect(client, false) catch {
            app.io.sleep(.fromSeconds(1), .awake) catch return;
            continue;
        };
        defer client.stream.close(app.io);
        _ = client.send("events.subscribe", .{ .since_seq = app.last_seq.load(.monotonic) }) catch continue;

        const in = &client.reader.interface;
        while (true) {
            const line = in.takeDelimiterExclusive('\n') catch break;
            const seq_key = "\"seq\":";
            if (std.mem.indexOf(u8, line, seq_key)) |at| {
                const rest = line[at + seq_key.len ..];
                const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
                const seq = std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
                if (seq != 0) app.last_seq.store(seq, .monotonic);
            }
            in.toss(1);
            wake('e');
        }
    }
}

pub fn run(gpa: std.mem.Allocator, connector: client_module.Connector) !void {
    try console.start();
    console.enter_sequence = enter_sequence;
    console.leave_sequence = leave_sequence;

    const size = console.size();
    var app: App = .{
        .gpa = gpa,
        .io = connector.io,
        .connector = connector,
        .screen = try .init(gpa, size.columns, size.rows),
        .previous = try .init(gpa, size.columns, size.rows),
        .feeds_arena = .init(gpa),
        .entries_arena = .init(gpa),
        .reader_arena = .init(gpa),
        .layout_arena = .init(gpa),
        .scratch = .init(gpa),
    };

    defer app.deinit();

    try app.connect();
    try console.enterRaw();
    defer restoreTerminal();
    console.installHandlers();

    app.readConfig();
    app.loadFeeds();
    app.loadEntries();
    app.loadStats();
    if (app.stats) |stats| app.last_seq.store(stats.last_event_seq, .monotonic);
    const events = try std.Thread.spawn(.{}, eventThread, .{&app});
    events.detach();
    try app.draw();

    var input: [4096]u8 = undefined;
    var pending: usize = 0;
    var last_live: i64 = 0;
    var last_watch: i64 = 0;

    while (app.running) {
        const now = Io.Clock.awake.now(app.io).toMilliseconds();
        var timeout: i32 = -1;
        if (app.live_pending) timeout = @intCast(@max(live_refresh_ms - (now - last_live), 0));
        if (app.watching_fetches) {
            const wait: i32 = @intCast(@max(fetch_watch_ms - (now - last_watch), 0));
            timeout = if (timeout < 0) wait else @min(timeout, wait);
        }
        if (pending != 0) timeout = escape_wait_ms;

        const ready = console.wait(timeout);
        var dirty = false;

        if (ready.woke) {
            var reasons: [256]u8 = undefined;
            const count = console.drainWake(&reasons);
            for (reasons[0..count]) |reason| {
                if (reason == 'e') app.live_pending = true;
                if (reason == 'w') dirty = true;
                if (reason == 'a') {
                    app.finishAdd();
                    dirty = true;
                }
            }
        }

        if (ready.input) {
            const count = console.readInput(input[pending..]);
            if (count <= 0) break; // The terminal went away.
            pending += @intCast(count);
            var used: usize = 0;
            while (used < pending) {
                const decoded = terminal.decodeKey(input[used..pending]) orelse break;
                app.handleKey(decoded.key);
                used += decoded.consumed;
                dirty = true;
                if (!app.running) break;
            }
            std.mem.copyForwards(u8, input[0 .. pending - used], input[used..pending]);
            pending -= used;
        } else if (ready.timed_out and pending != 0) {
            // Nothing followed, so this really was the Escape key.
            for (input[0..pending]) |byte| {
                if (byte == 0x1B) app.handleKey(.escape);
            }
            pending = 0;
            dirty = true;
        }

        const after = Io.Clock.awake.now(app.io).toMilliseconds();
        if (app.live_pending and after - last_live >= live_refresh_ms) {
            app.liveRefresh();
            last_live = after;
            dirty = true;
        }
        if (app.watching_fetches and after - last_watch >= fetch_watch_ms) {
            last_watch = after;
            app.loadStats();
            if (app.stats) |stats| {
                if (stats.due == 0 and stats.in_flight == 0) {
                    app.watching_fetches = false;
                    app.loadFeeds();
                    app.say("Refresh finished", .{});
                }
            }
            dirty = true;
        }

        if (dirty) {
            try app.draw();
            _ = app.scratch.reset(.retain_capacity);
        }
    }
}

test "scrolling keeps the selection visible" {
    var top: usize = 0;
    scrollInto(&top, 5, 3);
    try std.testing.expectEqual(3, top);
    scrollInto(&top, 4, 3);
    try std.testing.expectEqual(3, top);
    scrollInto(&top, 1, 3);
    try std.testing.expectEqual(1, top);
}

test "ages" {
    const hour = 3600 * 1000;
    var buffer: [16]u8 = undefined;
    const now: i64 = 1793957400000;
    try std.testing.expectEqualStrings("now", relativeDate(&buffer, now, now));
    try std.testing.expectEqualStrings("now", relativeDate(&buffer, now, now + hour));
    try std.testing.expectEqualStrings("5m", relativeDate(&buffer, now, now - 300 * 1000));
    try std.testing.expectEqualStrings("3h", relativeDate(&buffer, now, now - 3 * hour));
    try std.testing.expectEqualStrings("2d", relativeDate(&buffer, now, now - 48 * hour));
    try std.testing.expectEqualStrings("2026-10-07", relativeDate(&buffer, now, now - 30 * 24 * hour));
}

test "moving stops at both ends" {
    var index: usize = 2;
    App.moveBy(&index, 5, 100);
    try std.testing.expectEqual(4, index);
    App.moveBy(&index, 5, -100);
    try std.testing.expectEqual(0, index);
    App.moveBy(&index, 0, 1);
    try std.testing.expectEqual(0, index);
}
