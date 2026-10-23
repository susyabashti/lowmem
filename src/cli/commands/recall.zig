/// recall: search every memory ever recorded. One streaming pass over the
/// whole log — a search reads the log by nature, but it must not hold it —
/// keeping only the newest matches that fit PART_CHARS: a vague regex
/// matches the whole log, and the whole log does not fit in a harness's
/// output or in memory. A memory matches if the pattern is found anywhere
/// in its full line, id and date included.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const text = core.text;

/// The front of the match window is dropped by index, not by shift: the
/// window is capped at PART_CHARS bytes, so the shift is rare and bounded.
const SHIFT_AT = 1024;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    if (argv.len != 1) output.die(ctx.io, common.gpaPrint(ctx, "usage: {s} recall <regex>", .{ctx.me}));
    const pat = core.regex.Pattern.compile(argv[0]);
    var sc = store.Store.Scanner.init(s, ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
    defer sc.deinit(ctx.io);
    const cap: usize = @intCast(cfg.part_chars);
    var hits: u64 = 0;
    var kept = std.ArrayListUnmanaged([]const u8).empty;
    var front: usize = 0;
    var size: usize = 0;
    while (true) {
        const nx = sc.next(ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
        switch (nx) {
            .eof => break,
            .mem => |m| {
                const line = common.gpaPrint(ctx, "#{d} {s}", .{ m.id, m.line });
                if (!pat.search(line)) {
                    ctx.gpa.free(line);
                    continue;
                }
                hits += 1;
                kept.append(ctx.gpa, line) catch output.dieOom(ctx);
                size += line.len + 1;
                while (size > cap) {
                    const old = kept.items[front];
                    ctx.gpa.free(old);
                    size -= old.len + 1;
                    front += 1;
                    if (front == SHIFT_AT) {
                        // dst starts before src: a forwards copy is safe.
                        std.mem.copyForwards([]const u8, kept.items[0..], kept.items[front..]);
                        kept.items.len -= front;
                        front = 0;
                    }
                }
            },
        }
    }
    if (hits == 0) {
        output.println(ctx.io, "No match.");
        return;
    }
    const kept_n: u64 = @intCast(kept.items.len - front);
    if (kept_n == 0) {
        // The cap held less than one line: the reference joins an empty
        // window and prints the blank line the join leaves behind.
        output.println(ctx.io, "");
    } else {
        for (kept.items[front..]) |line| output.println(ctx.io, line);
    }
    const all = text.plural(ctx.gpa, hits, "match") catch output.dieOom(ctx);
    if (kept_n < hits) {
        output.println(ctx.io, common.gpaPrint(ctx, "Newest {d} of {s}. Narrow the regex.", .{ kept_n, all }));
    } else {
        output.println(ctx.io, common.gpaPrint(ctx, "{s}.", .{all}));
    }
}
