/// What every store command shares: opening the store (or refusing),
/// reading the sizes, and the failure voices more than one command uses.
const std = @import("std");
const core = @import("core");
const context = @import("context.zig");
const output = @import("output.zig");

pub const store = core.store;
pub const config = core.config;
pub const entry = core.entry;
pub const blocks = core.blocks;

/// A message the process cannot build is an out-of-memory, said the way
/// every other failure is said.
pub fn gpaPrint(ctx: *const context.Context, comptime fmt: []const u8, args: anytype) []const u8 {
    return ctx.gpa.print(fmt, args) catch output.dieOom(ctx);
}

/// Every command but init: the store must already exist. Missing — or a
/// path that is not a directory, which the reference tool's isdir() also
/// reads as missing — is the tool's no-memory refusal; anything else is
/// said in the tool's voice.
pub fn openStore(ctx: *const context.Context) store.Store {
    return store.Store.open(ctx.io, ctx.store_dir) catch |e| {
        if (e == store.Store.Error.NotFound or e == store.Store.Error.NotDirectory) output.dieNoMemory(ctx);
        output.dieFs(ctx, ctx.store_dir, e);
    };
}

/// This memory's sizes, or the tool's defaults. A missing `config` file
/// means "follow the tool"; a malformed one stops the command, naming the
/// file and the line it is written on.
pub fn loadConfig(ctx: *const context.Context, s: *const store.Store) config.Config {
    var cfg = config.Config{};
    const content = s.dir.readFileAlloc(ctx.io, "config", ctx.gpa, std.Io.Limit.unlimited) catch |e| {
        if (e == error.FileNotFound) return cfg;
        output.dieFs(ctx, gpaPrint(ctx, "{s}/config", .{ctx.store_dir_tilde}), store.Store.mapFs(e));
    };
    var info = config.ParseInfo{};
    var keybuf: [128]u8 = undefined;
    config.parse(content, &cfg, &info, &keybuf) catch |err| switch (err) {
        config.ParseError.UnknownKnob => output.die(
            ctx.io,
            gpaPrint(ctx, "{s}/config line {d}: {s} is not a size. Delete the line, or name one of: WAKE_LINES, ENTRY_CHARS, PART_CHARS, PART_LINES.", .{ ctx.store_dir_tilde, info.line, info.knob }),
        ),
        config.ParseError.BadValue => output.die(
            ctx.io,
            gpaPrint(ctx, "{s}/config line {d}: {s} must be a positive whole number, not '{s}'.", .{ ctx.store_dir_tilde, info.line, info.knob, info.value }),
        ),
        config.ParseError.TooBig => output.die(
            ctx.io,
            gpaPrint(ctx, "{s}/config line {d}: ENTRY_CHARS is at most {d}: a memory has to fit the record.", .{ ctx.store_dir_tilde, info.line, config.ENTRY_CHARS_MAX }),
        ),
    };
    return cfg;
}

/// Validate one memory's text (spec 4.3) and hand back the trimmed slice;
/// a broken rule dies in the tool's voice. The result borrows from `text`.
pub fn checkEntry(ctx: *const context.Context, text: []const u8, entry_chars: u32) []const u8 {
    return entry.validate(text, entry_chars) catch |e| switch (e) {
        entry.Error.Empty => output.die(ctx.io, "Empty. A memory is one line of text."),
        entry.Error.MultiLine => output.die(
            ctx.io,
            gpaPrint(ctx, "{d} lines. A memory is one line: merge them, or note them separately.", .{entry.lineCount(text)}),
        ),
        entry.Error.TooLong => output.die(
            ctx.io,
            gpaPrint(ctx, "Too long: {d} bytes, limit {d}. Accented characters cost 2 bytes. Compress it further.", .{ entry.trim(text).len, entry_chars }),
        ),
    };
}

/// A block-id argument that did not parse, word for word (spec 5.3).
pub fn dieBlockId(ctx: *const context.Context, arg: []const u8, e: blocks.IdError) noreturn {
    switch (e) {
        blocks.IdError.NotId => output.die(
            ctx.io,
            gpaPrint(ctx, "'{s}' is not a block id. Copy it from the prompt.", .{arg}),
        ),
        blocks.IdError.NotBlock => output.die(
            ctx.io,
            gpaPrint(ctx, "{s} is not a block. Copy the id printed by wake, like 16-31.", .{arg}),
        ),
    }
}

/// A summary record that is blank: the one exit is forgetting the block.
pub fn dieBlankSummary(ctx: *const context.Context, lo: u64, hi: u64) noreturn {
    output.die(
        ctx.io,
        gpaPrint(ctx, "The summary of #{d}-{d} is blank. Run: {s} forget {d}-{d}", .{ lo, hi - 1, ctx.me, lo, hi - 1 }),
    );
}

/// A summary record that is not a summary at all (not even valid UTF-8):
/// the one exit is the same forget.
pub fn dieCorruptSummary(ctx: *const context.Context, lo: u64, hi: u64) noreturn {
    output.die(
        ctx.io,
        gpaPrint(ctx, "The summary of #{d}-{d} is corrupt. Run: {s} forget {d}-{d}", .{ lo, hi - 1, ctx.me, lo, hi - 1 }),
    );
}

/// The log file, as the user would type it.
pub fn logPath(ctx: *const context.Context) []const u8 {
    return gpaPrint(ctx, "{s}/LOG", .{ctx.store_dir_tilde});
}

/// A tree level file, as the user would type it.
pub fn treePath(ctx: *const context.Context, size: u64) []const u8 {
    return gpaPrint(ctx, "{s}/TREE/{d}", .{ ctx.store_dir_tilde, size });
}

/// A file argument, absolute and $HOME-folded: the way the tool names it in
/// an error (the reference tool reports the resolved path, not the typed
/// one).
pub fn filePath(ctx: *const context.Context, p: []const u8) []const u8 {
    const abs = if (std.fs.path.isAbsolute(p)) p else blk: {
        const cwd = std.process.currentPathAlloc(ctx.io, ctx.gpa) catch output.dieOom(ctx);
        break :blk gpaPrint(ctx, "{s}/{s}", .{ cwd, p });
    };
    return context.Context.tilde(ctx.gpa, abs, ctx.home) catch output.dieOom(ctx);
}
