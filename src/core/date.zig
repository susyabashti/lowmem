/// Dates: today's local date (for `note`) and calendar validation
/// (for `import`). The date string is `YYYY-MM-DD` everywhere, which
/// orders lexically the way it orders chronologically.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// `localtime_r` failed; it only does so for out-of-range times,
    /// which "now" never is.
    Time,
};

// `struct tm` is not one layout. On every platform we run, its fields
// are `c_int` (plus a `c_long` offset and a pointer at the end), but
// Apple orders `tm_mon`/`tm_year` right after `tm_mday`, before
// `tm_wday`/`tm_yday`, while glibc/musl/BSD use the POSIX order.
const TmApple = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*c]const u8,
};

const TmPosix = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*c]const u8,
};

const Tm = if (builtin.os.tag.isDarwin()) TmApple else TmPosix;

extern "c" fn localtime_r(time: *const std.c.time_t, result: *Tm) ?*Tm;

/// Today's local date, `YYYY-MM-DD` — the equivalent of Python's
/// `datetime.date.today().isoformat()`.
pub fn today(io: std.Io) Error![10]u8 {
    const secs: std.c.time_t = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // struct tm is at most 56 bytes on the platforms we run; 64 leaves
    // headroom for either layout.
    var buf: [64]u8 align(8) = undefined;
    const tm = localtime_r(&secs, @ptrCast(&buf)) orelse return Error.Time;
    const raw_year: i32 = tm.tm_year + 1900;
    if (raw_year < 1 or raw_year > 9999) return Error.Time;
    const year: u32 = @intCast(raw_year);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    var out: [10]u8 = undefined;
    out[0] = digit(year / 1000);
    out[1] = digit((year / 100) % 10);
    out[2] = digit((year / 10) % 10);
    out[3] = digit(year % 10);
    out[4] = '-';
    out[5] = digit(month / 10);
    out[6] = digit(month % 10);
    out[7] = '-';
    out[8] = digit(day / 10);
    out[9] = digit(day % 10);
    return out;
}

fn digit(d: u32) u8 {
    return '0' + @as(u8, @intCast(d));
}

/// The import line shape: four digits, dash, two digits, dash, two
/// digits. ASCII digits only; Python's `\d` is Unicode, and a Unicode
/// digit is not a date (documented difference).
pub fn isDateShape(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s) |c| {
        if (c != '-' and (c < '0' or c > '9')) return false;
    }
    return true;
}

/// A shaped date that is a real calendar day: month 1..12, day within
/// the month, leap years included (Python's `strptime` does this too).
pub fn isRealDate(s: []const u8) bool {
    if (!isDateShape(s)) return false;
    const year: u32 = @as(u32, s[0] - '0') * 1000 + @as(u32, s[1] - '0') * 100 + @as(u32, s[2] - '0') * 10 + (s[3] - '0');
    const month: u32 = @as(u32, s[5] - '0') * 10 + (s[6] - '0');
    const day: u32 = @as(u32, s[8] - '0') * 10 + (s[9] - '0');
    if (year < 1 or month < 1 or month > 12) return false;
    return day >= 1 and day <= daysInMonth(year, month);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(year)) 29 else 28,
    };
}

fn isLeap(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

test "isDateShape" {
    try std.testing.expect(isDateShape("2020-01-01"));
    try std.testing.expect(!isDateShape("2020-1-1"));
    try std.testing.expect(!isDateShape("2020-01-011"));
    try std.testing.expect(!isDateShape("2020/01/01"));
    try std.testing.expect(!isDateShape("abcd-ef-gh"));
    try std.testing.expect(!isDateShape(""));
    try std.testing.expect(!isDateShape("2020-01-01\n"));
}

test "isRealDate: calendar days" {
    try std.testing.expect(isRealDate("2024-02-29")); // leap
    try std.testing.expect(!isRealDate("2023-02-29"));
    try std.testing.expect(isRealDate("2000-02-29")); // century leap
    try std.testing.expect(!isRealDate("2100-02-29")); // century, not leap
    try std.testing.expect(!isRealDate("2023-13-01"));
    try std.testing.expect(!isRealDate("2023-00-10"));
    try std.testing.expect(!isRealDate("2023-01-00"));
    try std.testing.expect(!isRealDate("0000-01-01")); // year 0 is not a year
    try std.testing.expect(isRealDate("0001-01-01"));
    try std.testing.expect(isRealDate("9999-12-31"));
    try std.testing.expect(!isRealDate("2027-99-99"));
    try std.testing.expect(!isRealDate("2020-01-1"));
}

test "today: shaped and real" {
    const io = std.testing.io;
    const d = try today(io);
    try std.testing.expect(isDateShape(&d));
    try std.testing.expect(isRealDate(&d));
    const year: u32 = @as(u32, d[0] - '0') * 1000 + @as(u32, d[1] - '0') * 100 + @as(u32, d[2] - '0') * 10 + (d[3] - '0');
    try std.testing.expect(year >= 1970 and year <= 2200);
}
