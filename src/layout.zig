//! Lays out blocks as lines of styled text for a given width. This is the only
//! place that decides how an article looks in a terminal.

const std = @import("std");
const blocks = @import("blocks.zig");
const terminal = @import("terminal.zig");

const Node = blocks.Node;
const Style = terminal.Style;

pub const Span = struct { text: []const u8, style: Style };
pub const Line = struct { spans: []const Span };

pub const Article = struct {
    lines: []const Line,
    /// Link targets, numbered from 1 in the order that they appear.
    links: []const []const u8,
};

const Error = error{OutOfMemory};

const Layout = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    links: std.ArrayList([]const u8) = .empty,

    fn addLine(l: *Layout, spans: []const Span) Error!void {
        try l.lines.append(l.arena, .{ .spans = spans });
    }

    fn blank(l: *Layout) Error!void {
        if (l.lines.items.len != 0 and l.lines.items[l.lines.items.len - 1].spans.len != 0) try l.addLine(&.{});
    }

    fn addLink(l: *Layout, url: []const u8) Error!usize {
        for (l.links.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, url)) return i + 1;
        }
        try l.links.append(l.arena, url);
        return l.links.items.len;
    }
};

/// A prefix repeated on each line, such as "│ " for a quote. `first` replaces it
/// on the first line, which is how a list bullet appears.
const Prefix = struct {
    rest: []const Span = &.{},
    first: ?[]const Span = null,
    width: usize = 0,
};

fn spansWidth(spans: []const Span) usize {
    var total: usize = 0;
    for (spans) |span| total += terminal.displayWidth(span.text);
    return total;
}

pub fn lay(arena: std.mem.Allocator, nodes: []const Node, columns: usize) Error!Article {
    var l: Layout = .{ .arena = arena };
    const usable = @max(columns, 8);
    try layBlocks(&l, nodes, usable, .{});
    if (l.links.items.len != 0) {
        try l.blank();
        for (l.links.items, 1..) |url, i| {
            const label = try std.fmt.allocPrint(arena, "[{d}] ", .{i});
            try wrapWords(&l, &.{ .{ .text = label, .style = .{ .fg = .cyan } }, .{ .text = url, .style = .{ .fg = .gray } } }, usable, .{}, true);
        }
    }
    return .{ .lines = l.lines.items, .links = l.links.items };
}

fn layBlocks(l: *Layout, nodes: []const Node, columns: usize, prefix: Prefix) Error!void {
    var current = prefix;
    for (nodes, 0..) |node, i| {
        if (i != 0 and needsGap(node)) try l.blank();
        try layBlock(l, node, columns, current);
        current.first = null;
    }
}

fn needsGap(node: Node) bool {
    return node.kind != .text and node.kind != .br;
}

fn layBlock(l: *Layout, node: Node, columns: usize, prefix: Prefix) Error!void {
    switch (node.kind) {
        .h => {
            var spans: std.ArrayList(Span) = .empty;
            const style: Style = .{ .bold = true, .fg = if (node.level <= 2) .yellow else .default };
            try flatten(l, node.children, style, &spans);
            try wrapWords(l, spans.items, columns, prefix, false);
        },
        .code => try layCode(l, node.value, columns, prefix),
        .img => {
            const number = try l.addLink(node.url);
            const label = if (node.label.len == 0) "image" else node.label;
            const text = try std.fmt.allocPrint(l.arena, "[image: {s}] [{d}]", .{ label, number });
            try wrapWords(l, &.{.{ .text = text, .style = .{ .fg = .gray } }}, columns, prefix, false);
        },
        .embed => {
            const number = try l.addLink(node.url);
            const text = try std.fmt.allocPrint(l.arena, "[embedded media] [{d}]", .{number});
            try wrapWords(l, &.{.{ .text = text, .style = .{ .fg = .gray } }}, columns, prefix, false);
        },
        .hr => {
            const available = columns -| prefix.width;
            const rule = try l.arena.alloc(u8, available * 3);
            for (0..available) |i| @memcpy(rule[i * 3 ..][0..3], "─");
            try wrapWords(l, &.{.{ .text = rule, .style = .{ .fg = .gray } }}, columns, prefix, true);
        },
        .quote => {
            const bar: []const Span = &.{.{ .text = "│ ", .style = .{ .fg = .gray } }};
            try layBlocks(l, node.children, columns, extend(l, prefix, bar, null) catch return error.OutOfMemory);
        },
        .list => try layList(l, node, columns, prefix),
        .table => try layTable(l, node, columns, prefix),
        else => {
            var spans: std.ArrayList(Span) = .empty;
            try flatten(l, if (node.kind == .p) node.children else &.{node}, .{}, &spans);
            try wrapWords(l, spans.items, columns, prefix, false);
        },
    }
}

fn extend(l: *Layout, prefix: Prefix, rest: []const Span, first: ?[]const Span) Error!Prefix {
    const joined = try std.mem.concat(l.arena, Span, &.{ prefix.rest, rest });
    const first_joined = try std.mem.concat(l.arena, Span, &.{ prefix.first orelse prefix.rest, first orelse rest });
    return .{ .rest = joined, .first = first_joined, .width = spansWidth(joined) };
}

fn layList(l: *Layout, node: Node, columns: usize, prefix: Prefix) Error!void {
    var current = prefix;
    for (node.children, 1..) |item, number| {
        const marker = if (node.ordered) try std.fmt.allocPrint(l.arena, "{d}. ", .{number}) else "• ";
        const indent_width = terminal.displayWidth(marker);
        const indent = try l.arena.alloc(u8, indent_width);
        @memset(indent, ' ');
        const rest = try l.arena.dupe(Span, &.{.{ .text = indent, .style = .{} }});
        const first = try l.arena.dupe(Span, &.{.{ .text = marker, .style = .{ .fg = .cyan } }});
        const item_prefix = try extend(l, current, rest, first);
        // An empty item has nothing to carry its marker, so it is skipped.
        if (item.children.len != 0) try layBlocks(l, item.children, columns, item_prefix);
        current.first = null;
    }
}

/// Aligned columns when they fit, otherwise one cell per line, since a table
/// squeezed into too little width is unreadable.
fn layTable(l: *Layout, node: Node, columns: usize, prefix: Prefix) Error!void {
    var cell_count: usize = 0;
    for (node.children) |row| cell_count = @max(cell_count, row.children.len);
    if (cell_count == 0) return;

    const widths = try l.arena.alloc(usize, cell_count);
    @memset(widths, 0);
    const text = try l.arena.alloc([]const []const u8, node.children.len);
    for (node.children, text) |row, *cells| {
        const row_text = try l.arena.alloc([]const u8, row.children.len);
        for (row.children, row_text, 0..) |cell, *value, i| {
            var out: std.Io.Writer.Allocating = .init(l.arena);
            blocks.writeText(&out.writer, cell.children) catch return error.OutOfMemory;
            value.* = out.written();
            widths[i] = @max(widths[i], terminal.displayWidth(value.*));
        }
        cells.* = row_text;
    }
    var total: usize = prefix.width + (cell_count - 1) * 3;
    for (widths) |value| total += value;

    if (total > columns) {
        for (text, 0..) |cells, row_index| {
            if (row_index != 0) try l.blank();
            for (cells) |value| {
                if (value.len != 0) try wrapWords(l, &.{.{ .text = value, .style = .{} }}, columns, prefix, false);
            }
        }
        return;
    }
    for (text, 0..) |cells, row_index| {
        var spans: std.ArrayList(Span) = .empty;
        try spans.appendSlice(l.arena, prefix.rest);
        for (cells, 0..) |value, i| {
            if (i != 0) try spans.append(l.arena, .{ .text = " │ ", .style = .{ .fg = .gray } });
            try spans.append(l.arena, .{ .text = value, .style = .{ .bold = row_index == 0 } });
            const padding = widths[i] - terminal.displayWidth(value);
            if (padding != 0 and i + 1 != cells.len) {
                const spaces = try l.arena.alloc(u8, padding);
                @memset(spaces, ' ');
                try spans.append(l.arena, .{ .text = spaces, .style = .{} });
            }
        }
        try l.addLine(spans.items);
    }
}

/// Code keeps its line breaks and is broken hard at the edge, not at words.
fn layCode(l: *Layout, code: []const u8, columns: usize, prefix: Prefix) Error!void {
    const bar: []const Span = &.{.{ .text = "▏ ", .style = .{ .fg = .gray } }};
    const inner = try extend(l, prefix, bar, null);
    const available = @max(columns -| inner.width, 4);
    const style: Style = .{ .fg = .green };

    var source = std.mem.splitScalar(u8, code, '\n');
    var first = true;
    while (source.next()) |line| {
        var start: usize = 0;
        var used: usize = 0;
        var it = terminal.codepoints(line);
        var expanded = line;
        if (std.mem.indexOfScalar(u8, line, '\t') != null) expanded = try std.mem.replaceOwned(u8, l.arena, line, "\t", "    ");
        it = terminal.codepoints(expanded);
        var position: usize = 0;
        while (it.next()) |cp| {
            const columns_used = if (terminal.isControl(cp)) 0 else terminal.width(cp);
            if (used + columns_used > available) {
                try addPrefixed(l, inner, first, expanded[start..position], style);
                first = false;
                start = position;
                used = 0;
            }
            used += columns_used;
            position = it.index;
        }
        try addPrefixed(l, inner, first, expanded[start..], style);
        first = false;
    }
}

fn addPrefixed(l: *Layout, prefix: Prefix, first: bool, text: []const u8, style: Style) Error!void {
    const lead = if (first) prefix.first orelse prefix.rest else prefix.rest;
    const spans = try l.arena.alloc(Span, lead.len + 1);
    @memcpy(spans[0..lead.len], lead);
    spans[lead.len] = .{ .text = text, .style = style };
    try l.addLine(spans);
}

fn flatten(l: *Layout, nodes: []const Node, style: Style, out: *std.ArrayList(Span)) Error!void {
    for (nodes) |node| {
        switch (node.kind) {
            .text => try out.append(l.arena, .{ .text = node.value, .style = style }),
            .code => {
                var code_style = style;
                code_style.fg = .green;
                try out.append(l.arena, .{ .text = node.value, .style = code_style });
            },
            .br => try out.append(l.arena, .{ .text = "\n", .style = style }),
            .em => {
                var inner = style;
                inner.italic = true;
                try flatten(l, node.children, inner, out);
            },
            .strong => {
                var inner = style;
                inner.bold = true;
                try flatten(l, node.children, inner, out);
            },
            .link => {
                var inner = style;
                inner.underline = true;
                inner.fg = .blue;
                try flatten(l, node.children, inner, out);
                const number = try l.addLink(node.url);
                const label = try std.fmt.allocPrint(l.arena, "[{d}]", .{number});
                try out.append(l.arena, .{ .text = label, .style = .{ .fg = .cyan } });
            },
            else => try flatten(l, node.children, style, out),
        }
    }
}

/// Greedy word wrap across styled spans. With `hard`, spaces are not break points
/// and a long run simply breaks at the edge, as a URL should.
fn wrapWords(l: *Layout, spans: []const Span, columns: usize, prefix: Prefix, hard: bool) Error!void {
    var first_line = true;
    const available = @max(columns -| prefix.width, 4);
    var line: std.ArrayList(Span) = .empty;
    var used: usize = 0;

    const flush = struct {
        fn run(layout: *Layout, p: Prefix, is_first: *bool, current: *std.ArrayList(Span), used_columns: *usize) Error!void {
            const lead = if (is_first.*) p.first orelse p.rest else p.rest;
            is_first.* = false;
            const all = try layout.arena.alloc(Span, lead.len + current.items.len);
            @memcpy(all[0..lead.len], lead);
            @memcpy(all[lead.len..], current.items);
            try layout.addLine(all);
            current.* = .empty;
            used_columns.* = 0;
        }
    }.run;

    for (spans) |span| {
        var rest = span.text;
        while (rest.len != 0) {
            if (rest[0] == '\n') {
                try flush(l, prefix, &first_line, &line, &used);
                rest = rest[1..];
                continue;
            }
            // The next piece: a word plus the spaces after it.
            var end: usize = 0;
            if (hard) {
                end = rest.len;
            } else {
                while (end < rest.len and rest[end] != ' ' and rest[end] != '\n') end += 1;
                while (end < rest.len and rest[end] == ' ') end += 1;
            }
            const piece = rest[0..end];
            const word = std.mem.trimEnd(u8, piece, " ");
            const word_width = terminal.displayWidth(word);

            if (!hard and used != 0 and used + word_width > available) try flush(l, prefix, &first_line, &line, &used);

            if (word_width > available or (hard and word_width + used > available)) {
                // Longer than a line, so it must break mid-word.
                const room = available - used;
                const cut = cutAt(piece, room);
                if (cut == 0) {
                    try flush(l, prefix, &first_line, &line, &used);
                    const forced = @max(cutAt(piece, available), firstCodepointLength(piece));
                    try line.append(l.arena, .{ .text = piece[0..forced], .style = span.style });
                    used += terminal.displayWidth(piece[0..forced]);
                    rest = rest[forced..];
                    continue;
                }
                try line.append(l.arena, .{ .text = piece[0..cut], .style = span.style });
                used += terminal.displayWidth(piece[0..cut]);
                rest = rest[cut..];
                try flush(l, prefix, &first_line, &line, &used);
                continue;
            }

            if (used == 0 and std.mem.trim(u8, piece, " ").len == 0) {
                rest = rest[end..]; // No leading space on a line.
                continue;
            }
            try line.append(l.arena, .{ .text = piece, .style = span.style });
            used += terminal.displayWidth(piece);
            rest = rest[end..];
        }
    }
    if (line.items.len != 0 or first_line) try flush(l, prefix, &first_line, &line, &used);
}

fn firstCodepointLength(text: []const u8) usize {
    var it = terminal.codepoints(text);
    _ = it.next();
    return @max(it.index, 1);
}

/// The longest prefix of `text`, in bytes, that fits in `columns`.
fn cutAt(text: []const u8, columns: usize) usize {
    var it = terminal.codepoints(text);
    var used: usize = 0;
    var end: usize = 0;
    while (it.next()) |cp| {
        const next_width = if (terminal.isControl(cp)) 0 else terminal.width(cp);
        if (used + next_width > columns) break;
        used += next_width;
        end = it.index;
    }
    return end;
}

const testing = std.testing;
const html = @import("html.zig");

fn lineText(buffer: *std.ArrayList(u8), a: std.mem.Allocator, line: Line) ![]const u8 {
    buffer.clearRetainingCapacity();
    for (line.spans) |span| try buffer.appendSlice(a, span.text);
    return std.mem.trimEnd(u8, buffer.items, " ");
}

fn expectLines(input: []const u8, columns: usize, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const article = try lay(a, try html.toBlocks(a, input, .{}), columns);
    var buffer: std.ArrayList(u8) = .empty;
    try testing.expectEqual(expected.len, article.lines.len);
    for (article.lines, expected) |line, want| {
        try testing.expectEqualStrings(want, try lineText(&buffer, a, line));
    }
}

test "paragraphs wrap at words" {
    try expectLines("<p>one two three four</p><p>five</p>", 9, &.{ "one two", "three", "four", "", "five" });
}

test "a long word breaks" {
    try expectLines("<p>abcdefghijkl</p>", 8, &.{ "abcdefgh", "ijkl" });
}

test "wide text wraps by columns, not bytes" {
    try expectLines("<p>中文字符测试</p>", 8, &.{ "中文字符", "测试" });
}

test "styles span wrapped text" {
    try expectLines("<p>aa <b>bb cc</b> dd</p>", 8, &.{ "aa bb cc", "dd" });
}

test "lists hang their text" {
    try expectLines("<ul><li>one two three</li><li>x</li></ul>", 10, &.{ "• one two", "  three", "• x" });
    try expectLines("<ol><li>a</li><li>b</li></ol>", 10, &.{ "1. a", "2. b" });
}

test "quotes carry their bar on every line" {
    try expectLines("<blockquote>one two three</blockquote>", 9, &.{ "│ one two", "│ three" });
}

test "code keeps its lines" {
    try expectLines("<pre>a\n  b</pre>", 20, &.{ "▏ a", "▏   b" });
    try expectLines("<pre>abcdefghij</pre>", 8, &.{ "▏ abcdef", "▏ ghij" });
}

test "links are numbered and listed" {
    try expectLines("<p><a href=\"https://e.test/a\">see</a></p>", 30, &.{ "see[1]", "", "[1] https://e.test/a" });
}

test "a long link stays beside its number" {
    try expectLines("<a href=\"https://e.test/aaaaaaaaaaaaaaaaaaaaaaaaa\">x</a>", 20, &.{ "x[1]", "", "[1] https://e.test/a", "aaaaaaaaaaaaaaaaaaaa", "aaaa" });
}

test "the same link keeps its number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const article = try lay(a, try html.toBlocks(a, "<a href=\"https://e.test\">x</a> <a href=\"https://e.test\">y</a>", .{}), 40);
    try testing.expectEqual(1, article.links.len);
}

test "tables align when they fit, and stack when they do not" {
    try expectLines("<table><tr><td>a</td><td>bb</td></tr><tr><td>ccc</td><td>d</td></tr></table>", 20, &.{ "a   │ bb", "ccc │ d" });
    try expectLines("<table><tr><td>aaaaaa</td><td>bbbbbb</td></tr></table>", 10, &.{ "aaaaaa", "bbbbbb" });
}

test "headings and images" {
    try expectLines("<h1>T</h1><img src=\"http://e.test/a\" alt=\"pic\">", 40, &.{ "T", "", "[image: pic] [1]", "", "[1] http://e.test/a" });
}

test "no line exceeds the width, at any width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "<h2>Heading words</h2><p>Some <b>bold</b> 中文字符 <a href=\"https://e.test/very/long/url/that/goes/on\">link</a> averyveryverylongwordindeed</p><ul><li>item<ul><li>nested item text</li></ul></li></ul><blockquote><p>quoted text here</p></blockquote><pre>code line that is long</pre>";
    const nodes = try html.toBlocks(a, input, .{});
    var columns: usize = 8;
    while (columns < 100) : (columns += 1) {
        for ((try lay(a, nodes, columns)).lines) |line| {
            try testing.expect(spansWidth(line.spans) <= columns + 2);
        }
    }
}
