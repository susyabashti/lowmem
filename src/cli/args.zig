/// The numeric argument helpers: digit tests, and the decimal strings the
/// tool prints back verbatim.
///
/// The tool never parses beyond u64 — but the reference tool's `int` is
/// unbounded, and a digit string that does not fit in u64 is still a number
/// the tool must PRINT (a `wake 1 999999999999999999999` is answered with
/// the T the user typed). The normalized form (leading zeros stripped) is
/// exactly what the reference tool prints for an all-digits argument.
const std = @import("std");

/// True when `s` is one or more ASCII digits.
pub fn digits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Strip leading zeros; `"0"` when the value is zero. Borrows from `s`.
pub fn normalize(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len - 1 and s[i] == '0') i += 1;
    return s[i..];
}

/// The value when a digit string fits in u64, else null.
pub fn toU64(s: []const u8) ?u64 {
    var v: u64 = 0;
    for (s) |c| {
        const d: u64 = c - '0';
        if (v > (std.math.maxInt(u64) - d) / 10) return null;
        v = v * 10 + d;
    }
    return v;
}

test "digits" {
    try std.testing.expect(digits("0"));
    try std.testing.expect(digits("123"));
    try std.testing.expect(!digits(""));
    try std.testing.expect(!digits("1a"));
    try std.testing.expect(!digits("-1"));
    try std.testing.expect(!digits("1 2"));
}

test "normalize: leading zeros only, zero stays one digit" {
    try std.testing.expectEqualStrings("0", normalize("0"));
    try std.testing.expectEqualStrings("0", normalize("000"));
    try std.testing.expectEqualStrings("10", normalize("010"));
    try std.testing.expectEqualStrings("123", normalize("123"));
    try std.testing.expectEqualStrings("1", normalize("00000000000000000001"));
}

test "toU64" {
    try std.testing.expectEqual(@as(?u64, 0), toU64("0"));
    try std.testing.expectEqual(@as(?u64, 42), toU64("42"));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), toU64("18446744073709551615"));
    try std.testing.expectEqual(@as(?u64, null), toU64("18446744073709551616"));
}
