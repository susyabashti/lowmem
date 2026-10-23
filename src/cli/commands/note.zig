/// note: record one memory. The text is validated like every other entry,
/// dated with today's local date, and appended under the lock — so the id
/// it prints is the one that was assigned, whatever else wrote meanwhile.
/// A nap due after the append follows on a blank line.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    if (argv.len != 1) output.die(
        ctx.io,
        common.gpaPrint(ctx, "usage: {s} note \"<one line, at most {d} bytes>\"", .{ ctx.me, cfg.entry_chars }),
    );
    const text = common.checkEntry(ctx, argv[0], cfg.entry_chars);
    const d = core.date.today(ctx.io) catch output.die(ctx.io, "cannot determine today's date.");
    const item = store.Store.NewMemory{ .date = d, .text = text };
    const items = [_]store.Store.NewMemory{item};
    const id = s.append(ctx.gpa, ctx.io, &items) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    output.println(ctx.io, common.gpaPrint(ctx, "Saved as #{d}.", .{id}));
    const r = core.nap.nextNap(s, ctx.gpa, ctx.io, id + 1, ctx.me, cfg.entry_chars) catch |e| {
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
