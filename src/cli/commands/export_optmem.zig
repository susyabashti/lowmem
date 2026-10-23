/// export-optmem: write this memory as an OptMem store — the fixed-width
/// LOG.txt and one TREE file per level that carries a summary — into a new
/// or empty directory. All-or-nothing: a record that cannot fit the fixed
/// width refuses the whole export before the first byte. The size knobs are
/// not carried over; the new store follows the OptMem defaults.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const text = core.text;
const optmem = core.optmem;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    if (argv.len != 1) output.die(
        ctx.io,
        common.gpaPrint(ctx, "usage: {s} export-optmem <dir>   # write this memory as an OptMem store", .{ctx.me}),
    );
    const pretty = common.filePath(ctx, argv[0]);
    // A new or existing directory; missing is created, a file is refused.
    const out = std.Io.Dir.cwd().openDir(ctx.io, argv[0], .{}) catch |e| switch (store.Store.mapFs(e)) {
        error.NotFound => blk: {
            std.Io.Dir.cwd().createDirPath(ctx.io, argv[0]) catch |e2| output.dieFs(ctx, pretty, store.Store.mapFs(e2));
            break :blk std.Io.Dir.cwd().openDir(ctx.io, argv[0], .{}) catch |e2| output.dieFs(ctx, pretty, store.Store.mapFs(e2));
        },
        else => |err| output.dieFs(ctx, pretty, err),
    };
    defer std.Io.Dir.close(out, ctx.io);
    // An export must not mix with an existing OptMem store.
    const has_log: bool = blk: {
        _ = out.openFile(ctx.io, "LOG.txt", .{ .mode = .read_only }) catch |e| switch (store.Store.mapFs(e)) {
            error.NotFound => break :blk false,
            else => |err| output.dieFs(ctx, pretty, err),
        };
        break :blk true;
    };
    if (has_log) {
        output.die(ctx.io, common.gpaPrint(ctx, "{s} already has a LOG.txt: export to an empty or new directory.", .{pretty}));
    }
    const T = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    const r = optmem.exportStore(s, ctx.io, ctx.gpa, out) catch |e| output.dieFs(ctx, pretty, e);
    switch (r) {
        .memoryTooLong => |x| output.die(
            ctx.io,
            common.gpaPrint(ctx, "Cannot export: memory #{d} is {d} bytes; an OptMem record holds {d}.", .{ x.id, x.len, optmem.LOG_PAYLOAD }),
        ),
        .summaryTooLong => |x| output.die(
            ctx.io,
            common.gpaPrint(ctx, "Cannot export: the summary of #{d}-{d} is {d} bytes; an OptMem record holds {d}.", .{ x.lo, x.hi - 1, x.len, optmem.TREE_PAYLOAD }),
        ),
        .done => |m| {
            output.println(
                ctx.io,
                common.gpaPrint(ctx, "Exported {s} and {s} to {s}.", .{
                    text.plural(ctx.gpa, T, "memory") catch output.dieOom(ctx),
                    text.plural(ctx.gpa, m, "summary") catch output.dieOom(ctx),
                    pretty,
                }),
            );
            if (cfg.isSet(0) or cfg.isSet(1) or cfg.isSet(2) or cfg.isSet(3)) {
                output.println(ctx.io, "The size knobs were not carried over: the new store follows the OptMem defaults.");
            }
        },
    }
}
