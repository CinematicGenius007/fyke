//! URL handling written for feeds: resolving relative links, removing tracking
//! parameters so that one article matches across feeds, and deciding which
//! network addresses a fetch may reach.

const std = @import("std");

pub const Parts = struct {
    scheme: []const u8 = "",
    /// Includes any port and user info. Null when the URL has no "//" part.
    authority: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,
};

/// Splits a URL using the pattern from RFC 3986, appendix B.
pub fn split(url: []const u8) Parts {
    var parts: Parts = .{};
    var rest = url;
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        parts.fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        parts.query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        if (i != 0 and isScheme(rest[0..i])) {
            parts.scheme = rest[0..i];
            rest = rest[i + 1 ..];
        }
    }
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        parts.authority = rest[0..end];
        rest = rest[end..];
    }
    parts.path = rest;
    return parts;
}

fn isScheme(text: []const u8) bool {
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

/// True for the only schemes a feed may link to. In particular this refuses
/// "javascript:" and "data:".
pub fn isSafeLink(url: []const u8) bool {
    const scheme = split(url).scheme;
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "mailto");
}

pub fn isHttp(url: []const u8) bool {
    const parts = split(url);
    const is_web = std.ascii.eqlIgnoreCase(parts.scheme, "http") or std.ascii.eqlIgnoreCase(parts.scheme, "https");
    return is_web and parts.authority != null and parts.authority.?.len != 0;
}

/// Resolves `reference` against `base`, per RFC 3986 section 5.
pub fn resolve(arena: std.mem.Allocator, base: []const u8, reference: []const u8) error{OutOfMemory}![]const u8 {
    const ref_trimmed = std.mem.trim(u8, reference, " \t\r\n");
    const ref = split(ref_trimmed);
    if (ref.scheme.len != 0) return ref_trimmed;
    const b = split(base);
    if (b.scheme.len == 0) return ref_trimmed;

    var out: std.ArrayList(u8) = try .initCapacity(arena, base.len + ref_trimmed.len + 2);
    try out.appendSlice(arena, b.scheme);
    try out.append(arena, ':');

    if (ref.authority) |authority| {
        try out.appendSlice(arena, "//");
        try out.appendSlice(arena, authority);
        try appendPath(arena, &out, ref.path);
    } else {
        if (b.authority) |authority| {
            try out.appendSlice(arena, "//");
            try out.appendSlice(arena, authority);
        }
        if (ref.path.len == 0) {
            try appendPath(arena, &out, b.path);
            if (ref.query == null) {
                if (b.query) |query| {
                    try out.append(arena, '?');
                    try out.appendSlice(arena, query);
                }
            }
        } else if (ref.path[0] == '/') {
            try appendPath(arena, &out, ref.path);
        } else {
            const directory_end = if (std.mem.lastIndexOfScalar(u8, b.path, '/')) |i| i + 1 else 0;
            var merged: std.ArrayList(u8) = try .initCapacity(arena, directory_end + ref.path.len + 1);
            if (b.authority != null and directory_end == 0) try merged.append(arena, '/');
            try merged.appendSlice(arena, b.path[0..directory_end]);
            try merged.appendSlice(arena, ref.path);
            try appendPath(arena, &out, merged.items);
        }
    }
    if (ref.query) |query| {
        try out.append(arena, '?');
        try out.appendSlice(arena, query);
    }
    if (ref.fragment) |fragment| {
        try out.append(arena, '#');
        try out.appendSlice(arena, fragment);
    }
    return out.items;
}

/// Appends `path` with its "." and ".." segments removed.
fn appendPath(arena: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) error{OutOfMemory}!void {
    const root = out.items.len;
    var segments = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (segments.next()) |segment| {
        const is_last = segments.peek() == null;
        if (first) {
            first = false;
            if (segment.len == 0) continue; // The empty segment before a leading "/".
        }
        if (std.mem.eql(u8, segment, ".")) {
            if (is_last) try out.append(arena, '/');
        } else if (std.mem.eql(u8, segment, "..")) {
            if (std.mem.lastIndexOfScalar(u8, out.items[root..], '/')) |slash| out.shrinkRetainingCapacity(root + slash);
            if (is_last) try out.append(arena, '/');
        } else {
            try out.append(arena, '/');
            try out.appendSlice(arena, segment);
        }
    }
}

const tracking_params = [_][]const u8{
    "fbclid", "gclid", "dclid",  "msclkid", "mc_cid",  "mc_eid",
    "igshid", "yclid", "_hsenc", "_hsmi",   "mkt_tok", "ref_src",
    "cmpid",  "ocid",  "spm",    "vero_id",
};

fn isTrackingParam(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "utm_")) return true;
    for (tracking_params) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

/// A form of `url` for matching the same article across feeds. It is for
/// comparison only, since some sites do treat these forms as different pages.
pub fn canonical(arena: std.mem.Allocator, url: []const u8) error{OutOfMemory}![]const u8 {
    const parts = split(url);
    const authority = parts.authority orelse return url;
    if (parts.scheme.len == 0) return url;

    var out: std.ArrayList(u8) = try .initCapacity(arena, url.len);
    for (parts.scheme) |c| out.appendAssumeCapacity(std.ascii.toLower(c));
    out.appendSliceAssumeCapacity("://");

    var host = authority;
    if (std.ascii.startsWithIgnoreCase(host, "www.")) host = host[4..];
    if (std.mem.endsWith(u8, host, ":80") and std.ascii.eqlIgnoreCase(parts.scheme, "http")) host = host[0 .. host.len - 3];
    if (std.mem.endsWith(u8, host, ":443") and std.ascii.eqlIgnoreCase(parts.scheme, "https")) host = host[0 .. host.len - 4];
    for (host) |c| out.appendAssumeCapacity(std.ascii.toLower(c));

    const path = if (parts.path.len > 1) std.mem.trimEnd(u8, parts.path, "/") else "";
    out.appendSliceAssumeCapacity(path);

    if (parts.query) |query| {
        var first = true;
        var params = std.mem.splitScalar(u8, query, '&');
        while (params.next()) |param| {
            const name_end = std.mem.indexOfScalar(u8, param, '=') orelse param.len;
            if (param.len == 0 or isTrackingParam(param[0..name_end])) continue;
            out.appendAssumeCapacity(if (first) '?' else '&');
            out.appendSliceAssumeCapacity(param);
            first = false;
        }
    }
    return out.items;
}

/// True if an address is reachable from the public internet. Feeds come from
/// untrusted sources, and a fetch must not become a way to probe this machine or
/// its local network.
pub fn isPublicIp4(a: [4]u8) bool {
    return switch (a[0]) {
        0, 10, 127 => false,
        100 => !(a[1] >= 64 and a[1] < 128), // Carrier-grade NAT.
        169 => a[1] != 254, // Link-local, including cloud metadata services.
        172 => !(a[1] >= 16 and a[1] < 32),
        192 => !((a[1] == 168) or (a[1] == 0 and a[2] == 0) or (a[1] == 0 and a[2] == 2)),
        198 => !((a[1] == 18 or a[1] == 19) or (a[1] == 51 and a[2] == 100)),
        203 => !(a[1] == 0 and a[2] == 113),
        else => a[0] < 224, // 224 and above are multicast and reserved.
    };
}

pub fn isPublicIp6(a: [16]u8) bool {
    const all_zero_prefix = std.mem.allEqual(u8, a[0..10], 0);
    if (all_zero_prefix and a[10] == 0xFF and a[11] == 0xFF) return isPublicIp4(a[12..16].*); // ::ffff:0:0/96
    if (std.mem.eql(u8, a[0..12], &[_]u8{ 0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0 })) return isPublicIp4(a[12..16].*); // NAT64
    if (std.mem.allEqual(u8, a[0..12], 0)) return false; // ::, ::1 and IPv4-compatible.
    if (a[0] & 0xFE == 0xFC) return false; // Unique local.
    if (a[0] == 0xFE and a[1] & 0xC0 == 0x80) return false; // Link-local.
    if (a[0] == 0xFF) return false; // Multicast.
    if (a[0] == 0x20 and a[1] == 0x01 and a[2] == 0x0D and a[3] == 0xB8) return false; // Documentation.
    if (a[0] == 0x20 and a[1] == 0x02) return isPublicIp4(a[2..6].*); // 6to4 carries an IPv4 address.
    if (a[0] == 0x20 and a[1] == 0x01 and a[2] == 0 and a[3] == 0) return false; // Teredo tunnels.
    return true;
}

const testing = std.testing;

fn expectResolve(expected: []const u8, base: []const u8, reference: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try resolve(arena.allocator(), base, reference));
}

test "RFC 3986 section 5.4 examples" {
    const base = "http://a/b/c/d;p?q";
    try expectResolve("g:h", base, "g:h");
    try expectResolve("http://a/b/c/g", base, "g");
    try expectResolve("http://a/b/c/g", base, "./g");
    try expectResolve("http://a/b/c/g/", base, "g/");
    try expectResolve("http://a/g", base, "/g");
    try expectResolve("http://g", base, "//g");
    try expectResolve("http://a/b/c/d;p?y", base, "?y");
    try expectResolve("http://a/b/c/g?y", base, "g?y");
    try expectResolve("http://a/b/c/d;p?q#s", base, "#s");
    try expectResolve("http://a/b/c/g#s", base, "g#s");
    try expectResolve("http://a/b/c/;x", base, ";x");
    try expectResolve("http://a/b/c/d;p?q", base, "");
    try expectResolve("http://a/b/c/", base, ".");
    try expectResolve("http://a/b/", base, "..");
    try expectResolve("http://a/b/g", base, "../g");
    try expectResolve("http://a/", base, "../..");
    try expectResolve("http://a/g", base, "../../g");
    try expectResolve("http://a/g", base, "../../../g");
    try expectResolve("http://a/g", base, "/./g");
    try expectResolve("http://a/g", base, "/../g");
}

test "a base with no path" {
    try expectResolve("https://example.com/a", "https://example.com", "a");
}

test "link safety" {
    try testing.expect(isSafeLink("https://example.com"));
    try testing.expect(isSafeLink("mailto:a@example.com"));
    try testing.expect(!isSafeLink("javascript:alert(1)"));
    try testing.expect(!isSafeLink("JaVaScRiPt:alert(1)"));
    try testing.expect(!isSafeLink("data:text/html,x"));
    try testing.expect(!isSafeLink("vbscript:x"));
    try testing.expect(!isSafeLink("relative/path"));
}

test "canonical form matches the same article" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = "https://example.com/post?id=1";
    try testing.expectEqualStrings(expected, try canonical(a, "HTTPS://WWW.Example.com:443/post/?utm_source=x&id=1&fbclid=y#frag"));
    try testing.expectEqualStrings(expected, try canonical(a, expected));
    try testing.expectEqualStrings("https://example.com", try canonical(a, "https://example.com/"));
}

test "canonical form of a URL with no scheme" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("//host/a", try canonical(arena.allocator(), "//host/a"));
}

test "private addresses are not public" {
    const private = [_][4]u8{
        .{ 127, 0, 0, 1 },    .{ 10, 1, 2, 3 },        .{ 192, 168, 1, 1 }, .{ 172, 16, 0, 1 },
        .{ 172, 31, 255, 1 }, .{ 169, 254, 169, 254 }, .{ 0, 0, 0, 0 },     .{ 100, 64, 0, 1 },
        .{ 224, 0, 0, 1 },    .{ 255, 255, 255, 255 }, .{ 198, 18, 0, 1 },
    };
    for (private) |address| try testing.expect(!isPublicIp4(address));
    const public = [_][4]u8{ .{ 8, 8, 8, 8 }, .{ 1, 1, 1, 1 }, .{ 172, 15, 0, 1 }, .{ 172, 32, 0, 1 }, .{ 100, 63, 0, 1 }, .{ 192, 169, 0, 1 } };
    for (public) |address| try testing.expect(isPublicIp4(address));
}

test "IPv6 cannot be used to reach private addresses" {
    const loopback: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const mapped_private: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1 };
    const mapped_public: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 8, 8, 8, 8 };
    const nat64_private: [16]u8 = .{ 0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 0, 1 };
    const link_local: [16]u8 = .{ 0xFE, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const unique_local: [16]u8 = .{ 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const public: [16]u8 = .{ 0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expect(!isPublicIp6(loopback));
    try testing.expect(!isPublicIp6(mapped_private));
    try testing.expect(isPublicIp6(mapped_public));
    try testing.expect(!isPublicIp6(nat64_private));
    try testing.expect(!isPublicIp6(link_local));
    try testing.expect(!isPublicIp6(unique_local));
    try testing.expect(isPublicIp6(public));
}

test "IPv6 tunnels are judged by the address they carry" {
    const private_6to4 = [16]u8{ 0x20, 0x02, 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const public_6to4 = [16]u8{ 0x20, 0x02, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const teredo = [16]u8{ 0x20, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expect(!isPublicIp6(private_6to4));
    try testing.expect(isPublicIp6(public_6to4));
    try testing.expect(!isPublicIp6(teredo));
}
