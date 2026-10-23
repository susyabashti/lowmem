/// Import parsing: a bootstrap file of dated memories, one per line.
///
/// Each line is `YYYY-MM-DD <text>`; dates must be real calendar days and
/// must not precede the last existing memory (or the previous imported
/// line). Blank lines are skipped but keep their line number. Parsing is
/// all-or-nothing: the first failing line stops the whole import, and the
/// result names the line so the CLI can point at it.
const std = @import("std");
const date = @import("date.zig");
const entry = @import("entry.zig");

/// One accepted line. `text` borrows from the line it was parsed from;
/// the caller keeps those alive until the append is done.
pub const Item = struct {
    date: [10]u8,
    text: []const u8,
};

/// Where the import stopped, with enough of the line for the CLI to
/// message it. `text`/`date` borrow from the input.
pub const Result = union(enum) {
    /// Every line in order. The items array is gpa-allocated (an empty
    /// one is a constant: do not free it); the texts borrow from the
    /// input lines.
    ok: []Item,
    /// Not shaped `YYYY-MM-DD <text>`.
    badShape: struct {
        line: u32,
        text: []const u8,
    },
    /// Shaped, but not a real calendar day.
    notRealDate: struct {
        line: u32,
        date: [10]u8,
    },
    /// Before the previous memory; `last` is that date.
    precedes: struct {
        line: u32,
        date: [10]u8,
        last: [10]u8,
    },
    /// The text is empty or over the entry ceiling; `bytes` is its
    /// trimmed length.
    tooLong: struct {
        line: u32,
        bytes: u32,
    },
};

/// Parse `lines` (already split from the file, newlines removed) against
/// `last`, the date of the last existing memory — `0000-00-00` when the
/// log is empty. Lines are the file's lines, so their 1-based numbers
/// match what the user sees.
pub fn parse(
    gpa: std.mem.Allocator,
    lines: []const []const u8,
    entry_chars: u32,
    last: [10]u8,
) std.mem.Allocator.Error!Result {
    var items = std.ArrayListUnmanaged(Item).empty;
    defer items.deinit(gpa);
    var last_date = last; // 0.17 parameters are const: track the date locally
    var no: u32 = 0;
    for (lines) |raw| {
        no += 1;
        const line = raw;
        if (entry.trim(line).len == 0) continue;
        const sp = std.mem.findScalarPos(u8, line, 0, ' ') orelse line.len;
        const d = line[0..sp];
        if (!date.isDateShape(d)) {
            return .{ .badShape = .{ .line = no, .text = line } };
        }
        if (!date.isRealDate(d)) {
            var date10: [10]u8 = undefined;
            @memcpy(&date10, d);
            return .{ .notRealDate = .{ .line = no, .date = date10 } };
        }
        if (std.mem.order(u8, d, &last_date) == .lt) {
            var date10: [10]u8 = undefined;
            @memcpy(&date10, d);
            return .{ .precedes = .{ .line = no, .date = date10, .last = last_date } };
        }
        const rest = if (sp + 1 <= line.len) line[sp + 1 ..] else &.{};
        const t = entry.trim(rest);
        if (t.len == 0 or t.len > entry_chars) {
            return .{ .tooLong = .{ .line = no, .bytes = @intCast(t.len) } };
        }
        var date10: [10]u8 = undefined;
        @memcpy(&date10, d);
        try items.append(gpa, .{ .date = date10, .text = t });
        @memcpy(&last_date, d);
    }
    return .{ .ok = try items.toOwnedSlice(gpa) };
}

fn makeDate(s: []const u8) [10]u8 {
    var d: [10]u8 = undefined;
    @memcpy(&d, s);
    return d;
}

test "parse: the happy path, blanks kept out, numbers kept in" {
    const lines = &[_][]const u8{
        "2020-01-01 first day",
        "",
        "   ",
        "2020-01-02 second",
        "2020-01-02 same day, later line",
    };
    const r = try parse(std.testing.allocator, lines, 280, makeDate("0000-00-00"));
    switch (r) {
        .ok => |items| {
            defer if (items.len > 0) std.testing.allocator.free(items);
            try std.testing.expectEqual(@as(usize, 3), items.len);
            try std.testing.expectEqualStrings("first day", items[0].text);
            try std.testing.expectEqualStrings("second", items[1].text);
            try std.testing.expectEqualStrings("same day, later line", items[2].text);
            try std.testing.expect(std.mem.eql(u8, &items[2].date, "2020-01-02"));
        },
        else => return error.WantOk,
    }
}

test "parse: the first failure wins, numbered like the file" {
    const gpa = std.testing.allocator;
    const last = makeDate("0000-00-00");

    const bad_shape = try parse(gpa, &[_][]const u8{ "2020-01-01 ok", "no date here" }, 280, last);
    switch (bad_shape) {
        .badShape => |e| {
            try std.testing.expectEqual(@as(u32, 2), e.line);
            try std.testing.expectEqualStrings("no date here", e.text);
        },
        else => return error.WantBadShape,
    }

    const bad_date = try parse(gpa, &[_][]const u8{"2023-02-29 no leap"}, 280, last);
    switch (bad_date) {
        .notRealDate => |e| {
            try std.testing.expectEqual(@as(u32, 1), e.line);
            try std.testing.expect(std.mem.eql(u8, &e.date, "2023-02-29"));
        },
        else => return error.WantNotRealDate,
    }

    const before = makeDate("2020-06-01");
    const order = try parse(gpa, &[_][]const u8{"2020-05-31 too early"}, 280, before);
    switch (order) {
        .precedes => |e| {
            try std.testing.expectEqual(@as(u32, 1), e.line);
            try std.testing.expect(std.mem.eql(u8, &e.last, "2020-06-01"));
        },
        else => return error.WantPrecedes,
    }

    const long = try parse(gpa, &[_][]const u8{ "2020-01-01 ok", "2020-01-02   " }, 280, last);
    switch (long) {
        .tooLong => |e| {
            try std.testing.expectEqual(@as(u32, 2), e.line);
            try std.testing.expectEqual(@as(u32, 0), e.bytes);
        },
        else => return error.WantTooLong,
    }
}

test "parse: the ceiling is in bytes and trimming is real" {
    var line = std.ArrayListUnmanaged(u8).empty;
    defer line.deinit(std.testing.allocator);
    try line.appendSlice(std.testing.allocator, "2020-01-01 ");
    var i: u32 = 0;
    while (i < 280) : (i += 1) try line.append(std.testing.allocator, 'x');
    const at = [_][]const u8{line.items};
    const r = try parse(std.testing.allocator, &at, 280, makeDate("0000-00-00"));
    if (r == .ok) {
        defer std.testing.allocator.free(r.ok);
    } else {
        return error.WantOk;
    }
    const r2 = try parse(std.testing.allocator, &at, 279, makeDate("0000-00-00"));
    if (r2 != .tooLong) return error.WantTooLong;
}
