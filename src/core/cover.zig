/// The blocks `memo wake` prints: a partition of [0, T) into aligned
/// power-of-two blocks, at most `budget` of them, finest near T.
///
/// Detail decays with age, so recent memories stay verbatim and ancient
/// ones collapse. If everything fits, nothing is compressed at all.
const std = @import("std");
const blocks = @import("blocks.zig");
const Block = blocks.Block;

/// Largest cover block size that ever occurs for `t` memories: the root of
/// the tiling is the smallest power of two >= t, so depth is bounded by
/// 64 for u64 counts.
fn rootOf(t: u64) u64 {
    var root: u64 = 1;
    while (root < t) {
        if (root > std.math.maxInt(u64) / 2) {
            // t > 2^63: unreachable for real logs (exabytes of lines).
            return std.math.maxInt(u64);
        }
        root *= 2;
    }
    return root;
}

/// The keep rule, as a float comparison: split the block iff its size
/// exceeds `alpha` times its age. (f64 throughout: both sides are
/// magnitude-stable, and a mis-split is corrected by the 60-step search.)
fn keepSplit(size: u64, age: u64, alpha: f64) bool {
    return @as(f64, @floatFromInt(size)) > alpha * @as(f64, @floatFromInt(age));
}

/// Tiling with the keep rule "a block stays whole iff its size is at most
/// `alpha` times its age" (bigger alpha = coarser = fewer lines). The
/// result is appended to `out` in left-to-right order.
fn coverBuild(gpa: std.mem.Allocator, t: u64, alpha: f64, out: *std.ArrayListUnmanaged(Block)) std.mem.Allocator.Error!void {
    var stack: [65]Block = undefined;
    var top: usize = 0;
    stack[top] = Block{ .lo = 0, .hi = rootOf(t) };
    top += 1;
    while (top > 0) {
        top -= 1;
        const b = stack[top];
        if (b.lo >= t) continue;
        const size = b.hi - b.lo;
        const age = t - b.lo;
        if (size > 1 and (b.hi > t or keepSplit(size, age, alpha))) {
            const mid = (b.lo + b.hi) / 2;
            // Right half first: it is pushed deeper, so the left half (the
            // one rendered first) comes off the stack first.
            stack[top] = Block{ .lo = mid, .hi = b.hi };
            top += 1;
            stack[top] = Block{ .lo = b.lo, .hi = mid };
            top += 1;
        } else {
            try out.append(gpa, b);
        }
    }
}

/// How many blocks `coverBuild` would produce, without the allocation. The
/// 60-step binary search calls this with many alphas, so counting must be
/// O(blocks) in time and O(1) in space.
fn coverCount(t: u64, alpha: f64) u64 {
    var stack: [65]Block = undefined;
    var top: usize = 0;
    stack[top] = Block{ .lo = 0, .hi = rootOf(t) };
    top += 1;
    var n: u64 = 0;
    while (top > 0) {
        top -= 1;
        const b = stack[top];
        if (b.lo >= t) continue;
        const size = b.hi - b.lo;
        const age = t - b.lo;
        if (size > 1 and (b.hi > t or keepSplit(size, age, alpha))) {
            const mid = (b.lo + b.hi) / 2;
            stack[top] = Block{ .lo = mid, .hi = b.hi };
            top += 1;
            stack[top] = Block{ .lo = b.lo, .hi = mid };
            top += 1;
        } else {
            n += 1;
        }
    }
    return n;
}

/// The cover of [0, t) with at most `budget` blocks. The caller owns the
/// returned slice (free it with the same allocator).
pub fn cover(gpa: std.mem.Allocator, t: u64, budget: u64) ![]const Block {
    if (t == 0) return gpa.alloc(Block, 0);
    if (t <= budget) {
        // Everything fits: every memory is its own block, verbatim.
        var verbatim = std.ArrayListUnmanaged(Block).empty;
        defer verbatim.deinit(gpa);
        var i: u64 = 0;
        while (i < t) : (i += 1) {
            try verbatim.append(gpa, Block{ .lo = i, .hi = i + 1 });
        }
        return try verbatim.toOwnedSlice(gpa);
    }
    // Binary search the alpha that fits the budget. Block sizes jump in
    // powers of two, so alpha alone can undershoot; the tail loop below
    // spends what is left on the present, where detail is worth most.
    var lo: f64 = 0.0;
    var hi: f64 = 1.0;
    var step: u6 = 0;
    while (step < 60) : (step += 1) {
        const mid = (lo + hi) / 2;
        if (coverCount(t, mid) > budget) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    var out = std.ArrayListUnmanaged(Block).empty;
    defer out.deinit(gpa);
    try coverBuild(gpa, t, hi, &out);
    while (out.items.len < budget) {
        // Split the LAST block with size > 1: Python's
        // max((i for i, b in enumerate(out) if b[1] - b[0] > 1)) yields
        // indices, so it is the rightmost splittable one. Spending the
        // budget at the right edge keeps detail finest where it matters.
        var idx: ?usize = null;
        for (out.items, 0..) |b, i| {
            if (b.size() > 1) idx = i;
        }
        const i = idx orelse break;
        const b = out.items[i];
        const mid = (b.lo + b.hi) / 2;
        out.items[i] = Block{ .lo = b.lo, .hi = mid };
        try out.insert(gpa, i + 1, Block{ .lo = mid, .hi = b.hi });
    }
    return try out.toOwnedSlice(gpa);
}

test "cover spans, tiles, respects budget" {
    const budget: u64 = 96; // the shipped WAKE_LINES
    var t: u64 = 0;
    while (t < 400) : (t += 1) {
        checkCover(t, budget) catch |err| {
            std.debug.print("T={d}: {s}\n", .{ t, @errorName(err) });
            return err;
        };
    }
    const big = [_]u64{ 1000, 4096, 10000, 65536, 100003 };
    for (big) |tt| {
        try checkCover(tt, budget);
    }
}

fn checkCover(t: u64, budget: u64) !void {
    const c = try cover(std.testing.allocator, t, budget);
    defer std.testing.allocator.free(c);
    if (t == 0) {
        try std.testing.expectEqual(@as(usize, 0), c.len);
        return;
    }
    if (c.len > budget) return error.OverBudget;
    if (c.len == 0) return error.Empty;
    if (c[0].lo != 0) return error.NotFromZero;
    if (c[c.len - 1].hi != t) return error.NotToT;
    for (c, 0..) |b, i| {
        // Size-1 entries are verbatim memories, not tree blocks: power of
        // two and aligned, but not necessarily size >= 2.
        const s = b.size();
        if (s & (s - 1) != 0) return error.NotPowerOfTwo;
        if (b.lo % s != 0) return error.NotAligned;
        if (i > 0 and c[i - 1].hi != b.lo) return error.GapOrOverlap;
        // Coarse in the past, fine in the present: sizes never increase
        // toward T.
        if (i > 0 and b.size() > c[i - 1].size()) return error.NotFinestNearPresent;
    }
}

test "under budget, memory is verbatim" {
    const c = try cover(std.testing.allocator, 300, 320);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqual(@as(usize, 300), c.len);
    var i: u64 = 0;
    while (i < 300) : (i += 1) {
        try std.testing.expectEqual(i, c[i].lo);
        try std.testing.expectEqual(i + 1, c[i].hi);
    }
}

test "every block a cover needs is buildable" {
    // Every block the cover ever names must be one complete() yields: an
    // aligned power-of-two range with hi <= T. The property is structural,
    // so walk every tree shape up to 300 and then sample.
    const big = [_]u64{ 512, 700, 1000, 1023, 1024, 2000, 2999 };
    var all = std.ArrayListUnmanaged(u64).empty; // T values
    defer all.deinit(std.testing.allocator);
    var t: u64 = 1;
    while (t < 300) : (t += 1) try all.append(std.testing.allocator, t);
    for (big) |tt| try all.append(std.testing.allocator, tt);
    for (all.items) |tt| {
        const c = try cover(std.testing.allocator, tt, 96);
        var bad = false;
        for (c) |b| {
            // Only size > 1 entries must be tree blocks; size-1 entries
            // are verbatim memories.
            if (b.size() > 1 and !b.isBlock()) bad = true;
            if (b.hi > tt) bad = true;
        }
        std.testing.allocator.free(c);
        if (bad) return error.CoverBlockNotBuildable;
    }
}
