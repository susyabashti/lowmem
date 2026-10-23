/// One memory's text: the validation `note`, `nap` and `import` share.
///
/// A memory is one line of at most ENTRY_CHARS bytes: no embedded newline,
/// no leading or trailing whitespace, and not empty. The validator
/// trims first, exactly as the reference tool does, and reports which rule
/// broke; the CLI turns the error into the message the user reads.
const std = @import("std");

pub const Error = error{
    /// The text is empty or all whitespace after trimming.
    Empty,
    /// The text carries a line break somewhere inside.
    MultiLine,
    /// The trimmed text is over the entry ceiling, in bytes.
    TooLong,
};

/// The trimmed text, or which rule it breaks. The result borrows from
/// `text`.
pub fn validate(text: []const u8, entry_chars: u32) Error![]const u8 {
    const t = trim(text);
    if (t.len == 0) return Error.Empty;
    if (hasLineBreak(t)) return Error.MultiLine;
    if (t.len > entry_chars) return Error.TooLong;
    return t;
}

/// The number of lines a rejected multi-line text carries: the message
/// says "N lines", and the reference tool counts the breaks plus one.
pub fn lineCount(text: []const u8) u32 {
    var n: u32 = 1;
    for (trim(text)) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The trimmed text (ASCII whitespace at both ends; a memory is one line,
/// so the edges are the only place whitespace matters).
pub fn trim(text: []const u8) []const u8 {
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi and ws(text[lo])) lo += 1;
    while (hi > lo and ws(text[hi - 1])) hi -= 1;
    return text[lo..hi];
}

fn ws(c: u8) bool {
    // Zig 0.17 has no '\v' or '\f' character escapes: 0x0B is the
    // vertical tab, 0x0C the form feed.
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0B or c == 0x0C or c == '\r';
}

fn hasLineBreak(s: []const u8) bool {
    return std.mem.findAny(u8, s, "\n\r") != null;
}

test "validate: the rules in order" {
    const r1: Error![]const u8 = validate("  ", 280);
    try std.testing.expectError(Error.Empty, r1);
    const r2: Error![]const u8 = validate("\t\n", 280);
    try std.testing.expectError(Error.Empty, r2);
    const r3: Error![]const u8 = validate("a\nb", 280);
    try std.testing.expectError(Error.MultiLine, r3);
    const r4: Error![]const u8 = validate("a\rb", 280);
    try std.testing.expectError(Error.MultiLine, r4);
}

test "validate: the ceiling is in bytes" {
    const ok = try validate("x", 1);
    try std.testing.expectEqualStrings("x", ok);
    const short = validate("x", 0);
    try std.testing.expectError(Error.TooLong, short);
    // Two-byte characters cost two: 150 of them are 300 bytes.
    var long: std.ArrayListUnmanaged(u8) = .empty;
    defer long.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < 150) : (i += 1) {
        try long.appendSlice(std.testing.allocator, &[_]u8{ 0xC3, 0xA3 }); // ã
    }
    const over = validate(long.items, 280);
    try std.testing.expectError(Error.TooLong, over);
    const at = try validate(long.items, 300);
    try std.testing.expectEqual(@as(usize, 300), at.len);
}

test "validate: trims the edges, keeps the middle" {
    const t = try validate("  hello world \t", 280);
    try std.testing.expectEqualStrings("hello world", t);
}

test "lineCount" {
    try std.testing.expectEqual(@as(u32, 1), lineCount("one line"));
    try std.testing.expectEqual(@as(u32, 3), lineCount("a\nb\nc"));
    try std.testing.expectEqual(@as(u32, 2), lineCount("a\r\nb"));
}
