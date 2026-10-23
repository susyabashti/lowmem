/// forget: drop a summary and every block built on it, by truncating each
/// affected level back to before that block. The log is never touched, so
/// nothing is ever actually lost; the next nap computes the dropped blocks
/// again.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const text = core.text;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    _ = cfg; // forget drops; no size knob selects anything here
    if (argv.len != 1) output.die(ctx.io, common.gpaPrint(ctx, "usage: {s} forget <lo>-<hi>", .{ctx.me}));
    const b = core.blocks.parseId(argv[0]) catch |e| common.dieBlockId(ctx, argv[0], e);
    const gone = s.summaryDrop(ctx.gpa, ctx.io, b.lo, b.hi) catch |e|
        output.dieFs(ctx, common.treePath(ctx, b.size()), e);
    if (gone.len == 0) {
        output.die(ctx.io, common.gpaPrint(ctx, "No summary at {s}.", .{argv[0]}));
    }
    defer ctx.gpa.free(gone); // gone.len > 0 here: the empty case died above
    const n = text.plural(ctx.gpa, gone.len, "summary") catch output.dieOom(ctx);
    output.println(
        ctx.io,
        common.gpaPrint(ctx, "Forgot {s}, from {d}-{d} up. Run: {s} nap", .{ n, gone[0].lo, gone[0].hi - 1, ctx.me }),
    );
}
