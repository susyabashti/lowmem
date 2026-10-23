/// The tool's voice: every line it prints, and how a failure is said.
///
/// stdout carries the tool's documents; stderr carries its failures, one
/// human-readable line, exit 1. Filesystem errors are said in the tool's
/// voice too — `<path>: <errno message>.` — never as a stack trace or a
/// panic dump (spec: errors).
const std = @import("std");
const core = @import("core");
const context = @import("context.zig");

/// One line of the document. `msg` must not end in a newline; an empty
/// msg is a blank line. (The reference tool's print: every call ends the
/// line, and a multi-line document is one call per line.)
pub fn println(io: std.Io, msg: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {
        // A broken stdout is not recoverable; there is nothing left to say.
        std.process.exit(1);
    };
    std.Io.File.stdout().writeStreamingAll(io, "\n") catch {
        std.process.exit(1);
    };
}

/// The process could not pay for its own message.
pub fn dieOom(ctx: *const context.Context) noreturn {
    die(ctx.io, "Out of memory.");
}

/// One failure line to stderr, exit 1. `msg` must not end in a newline.
pub fn die(io: std.Io, msg: []const u8) noreturn {
    _ = std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    _ = std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    std.process.exit(1);
}

/// The usage block, as the no-arg run and the unknown-command error print
/// it. The caller owns the result (free it with the same allocator).
pub fn usage(gpa: std.mem.Allocator, me: []const u8) std.mem.Allocator.Error![]u8 {
    return gpa.print(
        \\LowMem: a permanent, append-only memory for AI agents.
        \\
        \\  {s} init             create this memory; print the setup block.
        \\  {s} wake [part [T]]  read your memory. Run first, every session.
        \\  {s} note "..."       record one memory: one short line.
        \\  {s} nap [id "..."]   do the pending compressions.
        \\  {s} recall <regex>   search every memory ever recorded.
        \\  {s} zoom <lo>-<hi>   open a tree node: its two halves.
        \\  {s} forget <lo>-<hi> drop a bad summary; nap rebuilds it.
        \\  {s} config [NAME=N]  show this memory's sizes, or change one.
        \\  {s} import <file>    bulk-load dated memories (bootstrap only).
        \\  {s} import-optmem <dir>    import an OptMem store: memories and summaries.
        \\  {s} export-optmem <dir>    write this memory as an OptMem store.
        \\
        \\The memories live in ~/.lowmem/memory, or in $MEMORY_DIR if set.
    ,
        .{ me, me, me, me, me, me, me, me, me, me, me },
    );
}

/// The no-store error, word for word: the directory as it is (not the
/// tilde form), and the tool's own path in the offered command.
pub fn dieNoMemory(ctx: *const context.Context) noreturn {
    const msg = ctx.gpa.print(
        "No memory at {s}.\nTo create one, run: {s} init\nTo use an existing one, point MEMORY_DIR at it.",
        .{ ctx.store_dir, ctx.me },
    ) catch {
        std.process.exit(1);
    };
    die(ctx.io, msg);
}

/// A filesystem failure, in the tool's voice: `<path>: <errno message>.`
/// `path` is the file that failed, as the user would type it.
pub fn dieFs(ctx: *const context.Context, path: []const u8, e: core.store.Store.Error) noreturn {
    const msg = ctx.gpa.print("{s}: {s}.", .{ path, fsText(e) }) catch {
        std.process.exit(1);
    };
    die(ctx.io, msg);
}

/// The errno text behind a store error, the way the filesystem says it.
pub fn fsText(e: core.store.Store.Error) []const u8 {
    return switch (e) {
        error.NotFound => "No such file or directory",
        error.NotDirectory => "Not a directory",
        error.PermissionDenied, error.AccessDenied => "Permission denied",
        error.NoSpace => "No space left on device",
        error.AlreadyExists => "File exists",
        error.IsDirectory => "Is a directory",
        error.ReadOnly => "Read-only file system",
        error.PathTooLong => "Name too long",
        error.IoError => "I/O error",
        error.OutOfMemory => "Out of memory",
        // Not filesystem failures; they reach the voice only if a command
        // mis-maps them, so the text says what they are.
        error.CorruptRecord => "corrupt record",
        error.TooLong => "too long",
    };
}
