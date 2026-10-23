/// The size knobs a memory may override in its `config` file.
///
/// A knob is a *reading* budget: it selects what gets printed, so
/// changing one never recomputes anything. The globals of the tool start
/// at these defaults, so a memory that overrides nothing follows the tool.
const std = @import("std");

/// The record ceiling (ADR 0001): one line, date, space, text, newline.
/// `ENTRY_CHARS` is capped at text = ceiling - 10 - 1 - 1.
pub const ENTRY_CHARS_MAX: u32 = 65523;

const Knob = struct {
    name: []const u8,
    what: []const u8,
    def: u32,
};

pub const KNOBS = [_]Knob{
    .{ .name = "WAKE_LINES", .what = "the memory context: how many lines wake prints", .def = 96 },
    .{ .name = "ENTRY_CHARS", .what = "the longest one memory may be, in bytes", .def = 280 },
    .{ .name = "PART_CHARS", .what = "output paging: largest part, in bytes", .def = 20000 },
    .{ .name = "PART_LINES", .what = "output paging: largest part, in lines", .def = 500 },
};

pub const Config = struct {
    /// The reading budgets are u64: the reference tool's int is unbounded,
    /// and a budget past a u32 would have wrapped. (Past 2^64-1 a value is
    /// refused; any budget past the log is behaviorally the same as the
    /// log length, so the cap costs no behavior.)
    wake_lines: u64 = KNOBS[0].def,
    entry_chars: u32 = KNOBS[1].def,
    part_chars: u64 = KNOBS[2].def,
    part_lines: u64 = KNOBS[3].def,
    /// True when the knob's line in the config file is uncommented, i.e.
    /// this memory sets it for itself. `config` annotates those with
    /// "(default N)"; write_config leaves them uncommented.
    set_wake_lines: bool = false,
    set_entry_chars: bool = false,
    set_part_chars: bool = false,
    set_part_lines: bool = false,

    pub fn knobIndex(name: []const u8) ?usize {
        for (KNOBS, 0..) |knob, i| {
            if (std.mem.eql(u8, knob.name, name)) return i;
        }
        return null;
    }

    pub fn value(self: *const Config, i: usize) u64 {
        return switch (i) {
            0 => self.wake_lines,
            1 => self.entry_chars,
            2 => self.part_chars,
            else => self.part_lines,
        };
    }

    pub fn setValue(self: *Config, i: usize, v: u64, set: bool) void {
        switch (i) {
            0 => {
                self.wake_lines = v;
                self.set_wake_lines = set;
            },
            1 => {
                // The ceiling check above guarantees v fits a u32.
                self.entry_chars = @intCast(v);
                self.set_entry_chars = set;
            },
            2 => {
                self.part_chars = v;
                self.set_part_chars = set;
            },
            else => {
                self.part_lines = v;
                self.set_part_lines = set;
            },
        }
    }

    pub fn isSet(self: *const Config, i: usize) bool {
        return switch (i) {
            0 => self.set_wake_lines,
            1 => self.set_entry_chars,
            2 => self.set_part_chars,
            else => self.set_part_lines,
        };
    }
};

pub const ParseError = error{
    /// A line names a knob that is not in KNOBS.
    UnknownKnob,
    /// A value is not a positive whole number.
    BadValue,
    /// A positive whole number, but over the knob's ceiling.
    TooBig,
};

/// Where a parse failure happened: the file line and the knob name, so the
/// error message can say where it is written. A bad knob stops every
/// command, so the message has to be actionable.
pub const ParseInfo = struct {
    line: u32 = 0,
    knob: []const u8 = "",
    /// The raw value that failed (bad values only); borrows from the
    /// content that was parsed.
    value: []const u8 = "",
};

/// Parse a config file's contents into `cfg`. Lines are
/// `NAME = VALUE`, `#` starts a comment, and a commented-out line means
/// "follow the tool's default". `keybuf` backs `info.knob` for unknown
/// knobs (upper-cased there); keep it alive until the error is rendered.
pub fn parse(content: []const u8, cfg: *Config, info: *ParseInfo, keybuf: *[128]u8) ParseError!void {
    var line_no: u32 = 0;
    var rest = content;
    while (rest.len > 0) {
        const nl = std.mem.findScalarPos(u8, rest, 0, '\n') orelse rest.len;
        const line = rest[0..nl];
        rest = if (nl < rest.len) rest[nl + 1 ..] else &.{};
        line_no += 1;
        // `line.split("#")[0].strip()`: a comment cuts the line off.
        const cut = commentCut(line);
        const eq = std.mem.findScalarPos(u8, cut, 0, '=') orelse continue;
        const key = upperTrim(cut[0..eq], keybuf);
        const val = trim(cut[eq + 1 ..]);
        info.line = line_no;
        const idx = Config.knobIndex(key) orelse {
            info.knob = key;
            return ParseError.UnknownKnob;
        };
        info.knob = KNOBS[idx].name;
        info.value = val;
        var v: u64 = 0;
        if (val.len == 0) return ParseError.BadValue;
        for (val) |c| {
            if (c < '0' or c > '9') return ParseError.BadValue;
            const d: u64 = c - '0';
            if (v > (std.math.maxInt(u64) - d) / 10) return ParseError.BadValue;
            v = v * 10 + d;
        }
        if (v < 1) return ParseError.BadValue;
        if (idx == 1 and v > ENTRY_CHARS_MAX) return ParseError.TooBig;
        cfg.setValue(idx, @intCast(v), true);
    }
}

/// The part of `line` before the first `#`, whitespace-trimmed.
fn commentCut(line: []const u8) []const u8 {
    const hash = std.mem.findScalarPos(u8, line, 0, '#') orelse line.len;
    return trim(line[0..hash]);
}

fn trim(s: []const u8) []const u8 {
    var lo: usize = 0;
    var hi: usize = s.len;
    while (lo < hi and (s[lo] == ' ' or s[lo] == '\t')) lo += 1;
    while (hi > lo and (s[hi - 1] == ' ' or s[hi - 1] == '\t')) hi -= 1;
    return s[lo..hi];
}

/// Upper-case and trim (ASCII: the knob names are ASCII, and a non-ASCII
/// name is not a knob either way). The result borrows from `buf` when it
/// fits, otherwise from the input.
fn upperTrim(s: []const u8, buf: [*]u8) []const u8 {
    const t = trim(s);
    if (t.len > 128) return t; // not a knob name anyway
    for (t, 0..) |c, i| {
        buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    return buf[0..t.len];
}

/// The `config` file as `lowmem config` writes it: every knob on its own
/// line, commented out unless this memory overrides it. The caller owns
/// the returned bytes (free with the same allocator).
pub fn renderFile(gpa: std.mem.Allocator, me: []const u8, cfg: *const Config) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "# LowMem sizes for this memory. A commented line means: follow the\n");
    try out.print(gpa, "# tool's default. Edit with `{s} config NAME=VALUE`.\n\n", .{me});
    for (KNOBS, 0..) |knob, i| {
        const set = cfg.isSet(i);
        const v = cfg.value(i);
        // The prefix is always two chars: "  " when set, "# " when not.
        if (set) {
            try out.append(gpa, ' ');
            try out.append(gpa, ' ');
        } else {
            try out.append(gpa, '#');
            try out.append(gpa, ' ');
        }
        try out.appendSlice(gpa, knob.name);
        for (knob.name.len..12) |_| try out.append(gpa, ' ');
        try out.appendSlice(gpa, " = ");
        var digits: [21]u8 = undefined;
        const d = std.fmt.bufPrint(&digits, "{d}", .{v}) catch unreachable;
        try out.appendSlice(gpa, d);
        // %-6d: a minimum width, no truncation — a big budget is echoed
        // back in full.
        var pad: usize = 0;
        while (pad + d.len < 6) : (pad += 1) try out.append(gpa, ' ');
        try out.appendSlice(gpa, " # ");
        try out.appendSlice(gpa, knob.what);
        try out.append(gpa, '\n');
    }
    return try out.toOwnedSlice(gpa);
}

test "parse: overrides and comments" {
    var cfg = Config{};
    var info = ParseInfo{};
    var keybuf: [128]u8 = undefined;
    try parse(
        "WAKE_LINES = 12\n# ENTRY_CHARS = 280\nPART_CHARS=25000  # tuned\n\n",
        &cfg,
        &info,
        &keybuf,
    );
    try std.testing.expectEqual(@as(u32, 12), cfg.wake_lines);
    try std.testing.expect(cfg.set_wake_lines);
    try std.testing.expectEqual(@as(u32, 280), cfg.entry_chars);
    try std.testing.expect(!cfg.set_entry_chars);
    try std.testing.expectEqual(@as(u32, 25000), cfg.part_chars);
    try std.testing.expectEqual(@as(u32, 500), cfg.part_lines);
}

test "parse: unknown knob names the knob" {
    var cfg = Config{};
    var info = ParseInfo{};
    var keybuf: [128]u8 = undefined;
    _ = parse("WAKE_LNES = 100\n", &cfg, &info, &keybuf) catch |err| {
        try std.testing.expectEqual(ParseError.UnknownKnob, err);
    };
    try std.testing.expectEqual(@as(u32, 1), info.line);
    try std.testing.expectEqualStrings("WAKE_LNES", info.knob);
}

test "parse: bad values" {
    const bad = [_][]const u8{
        "WAKE_LINES = 0\n",
        "WAKE_LINES = x\n",
        "WAKE_LINES = -5\n",
        "WAKE_LINES =\n",
    };
    for (bad) |content| {
        var cfg = Config{};
        var info = ParseInfo{};
        var keybuf: [128]u8 = undefined;
        _ = parse(content, &cfg, &info, &keybuf) catch |err| {
            try std.testing.expectEqual(ParseError.BadValue, err);
        };
        if (info.line == 0) return error.ParseSucceeded;
    }
}

test "parse: ENTRY_CHARS ceiling" {
    var cfg = Config{};
    var info = ParseInfo{};
    var keybuf: [128]u8 = undefined;
    _ = parse("ENTRY_CHARS = 65523\n", &cfg, &info, &keybuf) catch |err| {
        std.debug.print("65523 rejected: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqual(@as(u32, 65523), cfg.entry_chars);
    var cfg2 = Config{};
    _ = parse("ENTRY_CHARS = 65524\n", &cfg2, &info, &keybuf) catch |err| {
        try std.testing.expectEqual(ParseError.TooBig, err);
    };
}

test "renderFile: the file format" {
    var cfg = Config{};
    cfg.setValue(0, 12, true); // WAKE_LINES = 12, the rest default
    const text = try renderFile(std.testing.allocator, "/tmp/lowmem", &cfg);
    defer std.testing.allocator.free(text);
    const want =
        \\# LowMem sizes for this memory. A commented line means: follow the
        \\# tool's default. Edit with `/tmp/lowmem config NAME=VALUE`.
        \\
        \\  WAKE_LINES   = 12     # the memory context: how many lines wake prints
        \\# ENTRY_CHARS  = 280    # the longest one memory may be, in bytes
        \\# PART_CHARS   = 20000  # output paging: largest part, in bytes
        \\# PART_LINES   = 500    # output paging: largest part, in lines
        \\
    ;
    try std.testing.expectEqualStrings(want, text);
}

test "renderFile: a budget wider than the column" {
    var cfg = Config{};
    cfg.setValue(0, 1_000_000_000_000_000_000, true); // 19 digits
    const text = try renderFile(std.testing.allocator, "/tmp/lowmem", &cfg);
    defer std.testing.allocator.free(text);
    const want =
        \\# LowMem sizes for this memory. A commented line means: follow the
        \\# tool's default. Edit with `/tmp/lowmem config NAME=VALUE`.
        \\
        \\  WAKE_LINES   = 1000000000000000000 # the memory context: how many lines wake prints
        \\# ENTRY_CHARS  = 280    # the longest one memory may be, in bytes
        \\# PART_CHARS   = 20000  # output paging: largest part, in bytes
        \\# PART_LINES   = 500    # output paging: largest part, in lines
        \\
    ;
    try std.testing.expectEqualStrings(want, text);
}

test "knobIndex" {
    try std.testing.expectEqual(@as(usize, 0), Config.knobIndex("WAKE_LINES"));
    try std.testing.expectEqual(@as(usize, 3), Config.knobIndex("PART_LINES"));
    try std.testing.expect(Config.knobIndex("NOPE") == null);
}
