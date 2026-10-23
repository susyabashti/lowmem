/// zoom: open one node of the tree — its two halves, each rendered the way
/// wake renders a covered block: a summary, or the raw memory once a half
/// is single. A half beyond T is the future: omitted, not printed. The
/// tool only reads; the navigating intelligence is the agent's.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    _ = cfg; // zoom reads; no size knob selects anything here
    if (argv.len != 1) output.die(
        ctx.io,
        common.gpaPrint(ctx, "usage: {s} zoom <lo>-<hi>   # a block id, as wake prints them", .{ctx.me}),
    );
    const b = core.blocks.parseId(argv[0]) catch |e| common.dieBlockId(ctx, argv[0], e);
    const T = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    if (b.lo >= T) {
        const n = core.text.plural(ctx.gpa, T, "memory") catch output.dieOom(ctx);
        output.die(ctx.io, common.gpaPrint(ctx, "#{s} is beyond the memory: it holds {s}. Run: {s} wake", .{ argv[0], n, ctx.me }));
    }
    const halves = b.halves();
    for (halves) |h| {
        if (h.lo >= T) continue; // the future: no memories there yet
        if (h.size() == 1) {
            const m = s.get(ctx.gpa, ctx.io, h.lo) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
            output.println(ctx.io, common.gpaPrint(ctx, "#{d} {s} {s}", .{ m.id, &m.date, m.text }));
            ctx.gpa.free(m.text);
        } else {
            const sum = s.summaryGet(ctx.gpa, ctx.io, h.lo, h.hi) catch |e| {
                if (e == store.Store.Error.CorruptRecord) common.dieCorruptSummary(ctx, h.lo, h.hi);
                output.dieFs(ctx, common.treePath(ctx, h.size()), e);
            };
            switch (sum) {
                .text => |t| {
                    output.println(ctx.io, common.gpaPrint(ctx, "#{d}-{d} {s}", .{ h.lo, h.hi - 1, t }));
                    ctx.gpa.free(t);
                },
                // A missing summary is pending work; a blank one is a
                // deliberately written nothing. Both read as "not yet".
                .missing, .blank => output.println(ctx.io, common.gpaPrint(ctx, "#{d}-{d} not compressed yet", .{ h.lo, h.hi - 1 })),
            }
        }
    }
}
