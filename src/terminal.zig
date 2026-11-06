//! The pure half of the terminal UI: display widths, a cell grid that renders
//! itself as a minimal diff, and the decoder for keyboard input. Nothing here
//! touches a real terminal, so all of it can be tested and fuzzed directly.
//!
//! Terminals are a text protocol that feed content must never get to speak. Every
//! character reaches the screen through `Screen.put`, which refuses control codes,
//! so this file is the last defense against escape sequence injection.

const std = @import("std");
const table = @import("width_table.zig");

fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (cp < ranges[middle][0]) {
            high = middle;
        } else if (cp > ranges[middle][1]) {
            low = middle + 1;
        } else return true;
    }
    return false;
}

/// True for anything a terminal might act on rather than display, including the
/// C1 controls and the bidirectional overrides that can disguise text.
pub fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp < 0xA0) or
        (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069);
}

/// Columns a codepoint occupies: 0, 1 or 2.
pub fn width(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inRanges(&table.zero_width, cp)) return 0;
    if (inRanges(&table.wide, cp)) return 2;
    return 1;
}

/// Columns a string occupies, ignoring anything `Screen.put` would drop.
pub fn displayWidth(text: []const u8) usize {
    var total: usize = 0;
    var it = codepoints(text);
    while (it.next()) |cp| {
        if (!isControl(cp)) total += width(cp);
    }
    return total;
}

/// Iterates UTF-8, reading invalid bytes as U+FFFD instead of failing.
pub const Codepoints = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(it: *Codepoints) ?u21 {
        if (it.index >= it.bytes.len) return null;
        const length = std.unicode.utf8ByteSequenceLength(it.bytes[it.index]) catch {
            it.index += 1;
            return 0xFFFD;
        };
        if (it.index + length > it.bytes.len) {
            it.index = it.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(it.bytes[it.index .. it.index + length]) catch {
            it.index += 1;
            return 0xFFFD;
        };
        it.index += length;
        return cp;
    }
};

pub fn codepoints(text: []const u8) Codepoints {
    return .{ .bytes = text };
}

/// The 16 ANSI colors, so that the UI follows the user's own terminal theme.
pub const Color = enum(u8) {
    default,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    gray,

    fn foreground(color: Color) u8 {
        return switch (color) {
            .default => 39,
            .red => 31,
            .green => 32,
            .yellow => 33,
            .blue => 34,
            .magenta => 35,
            .cyan => 36,
            .gray => 90,
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,

    fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }

    fn write(style: Style, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("\x1b[0");
        if (style.bold) try w.writeAll(";1");
        if (style.dim) try w.writeAll(";2");
        if (style.italic) try w.writeAll(";3");
        if (style.underline) try w.writeAll(";4");
        if (style.reverse) try w.writeAll(";7");
        if (style.fg != .default) try w.print(";{d}", .{style.fg.foreground()});
        try w.writeByte('m');
    }
};

const blank_bytes: [16]u8 = blank: {
    var bytes: [16]u8 = @splat(0);
    bytes[0] = ' ';
    break :blank bytes;
};

/// One column of the screen. The second column of a wide character is a cell of
/// width 0. Combining marks are stored with the character that they modify.
pub const Cell = struct {
    bytes: [16]u8 = blank_bytes,
    len: u8 = 1,
    width: u2 = 1,
    style: Style = .{},

    fn text(cell: *const Cell) []const u8 {
        return cell.bytes[0..cell.len];
    }

    fn eql(a: *const Cell, b: *const Cell) bool {
        return a.width == b.width and a.style.eql(b.style) and std.mem.eql(u8, a.text(), b.text());
    }
};

pub const Screen = struct {
    width: usize,
    height: usize,
    cells: []Cell,
    /// Where to leave the visible cursor, or null to hide it.
    cursor: ?struct { x: usize, y: usize } = null,

    pub fn init(gpa: std.mem.Allocator, columns: usize, rows: usize) error{OutOfMemory}!Screen {
        const cells = try gpa.alloc(Cell, columns * rows);
        @memset(cells, .{});
        return .{ .width = columns, .height = rows, .cells = cells };
    }

    pub fn deinit(s: *Screen, gpa: std.mem.Allocator) void {
        gpa.free(s.cells);
    }

    pub fn clear(s: *Screen) void {
        @memset(s.cells, .{});
        s.cursor = null;
    }

    fn at(s: *const Screen, x: usize, y: usize) *Cell {
        return &s.cells[y * s.width + x];
    }

    /// Writes text at (x, y), stopping before column `limit`, and returns the
    /// column after the last one written. Control characters are dropped.
    pub fn put(s: *Screen, x_start: usize, y: usize, limit_in: usize, text: []const u8, style: Style) usize {
        if (y >= s.height) return x_start;
        const limit = @min(limit_in, s.width);
        var x = x_start;
        var it = codepoints(text);
        while (it.next()) |cp| {
            if (isControl(cp)) continue;
            const columns = width(cp);
            if (columns == 0) {
                if (x > x_start) s.appendMark(x - 1, y, cp);
                continue;
            }
            if (x + columns > limit) break;
            s.clearWideAt(x, y);
            if (columns == 2) s.clearWideAt(x + 1, y);
            const cell = s.at(x, y);
            cell.* = .{ .style = style, .width = columns };
            cell.len = std.unicode.utf8Encode(cp, &cell.bytes) catch 0;
            if (columns == 2) s.at(x + 1, y).* = .{ .width = 0, .len = 0, .style = style };
            x += columns;
        }
        return x;
    }

    /// Overwriting half of a wide character must blank its other half.
    fn clearWideAt(s: *Screen, x: usize, y: usize) void {
        const cell = s.at(x, y);
        if (cell.width == 0 and x > 0) s.at(x - 1, y).* = .{ .style = s.at(x - 1, y).style };
        if (cell.width == 2 and x + 1 < s.width) s.at(x + 1, y).* = .{ .style = cell.style };
    }

    fn appendMark(s: *Screen, x_in: usize, y: usize, cp: u21) void {
        var x = x_in;
        if (s.at(x, y).width == 0 and x > 0) x -= 1;
        const cell = s.at(x, y);
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(cp, &buffer) catch return;
        if (cell.len + length > cell.bytes.len) return;
        @memcpy(cell.bytes[cell.len..][0..length], buffer[0..length]);
        cell.len += length;
    }

    /// Fills columns [x, limit) of a row with spaces in `style`.
    pub fn fill(s: *Screen, x_start: usize, y: usize, limit_in: usize, style: Style) void {
        if (y >= s.height) return;
        var x = x_start;
        while (x < @min(limit_in, s.width)) : (x += 1) {
            s.clearWideAt(x, y);
            s.at(x, y).* = .{ .style = style };
        }
    }

    /// Writes what is needed to turn `previous` into this screen. With no previous
    /// screen, or a different size, it redraws everything.
    pub fn render(s: *const Screen, previous: ?*const Screen, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const old = if (previous) |p| (if (p.width == s.width and p.height == s.height) p else null) else null;
        try w.writeAll("\x1b[?25l");
        if (old == null) try w.writeAll("\x1b[0m\x1b[2J");

        var style: ?Style = null;
        for (0..s.height) |y| {
            var x: usize = 0;
            var cursor_x: ?usize = null;
            while (x < s.width) {
                const cell = s.at(x, y);
                if (cell.width == 0 or (old != null and cell.eql(old.?.at(x, y)) and !wideChanged(old.?, s, x, y))) {
                    x += 1;
                    continue;
                }
                if (cursor_x != x) try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                if (style == null or !style.?.eql(cell.style)) {
                    try cell.style.write(w);
                    style = cell.style;
                }
                try w.writeAll(cell.text());
                x += cell.width;
                cursor_x = x;
            }
        }
        try w.writeAll("\x1b[0m");
        if (s.cursor) |cursor| try w.print("\x1b[{d};{d}H\x1b[?25h", .{ cursor.y + 1, cursor.x + 1 });
    }

    /// A wide character is written whole, so a change to its second column counts.
    fn wideChanged(old: *const Screen, new: *const Screen, x: usize, y: usize) bool {
        return new.at(x, y).width == 2 and x + 1 < new.width and !new.at(x + 1, y).eql(old.at(x + 1, y));
    }
};

pub const Mouse = struct {
    pub const Button = enum { left, middle, right, wheel_up, wheel_down, other };

    button: Button,
    /// Zero-based cell.
    x: usize,
    y: usize,
    /// False for a release.
    pressed: bool,
};

pub const Key = union(enum) {
    char: u21,
    mouse: Mouse,
    /// Ctrl plus a letter, as that lower-case letter.
    ctrl: u8,
    enter,
    tab,
    backtab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    /// A sequence that was understood well enough to skip.
    ignored,
};

pub const Decoded = struct { key: Key, consumed: usize };

/// Longest escape sequence accepted. Anything longer is garbage to skip past.
const max_sequence = 32;

/// Decodes one key from the start of `input`. Returns null if more bytes are
/// needed, which for a lone ESC means the caller should wait briefly, then treat
/// it as the Escape key.
pub fn decodeKey(input: []const u8) ?Decoded {
    if (input.len == 0) return null;
    const first = input[0];
    switch (first) {
        0x1B => return decodeEscape(input),
        '\r', '\n' => return .{ .key = .enter, .consumed = 1 },
        '\t' => return .{ .key = .tab, .consumed = 1 },
        0x7F, 0x08 => return .{ .key = .backspace, .consumed = 1 },
        0x01...0x07, 0x0B, 0x0C, 0x0E...0x1A => return .{ .key = .{ .ctrl = first + 'a' - 1 }, .consumed = 1 },
        0x00, 0x1C...0x1F => return .{ .key = .ignored, .consumed = 1 },
        else => {},
    }
    const length = std.unicode.utf8ByteSequenceLength(first) catch return .{ .key = .ignored, .consumed = 1 };
    if (input.len < length) return null;
    const cp = std.unicode.utf8Decode(input[0..length]) catch return .{ .key = .ignored, .consumed = 1 };
    if (isControl(cp)) return .{ .key = .ignored, .consumed = length };
    return .{ .key = .{ .char = cp }, .consumed = length };
}

fn decodeEscape(input: []const u8) ?Decoded {
    if (input.len == 1) return null;
    if (input[1] == 'O') {
        if (input.len < 3) return null;
        const key: Key = switch (input[2]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => .ignored,
        };
        return .{ .key = key, .consumed = 3 };
    }
    if (input[1] != '[') return .{ .key = .escape, .consumed = 1 };

    var i: usize = 2;
    while (i < input.len and i < max_sequence) : (i += 1) {
        const c = input[i];
        if (c >= 0x40 and c <= 0x7E) return .{ .key = csiKey(c, input[2..i]), .consumed = i + 1 };
        if (c < 0x20 or c > 0x3F) return .{ .key = .ignored, .consumed = i };
    }
    if (i >= max_sequence) return .{ .key = .ignored, .consumed = i };
    return null;
}

/// Reads an SGR mouse report: ESC [ < button ; column ; row, ending in M for a
/// press or m for a release. Bit 6 of the button means the wheel, and bit 5 means
/// movement, which is not used.
fn mouseKey(final: u8, parameters: []const u8) Key {
    var fields = std.mem.splitScalar(u8, parameters[1..], ';');
    const code = std.fmt.parseInt(u16, fields.next() orelse return .ignored, 10) catch return .ignored;
    const column = std.fmt.parseInt(u32, fields.next() orelse return .ignored, 10) catch return .ignored;
    const row = std.fmt.parseInt(u32, fields.next() orelse return .ignored, 10) catch return .ignored;
    if (column == 0 or row == 0) return .ignored;

    const button: Mouse.Button = if (code & 32 != 0) .other else if (code & 64 != 0)
        (if (code & 3 == 0) .wheel_up else if (code & 3 == 1) .wheel_down else .other)
    else switch (code & 3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .other,
    };
    return .{ .mouse = .{ .button = button, .x = column - 1, .y = row - 1, .pressed = final == 'M' } };
}

fn csiKey(final: u8, parameters: []const u8) Key {
    if (parameters.len != 0 and parameters[0] == '<') {
        return if (final == 'M' or final == 'm') mouseKey(final, parameters) else .ignored;
    }
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'Z' => .backtab,
        '~' => {
            const end = std.mem.indexOfScalar(u8, parameters, ';') orelse parameters.len;
            const code = std.fmt.parseInt(u8, parameters[0..end], 10) catch return .ignored;
            return switch (code) {
                1, 7 => .home,
                4, 8 => .end,
                3 => .delete,
                5 => .page_up,
                6 => .page_down,
                else => .ignored,
            };
        },
        else => .ignored,
    };
}

const testing = std.testing;

test "widths" {
    try testing.expectEqual(1, width('a'));
    try testing.expectEqual(1, width(0xE9)); // é
    try testing.expectEqual(0, width(0x301)); // Combining acute.
    try testing.expectEqual(2, width(0x4E2D)); // 中
    try testing.expectEqual(2, width(0x1F600)); // 😀
    try testing.expectEqual(0, width(0x200D)); // Zero-width joiner.
    try testing.expectEqual(8, displayWidth("中文 abc"));
    try testing.expectEqual(3, displayWidth("a\x1bb\x07c"));
}

test "invalid UTF-8 is replaced, never fatal" {
    try testing.expectEqual(2, displayWidth("\xFF\xC3"));
}

fn renderToString(s: *const Screen, previous: ?*const Screen, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try s.render(previous, &w);
    return w.buffered();
}

test "control characters cannot reach the output" {
    var s: Screen = try .init(testing.allocator, 20, 1);
    defer s.deinit(testing.allocator);
    _ = s.put(0, 0, 20, "a\x1b[2Jb\xC2\x9Bc\xe2\x80\xaed", .{});
    var buffer: [512]u8 = undefined;
    const out = try renderToString(&s, null, &buffer);
    try testing.expect(std.mem.indexOf(u8, out, "a[2Jbcd") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2Jb") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xae") == null);
}

test "text stops at the limit, and a wide character never straddles it" {
    var s: Screen = try .init(testing.allocator, 5, 1);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(4, s.put(0, 0, 5, "中文字", .{}));
    try testing.expectEqual(' ', s.at(4, 0).bytes[0]);
    try testing.expectEqual(2, s.put(0, 0, 2, "abcdef", .{}));
}

test "overwriting half of a wide character blanks the other half" {
    var s: Screen = try .init(testing.allocator, 4, 1);
    defer s.deinit(testing.allocator);
    _ = s.put(0, 0, 4, "中", .{});
    _ = s.put(1, 0, 4, "x", .{});
    try testing.expectEqual(1, s.at(0, 0).width);
    try testing.expectEqual(' ', s.at(0, 0).bytes[0]);
    try testing.expectEqual('x', s.at(1, 0).bytes[0]);
}

test "combining marks stay with their character" {
    var s: Screen = try .init(testing.allocator, 4, 1);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(1, s.put(0, 0, 4, "e\xCC\x81", .{}));
    try testing.expectEqualStrings("e\xCC\x81", s.at(0, 0).text());
}

test "render writes only what changed" {
    var a: Screen = try .init(testing.allocator, 10, 3);
    defer a.deinit(testing.allocator);
    var b: Screen = try .init(testing.allocator, 10, 3);
    defer b.deinit(testing.allocator);
    _ = a.put(0, 0, 10, "same", .{});
    _ = b.put(0, 0, 10, "same", .{});
    _ = b.put(3, 2, 10, "x", .{ .bold = true });

    var buffer: [256]u8 = undefined;
    const out = try renderToString(&b, &a, &buffer);
    try testing.expectEqualStrings("\x1b[?25l\x1b[3;4H\x1b[0;1mx\x1b[0m", out);

    @memcpy(a.cells, b.cells);
    try testing.expectEqualStrings("\x1b[?25l\x1b[0m", try renderToString(&b, &a, &buffer));
}

test "a resize redraws everything" {
    var a: Screen = try .init(testing.allocator, 2, 1);
    defer a.deinit(testing.allocator);
    var b: Screen = try .init(testing.allocator, 3, 1);
    defer b.deinit(testing.allocator);
    var buffer: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try renderToString(&b, &a, &buffer), "\x1b[2J") != null);
}

fn expectKey(expected: Key, input: []const u8) !void {
    const decoded = decodeKey(input).?;
    try testing.expectEqual(expected, decoded.key);
    try testing.expectEqual(input.len, decoded.consumed);
}

test "keys" {
    try expectKey(.{ .char = 'j' }, "j");
    try expectKey(.{ .char = 0x4E2D }, "中");
    try expectKey(.enter, "\r");
    try expectKey(.backspace, "\x7f");
    try expectKey(.{ .ctrl = 'd' }, "\x04");
    try expectKey(.up, "\x1b[A");
    try expectKey(.down, "\x1bOB");
    try expectKey(.page_down, "\x1b[6~");
    try expectKey(.delete, "\x1b[3~");
    try expectKey(.home, "\x1b[1~");
    try expectKey(.backtab, "\x1b[Z");
    try expectKey(.up, "\x1b[1;5A");
    try expectKey(.ignored, "\x1b[200~");
}

test "mouse reports" {
    try expectKey(.{ .mouse = .{ .button = .left, .x = 9, .y = 4, .pressed = true } }, "\x1b[<0;10;5M");
    try expectKey(.{ .mouse = .{ .button = .left, .x = 9, .y = 4, .pressed = false } }, "\x1b[<0;10;5m");
    try expectKey(.{ .mouse = .{ .button = .wheel_up, .x = 0, .y = 0, .pressed = true } }, "\x1b[<64;1;1M");
    try expectKey(.{ .mouse = .{ .button = .wheel_down, .x = 1, .y = 1, .pressed = true } }, "\x1b[<65;2;2M");
    try expectKey(.{ .mouse = .{ .button = .other, .x = 1, .y = 1, .pressed = true } }, "\x1b[<35;2;2M");
    try expectKey(.ignored, "\x1b[<0;0;5M");
    try expectKey(.ignored, "\x1b[<0;1M");
}

test "partial input waits for more" {
    try testing.expectEqual(null, decodeKey("\x1b"));
    try testing.expectEqual(null, decodeKey("\x1b["));
    try testing.expectEqual(null, decodeKey("\x1b[1;"));
    try testing.expectEqual(null, decodeKey("\xE4\xB8"));
}

test "garbage is consumed, so input cannot stall" {
    const digits: [100]u8 = @splat('1');
    const long = "\x1b[" ++ digits;
    try testing.expect(decodeKey(long).?.consumed > 0);
    try testing.expectEqual(1, decodeKey("\xFF").?.consumed);
    try testing.expectEqual(Key.escape, decodeKey("\x1bx").?.key);
}
