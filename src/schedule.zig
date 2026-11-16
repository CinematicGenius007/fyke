//! Local civil-time schedules with an injected conversion from epoch minutes.
const std = @import("std");
pub const Kind = enum { manual, daily, weekdays, weekly };
pub const Schedule = struct { kind: Kind = .manual, time: []const u8 = "09:00", days: []const i64 = &.{} };
pub const Civil = struct { day: i64, weekday: u8, minute: u16 };
pub fn parse(a: std.mem.Allocator, text: []const u8) !Schedule {
    const s = std.json.parseFromSliceLeaky(Schedule, a, text, .{}) catch return error.InvalidSchedule;
    if (s.time.len != 5 or s.time[2] != ':') return error.InvalidSchedule;
    for ([_]usize{ 0, 1, 3, 4 }) |i| if (!std.ascii.isDigit(s.time[i])) return error.InvalidSchedule;
    const hour = std.fmt.parseInt(u8, s.time[0..2], 10) catch return error.InvalidSchedule;
    const minute = std.fmt.parseInt(u8, s.time[3..], 10) catch return error.InvalidSchedule;
    if (hour > 23 or minute > 59 or s.days.len > 7) return error.InvalidSchedule;
    for (s.days) |d| if (d < 0 or d > 6) return error.InvalidSchedule;
    if (s.kind == .weekly and s.days.len == 0) return error.InvalidSchedule;
    return s;
}
fn allowed(s: Schedule, weekday: u8) bool {
    return switch (s.kind) {
        .manual => false,
        .daily => true,
        .weekdays => weekday >= 1 and weekday <= 5,
        .weekly => std.mem.indexOfScalar(i64, s.days, weekday) != null,
    };
}
/// The first valid local minute at or after the requested time fires once per
/// civil day. A spring gap advances to the next minute; a repeated hour fires once.
pub fn next(s: Schedule, after: i64, context: anytype, convert: anytype) ?i64 {
    if (s.kind == .manual) return null;
    const target = (std.fmt.parseInt(u16, s.time[0..2], 10) catch return null) * 60 + (std.fmt.parseInt(u16, s.time[3..], 10) catch return null);
    var epoch = @divFloor(after, 60000) * 60000 + 60000;
    const initial = convert(context, after);
    var previous = initial;
    for (0..9 * 25 * 60) |_| {
        const c = convert(context, epoch);
        const crossed = c.minute >= target and (c.day != previous.day or previous.minute < target);
        if (allowed(s, c.weekday) and crossed and (c.day != initial.day or initial.minute < target)) return epoch;
        previous = c;
        epoch += 60000;
    }
    return null;
}
test "missed days coalesce, gaps advance, repeated times fire once" {
    const Convert = struct {
        fn civil(_: void, ms: i64) Civil {
            const m = @divFloor(ms, 60000);
            const shifted = if (m >= 120 and m < 1440) m + 60 else if (m >= 1440 and m < 1560) m else if (m >= 1560) m - 60 else m;
            return .{ .day = @divFloor(shifted, 1440), .weekday = @intCast(@mod(@divFloor(shifted, 1440) + 1, 7)), .minute = @intCast(@mod(shifted, 1440)) };
        }
    };
    const daily = Schedule{ .kind = .daily, .time = "02:30" };
    try std.testing.expectEqual(@as(?i64, 120 * 60000), next(daily, 0, {}, Convert.civil));
    try std.testing.expectEqual(@as(?i64, 1650 * 60000), next(daily, 1440 * 60000, {}, Convert.civil));
    try std.testing.expectEqual(@as(?i64, null), next(.{}, 0, {}, Convert.civil));
}

test "autumn repeated hour and missed weekday schedules" {
    const Fold = struct {
        fn civil(_: void, ms: i64) Civil {
            const epoch = @divFloor(ms, 60000);
            const minute = if (epoch >= 120) epoch - 60 else epoch;
            return .{ .day = @divFloor(minute, 1440), .weekday = @intCast(@mod(@divFloor(minute, 1440) + 1, 7)), .minute = @intCast(@mod(minute, 1440)) };
        }
    };
    const daily = Schedule{ .kind = .daily, .time = "01:30" };
    try std.testing.expectEqual(@as(?i64, 90 * 60000), next(daily, 0, {}, Fold.civil));
    try std.testing.expectEqual(@as(?i64, 1590 * 60000), next(daily, 90 * 60000, {}, Fold.civil));
    const Utc = struct {
        fn civil(_: void, ms: i64) Civil {
            const minute = @divFloor(ms, 60000);
            const day = @divFloor(minute, 1440);
            return .{ .day = day, .weekday = @intCast(@mod(day + 1, 7)), .minute = @intCast(@mod(minute, 1440)) };
        }
    };
    const weekdays = Schedule{ .kind = .weekdays, .time = "09:00" };
    try std.testing.expectEqual(@as(?i64, (7 * 1440 + 540) * 60000), next(weekdays, (4 * 1440 + 541) * 60000, {}, Utc.civil));
    try std.testing.expectEqual(@as(?i64, (14 * 1440 + 540) * 60000), next(weekdays, (13 * 1440 + 600) * 60000, {}, Utc.civil));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "{\"kind\":\"hourly\"}", "{\"kind\":\"weekly\",\"days\":[]}", "{\"time\":\"24:00\"}", "{\"days\":[-1]}", "{\"days\":[7]}" }) |bad| try std.testing.expectError(error.InvalidSchedule, parse(arena.allocator(), bad));
}
