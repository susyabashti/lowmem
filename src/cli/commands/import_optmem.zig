/// import-optmem: adopt an OptMem store — its memories and its summaries —
/// into this memory. The target must be empty: the carried summaries are
/// aligned to #0, and appending onto an existing log would set them adrift.
/// A source that cannot be read — missing, corrupt, non-chronological, or
/// empty — is refused before the store is touched. The source's size knobs
/// are not carried over: this memory keeps its own.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const text = core.text;
const blocks = core.blocks;
const nap = core.nap;
const optmem = core.optmem;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    _ = cfg; // the source's sizes are not this memory's
    if (argv.len != 1) output.die(
        ctx.io,
        common.gpaPrint(ctx, "usage: {s} import-optmem <dir>   # an OptMem store directory", .{ctx.me}),
    );
    const pretty = common.filePath(ctx, argv[0]);
    const src = std.Io.Dir.cwd().openDir(ctx.io, argv[0], .{}) catch |e| output.dieFs(ctx, pretty, store.Store.mapFs(e));
    defer std.Io.Dir.close(src, ctx.io);
    const r = optmem.readLog(src, ctx.io, ctx.gpa) catch |e| {
        output.dieFs(ctx, common.gpaPrint(ctx, "{s}/LOG.txt", .{pretty}), e);
    };
    switch (r) {
        .corrupt => |id| output.die(
            ctx.io,
            common.gpaPrint(
                ctx,
                "The OptMem log at {s} is corrupt at record #{d}; the import stopped before touching the store.",
                .{ pretty, id },
            ),
        ),
        .nonChronological => |id| output.die(
            ctx.io,
            common.gpaPrint(
                ctx,
                "The OptMem log at {s} goes backwards at record #{d}; the import stopped before touching the store.",
                .{ pretty, id },
            ),
        ),
        .ok => |mems| {
            if (mems.len == 0) output.die(ctx.io, common.gpaPrint(ctx, "{s} has no memories.", .{pretty}));
            const T: u64 = @intCast(mems.len);
            const base = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
            if (base > 0) output.die(
                ctx.io,
                common.gpaPrint(
                    ctx,
                    "This memory already holds {s}. import-optmem imports into an empty store: the carried summaries are aligned to #0.",
                    .{text.plural(ctx.gpa, base, "memory") catch output.dieOom(ctx)},
                ),
            );
            var news = std.ArrayListUnmanaged(store.Store.NewMemory).empty;
            defer news.deinit(ctx.gpa);
            for (mems) |m| {
                news.append(ctx.gpa, .{ .date = m.date, .text = m.text }) catch output.dieOom(ctx);
            }
            _ = s.append(ctx.gpa, ctx.io, news.items) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
            // Carry the summaries level by level, a dense prefix per level
            // (the readLevel rule): a gap the next nap fills, not a failure.
            var carried: u64 = 0;
            var size: u64 = 2;
            while (size <= T) : (size = blocks.nextLevel(size, T) orelse break) {
                const lv = optmem.readLevel(src, ctx.io, ctx.gpa, size) catch |e| {
                    output.dieFs(ctx, common.gpaPrint(ctx, "{s}/TREE/{d}", .{ pretty, size }), e);
                };
                if (lv) |texts| {
                    s.summaryAppend(ctx.gpa, ctx.io, size, texts) catch |e| output.dieFs(ctx, common.treePath(ctx, size), e);
                    carried += @intCast(texts.len);
                }
            }
            output.println(ctx.io, common.gpaPrint(ctx, "Imported {s}, #0 to #{d}.", .{ text.plural(ctx.gpa, T, "memory") catch output.dieOom(ctx), T - 1 }));
            if (carried > 0) {
                output.println(ctx.io, common.gpaPrint(ctx, "Carried {s}.", .{text.plural(ctx.gpa, carried, "summary") catch output.dieOom(ctx)}));
            }
            const pc = nap.pendingCount(s, ctx.gpa, ctx.io, T) catch |e| {
                if (e == store.Store.Error.CorruptRecord) output.dieFs(ctx, common.logPath(ctx), e);
                output.dieFs(ctx, ctx.store_dir_tilde, e);
            };
            if (pc > 0) {
                output.println(ctx.io, common.gpaPrint(ctx, "{s} pending. Run: {s} nap", .{ text.plural(ctx.gpa, pc, "compression") catch output.dieOom(ctx), ctx.me }));
            }
        },
    }
}
