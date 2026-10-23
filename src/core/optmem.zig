/// The OptMem store format (the reference tool), read and written for
/// migration: `import-optmem` reads a source store into this one,
/// `export-optmem` writes this one out.
///
///   LOG.txt    "#<id> YYYY-MM-DD <text>" + spaces + "\n"  — 320 bytes/record
///   TREE/<s>   "<summary>" + spaces + "\n"                — 288 bytes/record
///
/// Position IS identity: memory i sits at i*320, block k of level s at
/// k*288, a dense prefix per level. A torn trailing record — a crash in
/// the reference tool — is not a memory: reading skips it the way the
/// reference's repair truncates it. A blank or undecodable summary record
/// stops the prefix it is in; later blocks rest on a hole and are simply
/// not carried (the next nap recomputes them, the log is never touched).
const std = @import("std");
const blocks = @import("blocks.zig");
const date = @import("date.zig");
const store = @import("store.zig");

const mem = std.mem;

pub const LOG_REC: u64 = 320;
pub const TREE_REC: u64 = 288;
/// A record's payload: the text before the padding and the newline.
pub const LOG_PAYLOAD: u64 = 319;
pub const TREE_PAYLOAD: u64 = 287;

/// Filesystem and allocation failures, mapped from the store's set.
pub const Error = store.Store.Error;

/// One OptMem memory, ready for a LowMem append. `text` is gpa-allocated;
/// the caller owns it.
pub const Memory = struct {
    date: [10]u8,
    text: []const u8,
};

/// The outcome of readLog: every complete record, or the record that broke
/// the format (and why). On anything but `ok`, no memories are returned.
pub const LogRead = union(enum) {
    /// Every complete record parsed. The caller owns the slice and each
    /// text (free them with the allocator it passed).
    ok: []Memory,
    /// The record named by id is not "#<id> YYYY-MM-DD <text>" at all.
    corrupt: u64,
    /// The record named by id carries a date before the one before it.
    nonChronological: u64,
};

/// Read the whole LOG.txt of an OptMem store. The directory must be open;
/// a missing LOG.txt is `NotFound`. A torn trailing record is not a
/// memory and is skipped.
pub fn readLog(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator) Error!LogRead {
    const f = dir.openFile(io, "LOG.txt", .{ .mode = .read_only }) catch |e| return store.Store.mapFs(e);
    defer std.Io.File.close(f, io);
    const size = std.Io.File.length(f, io) catch |e| return store.Store.mapFs(e);
    const n: u64 = size / LOG_REC; // a torn tail is not a record
    var out = std.ArrayListUnmanaged(Memory).empty;
    var buf: [LOG_REC]u8 = undefined;
    var prev_date: [10]u8 = undefined;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const got = std.Io.File.readPositionalAll(f, io, &buf, i * LOG_REC) catch {
            return abort(gpa, &out, .{ .corrupt = i });
        };
        if (got != LOG_REC) return abort(gpa, &out, .{ .corrupt = i });
        if (buf[LOG_PAYLOAD] != '\n') return abort(gpa, &out, .{ .corrupt = i });
        const line = rtrim(buf[0..LOG_PAYLOAD]);
        // "#<id> YYYY-MM-DD <text>": the id, a space, a shaped date, a
        // space, and the text (which may be empty).
        if (line.len < 2 or line[0] != '#') return abort(gpa, &out, .{ .corrupt = i });
        const id_end = mem.findScalarPos(u8, line[1..], 0, ' ') orelse return abort(gpa, &out, .{ .corrupt = i });
        const id = parseDigits(line[1 .. 1 + id_end]) orelse return abort(gpa, &out, .{ .corrupt = i });
        if (id != i) return abort(gpa, &out, .{ .corrupt = i }); // position is identity
        const rest = line[1 + id_end + 1 ..];
        if (rest.len < 11 or rest[10] != ' ') return abort(gpa, &out, .{ .corrupt = i });
        if (!date.isDateShape(rest[0..10])) return abort(gpa, &out, .{ .corrupt = i });
        if (i > 0 and mem.order(u8, rest[0..10], &prev_date) == .lt) return abort(gpa, &out, .{ .nonChronological = i });
        if (!std.unicode.utf8ValidateSlice(rest[11..])) return abort(gpa, &out, .{ .corrupt = i });
        const text = gpa.dupe(u8, rest[11..]) catch {
            return abort(gpa, &out, .{ .corrupt = i });
        };
        var d: [10]u8 = undefined;
        @memcpy(&d, rest[0..10]);
        out.append(gpa, .{ .date = d, .text = text }) catch {
            gpa.free(text);
            return abort(gpa, &out, .{ .corrupt = i });
        };
        @memcpy(&prev_date, rest[0..10]);
    }
    const slice = out.toOwnedSlice(gpa) catch {
        for (out.items) |m| gpa.free(m.text);
        out.deinit(gpa);
        return error.OutOfMemory;
    };
    return .{ .ok = slice };
}

/// A format failure: a union return is not an error, so errdefer would not
/// run — release what was accumulated and report the broken record.
fn abort(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Memory), res: LogRead) LogRead {
    for (out.items) |m| gpa.free(m.text);
    out.deinit(gpa);
    return res;
}

/// The dense prefix of level `size`'s non-blank summaries, or null when
/// the level file does not exist. Reading stops at the first blank or
/// undecodable record (later blocks rest on a hole and are dropped: the
/// next nap recomputes them) and skips a torn trailing record. The caller
/// owns the slice and each text (free them with the allocator it passed).
pub fn readLevel(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, size: u64) Error!?[][]const u8 {
    const path = try levelPath(gpa, size);
    defer gpa.free(path);
    const f = dir.openFile(io, path, .{ .mode = .read_only }) catch |e| switch (store.Store.mapFs(e)) {
        error.NotFound => return null,
        else => |err| return err,
    };
    defer std.Io.File.close(f, io);
    const fsize = std.Io.File.length(f, io) catch |e| return store.Store.mapFs(e);
    const n: u64 = fsize / TREE_REC; // a torn tail is not a record
    var out = std.ArrayListUnmanaged([]const u8).empty;
    errdefer for (out.items) |t| gpa.free(t);
    errdefer out.deinit(gpa);
    var buf: [TREE_REC]u8 = undefined;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const got = std.Io.File.readPositionalAll(f, io, &buf, i * TREE_REC) catch |e| return store.Store.mapFs(e);
        if (got != TREE_REC) break; // a short "record": not one
        if (buf[TREE_PAYLOAD] != '\n') break; // torn: a crash, not a record
        const line = rtrim(buf[0..TREE_PAYLOAD]);
        if (line.len == 0) break; // blank: a hole the next nap rebuilds
        if (!std.unicode.utf8ValidateSlice(line)) break;
        const t = gpa.dupe(u8, line) catch return error.OutOfMemory;
        errdefer gpa.free(t);
        try out.append(gpa, t);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// True when memory `id` with this date and text fits an OptMem log
/// record: "#<id> <date> <text>" in 319 bytes. Every date is ten bytes.
pub fn logFits(id: u64, date_str: []const u8, text: []const u8) bool {
    _ = date_str;
    return 1 + digitCount(id) + 1 + 10 + 1 + text.len <= LOG_PAYLOAD;
}

/// True when a summary fits an OptMem tree record.
pub fn treeFits(text: []const u8) bool {
    return text.len <= TREE_PAYLOAD;
}

/// The outcome of exportStore: the summaries written, or the first record
/// that cannot fit the fixed width (nothing was written).
pub const ExportResult = union(enum) {
    /// An OptMem store was written; the value is the summaries in it.
    done: u64,
    /// The memory named by id does not fit a 319-byte record.
    memoryTooLong: struct { id: u64, len: u64 },
    /// The summary of the named block does not fit a 287-byte record.
    summaryTooLong: struct { lo: u64, hi: u64, len: u64 },
};

/// Write an OptMem store from a LowMem store: a fresh LOG.txt and one
/// TREE file per level that carries a summary. All-or-nothing — every
/// record's fit is checked before the first byte is written. The output
/// directory must exist; its TREE/ is created when absent. A blank or
/// undecodable summary stops its level's prefix (the readLevel rule): the
/// export never names a block that rests on a hole.
pub fn exportStore(s: *const store.Store, io: std.Io, gpa: std.mem.Allocator, out: std.Io.Dir) Error!ExportResult {
    const T = try s.count(gpa, io);
    // Pass one: no memory may outgrow the fixed record, or the export
    // cannot finish and nothing may be half-written.
    {
        var sc = store.Store.Scanner.init(s, gpa, io) catch |e| return e;
        defer sc.deinit(io);
        while (true) {
            const nx = sc.next(io) catch |e| return e;
            switch (nx) {
                .eof => break,
                .mem => |m| {
                    const len: u64 = 1 + digitCount(m.id) + 1 + m.line.len;
                    if (len > LOG_PAYLOAD) return .{ .memoryTooLong = .{ .id = m.id, .len = len } };
                },
            }
        }
    }
    // Pass two: no summary may outgrow it either.
    var size: u64 = 2;
    while (size <= T) : (size = blocks.nextLevel(size, T) orelse break) {
        const n = try s.levelCount(gpa, io, size);
        var k: u64 = 0;
        while (k < n) : (k += 1) {
            const sum = s.summaryGet(gpa, io, k * size, (k + 1) * size) catch |e| {
                if (e == Error.CorruptRecord) break; // undecodable: the prefix ends
                return e;
            };
            switch (sum) {
                .text => |t| {
                    defer gpa.free(t);
                    if (t.len > TREE_PAYLOAD) {
                        return .{ .summaryTooLong = .{ .lo = k * size, .hi = (k + 1) * size, .len = t.len } };
                    }
                },
                // The prefix ends at the first hole; later records rest on it.
                .missing, .blank => break,
            }
        }
    }
    // Write: the log, then each level that has something to carry.
    var written: u64 = 0;
    {
        const f = out.createFile(io, "LOG.txt", .{ .truncate = true }) catch |e| return store.Store.mapFs(e);
        defer std.Io.File.close(f, io);
        var sc2 = store.Store.Scanner.init(s, gpa, io) catch |e| return e;
        defer sc2.deinit(io);
        var rec: [LOG_REC]u8 = undefined;
        while (true) {
            const nx = sc2.next(io) catch |e| return e;
            switch (nx) {
                .eof => break,
                .mem => |m| {
                    std.debug.assert(1 + digitCount(m.id) + 1 + m.line.len <= LOG_PAYLOAD);
                    var pos: u64 = 0;
                    rec[pos] = '#';
                    pos += 1;
                    const id_text = std.fmt.bufPrint(rec[pos..], "{d}", .{m.id}) catch unreachable;
                    pos += id_text.len;
                    rec[pos] = ' ';
                    pos += 1;
                    @memcpy(rec[pos .. pos + m.line.len], m.line);
                    pos += m.line.len;
                    while (pos < LOG_PAYLOAD) : (pos += 1) rec[pos] = ' ';
                    rec[LOG_PAYLOAD] = '\n';
                    std.Io.File.writePositionalAll(f, io, &rec, m.id * LOG_REC) catch |e| return store.Store.mapFs(e);
                },
            }
        }
        std.Io.File.sync(f, io) catch |e| return store.Store.mapFs(e);
    }
    size = 2;
    while (size <= T) : (size = blocks.nextLevel(size, T) orelse break) {
        const n = try s.levelCount(gpa, io, size);
        var texts = std.ArrayListUnmanaged([]const u8).empty;
        errdefer for (texts.items) |t| gpa.free(t);
        errdefer texts.deinit(gpa);
        var k: u64 = 0;
        while (k < n) : (k += 1) {
            const sum = s.summaryGet(gpa, io, k * size, (k + 1) * size) catch |e| {
                if (e == Error.CorruptRecord) break; // undecodable: the prefix ends
                return e;
            };
            switch (sum) {
                .text => |t| {
                    defer gpa.free(t);
                    const c = gpa.dupe(u8, t) catch return error.OutOfMemory;
                    errdefer gpa.free(c);
                    try texts.append(gpa, c);
                },
                .missing, .blank => break,
            }
        }
        if (texts.items.len == 0) continue;
        out.createDirPath(io, "TREE") catch |e| switch (store.Store.mapFs(e)) {
            error.AlreadyExists => {},
            else => |err| return err,
        };
        const path = try levelPath(gpa, size);
        defer gpa.free(path);
        const f = out.createFile(io, path, .{ .truncate = true }) catch |e| return store.Store.mapFs(e);
        defer std.Io.File.close(f, io);
        var rec: [TREE_REC]u8 = undefined;
        var off: u64 = 0;
        for (texts.items) |t| {
            @memcpy(rec[0..t.len], t);
            var pos: u64 = t.len;
            while (pos < TREE_PAYLOAD) : (pos += 1) rec[pos] = ' ';
            rec[TREE_PAYLOAD] = '\n';
            std.Io.File.writePositionalAll(f, io, &rec, off) catch |e| return store.Store.mapFs(e);
            off += TREE_REC;
        }
        std.Io.File.sync(f, io) catch |e| return store.Store.mapFs(e);
        written += @intCast(texts.items.len);
        for (texts.items) |t| gpa.free(t);
        texts.deinit(gpa);
    }
    return .{ .done = written };
}

// ------------------------------------------------------------------ utils

fn levelPath(gpa: std.mem.Allocator, size: u64) Error![]u8 {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "TREE/{d}", .{size}) catch unreachable;
    return gpa.dupe(u8, s) catch error.OutOfMemory;
}

/// Strip trailing spaces — the padding both record kinds use.
fn rtrim(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    return s[0..end];
}

fn parseDigits(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        const d: u64 = c - '0';
        if (v > (std.math.maxInt(u64) - d) / 10) return null;
        v = v * 10 + d;
    }
    return v;
}

fn digitCount(v: u64) u64 {
    var n: u64 = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

// ------------------------------------------------------------------ tests

var temp_counter: u64 = 0;

const TempDir = struct {
    path: []u8,
    dir: std.Io.Dir,
};

fn tempDir(gpa: std.mem.Allocator, io: std.Io) !TempDir {
    temp_counter += 1;
    var buf: [96]u8 = undefined;
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const s = std.fmt.bufPrint(&buf, "/tmp/lowmem-optmem-test-{d}-{d}", .{ ns, temp_counter }) catch unreachable;
    const path = try gpa.dupe(u8, s);
    errdefer gpa.free(path);
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return store.Store.mapFs(e),
    };
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch |e| return store.Store.mapFs(e);
    errdefer std.Io.Dir.close(dir, io);
    return .{ .path = path, .dir = dir };
}

fn cleanup(gpa: std.mem.Allocator, io: std.Io, t: TempDir) void {
    std.Io.Dir.close(t.dir, io);
    std.Io.Dir.cwd().deleteTree(io, t.path) catch {};
    gpa.free(t.path);
}

/// Write an OptMem LOG.txt of n records "#<i> 2020-01-01 memory <i>" plus
/// an optional torn tail.
fn writeOptLog(t: TempDir, io: std.Io, n: u64, torn: u64) !void {
    const f = t.dir.createFile(io, "LOG.txt", .{ .truncate = true }) catch |e| return store.Store.mapFs(e);
    defer std.Io.File.close(f, io);
    var rec: [LOG_REC]u8 = undefined;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const line = std.fmt.bufPrint(&rec, "#{d} 2020-01-01 memory {d}", .{ i, i }) catch unreachable;
        var pos: u64 = line.len;
        while (pos < LOG_PAYLOAD) : (pos += 1) rec[pos] = ' ';
        rec[LOG_PAYLOAD] = '\n';
        std.Io.File.writePositionalAll(f, io, &rec, i * LOG_REC) catch |e| return store.Store.mapFs(e);
    }
    if (torn > 0) {
        var tail: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&tail, "#{d} 2020-01-01 torn", .{n}) catch unreachable;
        std.Io.File.writePositionalAll(f, io, s, n * LOG_REC) catch |e| return store.Store.mapFs(e);
    }
    std.Io.File.sync(f, io) catch |e| return store.Store.mapFs(e);
}

test "readLog: healthy records and a torn tail" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    try writeOptLog(t, io, 3, 40);
    const r = try readLog(t.dir, io, testing.allocator);
    if (r != .ok) return error.WantOk;
    defer {
        for (r.ok) |m| testing.allocator.free(m.text);
        testing.allocator.free(r.ok);
    }
    try testing.expectEqual(@as(usize, 3), r.ok.len);
    try testing.expectEqualStrings("memory 2", r.ok[2].text);
    try testing.expectEqualStrings("2020-01-01", &r.ok[2].date);
}

test "readLog: the id must match its position" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    try writeOptLog(t, io, 2, 0);
    // Record 1's id: "#1 " becomes "#7 " (the id is at offset 1).
    {
        const f = t.dir.openFile(io, "LOG.txt", .{ .mode = .write_only }) catch |e| return store.Store.mapFs(e);
        defer std.Io.File.close(f, io);
        std.Io.File.writePositionalAll(f, io, "7", LOG_REC + 1) catch |e| return store.Store.mapFs(e);
    }
    const r = try readLog(t.dir, io, testing.allocator);
    if (r != .corrupt) return error.WantCorrupt;
    try testing.expectEqual(@as(u64, 1), r.corrupt);
}

test "readLog: a date that goes backwards is named" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    try writeOptLog(t, io, 2, 0);
    // Record 1's date, from 2020-01-01 back to 2019-12-31 (the date
    // starts at offset 3: "#1 ").
    {
        const f = t.dir.openFile(io, "LOG.txt", .{ .mode = .write_only }) catch |e| return store.Store.mapFs(e);
        defer std.Io.File.close(f, io);
        std.Io.File.writePositionalAll(f, io, "2019-12-31", LOG_REC + 3) catch |e| return store.Store.mapFs(e);
    }
    const r = try readLog(t.dir, io, testing.allocator);
    if (r != .nonChronological) return error.WantNonChrono;
    try testing.expectEqual(@as(u64, 1), r.nonChronological);
}

test "readLog: a non-UTF-8 text is corrupt" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    try writeOptLog(t, io, 1, 0);
    // "#0 2020-01-01 memory 0" — the text starts at offset 14.
    {
        const f = t.dir.openFile(io, "LOG.txt", .{ .mode = .write_only }) catch |e| return store.Store.mapFs(e);
        defer std.Io.File.close(f, io);
        std.Io.File.writePositionalAll(f, io, "\xff", 16) catch |e| return store.Store.mapFs(e);
    }
    const r = try readLog(t.dir, io, testing.allocator);
    if (r != .corrupt) return error.WantCorrupt;
    try testing.expectEqual(@as(u64, 0), r.corrupt);
}

test "readLevel: missing, blank stops, torn tail skipped" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    try testing.expectEqual(@as(?[][]const u8, null), try readLevel(t.dir, io, testing.allocator, 2));
    try t.dir.createDirPath(io, "TREE");
    const f = t.dir.createFile(io, "TREE/2", .{ .truncate = true }) catch |e| return store.Store.mapFs(e);
    // [settled, blank, settled] + a torn tail: only the first is carried.
    const recs = [_][]const u8{ "settled", "   ", "later" };
    var off: u64 = 0;
    for (recs) |r| {
        var buf: [TREE_REC]u8 = undefined;
        @memcpy(buf[0..r.len], r);
        var pos: u64 = r.len;
        while (pos < TREE_PAYLOAD) : (pos += 1) buf[pos] = ' ';
        buf[TREE_PAYLOAD] = '\n';
        std.Io.File.writePositionalAll(f, io, &buf, off) catch |e| return store.Store.mapFs(e);
        off += TREE_REC;
    }
    std.Io.File.writePositionalAll(f, io, "torn", off) catch |e| return store.Store.mapFs(e);
    std.Io.File.sync(f, io) catch |e| return store.Store.mapFs(e);
    std.Io.File.close(f, io);
    const lv = try readLevel(t.dir, io, testing.allocator, 2);
    if (lv == null) return error.WantLevel;
    defer {
        for (lv.?) |x| testing.allocator.free(x);
        testing.allocator.free(lv.?);
    }
    try testing.expectEqual(@as(usize, 1), lv.?.len);
    try testing.expectEqualStrings("settled", lv.?[0]);
}

/// A run of one byte, by value: the caller addresses it (&repeat(…)) to
/// get a slice. Constant-folded for comptime sizes.
fn repeat(c: u8, comptime n: usize) [n]u8 {
    var out: [n]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = c;
    return out;
}

test "logFits and treeFits at the edges" {
    // "#0 2020-01-01 " is 14 bytes; 319 - 14 = 305 of text for id 0.
    try std.testing.expect(logFits(0, "2020-01-01", &repeat('x', 305)));
    try std.testing.expect(!logFits(0, "2020-01-01", &repeat('x', 306)));
    // A ten-digit id costs nine more.
    try std.testing.expect(logFits(1_000_000_000, "2020-01-01", &repeat('x', 296)));
    try std.testing.expect(!logFits(1_000_000_000, "2020-01-01", &repeat('x', 297)));
    try std.testing.expect(treeFits(&repeat('x', 287)));
    try std.testing.expect(!treeFits(&repeat('x', 288)));
}

test "exportStore: a round trip and the fit refusal" {
    const testing = std.testing;
    const io = testing.io;
    // A LowMem store: two memories, one settled pair.
    const src = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, src);
    var s = store.Store.open(io, src.path) catch |e| return e;
    defer s.close(io);
    const d1 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '1' };
    const d2 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '2' };
    const items = [_]store.Store.NewMemory{
        .{ .date = d1, .text = "first" },
        .{ .date = d2, .text = "second" },
    };
    _ = try s.append(testing.allocator, io, &items);
    _ = try s.summaryPut(testing.allocator, io, 0, 2, "a pair");

    const out = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, out);
    const r = try exportStore(&s, io, testing.allocator, out.dir);
    if (r != .done) return error.WantDone;
    try testing.expectEqual(@as(u64, 1), r.done);

    // The export reads back as the same memories and summaries.
    const back = try readLog(out.dir, io, testing.allocator);
    if (back != .ok) return error.WantBack;
    defer {
        for (back.ok) |m| testing.allocator.free(m.text);
        testing.allocator.free(back.ok);
    }
    try testing.expectEqual(@as(usize, 2), back.ok.len);
    try testing.expectEqualStrings("first", back.ok[0].text);
    try testing.expectEqualStrings("second", back.ok[1].text);
    const lv = try readLevel(out.dir, io, testing.allocator, 2);
    if (lv == null) return error.WantBackLevel;
    defer {
        for (lv.?) |x| testing.allocator.free(x);
        testing.allocator.free(lv.?);
    }
    try testing.expectEqualStrings("a pair", lv.?[0]);

    // The record is fixed width: 320 bytes apiece.
    {
        const f = out.dir.openFile(io, "LOG.txt", .{ .mode = .read_only }) catch |e| return e;
        defer std.Io.File.close(f, io);
        try testing.expectEqual(@as(u64, 2 * LOG_REC), std.Io.File.length(f, io) catch |e| return e);
    }

    // A memory past the record is refused before anything is written.
    const d3 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '3' };
    const big = [_]store.Store.NewMemory{.{ .date = d3, .text = &repeat('x', 306) }};
    _ = try s.append(testing.allocator, io, &big);
    const out2 = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, out2);
    const r2 = try exportStore(&s, io, testing.allocator, out2.dir);
    if (r2 != .memoryTooLong) return error.WantTooLong;
    try testing.expectEqual(@as(u64, 2), r2.memoryTooLong.id);
    // Nothing was written: no LOG.txt in the target.
    const probe = out2.dir.openFile(io, "LOG.txt", .{ .mode = .read_only });
    try testing.expectError(error.FileNotFound, probe);
}

test "exportStore: an undecodable summary ends its level's prefix" {
    const testing = std.testing;
    const io = testing.io;
    // Four memories and one settled pair, then a second record of the same
    // level that is not valid UTF-8 (a hand edit, or a torn write that
    // happened to end on a newline). The export carries what stands before
    // the hole and stops there; it does not fail, and the re-read of the
    // export agrees (the readLevel rule).
    const src = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, src);
    var s = store.Store.open(io, src.path) catch |e| return e;
    defer s.close(io);
    const d1 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '1' };
    const d2 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '2' };
    const d3 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '3' };
    const d4 = [10]u8{ '2', '0', '2', '0', '-', '0', '1', '-', '0', '4' };
    _ = try s.append(testing.allocator, io, &[_]store.Store.NewMemory{
        .{ .date = d1, .text = "a" },
        .{ .date = d2, .text = "b" },
        .{ .date = d3, .text = "c" },
        .{ .date = d4, .text = "d" },
    });
    _ = try s.summaryPut(testing.allocator, io, 0, 2, "a pair");
    {
        const f = src.dir.openFile(io, "TREE/2", .{ .mode = .write_only }) catch |e| return e;
        defer std.Io.File.close(f, io);
        const bad = [_]u8{ 0xff, 0xfe, ' ', 'x', '\n' };
        const at = std.Io.File.length(f, io) catch |e| return e;
        try std.Io.File.writePositionalAll(f, io, &bad, at);
    }
    const out = try tempDir(testing.allocator, io);
    defer cleanup(testing.allocator, io, out);
    const r = try exportStore(&s, io, testing.allocator, out.dir);
    if (r != .done) return error.WantDone;
    try testing.expectEqual(@as(u64, 1), r.done); // only the record before the hole
    const lv = try readLevel(out.dir, io, testing.allocator, 2);
    if (lv == null) return error.WantLevel;
    defer {
        for (lv.?) |x| testing.allocator.free(x);
        testing.allocator.free(lv.?);
    }
    try testing.expectEqual(@as(usize, 1), lv.?.len);
    try testing.expectEqualStrings("a pair", lv.?[0]);
    // The higher level has nothing to carry and no file is created.
    const probe4 = out.dir.openFile(io, "TREE/4", .{ .mode = .read_only });
    try testing.expectError(error.FileNotFound, probe4);
}
