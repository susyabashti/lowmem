/// nap: do the pending compressions. With no arguments it prints the next
/// nap (or that nothing is left). With two, it pays one: the id must be
/// the next pending block, a settled id reports so without writing, and a
/// lost race reports the other outcome. After any nap with arguments the
/// next nap follows on a blank line — nap never prints "You are awake.",
/// only wake may.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    const T = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    var said = false;
    if (argv.len != 0) {
        said = true;
        if (argv.len != 2) output.die(ctx.io, common.gpaPrint(ctx, "usage: {s} nap <lo>-<hi> \"<one line>\"", .{ctx.me}));
        const b = core.blocks.parseId(argv[0]) catch |e| common.dieBlockId(ctx, argv[0], e);
        const todo = core.nap.nextPending(s, ctx.gpa, ctx.io, T) catch |e| {
            if (e == store.Store.Error.CorruptRecord) output.dieFs(ctx, common.logPath(ctx), e);
            output.dieFs(ctx, ctx.store_dir_tilde, e);
        };
        if (todo == null) {
            output.println(ctx.io, "Nothing left to compress.");
            return;
        }
        if (b.lo != todo.?.lo or b.hi != todo.?.hi) {
            // A settled block is reported, not an error: two sessions paying
            // the same nap is the documented outcome, not a fault. A blank
            // record is not settled — the reference tool reads it as None —
            // and lands in the wrong-block refusal.
            const sum = s.summaryGet(ctx.gpa, ctx.io, b.lo, b.hi) catch |e| {
                if (e == store.Store.Error.CorruptRecord) common.dieCorruptSummary(ctx, b.lo, b.hi);
                output.dieFs(ctx, common.treePath(ctx, b.size()), e);
            };
            if (sum == .text) {
                output.println(ctx.io, common.gpaPrint(ctx, "{d}-{d} is already settled.", .{ b.lo, b.hi - 1 }));
            } else {
                output.die(
                    ctx.io,
                    common.gpaPrint(
                        ctx,
                        "Wrong block: {s}. Blocks are built in order; the next is {d}-{d}. Run: {s} nap",
                        .{ argv[0], todo.?.lo, todo.?.hi - 1, ctx.me },
                    ),
                );
            }
        } else {
            const text = common.checkEntry(ctx, argv[1], cfg.entry_chars);
            const r = s.summaryPut(ctx.gpa, ctx.io, b.lo, b.hi, text) catch |e|
                output.dieFs(ctx, common.treePath(ctx, b.size()), e);
            if (r == .appended) {
                output.println(ctx.io, common.gpaPrint(ctx, "{d}-{d} saved.", .{ b.lo, b.hi - 1 }));
            } else {
                output.println(ctx.io, common.gpaPrint(ctx, "{d}-{d} was settled or forgotten meanwhile.", .{ b.lo, b.hi - 1 }));
            }
        }
    }
    const r = core.nap.nextNap(s, ctx.gpa, ctx.io, T, ctx.me, cfg.entry_chars) catch |e| {
        if (e == store.Store.Error.CorruptRecord) output.dieFs(ctx, common.logPath(ctx), e);
        output.dieFs(ctx, ctx.store_dir_tilde, e);
    };
    switch (r) {
        .prompt => |p| {
            if (said) output.println(ctx.io, "");
            output.println(ctx.io, p.text);
        },
        .none => output.println(ctx.io, "Nothing left to compress."),
        .blankHalf => |h| common.dieBlankSummary(ctx, h.lo, h.hi),
        .corrupt => |h| common.dieCorruptSummary(ctx, h.lo, h.hi),
    }
}
