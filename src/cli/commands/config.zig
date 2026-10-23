/// config: show this memory's sizes, or change one. A size is a *reading*
/// budget: it selects what gets printed, so changing one is free — no
/// memory is touched and nothing is recomputed. An empty value restores
/// the tool's default.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const entry = core.entry;

pub fn run(ctx: *const context.Context, s: *const store.Store, cfg: *const config.Config, argv: []const []const u8) void {
    var c = cfg.*; // a mutable copy: the command rewrites the file from it
    for (argv) |a| {
        const eq = std.mem.findScalarPos(u8, a, 0, '=') orelse usage(ctx);
        var keybuf: [128]u8 = undefined;
        const k = knobKey(a[0..eq], &keybuf);
        const idx = config.Config.knobIndex(k) orelse usage(ctx);
        const v = entry.trim(a[eq + 1 ..]);
        if (v.len != 0) {
            var val: u64 = 0;
            var ok = true;
            for (v) |ch| {
                if (ch < '0' or ch > '9') {
                    ok = false;
                    break;
                }
                const d: u64 = ch - '0';
                if (val > (std.math.maxInt(u64) - d) / 10) {
                    ok = false;
                    break;
                }
                val = val * 10 + d;
            }
            if (!ok or val < 1) {
                output.die(
                    ctx.io,
                    common.gpaPrint(ctx, "{s} must be a positive whole number, not '{s}'.", .{ config.KNOBS[idx].name, v }),
                );
            }
            if (idx == 1 and val > config.ENTRY_CHARS_MAX) {
                output.die(
                    ctx.io,
                    common.gpaPrint(ctx, "ENTRY_CHARS is at most {d}: a memory has to fit the record.", .{config.ENTRY_CHARS_MAX}),
                );
            }
            c.setValue(idx, val, true);
        } else {
            c.setValue(idx, config.KNOBS[idx].def, false);
        }
    }
    if (argv.len != 0) {
        const file = config.renderFile(ctx.gpa, ctx.me, &c) catch output.dieOom(ctx);
        defer ctx.gpa.free(file);
        s.dir.writeFile(ctx.io, .{ .sub_path = "config", .data = file, .flags = .{ .truncate = true } }) catch |e|
            output.dieFs(ctx, common.gpaPrint(ctx, "{s}/config", .{ctx.store_dir_tilde}), store.Store.mapFs(e));
    }
    for (config.KNOBS, 0..) |knob, i| {
        const ann = if (c.isSet(i)) common.gpaPrint(ctx, " (default {d})", .{knob.def}) else "";
        output.println(
            ctx.io,
            common.gpaPrint(ctx, "{s:<12} {d:<7} {s}{s}", .{ knob.name, c.value(i), knob.what, ann }),
        );
    }
}

fn usage(ctx: *const context.Context) noreturn {
    output.die(
        ctx.io,
        common.gpaPrint(ctx, "usage: {s} config [NAME=VALUE ...]   # NAME one of WAKE_LINES, ENTRY_CHARS, PART_CHARS, PART_LINES", .{ctx.me}),
    );
}

/// The knob name, trimmed and upper-cased (ASCII: knob names are ASCII, and
/// a non-ASCII name is not a knob either way).
fn knobKey(a: []const u8, buf: *[128]u8) []const u8 {
    const t = entry.trim(a);
    if (t.len > 128) return t;
    for (t, 0..) |ch, i| {
        buf[i] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
    }
    return buf[0..t.len];
}
