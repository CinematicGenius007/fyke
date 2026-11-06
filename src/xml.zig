//! Lenient streaming XML pull parser for hostile, frequently malformed input.
//!
//! The parser allocates nothing: events are slices of the input. It always
//! produces a balanced stream, so consumers never handle a missing end tag.
//!
//! Lenient means broken markup is recovered from rather than rejected:
//!   * a mismatched end tag closes up to its nearest open match, or is dropped
//!   * elements still open at the end of the input are closed
//!   * "<" that cannot start a tag is plain text
//!   * attribute values may be unquoted
//!
//! Hardened means nothing in the input can make the work explode:
//!   * DOCTYPE is skipped, so no entity can ever be defined or expanded
//!   * nesting depth is capped
//!   * entity decoding only ever shrinks text, so output is bounded by input

const std = @import("std");
const encoding = @import("encoding.zig");

pub const max_depth = 256;
const max_bindings = 128;

pub const Error = error{TooDeep};

pub const Name = struct {
    /// As written, including any prefix.
    raw: []const u8,
    prefix: []const u8,
    local: []const u8,
    /// Namespace URI, or empty when none is in scope.
    uri: []const u8,
};

pub const Start = struct {
    name: Name,
    attrs: []const u8,

    pub fn attributes(start: Start) AttributeIterator {
        return .{ .bytes = start.attrs };
    }

    /// Returns the raw value of an attribute, matched by name as written.
    pub fn attribute(start: Start, name: []const u8) ?[]const u8 {
        var it = start.attributes();
        while (it.next()) |attr| {
            if (std.mem.eql(u8, attr.name, name)) return attr.value;
        }
        return null;
    }
};

pub const Event = union(enum) {
    start: Start,
    end: Name,
    /// Raw character data. Pass through `decodeText`.
    text: []const u8,
    /// Literal character data, which needs no decoding.
    cdata: []const u8,
    eof,
};

pub const Attribute = struct { name: []const u8, value: []const u8 };

pub const AttributeIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(it: *AttributeIterator) ?Attribute {
        const b = it.bytes;
        var i = it.index;
        defer it.index = i;
        while (true) {
            while (i < b.len and !isNameStart(b[i])) i += 1;
            if (i >= b.len) return null;
            const name_start = i;
            while (i < b.len and isNameChar(b[i])) i += 1;
            const name = b[name_start..i];
            while (i < b.len and isSpace(b[i])) i += 1;
            if (i >= b.len or b[i] != '=') return .{ .name = name, .value = "" };
            i += 1;
            while (i < b.len and isSpace(b[i])) i += 1;
            if (i >= b.len) return .{ .name = name, .value = "" };
            if (b[i] == '"' or b[i] == '\'') {
                const quote = b[i];
                const value_start = i + 1;
                const close = std.mem.indexOfScalarPos(u8, b, value_start, quote) orelse b.len;
                i = @min(close + 1, b.len);
                return .{ .name = name, .value = b[value_start..close] };
            }
            const value_start = i;
            while (i < b.len and !isSpace(b[i])) i += 1;
            return .{ .name = name, .value = b[value_start..i] };
        }
    }
};

const Binding = struct { prefix: []const u8, uri: []const u8 };

const Open = struct {
    name: Name,
    /// Length of `bindings` before this element added its own.
    bindings_before: u16,
};

pub const Parser = struct {
    input: []const u8,
    pos: usize = 0,
    /// Offset where the most recent event began in `input`.
    token_start: usize = 0,

    open: [max_depth]Open = undefined,
    depth: u16 = 0,
    bindings: [max_bindings]Binding = undefined,
    binding_count: u16 = 0,

    /// No "]]>" remains in the input. Remembering this keeps a document of broken
    /// CDATA sections linear rather than rescanning to the end for each one.
    no_cdata_close: bool = false,

    /// Set after "<a/>" so that its end event is produced next.
    pending_end: bool = false,
    /// End tag that matched an element below the top of the stack. Closes are
    /// produced one per call until that element itself is closed.
    close_to_depth: ?u16 = null,

    pub fn init(input: []const u8) Parser {
        return .{ .input = input };
    }

    pub fn next(p: *Parser) Error!Event {
        if (p.pending_end) {
            p.pending_end = false;
            return .{ .end = p.pop() };
        }
        if (p.close_to_depth) |target| {
            const name = p.pop();
            if (p.depth <= target) p.close_to_depth = null;
            return .{ .end = name };
        }

        while (true) {
            if (p.pos >= p.input.len) {
                p.token_start = p.input.len;
                if (p.depth > 0) return .{ .end = p.pop() };
                return .eof;
            }
            p.token_start = p.pos;
            const rest = p.input[p.pos..];

            if (rest[0] != '<') return p.takeText();

            if (std.mem.startsWith(u8, rest, "<!--")) {
                p.skipPast(4, "-->");
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                return p.takeCdata();
            } else if (std.mem.startsWith(u8, rest, "<?")) {
                p.skipPast(2, "?>");
            } else if (std.mem.startsWith(u8, rest, "<!")) {
                p.skipDeclaration();
            } else if (std.mem.startsWith(u8, rest, "</")) {
                if (p.takeEndTag()) |event| return event;
            } else if (rest.len > 1 and isNameStart(rest[1])) {
                return p.takeStartTag();
            } else {
                // A bare "<", as in "a < b". Text runs to the next "<" after it.
                p.pos += 1;
                return p.takeTextFrom(p.token_start);
            }
        }
    }

    /// Consumes the rest of the element whose start event was just returned, and
    /// returns its inner markup as a slice of the input.
    pub fn skipElement(p: *Parser) Error![]const u8 {
        const inner_start = p.pos;
        const target = p.depth - 1;
        while (true) {
            const event = try p.next();
            if (event == .eof) return p.input[inner_start..];
            if (event == .end and p.depth == target) return p.input[inner_start..@max(inner_start, p.token_start)];
        }
    }

    fn takeCdata(p: *Parser) Event {
        const start = p.pos + "<![CDATA[".len;
        if (!p.no_cdata_close) {
            if (std.mem.indexOfPos(u8, p.input, start, "]]>")) |close| {
                p.pos = close + 3;
                return .{ .cdata = p.input[start..close] };
            }
            p.no_cdata_close = true;
        }
        // Some generators write "]]</description>", dropping the ">". Without this,
        // one broken section would swallow every entry after it.
        const close = std.mem.indexOfPos(u8, p.input, start, "]]<") orelse p.input.len;
        p.pos = @min(close + 2, p.input.len);
        return .{ .cdata = p.input[start..close] };
    }

    fn takeText(p: *Parser) Event {
        return p.takeTextFrom(p.pos);
    }

    fn takeTextFrom(p: *Parser, start: usize) Event {
        const close = std.mem.indexOfScalarPos(u8, p.input, p.pos, '<') orelse p.input.len;
        p.pos = close;
        return .{ .text = p.input[start..close] };
    }

    fn skipPast(p: *Parser, opening: usize, terminator: []const u8) void {
        const close = std.mem.indexOfPos(u8, p.input, p.pos + opening, terminator) orelse p.input.len;
        p.pos = @min(close + terminator.len, p.input.len);
    }

    /// Skips "<!DOCTYPE ...>" and any internal subset in brackets, unread. This is
    /// the whole defense against entity expansion attacks.
    fn skipDeclaration(p: *Parser) void {
        var i = p.pos + 2;
        var brackets: usize = 0;
        var quote: u8 = 0;
        while (i < p.input.len) : (i += 1) {
            const c = p.input[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
            } else switch (c) {
                '"', '\'' => quote = c,
                '[' => brackets += 1,
                ']' => brackets -|= 1,
                '>' => if (brackets == 0) {
                    p.pos = i + 1;
                    return;
                },
                else => {},
            }
        }
        p.pos = p.input.len;
    }

    fn takeEndTag(p: *Parser) ?Event {
        const start = p.pos + 2;
        var i = start;
        while (i < p.input.len and isNameChar(p.input[i])) i += 1;
        const raw = p.input[start..i];
        const close = std.mem.indexOfScalarPos(u8, p.input, i, '>') orelse p.input.len;
        p.pos = @min(close + 1, p.input.len);

        var d = p.depth;
        while (d > 0) : (d -= 1) {
            if (std.mem.eql(u8, p.open[d - 1].name.raw, raw)) {
                if (d != p.depth) p.close_to_depth = d - 1;
                return .{ .end = p.pop() };
            }
        }
        return null;
    }

    fn takeStartTag(p: *Parser) Error!Event {
        const name_start = p.pos + 1;
        var i = name_start;
        while (i < p.input.len and isNameChar(p.input[i])) i += 1;
        const raw = p.input[name_start..i];

        const attrs_start = i;
        const tag_end = findTagEnd(p.input, i);
        var attrs_end = tag_end;
        const self_closing = attrs_end > attrs_start and p.input[attrs_end - 1] == '/';
        if (self_closing) attrs_end -= 1;
        p.pos = @min(tag_end + 1, p.input.len);

        if (p.depth == max_depth) return error.TooDeep;

        const bindings_before = p.binding_count;
        const attrs = p.input[attrs_start..attrs_end];
        var it: AttributeIterator = .{ .bytes = attrs };
        while (it.next()) |attr| {
            if (std.mem.eql(u8, attr.name, "xmlns")) {
                p.bind("", attr.value);
            } else if (std.mem.startsWith(u8, attr.name, "xmlns:")) {
                p.bind(attr.name[6..], attr.value);
            }
        }

        const name = p.resolve(raw);
        p.open[p.depth] = .{ .name = name, .bindings_before = bindings_before };
        p.depth += 1;
        p.pending_end = self_closing;
        return .{ .start = .{ .name = name, .attrs = attrs } };
    }

    fn bind(p: *Parser, prefix: []const u8, uri: []const u8) void {
        if (p.binding_count == max_bindings) return;
        p.bindings[p.binding_count] = .{ .prefix = prefix, .uri = uri };
        p.binding_count += 1;
    }

    fn resolve(p: *const Parser, raw: []const u8) Name {
        const colon = std.mem.indexOfScalar(u8, raw, ':');
        const prefix = if (colon) |c| raw[0..c] else "";
        const local = if (colon) |c| raw[c + 1 ..] else raw;
        var i = p.binding_count;
        while (i > 0) : (i -= 1) {
            const binding = p.bindings[i - 1];
            if (std.mem.eql(u8, binding.prefix, prefix)) {
                return .{ .raw = raw, .prefix = prefix, .local = local, .uri = binding.uri };
            }
        }
        return .{ .raw = raw, .prefix = prefix, .local = local, .uri = "" };
    }

    fn pop(p: *Parser) Name {
        p.depth -= 1;
        const open = p.open[p.depth];
        p.binding_count = open.bindings_before;
        return open.name;
    }
};

/// Finds the ">" that ends a tag, ignoring any inside quotes. An unterminated
/// quote falls back to the first ">", so that one stray quote cannot swallow the
/// rest of the document.
fn findTagEnd(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '>' => return i,
            '"', '\'' => {
                const close = std.mem.indexOfScalarPos(u8, input, i + 1, input[i]) orelse {
                    return std.mem.indexOfScalarPos(u8, input, start, '>') orelse input.len;
                };
                i = close;
            },
            else => {},
        }
    }
    return input.len;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':' or c >= 0x80;
}

fn isNameChar(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.';
}

/// Resolves entity references. Unknown entities are kept as written, and input
/// with no "&" is returned without copying.
pub fn decodeText(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    var i = std.mem.indexOfScalar(u8, raw, '&') orelse return raw;
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    out.appendSliceAssumeCapacity(raw[0..i]);
    while (i < raw.len) {
        if (raw[i] != '&') {
            const stop = std.mem.indexOfScalarPos(u8, raw, i, '&') orelse raw.len;
            out.appendSliceAssumeCapacity(raw[i..stop]);
            i = stop;
            continue;
        }
        const window = raw[i + 1 .. @min(raw.len, i + 1 + 32)];
        const semicolon = std.mem.indexOfScalar(u8, window, ';');
        if (semicolon) |length| {
            if (resolveEntity(window[0..length])) |codepoint| {
                try encoding.appendCodepoint(arena, &out, codepoint);
                i += length + 2;
                continue;
            }
        }
        out.appendAssumeCapacity('&');
        i += 1;
    }
    return out.items;
}

fn resolveEntity(name: []const u8) ?u21 {
    if (name.len > 1 and name[0] == '#') {
        const value = if (name[1] == 'x' or name[1] == 'X')
            std.fmt.parseInt(u32, name[2..], 16)
        else
            std.fmt.parseInt(u32, name[1..], 10);
        const codepoint = value catch return null;
        if (codepoint == 0 or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint < 0xE000)) return 0xFFFD;
        return @intCast(codepoint);
    }
    return named_entities.get(name);
}

/// The five XML entities, plus the HTML 4 set that feeds use without declaring
/// it. Every entry is shorter decoded than encoded, which `decodeText` relies on.
const named_entities: std.StaticStringMap(u21) = .initComptime(.{
    .{ "quot", '"' },
    .{ "amp", '&' },
    .{ "lt", '<' },
    .{ "gt", '>' },
    .{ "nbsp", 0xA0 },
    .{ "iexcl", 0xA1 },
    .{ "cent", 0xA2 },
    .{ "pound", 0xA3 },
    .{ "curren", 0xA4 },
    .{ "yen", 0xA5 },
    .{ "brvbar", 0xA6 },
    .{ "sect", 0xA7 },
    .{ "uml", 0xA8 },
    .{ "copy", 0xA9 },
    .{ "ordf", 0xAA },
    .{ "laquo", 0xAB },
    .{ "not", 0xAC },
    .{ "shy", 0xAD },
    .{ "reg", 0xAE },
    .{ "macr", 0xAF },
    .{ "deg", 0xB0 },
    .{ "plusmn", 0xB1 },
    .{ "sup2", 0xB2 },
    .{ "sup3", 0xB3 },
    .{ "acute", 0xB4 },
    .{ "micro", 0xB5 },
    .{ "para", 0xB6 },
    .{ "middot", 0xB7 },
    .{ "cedil", 0xB8 },
    .{ "sup1", 0xB9 },
    .{ "ordm", 0xBA },
    .{ "raquo", 0xBB },
    .{ "frac14", 0xBC },
    .{ "frac12", 0xBD },
    .{ "frac34", 0xBE },
    .{ "iquest", 0xBF },
    .{ "Agrave", 0xC0 },
    .{ "Aacute", 0xC1 },
    .{ "Acirc", 0xC2 },
    .{ "Atilde", 0xC3 },
    .{ "Auml", 0xC4 },
    .{ "Aring", 0xC5 },
    .{ "AElig", 0xC6 },
    .{ "Ccedil", 0xC7 },
    .{ "Egrave", 0xC8 },
    .{ "Eacute", 0xC9 },
    .{ "Ecirc", 0xCA },
    .{ "Euml", 0xCB },
    .{ "Igrave", 0xCC },
    .{ "Iacute", 0xCD },
    .{ "Icirc", 0xCE },
    .{ "Iuml", 0xCF },
    .{ "ETH", 0xD0 },
    .{ "Ntilde", 0xD1 },
    .{ "Ograve", 0xD2 },
    .{ "Oacute", 0xD3 },
    .{ "Ocirc", 0xD4 },
    .{ "Otilde", 0xD5 },
    .{ "Ouml", 0xD6 },
    .{ "times", 0xD7 },
    .{ "Oslash", 0xD8 },
    .{ "Ugrave", 0xD9 },
    .{ "Uacute", 0xDA },
    .{ "Ucirc", 0xDB },
    .{ "Uuml", 0xDC },
    .{ "Yacute", 0xDD },
    .{ "THORN", 0xDE },
    .{ "szlig", 0xDF },
    .{ "agrave", 0xE0 },
    .{ "aacute", 0xE1 },
    .{ "acirc", 0xE2 },
    .{ "atilde", 0xE3 },
    .{ "auml", 0xE4 },
    .{ "aring", 0xE5 },
    .{ "aelig", 0xE6 },
    .{ "ccedil", 0xE7 },
    .{ "egrave", 0xE8 },
    .{ "eacute", 0xE9 },
    .{ "ecirc", 0xEA },
    .{ "euml", 0xEB },
    .{ "igrave", 0xEC },
    .{ "iacute", 0xED },
    .{ "icirc", 0xEE },
    .{ "iuml", 0xEF },
    .{ "eth", 0xF0 },
    .{ "ntilde", 0xF1 },
    .{ "ograve", 0xF2 },
    .{ "oacute", 0xF3 },
    .{ "ocirc", 0xF4 },
    .{ "otilde", 0xF5 },
    .{ "ouml", 0xF6 },
    .{ "divide", 0xF7 },
    .{ "oslash", 0xF8 },
    .{ "ugrave", 0xF9 },
    .{ "uacute", 0xFA },
    .{ "ucirc", 0xFB },
    .{ "uuml", 0xFC },
    .{ "yacute", 0xFD },
    .{ "thorn", 0xFE },
    .{ "yuml", 0xFF },
    .{ "OElig", 0x152 },
    .{ "oelig", 0x153 },
    .{ "Scaron", 0x160 },
    .{ "scaron", 0x161 },
    .{ "Yuml", 0x178 },
    .{ "fnof", 0x192 },
    .{ "circ", 0x2C6 },
    .{ "tilde", 0x2DC },
    .{ "Alpha", 0x391 },
    .{ "Beta", 0x392 },
    .{ "Gamma", 0x393 },
    .{ "Delta", 0x394 },
    .{ "Epsilon", 0x395 },
    .{ "Zeta", 0x396 },
    .{ "Eta", 0x397 },
    .{ "Theta", 0x398 },
    .{ "Iota", 0x399 },
    .{ "Kappa", 0x39A },
    .{ "Lambda", 0x39B },
    .{ "Mu", 0x39C },
    .{ "Nu", 0x39D },
    .{ "Xi", 0x39E },
    .{ "Omicron", 0x39F },
    .{ "Pi", 0x3A0 },
    .{ "Rho", 0x3A1 },
    .{ "Sigma", 0x3A3 },
    .{ "Tau", 0x3A4 },
    .{ "Upsilon", 0x3A5 },
    .{ "Phi", 0x3A6 },
    .{ "Chi", 0x3A7 },
    .{ "Psi", 0x3A8 },
    .{ "Omega", 0x3A9 },
    .{ "alpha", 0x3B1 },
    .{ "beta", 0x3B2 },
    .{ "gamma", 0x3B3 },
    .{ "delta", 0x3B4 },
    .{ "epsilon", 0x3B5 },
    .{ "zeta", 0x3B6 },
    .{ "eta", 0x3B7 },
    .{ "theta", 0x3B8 },
    .{ "iota", 0x3B9 },
    .{ "kappa", 0x3BA },
    .{ "lambda", 0x3BB },
    .{ "mu", 0x3BC },
    .{ "nu", 0x3BD },
    .{ "xi", 0x3BE },
    .{ "omicron", 0x3BF },
    .{ "pi", 0x3C0 },
    .{ "rho", 0x3C1 },
    .{ "sigmaf", 0x3C2 },
    .{ "sigma", 0x3C3 },
    .{ "tau", 0x3C4 },
    .{ "upsilon", 0x3C5 },
    .{ "phi", 0x3C6 },
    .{ "chi", 0x3C7 },
    .{ "psi", 0x3C8 },
    .{ "omega", 0x3C9 },
    .{ "thetasym", 0x3D1 },
    .{ "upsih", 0x3D2 },
    .{ "piv", 0x3D6 },
    .{ "ensp", 0x2002 },
    .{ "emsp", 0x2003 },
    .{ "thinsp", 0x2009 },
    .{ "zwnj", 0x200C },
    .{ "zwj", 0x200D },
    .{ "lrm", 0x200E },
    .{ "rlm", 0x200F },
    .{ "ndash", 0x2013 },
    .{ "mdash", 0x2014 },
    .{ "lsquo", 0x2018 },
    .{ "rsquo", 0x2019 },
    .{ "sbquo", 0x201A },
    .{ "ldquo", 0x201C },
    .{ "rdquo", 0x201D },
    .{ "bdquo", 0x201E },
    .{ "dagger", 0x2020 },
    .{ "Dagger", 0x2021 },
    .{ "bull", 0x2022 },
    .{ "hellip", 0x2026 },
    .{ "permil", 0x2030 },
    .{ "prime", 0x2032 },
    .{ "Prime", 0x2033 },
    .{ "lsaquo", 0x2039 },
    .{ "rsaquo", 0x203A },
    .{ "oline", 0x203E },
    .{ "frasl", 0x2044 },
    .{ "euro", 0x20AC },
    .{ "image", 0x2111 },
    .{ "weierp", 0x2118 },
    .{ "real", 0x211C },
    .{ "trade", 0x2122 },
    .{ "alefsym", 0x2135 },
    .{ "larr", 0x2190 },
    .{ "uarr", 0x2191 },
    .{ "rarr", 0x2192 },
    .{ "darr", 0x2193 },
    .{ "harr", 0x2194 },
    .{ "crarr", 0x21B5 },
    .{ "lArr", 0x21D0 },
    .{ "uArr", 0x21D1 },
    .{ "rArr", 0x21D2 },
    .{ "dArr", 0x21D3 },
    .{ "hArr", 0x21D4 },
    .{ "forall", 0x2200 },
    .{ "part", 0x2202 },
    .{ "exist", 0x2203 },
    .{ "empty", 0x2205 },
    .{ "nabla", 0x2207 },
    .{ "isin", 0x2208 },
    .{ "notin", 0x2209 },
    .{ "ni", 0x220B },
    .{ "prod", 0x220F },
    .{ "sum", 0x2211 },
    .{ "minus", 0x2212 },
    .{ "lowast", 0x2217 },
    .{ "radic", 0x221A },
    .{ "prop", 0x221D },
    .{ "infin", 0x221E },
    .{ "ang", 0x2220 },
    .{ "and", 0x2227 },
    .{ "or", 0x2228 },
    .{ "cap", 0x2229 },
    .{ "cup", 0x222A },
    .{ "int", 0x222B },
    .{ "there4", 0x2234 },
    .{ "sim", 0x223C },
    .{ "cong", 0x2245 },
    .{ "asymp", 0x2248 },
    .{ "ne", 0x2260 },
    .{ "equiv", 0x2261 },
    .{ "le", 0x2264 },
    .{ "ge", 0x2265 },
    .{ "sub", 0x2282 },
    .{ "sup", 0x2283 },
    .{ "nsub", 0x2284 },
    .{ "sube", 0x2286 },
    .{ "supe", 0x2287 },
    .{ "oplus", 0x2295 },
    .{ "otimes", 0x2297 },
    .{ "perp", 0x22A5 },
    .{ "sdot", 0x22C5 },
    .{ "lceil", 0x2308 },
    .{ "rceil", 0x2309 },
    .{ "lfloor", 0x230A },
    .{ "rfloor", 0x230B },
    .{ "lang", 0x2329 },
    .{ "rang", 0x232A },
    .{ "loz", 0x25CA },
    .{ "spades", 0x2660 },
    .{ "clubs", 0x2663 },
    .{ "hearts", 0x2665 },
    .{ "diams", 0x2666 },
    .{ "apos", '\'' },
    .{ "NoBreak", 0x2060 }, // From HTML5, and common in real bodies.
});

const testing = std.testing;

const Trace = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    fn add(t: *Trace, comptime format: []const u8, args: anytype) void {
        t.len += (std.fmt.bufPrint(t.buffer[t.len..], format, args) catch unreachable).len;
    }
};

fn expectTrace(input: []const u8, expected: []const u8) !void {
    var p: Parser = .init(input);
    var trace: Trace = .{};
    while (true) {
        switch (try p.next()) {
            .start => |s| trace.add("+{s} ", .{s.name.raw}),
            .end => |n| trace.add("-{s} ", .{n.raw}),
            .text => |t| trace.add("'{s}' ", .{t}),
            .cdata => |t| trace.add("[{s}] ", .{t}),
            .eof => break,
        }
    }
    try testing.expectEqualStrings(expected, trace.buffer[0..trace.len]);
}

test "well-formed document" {
    try expectTrace("<?xml version=\"1.0\"?><a x=\"1\"><b>hi</b><!-- no --><c/></a>", "+a +b 'hi' -b +c -c -a ");
}

test "CDATA is literal" {
    try expectTrace("<a><![CDATA[<b>&amp;]]></a>", "+a [<b>&amp;] -a ");
}

test "missing end tags are supplied" {
    try expectTrace("<a><b>text", "+a +b 'text' -b -a ");
}

test "an end tag closes everything open inside it" {
    try expectTrace("<a><b><c></a><d/>", "+a +b +c -c -b -a +d -d ");
}

test "a stray end tag is dropped" {
    try expectTrace("<a></x></a>", "+a -a ");
}

test "a bare less-than sign is text" {
    try expectTrace("<a>1 < 2</a>", "+a '1 ' '< 2' -a ");
}

test "a greater-than sign inside an attribute does not end the tag" {
    try expectTrace("<a title=\"x>y\"><b/></a>", "+a +b -b -a ");
}

test "an unterminated quote does not swallow the document" {
    try expectTrace("<a x=\"1><b/></a>", "+a +b -b -a ");
}

test "unterminated constructs end cleanly" {
    try expectTrace("<a><!-- never", "+a -a ");
    try expectTrace("<a><![CDATA[never", "+a [never] -a ");
    try expectTrace("<a", "+a -a ");
}

test "a CDATA section missing its final > ends at the next tag" {
    try expectTrace("<a><b><![CDATA[one]]</b><b><![CDATA[two]]</b></a>", "+a +b [one] -b +b [two] -b -a ");
}

test "a real CDATA terminator wins over the fallback" {
    try expectTrace("<a><![CDATA[x[y[0]]</code>]]></a>", "+a [x[y[0]]</code>] -a ");
}

test "DOCTYPE and its internal subset are skipped unread" {
    const bomb =
        \\<!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;">]><a>&lol2;</a>
    ;
    try expectTrace(bomb, "+a '&lol2;' -a ");
}

test "undefined entities are never expanded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("&lol2;", try decodeText(arena.allocator(), "&lol2;"));
}

test "namespaces resolve through scopes" {
    var p: Parser = .init("<r xmlns=\"d\" xmlns:c=\"u\"><c:x/><y xmlns=\"e\"><z/></y><w/></r>");
    const expected = [_][2][]const u8{ .{ "r", "d" }, .{ "x", "u" }, .{ "y", "e" }, .{ "z", "e" }, .{ "w", "d" } };
    var index: usize = 0;
    while (true) {
        const event = try p.next();
        if (event == .eof) break;
        if (event == .start) {
            try testing.expectEqualStrings(expected[index][0], event.start.name.local);
            try testing.expectEqualStrings(expected[index][1], event.start.name.uri);
            index += 1;
        }
    }
    try testing.expectEqual(expected.len, index);
}

test "depth is capped" {
    var input: [(max_depth + 1) * 3]u8 = undefined;
    for (0..max_depth + 1) |i| @memcpy(input[i * 3 ..][0..3], "<a>");
    var p: Parser = .init(&input);
    while (true) {
        const event = p.next() catch |err| {
            try testing.expectEqual(error.TooDeep, err);
            return;
        };
        if (event == .eof) return error.TestUnexpectedResult;
    }
}

test "skipElement returns inner markup" {
    var p: Parser = .init("<a><div><b>x</b> y</div></a><z/>");
    _ = try p.next();
    _ = try p.next();
    try testing.expectEqualStrings("<b>x</b> y", try p.skipElement());
    try testing.expectEqualStrings("a", (try p.next()).end.raw);
    try testing.expectEqualStrings("z", (try p.next()).start.name.raw);
}

test "attributes" {
    var p: Parser = .init("<a x=\"1\" y='2' z=3 flag/>");
    const start = (try p.next()).start;
    try testing.expectEqualStrings("1", start.attribute("x").?);
    try testing.expectEqualStrings("2", start.attribute("y").?);
    try testing.expectEqualStrings("3", start.attribute("z").?);
    try testing.expectEqualStrings("", start.attribute("flag").?);
    try testing.expectEqual(null, start.attribute("w"));
}

test "entities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a&b", try decodeText(a, "a&amp;b"));
    try testing.expectEqualStrings("A\xE2\x82\xAC", try decodeText(a, "&#65;&#x20AC;"));
    try testing.expectEqualStrings("\xC2\xA0", try decodeText(a, "&nbsp;"));
    try testing.expectEqualStrings("\xC3\xAB", try decodeText(a, "&euml;"));
    try testing.expectEqualStrings("a & b", try decodeText(a, "a & b"));
    try testing.expectEqualStrings("\xEF\xBF\xBD", try decodeText(a, "&#xD800;"));
    try testing.expectEqualStrings("&#xFFFFFFFFFF;", try decodeText(a, "&#xFFFFFFFFFF;"));
}
