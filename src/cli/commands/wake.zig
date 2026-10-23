/// wake: read the memory. The document is cover(T, WAKE_LINES) rendered
/// oldest first, paged to PART_CHARS/PART_LINES, and it refuses — the only
/// reason it ever refuses — when a summary the document needs is not built
/// yet: the nap prompt is printed and the exit is 1. A part is rendered as
/// of T, so a note landing between two parts cannot shift a boundary.
const std = @import("std");
const core = @import("core");
const args = @import("../args.zig");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const blocks = core.blocks;
const config = core.config;
const napmod = core.nap;
const text = core.text;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    const now = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    var k_str: []const u8 = "1";
    var T: u64 = now;
    if (argv.len != 0) {
        if (argv.len > 2 or !args.digits(argv[0]) or (argv.len == 2 and !args.digits(argv[1])))
            output.die(ctx.io, common.gpaPrint(ctx, "usage: {s} wake [part [T]]", .{ctx.me}));
        k_str = args.normalize(argv[0]);
        if (argv.len == 2) {
            const ts = args.normalize(argv[1]);
            if (args.toU64(ts)) |t| {
                if (t > now) noMemoriesT(ctx, s, ts, now);
                T = t;
            } else {
                // Past u64: past the log for sure.
                noMemoriesT(ctx, s, ts, now);
            }
        }
    }
    if (T == 0) {
        output.println(ctx.io, common.gpaPrint(ctx, "No memories yet. Record the first with: {s} note \"<one line>\"", .{ctx.me}));
        output.println(ctx.io, "You are awake.");
        return;
    }
    const cover_ = core.cover.cover(ctx.gpa, T, cfg.wake_lines) catch output.dieOom(ctx);
    defer ctx.gpa.free(cover_);
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    for (cover_) |b| {
        if (b.size() == 1) {
            const m = s.get(ctx.gpa, ctx.io, b.lo) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
            const line = common.gpaPrint(ctx, "#{d} {s} {s}", .{ m.id, &m.date, m.text });
            ctx.gpa.free(m.text);
            lines.append(ctx.gpa, line) catch output.dieOom(ctx);
        } else {
            const t = summary(ctx, s, b, T, cfg.entry_chars);
            const line = common.gpaPrint(ctx, "#{d}-{d} {s}", .{ b.lo, b.hi - 1, t });
            ctx.gpa.free(t);
            lines.append(ctx.gpa, line) catch output.dieOom(ctx);
        }
    }
    const parts = paginate(ctx, lines.items, cfg.part_chars, cfg.part_lines);
    if (args.toU64(k_str)) |k| {
        if (k < 1 or k > parts.items.len) {
            const n = text.plural(ctx.gpa, parts.items.len, "part") catch output.dieOom(ctx);
            output.die(ctx.io, common.gpaPrint(ctx, "No part {s}: the memory has {s}. Run: {s} wake", .{ k_str, n, ctx.me }));
        }
        if (parts.items.len > 1) {
            const t = text.plural(ctx.gpa, T, "memory") catch output.dieOom(ctx);
            output.println(ctx.io, common.gpaPrint(ctx, "Your memory, part {d} of {d}, oldest first ({s}).", .{ k, parts.items.len, t }));
        }
        for (parts.items[k - 1].items) |line| output.println(ctx.io, line);
        if (k < parts.items.len) {
            output.println(ctx.io, common.gpaPrint(ctx, "Not awake yet. Run: {s} wake {d} {d}", .{ ctx.me, k + 1, T }));
        } else {
            output.println(ctx.io, "You are awake.");
            tailNap(ctx, s, T, cfg.entry_chars);
        }
    } else {
        // A part number past u64 is past every part count.
        const n = text.plural(ctx.gpa, parts.items.len, "part") catch output.dieOom(ctx);
        output.die(ctx.io, common.gpaPrint(ctx, "No part {s}: the memory has {s}. Run: {s} wake", .{ k_str, n, ctx.me }));
    }
}

/// T is larger than the log: the refusal names both numbers.
fn noMemoriesT(ctx: *const context.Context, s: *const store.Store, ts: []const u8, now: u64) noreturn {
    const n = text.plural(ctx.gpa, now, "memory") catch output.dieOom(ctx);
    output.die(ctx.io, common.gpaPrint(ctx, "T={s}, but the log holds {s}. Run: {s} wake", .{ ts, n, ctx.me }));
    _ = s;
}

/// The summary of a covered block, or the refusal and the blank/corrupt
/// exits. The text is gpa-allocated; the caller frees it.
fn summary(ctx: *const context.Context, s: *const store.Store, b: blocks.Block, T: u64, entry_chars: u32) []const u8 {
    const sum = fetch(ctx, s, b);
    switch (sum) {
        .text => |t| return t,
        .missing, .blank => {
            const r = napmod.nextNap(s, ctx.gpa, ctx.io, T, ctx.me, entry_chars) catch |e| napErr(ctx, e);
            switch (r) {
                .prompt => |p| refuse(ctx, s, b, p.text, T),
                .none => {
                    // Nothing is pending, so a parallel session may have paid
                    // the block in the meantime: read it once more.
                    const sum2 = fetch(ctx, s, b);
                    switch (sum2) {
                        .text => |t| return t,
                        else => common.dieBlankSummary(ctx, b.lo, b.hi),
                    }
                },
                .blankHalf => |h| common.dieBlankSummary(ctx, h.lo, h.hi),
                .corrupt => |h| common.dieCorruptSummary(ctx, h.lo, h.hi),
            }
        },
    }
}

fn fetch(ctx: *const context.Context, s: *const store.Store, b: blocks.Block) store.Store.Summary {
    return s.summaryGet(ctx.gpa, ctx.io, b.lo, b.hi) catch |e| {
        if (e == store.Store.Error.CorruptRecord) common.dieCorruptSummary(ctx, b.lo, b.hi);
        output.dieFs(ctx, common.treePath(ctx, b.size()), e);
    };
}

/// A store error while reading the next nap: a corrupt line reached through
/// the raw log is named at the log; the rest, at the store.
fn napErr(ctx: *const context.Context, e: store.Store.Error) noreturn {
    if (e == store.Store.Error.CorruptRecord) output.dieFs(ctx, common.logPath(ctx), e);
    output.dieFs(ctx, ctx.store_dir_tilde, e);
}

/// The refusal: the document cannot be written without that summary. The
/// prompt is the work, printed to stdout with the read, and the exit is 1.
fn refuse(ctx: *const context.Context, s: *const store.Store, b: blocks.Block, prompt: []const u8, T: u64) noreturn {
    const n = napmod.pendingCount(s, ctx.gpa, ctx.io, T) catch |e| output.dieFs(ctx, ctx.store_dir_tilde, store.Store.mapFs(e));
    const nstr = text.plural(ctx.gpa, n, "compression") catch output.dieOom(ctx);
    output.println(
        ctx.io,
        common.gpaPrint(
            ctx,
            // The trailing newline is the blank line before the prompt:
            // the reference print carries it inside the string, so the
            // line it ends on is empty.
            "Cannot wake: the memory context needs #{d}-{d}, which is not compressed yet.\nDo the {s} below, then run {s} wake again.\n",
            .{ b.lo, b.hi - 1, nstr, ctx.me },
        ),
    );
    output.println(ctx.io, prompt);
    std.process.exit(1);
}

/// The last part of a wake may still have pending work: the prompt follows
/// on a blank line, the way note's does.
fn tailNap(ctx: *const context.Context, s: *const store.Store, T: u64, entry_chars: u32) void {
    const r = napmod.nextNap(s, ctx.gpa, ctx.io, T, ctx.me, entry_chars) catch |e| {
        if (e == store.Store.Error.CorruptRecord) output.dieFs(ctx, common.logPath(ctx), e);
        output.dieFs(ctx, ctx.store_dir_tilde, e);
    };
    switch (r) {
        .prompt => |p| {
            output.println(ctx.io, "");
            output.println(ctx.io, p.text);
        },
        .none => {},
        .blankHalf => |h| common.dieBlankSummary(ctx, h.lo, h.hi),
        .corrupt => |h| common.dieCorruptSummary(ctx, h.lo, h.hi),
    }
}

/// Split the document into parts that survive any harness's output cap:
/// a part holds at most PART_LINES lines and PART_CHARS bytes (a line costs
/// its bytes plus the newline that carries it).
fn paginate(ctx: *const context.Context, lines: []const []const u8, part_chars: u64, part_lines: u64) std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) {
    const cap: usize = @intCast(part_chars);
    var parts = std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)).empty;
    var cur = std.ArrayListUnmanaged([]const u8).empty;
    var size: usize = 0;
    for (lines) |line| {
        const n = line.len + 1;
        if (cur.items.len > 0 and (cur.items.len >= part_lines or size + n > cap)) {
            parts.append(ctx.gpa, cur) catch output.dieOom(ctx);
            cur = .empty;
            size = 0;
        }
        cur.append(ctx.gpa, line) catch output.dieOom(ctx);
        size += n;
    }
    if (cur.items.len > 0) parts.append(ctx.gpa, cur) catch output.dieOom(ctx);
    return parts;
}
