/// import: bulk-append historical memories, one `YYYY-MM-DD <text>` per
/// line, for bootstrapping an identity from older records. Parsing is
/// all-or-nothing — the first failing line stops the whole import and names
/// the line — and the append happens under the lock as one batch, so a
/// failed import leaves the store exactly as it was.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const text = core.text;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    if (argv.len != 1) output.die(
        ctx.io,
        common.gpaPrint(ctx, "usage: {s} import <file>   # lines of 'YYYY-MM-DD <text>'", .{ctx.me}),
    );
    const pretty = common.filePath(ctx, argv[0]);
    const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, argv[0], ctx.gpa, std.Io.Limit.unlimited) catch |e|
        output.dieFs(ctx, pretty, store.Store.mapFs(e));
    if (!std.unicode.utf8ValidateSlice(content)) {
        output.die(
            ctx.io,
            common.gpaPrint(ctx, "{s} is not UTF-8 text. Convert it, then import again.", .{pretty}),
        );
    }
    const T = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    var last: [10]u8 = undefined;
    if (T > 0) {
        const m = s.get(ctx.gpa, ctx.io, T - 1) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
        defer ctx.gpa.free(m.text);
        @memcpy(&last, &m.date);
    } else {
        @memcpy(&last, "0000-00-00");
    }
    const lines = splitLines(ctx, content);
    defer ctx.gpa.free(lines);
    const r = core.ingest.parse(ctx.gpa, lines, cfg.entry_chars, last) catch output.dieOom(ctx);
    switch (r) {
        .badShape => |e| output.die(
            ctx.io,
            common.gpaPrint(ctx, "line {d}: expected 'YYYY-MM-DD <text>', got: {s}", .{ e.line, e.text }),
        ),
        .notRealDate => |e| output.die(
            ctx.io,
            common.gpaPrint(ctx, "line {d}: {s} is not a real date.", .{ e.line, &e.date }),
        ),
        .precedes => |e| output.die(
            ctx.io,
            common.gpaPrint(ctx, "line {d}: date {s} precedes the previous memory ({s}).", .{ e.line, &e.date, &e.last }),
        ),
        .tooLong => |e| output.die(
            ctx.io,
            common.gpaPrint(ctx, "line {d}: {d} bytes, limit {d}.", .{ e.line, e.bytes, cfg.entry_chars }),
        ),
        .ok => |items| {
            if (items.len == 0) {
                output.die(ctx.io, common.gpaPrint(ctx, "{s} has no memories.", .{argv[0]}));
            }
            defer ctx.gpa.free(items); // items.len > 0 here: the empty case died above
            var news = std.ArrayListUnmanaged(store.Store.NewMemory).empty;
            defer news.deinit(ctx.gpa);
            for (items) |it| {
                news.append(ctx.gpa, .{ .date = it.date, .text = it.text }) catch output.dieOom(ctx);
            }
            const base = s.append(ctx.gpa, ctx.io, news.items) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
            const n = text.plural(ctx.gpa, items.len, "memory") catch output.dieOom(ctx);
            output.println(
                ctx.io,
                common.gpaPrint(ctx, "Imported {s}, #{d} to #{d}.", .{ n, base, base + items.len - 1 }),
            );
            const pc = core.nap.pendingCount(s, ctx.gpa, ctx.io, T + items.len) catch |e| {
                if (e == store.Store.Error.CorruptRecord) output.dieFs(ctx, common.logPath(ctx), e);
                output.dieFs(ctx, ctx.store_dir_tilde, e);
            };
            if (pc > 0) {
                const ps = text.plural(ctx.gpa, pc, "compression") catch output.dieOom(ctx);
                output.println(ctx.io, common.gpaPrint(ctx, "{s} pending. Run: {s} nap", .{ ps, ctx.me }));
            }
        },
    }
}

/// The file's lines, newlines removed (a trailing newline does not start a
/// new line), as slices into `content`. The slice array is gpa-allocated;
/// the line slices borrow from the file bytes, which must outlive the
/// import.
fn splitLines(ctx: *const context.Context, content: []const u8) []const []const u8 {
    var n: usize = 1;
    for (content) |c| {
        if (c == '\n') n += 1;
    }
    var lines = ctx.gpa.alloc([]const u8, n) catch output.dieOom(ctx);
    errdefer ctx.gpa.free(lines);
    var start: usize = 0;
    var li: usize = 0;
    for (content, 0..) |c, i| {
        if (c != '\n') continue;
        lines[li] = content[start..i];
        li += 1;
        start = i + 1;
    }
    lines[li] = content[start..];
    return lines;
}
