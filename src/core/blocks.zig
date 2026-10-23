/// Blocks: aligned power-of-two ranges of memories.
///
/// A block [lo, hi) is the compression of its two halves; the blocks form
/// a binary merge tree over the log. Memory i is 0-based and sequential, so
/// a block's identity is its range: nothing else.
const std = @import("std");

pub const Block = struct {
    lo: u64,
    hi: u64,

    pub fn size(self: Block) u64 {
        return self.hi - self.lo;
    }

    /// The two halves, oldest first. Valid only for a real block (size >= 2,
    /// so the halves are non-empty).
    pub fn halves(self: Block) [2]Block {
        const mid = (self.lo + self.hi) / 2;
        return .{
            .{ .lo = self.lo, .hi = mid },
            .{ .lo = mid, .hi = self.hi },
        };
    }

    /// A real block: aligned, power of two, at least two memories. Without
    /// the shape check, `4-5` and `5-6` would name the same record.
    pub fn isBlock(self: Block) bool {
        const n = self.hi - self.lo;
        if (n < 2) return false;
        if (n & (n - 1) != 0) return false;
        return self.lo % n == 0;
    }
};

pub const IdError = error{
    /// Not `<digits>-<digits>` at all.
    NotId,
    /// Digits, but not an aligned power-of-two range.
    NotBlock,
};

/// Parse a block id as wake and the nap prompts print it: inclusive at both
/// ends (`0-1` names the block of memories 0 and 1), returned half-open.
///
/// Ranges that would need more than 2^64 memories are rejected as not
/// blocks; a real log cannot hold them (the file would be exabytes).
pub fn parseId(s: []const u8) IdError!Block {
    var lo: u64 = 0;
    var hi_incl: u64 = 0;
    if (!splitId(s, &lo, &hi_incl)) return IdError.NotId;
    // A backwards or empty range has no block: n = hi - lo < 2 there.
    if (hi_incl < lo) return IdError.NotBlock;
    // hi_incl + 1 is the exclusive end; a value that big is not a block.
    if (hi_incl == std.math.maxInt(u64)) return IdError.NotBlock;
    const b = Block{ .lo = lo, .hi = hi_incl + 1 };
    if (!b.isBlock()) return IdError.NotBlock;
    return b;
}

fn splitId(s: []const u8, lo: *u64, hi_incl: *u64) bool {
    const dash = std.mem.findScalar(u8, s, '-') orelse return false;
    const left = s[0..dash];
    const right = s[dash + 1 ..];
    if (!digitsToU64(left, lo)) return false;
    if (!digitsToU64(right, hi_incl)) return false;
    return true;
}

/// All-ASCII-digit, overflow-checked. Leading zeros are allowed and parse
/// like Python's int() (`007` is 7).
fn digitsToU64(s: []const u8, out: *u64) bool {
    if (s.len == 0) return false;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
        const d: u64 = c - '0';
        const max: u64 = std.math.maxInt(u64);
        if (v > (max - d) / 10) return false;
        v = v * 10 + d;
    }
    out.* = v;
    return true;
}

/// How many blocks are buildable from `t` memories: for each size 2, 4, ...
/// up to the largest power of two <= t, t/size blocks. This is the oracle
/// `pending()` is written against: it follows the definition, never the
/// store's level lengths.
pub fn completeCount(t: u64) u64 {
    var n: u64 = 0;
    var size: u64 = 2;
    while (size <= t) {
        n += t / size;
        size = nextLevel(size, t) orelse break;
    }
    return n;
}

/// The next tree level, or null when `size` is the last level for `t`
/// (doubling would exceed t, or would overflow u64).
pub fn nextLevel(size: u64, t: u64) ?u64 {
    if (size > t / 2) return null;
    return size * 2;
}

test "block shape" {
    try std.testing.expect(isBlock(0, 2));
    try std.testing.expect(isBlock(2, 4));
    try std.testing.expect(isBlock(16, 32));
    try std.testing.expect(!isBlock(0, 1)); // too small
    try std.testing.expect(!isBlock(1, 3)); // unaligned
    try std.testing.expect(!isBlock(0, 3)); // not a power of two
}

fn isBlock(lo: u64, hi: u64) bool {
    return (Block{ .lo = lo, .hi = hi }).isBlock();
}

test "parseId" {
    _ = try std.testing.expectError(IdError.NotId, parseId("abc"));
    _ = try std.testing.expectError(IdError.NotId, parseId("1-2-3"));
    _ = try std.testing.expectError(IdError.NotId, parseId("-1"));
    _ = try std.testing.expectError(IdError.NotId, parseId("1-"));
    // `5-6` is not a block: [5,7) is unaligned.
    _ = try std.testing.expectError(IdError.NotBlock, parseId("5-6"));
    _ = try std.testing.expectError(IdError.NotBlock, parseId("1-2"));
    _ = try std.testing.expectError(IdError.NotBlock, parseId("9-3")); // backwards
    _ = try std.testing.expectError(IdError.NotBlock, parseId("3-9")); // size 7
    const z = try parseId("16-31");
    try std.testing.expectEqual(@as(u64, 16), z.lo);
    try std.testing.expectEqual(@as(u64, 32), z.hi);
    // `0-1` is the first block: memories 0 and 1.
    const l = try parseId("0-1");
    try std.testing.expectEqual(@as(u64, 0), l.lo);
    try std.testing.expectEqual(@as(u64, 2), l.hi);
    // leading zeros parse like Python's int()
    const lz = try parseId("0016-0031");
    try std.testing.expectEqual(@as(u64, 16), lz.lo);
    _ = try std.testing.expectError(IdError.NotBlock, parseId("18446744073709551615-18446744073709551615"));
}

test "completeCount" {
    // 2 memories: one block of size 2.
    try std.testing.expectEqual(@as(u64, 1), completeCount(2));
    // 4 memories: [0,2) [2,4) at size 2, [0,4) at size 4.
    try std.testing.expectEqual(@as(u64, 3), completeCount(4));
    // 5 memories: 2 at size 2, 1 at size 4.
    try std.testing.expectEqual(@as(u64, 3), completeCount(5));
    try std.testing.expectEqual(@as(u64, 0), completeCount(0));
    try std.testing.expectEqual(@as(u64, 0), completeCount(1));
}

test "work per appended memory is bounded" {
    // The property the reference suite checks to 2000: one new memory can
    // create at most 16 pending compressions.
    var worst: u64 = 0;
    var prev: u64 = 0;
    var t: u64 = 1;
    while (t < 2000) : (t += 1) {
        const cur = completeCount(t);
        if (cur > prev) worst = @max(worst, cur - prev);
        prev = cur;
    }
    try std.testing.expect(worst <= 16);
}
