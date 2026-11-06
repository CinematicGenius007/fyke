//! Reads robots.txt, per RFC 9309. Feeds are published to be fetched, but article
//! pages are not, so the daemon asks first before fetching one.

const std = @import("std");

const Rule = struct { path: []const u8, allow: bool };

/// Returns whether `agent` may fetch `path`. The most specific group applies, and
/// within it the longest matching rule, with Allow winning a tie.
pub fn isAllowed(text: []const u8, agent: []const u8, path: []const u8) bool {
    var best_length: ?usize = null;
    var best_allow = true;

    // Two passes: rules for this agent replace the rules for "*" if any exist.
    const named = hasGroup(text, agent);
    var in_group = false;
    var reading_agents = false;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw_line| {
        const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
        const line = std.mem.trim(u8, raw_line[0..comment], " \t");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
            if (!reading_agents) in_group = false;
            reading_agents = true;
            const matches = if (named) std.ascii.eqlIgnoreCase(value, agent) else std.mem.eql(u8, value, "*");
            in_group = in_group or matches;
            continue;
        }
        reading_agents = false;
        if (!in_group) continue;

        const allow = std.ascii.eqlIgnoreCase(key, "allow");
        if (!allow and !std.ascii.eqlIgnoreCase(key, "disallow")) continue;
        if (value.len == 0 or !matches_path(value, path)) continue;
        if (best_length == null or value.len > best_length.? or (value.len == best_length.? and allow)) {
            best_length = value.len;
            best_allow = allow;
        }
    }
    return best_allow;
}

fn hasGroup(text: []const u8, agent: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "user-agent")) continue;
        const comment = std.mem.indexOfScalar(u8, line, '#') orelse line.len;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[colon + 1 .. comment], " \t"), agent)) return true;
    }
    return false;
}

/// Matches a rule, in which "*" is any run of characters and a final "$" anchors
/// the end. Backtracking is limited to the latest "*", which keeps this linear
/// in practice even for a hostile rule.
fn matches_path(pattern_in: []const u8, path: []const u8) bool {
    const anchored = pattern_in.len != 0 and pattern_in[pattern_in.len - 1] == '$';
    const pattern = if (anchored) pattern_in[0 .. pattern_in.len - 1] else pattern_in;

    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var star_s: usize = 0;
    while (true) {
        if (p == pattern.len) {
            if (!anchored or s == path.len) return true;
        } else if (pattern[p] == '*') {
            star = p;
            star_s = s;
            p += 1;
            continue;
        } else if (s < path.len and pattern[p] == path[s]) {
            p += 1;
            s += 1;
            continue;
        }
        const restart = star orelse return false;
        if (star_s >= path.len) return false;
        star_s += 1;
        s = star_s;
        p = restart + 1;
    }
}

const testing = std.testing;

test "no rules allow everything" {
    try testing.expect(isAllowed("", "rss_", "/a"));
    try testing.expect(isAllowed("# nothing\n", "rss_", "/a"));
}

test "disallow and allow" {
    const text = "User-agent: *\nDisallow: /private\nAllow: /private/open\n";
    try testing.expect(!isAllowed(text, "rss_", "/private/x"));
    try testing.expect(isAllowed(text, "rss_", "/private/open/x"));
    try testing.expect(isAllowed(text, "rss_", "/public"));
}

test "a named group replaces the wildcard group" {
    const text = "User-agent: *\nDisallow: /\n\nUser-agent: rss_\nDisallow: /secret\n";
    try testing.expect(isAllowed(text, "rss_", "/a"));
    try testing.expect(!isAllowed(text, "rss_", "/secret"));
    try testing.expect(!isAllowed(text, "other", "/a"));
}

test "several agents may share a group" {
    const text = "User-agent: a\nUser-agent: *\nDisallow: /x\n";
    try testing.expect(!isAllowed(text, "rss_", "/x"));
}

test "an empty disallow means nothing is blocked" {
    try testing.expect(isAllowed("User-agent: *\nDisallow:\n", "rss_", "/a"));
}

test "wildcards and anchors" {
    const text = "User-agent: *\nDisallow: /*.pdf$\nDisallow: /a*/b\n";
    try testing.expect(!isAllowed(text, "rss_", "/x/y.pdf"));
    try testing.expect(isAllowed(text, "rss_", "/x/y.pdf.html"));
    try testing.expect(!isAllowed(text, "rss_", "/axx/b/c"));
    try testing.expect(isAllowed(text, "rss_", "/axx/c"));
}

test "comments, odd case and CRLF" {
    try testing.expect(!isAllowed("USER-AGENT: * # all\r\nDISALLOW: /x # no\r\n", "rss_", "/x"));
}
