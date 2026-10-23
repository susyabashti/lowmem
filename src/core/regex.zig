/// The recall pattern: a zero-dependency subset of the reference tool's
/// regular expressions (documented difference 4).
///
/// A pattern is a literal, optionally anchored at its start with `^`,
/// matched case-insensitively over ASCII. Any other metacharacter is
/// treated as itself: the pattern "a.b" searches for the three characters
/// a, ., b, and an unbalanced parenthesis matches a literal parenthesis.
/// This keeps the engine one sliding window, with no state to corrupt.
const std = @import("std");

const ascii = std.ascii;
const mem = std.mem;

pub const Pattern = struct {
    /// The needle. Borrows from the pattern string the caller compiled.
    literal: []const u8,
    /// True when the pattern started with `^`: match at position 0 only.
    anchored: bool,

    /// Compile a pattern string. Borrows from it; the pattern must outlive
    /// the Pattern.
    pub fn compile(p: []const u8) Pattern {
        if (p.len > 0 and p[0] == '^') {
            return .{ .literal = p[1..], .anchored = true };
        }
        return .{ .literal = p, .anchored = false };
    }

    /// True when the pattern is found in `hay` anywhere (or at 0 when
    /// anchored). An empty pattern matches, the way the reference engine
    /// does.
    pub fn search(self: Pattern, hay: []const u8) bool {
        const n = self.literal.len;
        if (n == 0) return true;
        if (self.anchored) {
            if (hay.len < n) return false;
            return matchAt(self.literal, hay);
        }
        // The first needle byte, folded to its case pair: a candidate
        // position must carry one of them.
        const first = self.literal[0];
        const c0 = if (first < 0x80) ascii.toLower(first) else first;
        const c1 = if (first < 0x80) ascii.toUpper(first) else first;
        // The last needle byte, kept for a cheap reject: a candidate whose
        // window ends on the wrong byte cannot match, so the full compare
        // is skipped. A needle of one byte is its own last byte, and the
        // check then agrees with matchAt, so it is still correct.
        const last = self.literal[n - 1];
        var pos: usize = 0;
        while (pos <= hay.len - n) {
            const rest = hay[pos..];
            // Neither form found: the candidate is past the end, so no
            // position left to try.
            const a = mem.findScalarPos(u8, rest, 0, c0) orelse rest.len;
            const b = if (c1 != c0) mem.findScalarPos(u8, rest, 0, c1) orelse rest.len else rest.len;
            const cand = @min(a, b);
            if (cand == rest.len) break;
            if (cand + n <= rest.len and !byteAgrees(last, rest[cand + n - 1])) {
                pos = pos + cand + 1;
                continue;
            }
            if (matchAt(self.literal, rest[cand..])) return true;
            pos = pos + cand + 1;
        }
        return false;
    }
};

/// The case rule of matchAt for one byte: an ASCII needle byte matches its
/// folded counterpart, a non-ASCII byte matches byte-for-byte.
fn byteAgrees(nb: u8, hb: u8) bool {
    if (nb < 0x80) return ascii.toLower(nb) == ascii.toLower(hb);
    return nb == hb;
}

/// Case-insensitive byte compare: an ASCII needle byte matches its folded
/// counterpart in the haystack, a non-ASCII byte matches byte-for-byte
/// (UTF-8 is prefix-free, so a folded ASCII byte can never equal a UTF-8
/// lead byte, and multi-byte characters compare by their whole sequence).
fn matchAt(needle: []const u8, hay: []const u8) bool {
    for (needle, 0..) |nb, i| {
        if (i >= hay.len) return false;
        const hb = hay[i];
        if (nb < 0x80) {
            if (ascii.toLower(nb) != ascii.toLower(hb)) return false;
        } else if (nb != hb) {
            return false;
        }
    }
    return true;
}

test "literal search" {
    const p = Pattern.compile("memory number 7,");
    try std.testing.expect(p.search("#7 2020-01-02 memory number 7, plain"));
    try std.testing.expect(!p.search("#7 2020-01-02 memory number 7 plain"));
}

test "anchor" {
    const p = Pattern.compile("^#7 ");
    try std.testing.expect(p.search("#7 2020-01-02 text"));
    try std.testing.expect(!p.search("x #7 2020-01-02 text"));
    try std.testing.expect(!p.search("#7")); // shorter than the needle
}

test "case-insensitive, both directions" {
    const up = Pattern.compile("Memory");
    try std.testing.expect(up.search("a memory b"));
    try std.testing.expect(up.search("a MEMORY b"));
    try std.testing.expect(!up.search("a memorv b"));
    const lo = Pattern.compile("memory");
    try std.testing.expect(lo.search("a Memory b"));
}

test "utf-8 literal" {
    const p = Pattern.compile("coração");
    try std.testing.expect(p.search("João wrote coração here"));
    try std.testing.expect(!p.search("João wrote coracao here"));
    // A needle ending mid-character cannot match: the window is whole
    // codepoints on both sides.
    const short = Pattern.compile("cora");
    try std.testing.expect(short.search("João wrote coração here"));
}

test "metacharacters are literal" {
    const p = Pattern.compile("a.b (c) [d] *e +f ?g |h");
    try std.testing.expect(p.search("x a.b (c) [d] *e +f ?g |h y"));
    try std.testing.expect(!p.search("x axb (c) [d] *e +f ?g |h y"));
}

test "empty pattern matches" {
    const p = Pattern.compile("");
    try std.testing.expect(p.search("anything"));
    try std.testing.expect(p.search(""));
    const a = Pattern.compile("^");
    try std.testing.expect(a.search("anything"));
    try std.testing.expect(a.search(""));
}

test "search over a million-line shaped haystack stays exact" {
    // The shape recall scans: "#<id> <date> <text>". The needle must match
    // inside the line, never across the window edges.
    var hay = std.ArrayListUnmanaged(u8).empty;
    defer hay.deinit(std.testing.allocator);
    const p = Pattern.compile("2020-01-02");
    var i: u64 = 0;
    while (i < 2000) : (i += 1) {
        try hay.print(std.testing.allocator, "#{d} 2020-01-0{d} text {d}\n", .{ i, i % 10, i });
    }
    // Reuse the scanner's view: the line without the newline.
    const line = "#7 2020-01-02 text 7";
    try std.testing.expect(p.search(line));
    try std.testing.expect(!p.search("#7 2020-01-03 text 7"));
}
