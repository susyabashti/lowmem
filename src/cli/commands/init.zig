/// init: the one command that may create the store. It creates whatever is
/// missing — the directory, TREE/, an empty LOG, and a config with the
/// defaults — and rewrites nothing that is there, so re-running it on a
/// lived-in store changes no byte of it.
const std = @import("std");
const core = @import("core");
const common = @import("../common.zig");
const context = @import("../context.zig");
const output = @import("../output.zig");

const store = core.store;
const config = core.config;
const text = core.text;

pub fn run(ctx: *const context.Context, argv: []const []const u8) void {
    if (argv.len != 0) output.die(ctx.io, common.gpaPrint(ctx, "usage: {s} init", .{ctx.me}));
    // "Created" names the act: the directory was absent before this init.
    // An existing directory (even an empty one) is a found store.
    const existed = store.Store.isDir(ctx.io, ctx.store_dir) catch |e| output.dieFs(ctx, ctx.store_dir, e);
    var s = store.Store.create(ctx.io, ctx.store_dir) catch |e| output.dieFs(ctx, ctx.store_dir, e);
    defer s.close(ctx.io);
    // The config is written only when absent: a memory that set its sizes
    // keeps them across re-inits.
    const have = s.dir.statFile(ctx.io, "config", .{}) catch |e| switch (e) {
        error.FileNotFound => null,
        else => output.dieFs(ctx, common.gpaPrint(ctx, "{s}/config", .{ctx.store_dir_tilde}), store.Store.mapFs(e)),
    };
    if (have == null) {
        const file = config.renderFile(ctx.gpa, ctx.me, &config.Config{}) catch output.dieOom(ctx);
        defer ctx.gpa.free(file);
        s.dir.writeFile(ctx.io, .{ .sub_path = "config", .data = file, .flags = .{ .truncate = true } }) catch |e|
            output.dieFs(ctx, common.gpaPrint(ctx, "{s}/config", .{ctx.store_dir_tilde}), store.Store.mapFs(e));
    }
    // A malformed config stops init too: it would stop every other command,
    // and creating a store that cannot wake is not creating a memory.
    const cfg = common.loadConfig(ctx, &s);
    if (existed) {
        const t = s.count(ctx.gpa, ctx.io) catch |e| output.dieFs(ctx, common.logPath(ctx), e);
        const n = text.plural(ctx.gpa, t, "memory") catch output.dieOom(ctx);
        output.println(ctx.io, common.gpaPrint(ctx, "Found {s}: {s}.", .{ ctx.store_dir_tilde, n }));
    } else {
        output.println(
            ctx.io,
            common.gpaPrint(ctx, "Created {s}: this machine's memory, one identity, forever.", .{ctx.store_dir_tilde}),
        );
    }
    output.println(ctx.io, common.gpaPrint(ctx, "Sizes live in {s}/config; the defaults are fine.", .{ctx.store_dir_tilde}));
    output.println(ctx.io, "");
    output.println(ctx.io, "Paste this at the top of your agent's AGENTS.md (or CLAUDE.md), done:");
    output.println(ctx.io, "");
    output.println(ctx.io, template(ctx, &cfg));
}

/// The setup block the user pastes into their agent's instruction file.
/// The reference tool's block, LowMem-named: the tool is `lowmem`, the
/// memory is LowMem, and a subagent is told not to run `lowmem`.
fn template(ctx: *const context.Context, cfg: *const config.Config) []const u8 {
    return common.gpaPrint(
        ctx,
        \\## Memory
        \\
        \\Your memory is LowMem:
        \\- The tool is `{s}`
        \\- Your memories are in `{s}`
        \\
        \\LowMem outlives every session, compaction, model and vendor change.
        \\Without it you do not know who you are, or what was decided and tried.
        \\
        \\### At startup: activating LowMem (mandatory)
        \\
        \\Run `{s} wake` before any other tool call, in every session, and
        \\then do exactly what it prints, to the end of its output.
        \\
        \\### While working: register memories (mandatory)
        \\
        \\Call `{s} note "<1 line, max {d} bytes>"` whenever you learn
        \\something new, or something worth keeping happens. That covers a task
        \\worth real effort, a fact or insight the user teaches you, anything you
        \\learn about their life (even indirectly), any event of lasting effect.
        \\
        \\Do not register redundant memories.
        \\
        \\If `{s} note` asks a compression: do it before your next action.
        \\
        \\Never edit or delete anything under `{s}`: the tool manages it.
        \\
        \\### When you need an old memory: search, or navigate
        \\
        \\`{s} recall <regex>` searches every memory, word for word.
        \\
        \\Your memories also form a binary tree: #0-1, #2-3 ... exist as one-line
        \\summaries, pairs of those as #0-3, and so on -- every `#a-b` line wake
        \\prints is one node of it. `{s} zoom <a-b>` opens a node into its
        \\two halves, down to the raw memories.
        \\
        \\### If you're a subagent: skip everything above
        \\
        \\Parallel sessions on this machine are all you, and may all write memories.
        \\A subagent is not: it must never run `lowmem`, because it cannot judge what
        \\is already known, and its notes would arrive duplicated and incorrectly.
        \\When you spawn one, write: `You are a subagent. Don't run lowmem.`
    ,
        .{
            ctx.me,
            ctx.store_dir_tilde,
            ctx.me,
            ctx.me,
            cfg.entry_chars,
            ctx.me,
            ctx.store_dir_tilde,
            ctx.me,
            ctx.me,
        },
    );
}
