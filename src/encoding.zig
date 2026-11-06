//! Converts feed bytes to valid UTF-8 before any parsing happens, so that every
//! later stage can assume UTF-8.
//!
//! Declared encodings are often wrong, so the bytes decide first: anything that
//! already validates as UTF-8 is UTF-8, whatever the XML declaration claims.

const std = @import("std");

pub const Error = error{ OutOfMemory, UnsupportedEncoding };

/// Returns `bytes` as valid UTF-8 with any byte order mark removed. Valid input
/// is returned without copying.
pub fn toUtf8(arena: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return toUtf8(arena, bytes[3..]);
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return fromUtf16(arena, bytes[2..], .little);
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return fromUtf16(arena, bytes[2..], .big);
    // UTF-16 with no mark still starts with a recognizable "<" and a zero byte.
    if (std.mem.startsWith(u8, bytes, "<\x00")) return fromUtf16(arena, bytes, .little);
    if (std.mem.startsWith(u8, bytes, "\x00<")) return fromUtf16(arena, bytes, .big);

    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;

    const declared = declaredEncoding(bytes);
    if (declared.len != 0 and !isWindows1252Compatible(declared)) return error.UnsupportedEncoding;
    return repair(arena, bytes);
}

/// Returns a web page as valid UTF-8. Pages declare their charset in the HTTP header
/// or a `<meta>` tag rather than an XML declaration. A charset this module cannot
/// convert is refused, since reading it as Windows-1252 would produce garbled text.
pub fn pageToUtf8(arena: std.mem.Allocator, bytes: []const u8, content_type: []const u8) Error![]const u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        const declared = declaredCharset(content_type);
        const name = if (declared.len != 0) declared else declaredCharset(bytes[0..@min(bytes.len, 2048)]);
        if (name.len != 0 and !isWindows1252Compatible(name)) return error.UnsupportedEncoding;
    }
    return toUtf8(arena, bytes);
}

/// Reads the value after the first `charset=`, or returns an empty slice.
fn declaredCharset(text: []const u8) []const u8 {
    const key = "charset=";
    const at = std.ascii.findIgnoreCase(text, key) orelse return "";
    const rest = std.mem.trimStart(u8, text[at + key.len ..], " \"'");
    const end = std.mem.indexOfAny(u8, rest, " \"';>/\r\n") orelse rest.len;
    return rest[0..end];
}

/// Reads `encoding="..."` from an XML declaration, or returns an empty slice.
pub fn declaredEncoding(bytes: []const u8) []const u8 {
    const head = bytes[0..@min(bytes.len, 256)];
    const decl_end = std.mem.indexOf(u8, head, "?>") orelse return "";
    const decl = head[0..decl_end];
    const key = std.mem.indexOf(u8, decl, "encoding") orelse return "";
    var i = key + "encoding".len;
    while (i < decl.len and (decl[i] == ' ' or decl[i] == '=')) i += 1;
    if (i >= decl.len or (decl[i] != '"' and decl[i] != '\'')) return "";
    const quote = decl[i];
    const rest = decl[i + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, quote) orelse return "";
    return rest[0..close];
}

fn isWindows1252Compatible(name: []const u8) bool {
    const names = [_][]const u8{
        "utf-8",       "utf8",         "us-ascii", "ascii",
        "iso-8859-1",  "iso8859-1",    "latin1",   "latin-1",
        "iso-8859-15", "windows-1252", "cp1252",   "x-mac-roman",
    };
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

/// Keeps every valid UTF-8 sequence and reads each stray byte as Windows-1252,
/// which also covers files that mix the two.
fn repair(arena: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, bytes.len + bytes.len / 2);
    var i: usize = 0;
    while (i < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (length != 0 and i + length <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + length])) {
            try out.appendSlice(arena, bytes[i .. i + length]);
            i += length;
            continue;
        }
        try appendCodepoint(arena, &out, windows1252(bytes[i]));
        i += 1;
    }
    return out.items;
}

fn windows1252(byte: u8) u21 {
    const high = [32]u21{
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    };
    return if (byte >= 0x80 and byte < 0xA0) high[byte - 0x80] else byte;
}

fn fromUtf16(arena: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, bytes.len);
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const unit = std.mem.readInt(u16, bytes[i..][0..2], endian);
        var codepoint: u21 = unit;
        if (unit >= 0xD800 and unit < 0xDC00 and i + 3 < bytes.len) {
            const low = std.mem.readInt(u16, bytes[i + 2 ..][0..2], endian);
            if (low >= 0xDC00 and low < 0xE000) {
                codepoint = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (low - 0xDC00);
                i += 2;
            }
        }
        try appendCodepoint(arena, &out, codepoint);
    }
    return out.items;
}

pub fn appendCodepoint(arena: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) error{OutOfMemory}!void {
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch std.unicode.utf8Encode(0xFFFD, &buffer) catch unreachable;
    try out.appendSlice(arena, buffer[0..length]);
}

const testing = std.testing;

test "valid UTF-8 is returned without copying" {
    const input = "<rss>caf\xC3\xA9</rss>";
    try testing.expectEqual(input.ptr, (try toUtf8(testing.allocator, input)).ptr);
}

test "a wrong declaration does not override valid UTF-8" {
    const input = "<?xml encoding=\"iso-8859-1\"?><a>caf\xC3\xA9</a>";
    try testing.expectEqualStrings(input, try toUtf8(testing.allocator, input));
}

test "byte order mark is removed" {
    try testing.expectEqualStrings("<a/>", try toUtf8(testing.allocator, "\xEF\xBB\xBF<a/>"));
}

test "Windows-1252 bytes become UTF-8" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try toUtf8(arena.allocator(), "<?xml encoding=\"windows-1252\"?>caf\xE9 \x93x\x94");
    try testing.expectEqualStrings("<?xml encoding=\"windows-1252\"?>caf\xC3\xA9 \xE2\x80\x9Cx\xE2\x80\x9D", result);
}

test "mixed UTF-8 and stray bytes keep the valid parts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("\xC3\xA9 \xC3\xA9", try toUtf8(arena.allocator(), "\xC3\xA9 \xE9"));
}

test "UTF-16 with a byte order mark" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("<a>", try toUtf8(arena.allocator(), "\xFF\xFE<\x00a\x00>\x00"));
}

test "unsupported declared encodings are refused rather than garbled" {
    try testing.expectError(error.UnsupportedEncoding, toUtf8(testing.allocator, "<?xml encoding=\"shift_jis\"?>\x82\xA0"));
}

test "a page in a charset this cannot convert is refused, wherever it is declared" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shift_jis = "<p>\x93\xFA\x96\x7B\x8C\xEA</p>";
    try std.testing.expectError(error.UnsupportedEncoding, pageToUtf8(a, shift_jis, "text/html; charset=Shift_JIS"));
    try std.testing.expectError(error.UnsupportedEncoding, pageToUtf8(a, "<meta charset=\"euc-kr\">\xC7\xD1", "text/html"));
    try std.testing.expectError(error.UnsupportedEncoding, pageToUtf8(a, "<meta http-equiv=content-type content='text/html; charset=windows-1251'>\xCF", ""));
}

test "pages that can be read still are" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("caf\xC3\xA9", try pageToUtf8(a, "caf\xE9", "text/html; charset=ISO-8859-1"));
    try std.testing.expectEqualStrings("caf\xC3\xA9", try pageToUtf8(a, "caf\xE9", "text/html"));
    try std.testing.expectEqualStrings("caf\xC3\xA9", try pageToUtf8(a, "caf\xC3\xA9", "text/html; charset=Shift_JIS"));
}
