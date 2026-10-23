/// Naps: which blocks are pending, and the prompt that pays the next one.
///
/// A block is pending when it is buildable from the log and its level file
/// has not reached it. Each level holds a dense prefix, so the pending work
/// is a count per level — one stat per level, never a scan. The prompt is
/// the document an agent copies and answers; it is generated here, in core,
/// because it is assembled from the store. The CLI only prints it.
const std = @import("std");
const blocks = @import("blocks.zig");
const store = @import("store.zig");

/// Blocks of at most this many memories compress from the raw log; bigger
/// blocks compress from their two halves' summaries.
pub const RAW_MAX: u64 = 16;

pub const Error = store.Store.Error || std.mem.Allocator.Error;

/// The outcome of nextNap.
pub const Result = union(enum) {
    /// Nothing is pending: the store is settled as of T.
    none: void,
    /// The prompt for the next pending block. `text` is gpa-allocated;
    /// the caller frees it with the allocator it passed.
    prompt: struct {
        block: blocks.Block,
        text: []u8,
    },
    /// A half of the next block is missing or blank: a corrupt write the
    /// prompt cannot name. The one exit is `forget <lo>-<hi-1>` for the
    /// named half.
    blankHalf: blocks.Block,
    /// A half of the next block is not a summary at all (not even valid
    /// UTF-8): a corrupt write. The one exit is the same `forget`.
    corrupt: blocks.Block,
};

/// The first pending block as of `t`, smallest first, or null when the
/// store is settled.
pub fn nextPending(s: *const store.Store, gpa: std.mem.Allocator, io: std.Io, t: u64) Error!?blocks.Block {
    var size: u64 = 2;
    while (size <= t) {
        const have = try s.levelCount(gpa, io, size);
        const need = t / size;
        if (have < need) {
            return blocks.Block{ .lo = have * size, .hi = (have + 1) * size };
        }
        size = blocks.nextLevel(size, t) orelse break;
    }
    return null;
}

/// How many blocks pending() would list, without listing them. A level can
/// hold more blocks than `t` needs — t is a snapshot, memories keep
/// arriving while an agent reads — so each level is clamped at zero.
pub fn pendingCount(s: *const store.Store, gpa: std.mem.Allocator, io: std.Io, t: u64) Error!u64 {
    var n: u64 = 0;
    var size: u64 = 2;
    while (size <= t) {
        const have = try s.levelCount(gpa, io, size);
        const need = t / size;
        if (have < need) n += need - have;
        size = blocks.nextLevel(size, t) orelse break;
    }
    return n;
}

/// The prompt for the next pending block as of `t`, or its failure. `me`
/// is the binary's path, embedded in the Run line; `entry_chars` is the
/// ceiling the prompt quotes.
pub fn nextNap(
    s: *const store.Store,
    gpa: std.mem.Allocator,
    io: std.Io,
    t: u64,
    me: []const u8,
    entry_chars: u32,
) Error!Result {
    const b = try nextPending(s, gpa, io, t) orelse return .{ .none = {} };
    const left = (try pendingCount(s, gpa, io, t)) - 1;
    return promptFor(s, gpa, io, b, left, me, entry_chars);
}

fn promptFor(
    s: *const store.Store,
    gpa: std.mem.Allocator,
    io: std.Io,
    b: blocks.Block,
    left: u64,
    me: []const u8,
    entry_chars: u32,
) Error!Result {
    // The body: the raw memories for a small block, the two half-summaries
    // for a big one.
    var body = std.ArrayListUnmanaged(u8).empty;
    defer body.deinit(gpa);
    if (b.size() <= RAW_MAX) {
        const mems = try s.slice(gpa, io, b.lo, b.hi);
        defer mems.deinit();
        for (mems.mems, 0..) |m, i| {
            if (i > 0) try body.append(gpa, '\n');
            try body.print(gpa, "  #{d} {s} {s}", .{ m.id, &m.date, m.text });
        }
    } else {
        const halves = b.halves();
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            const h = halves[i];
            if (i > 0) try body.append(gpa, '\n');
            const sum = s.summaryGet(gpa, io, h.lo, h.hi) catch |e| {
                if (e != store.Store.Error.CorruptRecord) return e;
                return .{ .corrupt = h };
            };
            switch (sum) {
                .text => |t| {
                    defer gpa.free(t);
                    try body.print(gpa, "  #{d}-{d} {s}", .{ h.lo, h.hi - 1, t });
                },
                // pending() lists a block only after its halves settled, so
                // a missing or blank half is a corrupt write, not pending
                // work: name it and refuse.
                .missing, .blank => return .{ .blankHalf = h },
            }
        }
    }

    // The tail: absent for the last compression (a single blank line then
    // separates body and Run line), present on its own line otherwise.
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(gpa);
    try out.print(
        gpa,
        "Compress memories #{d}-{d} into one line of at most {d} bytes.\n" ++
            "Keep what has lasting effect, drop what does not. Invent nothing.\n\n" ++
            "{s}\n",
        .{ b.lo, b.hi - 1, entry_chars, body.items },
    );
    if (left == 0) {
        try out.append(gpa, '\n');
    } else {
        try out.append(gpa, '\n');
        if (left == 1) {
            try out.appendSlice(gpa, "1 compression remains after this one.");
        } else {
            try out.print(gpa, "{d} compressions remain after this one.", .{left});
        }
        try out.append(gpa, '\n');
    }
    try out.print(gpa, "Run: {s} nap {d}-{d} \"<your line>\"", .{ me, b.lo, b.hi - 1 });
    return .{ .prompt = .{ .block = b, .text = try out.toOwnedSlice(gpa) } };
}

// Test helpers, at file scope: a 0.17 nested function cannot see block
// scope variables, so io is passed explicitly.

var temp_counter: u64 = 0;

fn tempStore(gpa: std.mem.Allocator, io: std.Io) !struct { path: []u8, store: store.Store } {
    temp_counter += 1;
    var buf: [96]u8 = undefined;
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const path_s = std.fmt.bufPrint(&buf, "/tmp/lowmem-nap-test-{d}-{d}", .{ ns, temp_counter }) catch unreachable;
    const path = try gpa.dupe(u8, path_s);
    errdefer gpa.free(path);
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return .{ .path = path, .store = try store.Store.open(io, path) };
}

fn cleanup(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    gpa.free(path);
}

fn appendN(s: *const store.Store, gpa: std.mem.Allocator, io: std.Io, n: u64) !void {
    var items = std.ArrayListUnmanaged(store.Store.NewMemory).empty;
    defer items.deinit(gpa);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        var d: [10]u8 = undefined;
        @memcpy(&d, "2020-01-01");
        try items.append(gpa, .{ .date = d, .text = "memory" });
    }
    _ = try s.append(gpa, io, items.items);
}

fn putSummary(s: *const store.Store, gpa: std.mem.Allocator, io: std.Io, lo: u64, hi: u64, text: []const u8) !void {
    const r = try s.summaryPut(gpa, io, lo, hi, text);
    if (r != .appended) return error.NotNext;
}

test "settled store: nothing pending" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t.path);
    defer t.store.close(io);
    _ = try nextPending(&t.store, testing.allocator, io, 0);
    try testing.expectEqual(@as(u64, 0), try pendingCount(&t.store, testing.allocator, io, 0));
    const r = try nextNap(&t.store, testing.allocator, io, 0, "/me", 280);
    if (r != .none) return error.WantNone;
}

test "pending lists blocks smallest first, clamped per level" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t.path);
    defer t.store.close(io);
    try appendN(&t.store, testing.allocator, io, 5);
    // 5 memories: [0,2) [2,4) [4,6)? no — size 2 needs k<5/2=2 → [0,2),
    // [2,4); size 4 needs k<5/4=1 → [0,4). The next pending is [0,2).
    const n = try nextPending(&t.store, testing.allocator, io, 5);
    if (n == null) return error.WantBlock;
    try testing.expectEqual(@as(u64, 0), n.?.lo);
    try testing.expectEqual(@as(u64, 2), n.?.hi);
    try testing.expectEqual(@as(u64, 3), try pendingCount(&t.store, testing.allocator, io, 5));
    // Settle [0,2): next is [2,4).
    try putSummary(&t.store, testing.allocator, io, 0, 2, "first pair");
    const n2 = try nextPending(&t.store, testing.allocator, io, 5);
    try testing.expectEqual(@as(u64, 2), n2.?.lo);
    // A level may hold more blocks than T needs: build [4,6) anyway, and T=5
    // must not call it missing-and-pending again... it is already built, so
    // pending only lists [2,4) and [0,4).
    try putSummary(&t.store, testing.allocator, io, 2, 4, "second pair");
    try putSummary(&t.store, testing.allocator, io, 0, 4, "the foursome");
    try putSummary(&t.store, testing.allocator, io, 4, 6, "ahead pair");
    try testing.expectEqual(@as(u64, 0), try pendingCount(&t.store, testing.allocator, io, 5));
}

test "the prompt for a small block quotes the raw memories" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t.path);
    defer t.store.close(io);
    try appendN(&t.store, testing.allocator, io, 2);
    const r = try nextNap(&t.store, testing.allocator, io, 2, "/me", 280);
    if (r != .prompt) return error.WantPrompt;
    const got = r.prompt.text;
    defer testing.allocator.free(got);
    const want =
        \\Compress memories #0-1 into one line of at most 280 bytes.
        \\Keep what has lasting effect, drop what does not. Invent nothing.
        \\
        \\  #0 2020-01-01 memory
        \\  #1 2020-01-01 memory
        \\
        \\Run: /me nap 0-1 "<your line>"
    ;
    try testing.expectEqualStrings(want, got);
}

test "the prompt tail counts what remains" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t.path);
    defer t.store.close(io);
    try appendN(&t.store, testing.allocator, io, 5);
    const r = try nextNap(&t.store, testing.allocator, io, 5, "/me", 280);
    if (r != .prompt) return error.WantPrompt;
    const got = r.prompt.text;
    defer testing.allocator.free(got);
    // Three pending: this one plus [2,4) and [0,4) → "2 compressions remain".
    const tail = std.mem.findScalarPos(u8, got, 0, '\n') orelse return error.Malformed;
    _ = tail;
    if (std.mem.indexOf(u8, got, "2 compressions remain after this one.\n") == null) return error.WantTail;
    if (std.mem.indexOf(u8, got, "Run: /me nap 0-1 \"<your line>\"") == null) return error.WantRun;
}

test "the prompt for a big block quotes the half summaries" {
    const testing = std.testing;
    const io = testing.io;
    // A block quotes its halves only when it is bigger than RAW_MAX; the
    // smallest such block is 32. Settle every level below it, so [0,32)
    // is the next pending.
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t.path);
    defer t.store.close(io);
    try appendN(&t.store, testing.allocator, io, 32);
    var size: u64 = 2;
    while (size <= 8) : (size *= 2) {
        var k: u64 = 0;
        while (k * size < 32) : (k += 1) {
            try putSummary(&t.store, testing.allocator, io, k * size, (k + 1) * size, "done");
        }
    }
    try putSummary(&t.store, testing.allocator, io, 0, 16, "pair zero");
    try putSummary(&t.store, testing.allocator, io, 16, 32, "pair two");
    const r = try nextNap(&t.store, testing.allocator, io, 32, "/me", 280);
    if (r != .prompt) return error.WantPrompt;
    const got = r.prompt.text;
    defer testing.allocator.free(got);
    const want =
        \\Compress memories #0-31 into one line of at most 280 bytes.
        \\Keep what has lasting effect, drop what does not. Invent nothing.
        \\
        \\  #0-15 pair zero
        \\  #16-31 pair two
        \\
        \\Run: /me nap 0-31 "<your line>"
    ;
    try testing.expectEqualStrings(want, got);
}

test "a blank half of the next big block is named" {
    const testing = std.testing;
    const io = testing.io;
    // The corrupt case is only reachable for blocks bigger than RAW_MAX:
    // a small block compresses from the raw log and never reads its halves.
    // With T=32, settle everything through level 16, then blank the
    // first size-16 block: [0,32) becomes pending, and its body needs
    // the blank half.
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t.path);
    defer t.store.close(io);
    try appendN(&t.store, testing.allocator, io, 32);
    var size: u64 = 2;
    while (size <= 16) : (size *= 2) {
        var k: u64 = 0;
        while (k * size < 32) : (k += 1) {
            try putSummary(&t.store, testing.allocator, io, k * size, (k + 1) * size, "done");
        }
    }
    // Blank the first size-16 half in place (a corrupt write): level 16
    // still holds two records, so the next pending is [0,32), and its body
    // needs the blank half.
    const l16 = try testing.allocator.print("{s}/TREE/16", .{t.path});
    defer testing.allocator.free(l16);
    {
        const f = try std.Io.Dir.cwd().openFile(io, l16, .{ .mode = .write_only });
        defer std.Io.File.close(f, io);
        try std.Io.File.writePositionalAll(f, io, "\n", 0);
    }
    const r = try nextNap(&t.store, testing.allocator, io, 32, "/me", 280);
    if (r != .blankHalf) return error.WantBlankHalf;
    try testing.expectEqual(@as(u64, 0), r.blankHalf.lo);
    try testing.expectEqual(@as(u64, 16), r.blankHalf.hi);
}
