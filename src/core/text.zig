/// Shared text helpers: the pluralization every message uses.
///
/// `plural` is the exact rule of the reference tool: 1 keeps the word, a
/// word ending in y takes ie, a word ending in s/h/x takes es, everything
/// else takes s. n=0 pluralizes too ("0 memories").
const std = @import("std");

/// The plural form of `word` for a count of `n` ("1 memory", "2 memories",
/// "0 summaries"). The caller owns the result (free it with `gpa`).
pub fn plural(gpa: std.mem.Allocator, n: u64, word: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(gpa);
    if (n == 1) {
        try out.appendSlice(gpa, "1 ");
        try out.appendSlice(gpa, word);
    } else {
        var digits: [24]u8 = undefined;
        const d = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
        try out.appendSlice(gpa, d);
        try out.append(gpa, ' ');
        const last = word[word.len - 1];
        if (last == 'y') {
            try out.appendSlice(gpa, word[0 .. word.len - 1]);
            try out.appendSlice(gpa, "ie");
        } else if (last == 's' or last == 'h' or last == 'x') {
            try out.appendSlice(gpa, word);
            try out.append(gpa, 'e');
        } else {
            try out.appendSlice(gpa, word);
        }
        try out.append(gpa, 's');
    }
    return try out.toOwnedSlice(gpa);
}

test "plural: the reference rule" {
    try check("1 memory", 1, "memory");
    try check("2 memories", 2, "memory");
    try check("0 memories", 0, "memory");
    try check("1 part", 1, "part");
    try check("3 parts", 3, "part");
    try check("1 match", 1, "match");
    try check("2 matches", 2, "match");
    try check("1 compression", 1, "compression");
    try check("16 compressions", 16, "compression");
    try check("1 summary", 1, "summary");
    try check("5 summaries", 5, "summary");
    try check("18446744073709551615 memories", std.math.maxInt(u64), "memory");
}

fn check(want: []const u8, n: u64, word: []const u8) !void {
    const got = try plural(std.testing.allocator, n, word);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}
