//! Parses feed dates into unix milliseconds, UTC.
//!
//! Feeds claim RFC 822 or RFC 3339 and frequently deliver neither, so this reads
//! tokens instead of matching a fixed layout: any order of day, month name, year
//! and clock is accepted. A date that makes no sense is null, never a guess.

const std = @import("std");

pub fn parse(input: []const u8) ?i64 {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len < 8 or text.len > 64) return null;
    if (std.ascii.isDigit(text[0]) and text.len >= 10 and text[4] == '-' and text[7] == '-') return parseIso(text);
    return parseWords(text);
}

/// Formats unix milliseconds as RFC 3339 in UTC, such as 2026-11-06T09:30:00Z.
/// Models read this reliably, which they do not do for raw timestamps.
pub fn formatIso(buffer: *[20]u8, millis: i64) []const u8 {
    const seconds = @divFloor(millis, 1000);
    const days = @divFloor(seconds, 86400);
    const second_of_day: u64 = @intCast(@mod(seconds, 86400));
    const date = civilFromDays(days);
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        date.year,
        date.month,
        date.day,
        second_of_day / 3600,
        second_of_day / 60 % 60,
        second_of_day % 60,
    }) catch unreachable;
}

/// The inverse of `daysFromCivil`.
fn civilFromDays(days_since_epoch: i64) struct { year: u64, month: u64, day: u64 } {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const day_of_era = z - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1;
    const month = if (shifted_month < 10) shifted_month + 3 else shifted_month - 9;
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    // `formatIso` has room for four digits.
    return .{ .year = @intCast(std.math.clamp(year, 0, 9999)), .month = @intCast(month), .day = @intCast(day) };
}

const min_year = 1900;

const Clock = struct { hour: i64 = 0, minute: i64 = 0, second: i64 = 0, millis: i64 = 0 };

/// 2026-11-06, 2026-11-06T09:30:00Z, 2026-11-06 09:30:00.123+05:30
fn parseIso(text: []const u8) ?i64 {
    const year = number(text[0..4]) orelse return null;
    const month = number(text[5..7]) orelse return null;
    const day = number(text[8..10]) orelse return null;
    if (text.len == 10) return toMillis(year, month, day, .{}, 0);

    if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return null;
    var i: usize = 11;
    const clock = parseClock(text, &i) orelse return null;
    while (i < text.len and text[i] == ' ') i += 1;
    const offset = if (i == text.len) 0 else parseZone(text[i..]) orelse return null;
    return toMillis(year, month, day, clock, offset);
}

/// Reads hh:mm[:ss[.fraction]] at text[i.*].
fn parseClock(text: []const u8, i: *usize) ?Clock {
    var clock: Clock = .{};
    clock.hour = digits(text, i, 2) orelse return null;
    if (i.* >= text.len or text[i.*] != ':') return null;
    i.* += 1;
    clock.minute = digits(text, i, 2) orelse return null;
    if (i.* < text.len and text[i.*] == ':') {
        i.* += 1;
        clock.second = digits(text, i, 2) orelse return null;
    }
    if (i.* < text.len and text[i.*] == '.') {
        i.* += 1;
        var scale: i64 = 100;
        while (i.* < text.len and std.ascii.isDigit(text[i.*])) : (i.* += 1) {
            clock.millis += (text[i.*] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    return clock;
}

/// Reads one or up to `max` digits.
fn digits(text: []const u8, i: *usize, max: usize) ?i64 {
    const start = i.*;
    while (i.* < text.len and i.* - start < max and std.ascii.isDigit(text[i.*])) i.* += 1;
    return number(text[start..i.*]);
}

fn number(text: []const u8) ?i64 {
    if (text.len == 0 or text.len > 9 or !std.ascii.isDigit(text[0])) return null;
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// Fri, 06 Nov 2026 09:30:00 GMT, and variations such as
/// "6 Nov 2026 9:30 PST", "Nov 6, 2026 09:30:00", "Friday, 6 November 2026".
fn parseWords(text: []const u8) ?i64 {
    var day: ?i64 = null;
    var month: ?i64 = null;
    var year: ?i64 = null;
    var clock: ?Clock = null;
    var offset: i64 = 0;

    var tokens = std.mem.tokenizeAny(u8, text, " ,\t");
    while (tokens.next()) |token| {
        // JavaScript's Date.toString() ends in "(Coordinated Universal Time)".
        if (token[0] == '(') break;
        if (std.mem.indexOfScalar(u8, token, ':') != null and clock == null) {
            var i: usize = 0;
            clock = parseClock(token, &i) orelse return null;
            if (i < token.len) offset = parseZone(token[i..]) orelse return null;
        } else if (number(token)) |value| {
            if (token.len >= 3) {
                if (year != null) return null;
                year = value;
            } else if (day == null) {
                day = value;
            } else if (year == null) {
                year = if (value < 70) 2000 + value else 1900 + value;
            } else return null;
        } else if (monthNumber(token)) |value| {
            month = value;
        } else if (dayName(token)) {
            continue;
        } else if (parseZone(token)) |value| {
            offset = value;
        } else if (ordinal(token)) |value| {
            day = value;
        } else return null;
    }
    return toMillis(year orelse return null, month orelse return null, day orelse return null, clock orelse .{}, offset);
}

/// "6th" as a day number.
fn ordinal(token: []const u8) ?i64 {
    if (token.len < 3) return null;
    const suffix = token[token.len - 2 ..];
    const names = [_][]const u8{ "st", "nd", "rd", "th" };
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(suffix, name)) return number(token[0 .. token.len - 2]);
    }
    return null;
}

fn monthNumber(token: []const u8) ?i64 {
    if (token.len < 3) return null;
    const trimmed = std.mem.trimEnd(u8, token, ".");
    // English, German, French and Spanish, the languages seen in real feeds.
    const names = [_]struct { []const u8, i64 }{
        .{ "january", 1 },   .{ "february", 2 }, .{ "march", 3 },      .{ "april", 4 },
        .{ "may", 5 },       .{ "june", 6 },     .{ "july", 7 },       .{ "august", 8 },
        .{ "september", 9 }, .{ "october", 10 }, .{ "november", 11 },  .{ "december", 12 },
        .{ "januar", 1 },    .{ "februar", 2 },  .{ "maerz", 3 },      .{ "mai", 5 },
        .{ "juni", 6 },      .{ "juli", 7 },     .{ "oktober", 10 },   .{ "dezember", 12 },
        .{ "janvier", 1 },   .{ "mars", 3 },     .{ "avril", 4 },      .{ "juin", 6 },
        .{ "juillet", 7 },   .{ "enero", 1 },    .{ "febrero", 2 },    .{ "marzo", 3 },
        .{ "abril", 4 },     .{ "mayo", 5 },     .{ "junio", 6 },      .{ "julio", 7 },
        .{ "agosto", 8 },    .{ "octubre", 10 }, .{ "diciembre", 12 },
    };
    for (names) |entry| {
        if (trimmed.len == 3 and entry[0].len >= 3 and std.ascii.eqlIgnoreCase(trimmed, entry[0][0..3])) return entry[1];
        if (std.ascii.eqlIgnoreCase(trimmed, entry[0])) return entry[1];
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "sept")) return 9;
    return null;
}

fn dayName(token: []const u8) bool {
    if (token.len < 3) return false;
    const names = [_][]const u8{ "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" };
    const trimmed = std.mem.trimEnd(u8, token, ".");
    for (names) |name| {
        if (trimmed.len == 3 and std.ascii.eqlIgnoreCase(trimmed, name[0..3])) return true;
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}

/// Returns the offset from UTC in minutes.
fn parseZone(zone_in: []const u8) ?i64 {
    if (zone_in.len == 0) return null;
    // "GMT+0000" and "UTC+01:00" are as common as a bare offset.
    const has_offset = zone_in.len > 3 and (zone_in[3] == '+' or zone_in[3] == '-');
    const named_base = has_offset and (std.ascii.startsWithIgnoreCase(zone_in, "gmt") or std.ascii.startsWithIgnoreCase(zone_in, "utc"));
    const zone = if (named_base) zone_in[3..] else zone_in;
    if (zone[0] == '+' or zone[0] == '-') {
        const sign: i64 = if (zone[0] == '-') -1 else 1;
        const rest = zone[1..];
        var hours: i64 = 0;
        var minutes: i64 = 0;
        if (rest.len == 5 and rest[2] == ':') {
            hours = number(rest[0..2]) orelse return null;
            minutes = number(rest[3..5]) orelse return null;
        } else if (rest.len == 4) {
            hours = number(rest[0..2]) orelse return null;
            minutes = number(rest[2..4]) orelse return null;
        } else if (rest.len == 2) {
            hours = number(rest) orelse return null;
        } else return null;
        if (hours > 14 or minutes > 59) return null;
        return sign * (hours * 60 + minutes);
    }
    const names = [_]struct { []const u8, i64 }{
        .{ "z", 0 },      .{ "ut", 0 },     .{ "utc", 0 },    .{ "gmt", 0 },
        .{ "est", -300 }, .{ "edt", -240 }, .{ "cst", -360 }, .{ "cdt", -300 },
        .{ "mst", -420 }, .{ "mdt", -360 }, .{ "pst", -480 }, .{ "pdt", -420 },
        .{ "bst", 60 },   .{ "cet", 60 },   .{ "cest", 120 }, .{ "ist", 330 },
        .{ "aest", 600 }, .{ "aedt", 660 }, .{ "jst", 540 },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(zone, entry[0])) return entry[1];
    }
    return null;
}

fn toMillis(year: i64, month: i64, day: i64, clock: Clock, offset_minutes: i64) ?i64 {
    // Years before this are placeholders, such as .NET's empty date of 0001-01-01,
    // and would pin an entry to the bottom of every timeline.
    if (year < min_year or year > 9999 or month < 1 or month > 12 or day < 1) return null;
    if (day > daysInMonth(year, month)) return null;
    if (clock.hour > 24 or clock.minute > 59 or clock.second > 60) return null;
    const days = daysFromCivil(year, month, day);
    const seconds = days * 86400 + clock.hour * 3600 + clock.minute * 60 + clock.second - offset_minutes * 60;
    return seconds * 1000 + clock.millis;
}

fn daysInMonth(year: i64, month: i64) i64 {
    const lengths = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    return if (month == 2 and leap) 29 else lengths[@intCast(month - 1)];
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar. Treating March as
/// the first month of the year puts the leap day last, which removes every
/// special case. See Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms".
fn daysFromCivil(year_in: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) year_in - 1 else year_in;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

const testing = std.testing;

fn expectDate(expected: ?i64, input: []const u8) !void {
    try testing.expectEqual(expected, parse(input));
}

// 2026-11-06T09:30:00Z, confirmed with `date -u -r 1793957400`.
const reference: i64 = 1793957400000;

test "RFC 3339" {
    try expectDate(reference, "2026-11-06T09:30:00Z");
    try expectDate(reference, "2026-11-06T15:00:00+05:30");
    try expectDate(reference, "2026-11-06T04:30:00-05:00");
    try expectDate(reference + 123, "2026-11-06T09:30:00.123Z");
    try expectDate(reference, "2026-11-06 09:30:00");
    try expectDate(reference, "2026-11-06T09:30Z");
}

test "date only" {
    try expectDate(reference - (9 * 3600 + 30 * 60) * 1000, "2026-11-06");
}

test "RFC 822" {
    try expectDate(reference, "Fri, 06 Nov 2026 09:30:00 GMT");
    try expectDate(reference, "Fri, 06 Nov 2026 09:30:00 +0000");
    try expectDate(reference, "Fri, 6 Nov 2026 01:30 PST");
    try expectDate(reference, "6 Nov 2026 04:30:00 EST");
}

test "variations seen in real feeds" {
    try expectDate(reference, "Friday, 6 November 2026 09:30:00 GMT");
    try expectDate(reference, "Nov 6, 2026 09:30:00");
    try expectDate(reference, "Fri, 06 Nov 26 09:30:00 GMT");
    try expectDate(reference, "6th November 2026 09:30");
}

test "the epoch and leap days" {
    try expectDate(0, "1970-01-01T00:00:00Z");
    try expectDate(951782400000, "2000-02-29T00:00:00Z");
}

test "JavaScript date strings" {
    try expectDate(reference, "Fri Nov 06 2026 09:30:00 GMT+0000 (Coordinated Universal Time)");
    try expectDate(reference, "Fri Nov 06 2026 15:00:00 GMT+0530 (India Standard Time)");
}

test "placeholder dates are null" {
    try expectDate(null, "Mon, 01 Jan 0001 00:00:00 +0000");
    try expectDate(null, "0001-01-01T00:00:00Z");
}

test "formatting is the inverse of parsing" {
    var buffer: [20]u8 = undefined;
    try testing.expectEqualStrings("2026-11-06T09:30:00Z", formatIso(&buffer, reference));
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatIso(&buffer, 0));
    try testing.expectEqualStrings("2000-02-29T23:59:59Z", formatIso(&buffer, 951868799000));
    var day: i64 = -20000;
    while (day < 40000) : (day += 37) {
        const at = day * 86400 * 1000 + 12345000;
        try testing.expectEqual(at, parse(formatIso(&buffer, at)).?);
    }
}

test "nonsense is null" {
    try expectDate(null, "");
    try expectDate(null, "not a date at all");
    try expectDate(null, "2026-13-45T00:00:00Z");
    try expectDate(null, "2026-02-30T00:00:00Z");
    try expectDate(null, "Fri, 32 Nov 2026 09:30:00 GMT");
    try expectDate(null, "2025-02-29");
}
