/// The CLI: dispatch a command to its file. No command is the usage; an
/// unknown one is a refusal with the usage attached. init may run without a
/// store — it is the one that creates it; every other command opens the
/// store first, so a typo in MEMORY_DIR is an error instead of a second,
/// empty identity.
const std = @import("std");
pub const args = @import("args.zig");
pub const common = @import("common.zig");
pub const config_cmd = @import("commands/config.zig");
pub const context = @import("context.zig");
pub const export_optmem = @import("commands/export_optmem.zig");
pub const forget = @import("commands/forget.zig");
pub const import_cmd = @import("commands/import.zig");
pub const import_optmem = @import("commands/import_optmem.zig");
pub const init = @import("commands/init.zig");
pub const nap = @import("commands/nap.zig");
pub const note = @import("commands/note.zig");
pub const output = @import("output.zig");
pub const recall = @import("commands/recall.zig");
pub const wake = @import("commands/wake.zig");
pub const zoom = @import("commands/zoom.zig");

pub fn run(ctx: *const context.Context, argv: []const []const u8) void {
    if (argv.len == 0) {
        const u = output.usage(ctx.gpa, ctx.me) catch output.dieOom(ctx);
        output.println(ctx.io, u);
        std.process.exit(0);
    }
    const rest = argv[1..];
    const cmd = argv[0];
    if (std.mem.eql(u8, cmd, "init")) {
        init.run(ctx, rest);
    } else if (std.mem.eql(u8, cmd, "wake")) {
        withStore(ctx, rest, wake);
    } else if (std.mem.eql(u8, cmd, "note")) {
        withStore(ctx, rest, note);
    } else if (std.mem.eql(u8, cmd, "nap")) {
        withStore(ctx, rest, nap);
    } else if (std.mem.eql(u8, cmd, "recall")) {
        withStore(ctx, rest, recall);
    } else if (std.mem.eql(u8, cmd, "zoom")) {
        withStore(ctx, rest, zoom);
    } else if (std.mem.eql(u8, cmd, "forget")) {
        withStore(ctx, rest, forget);
    } else if (std.mem.eql(u8, cmd, "config")) {
        withStore(ctx, rest, config_cmd);
    } else if (std.mem.eql(u8, cmd, "import")) {
        withStore(ctx, rest, import_cmd);
    } else if (std.mem.eql(u8, cmd, "import-optmem")) {
        withStore(ctx, rest, import_optmem);
    } else if (std.mem.eql(u8, cmd, "export-optmem")) {
        withStore(ctx, rest, export_optmem);
    } else {
        const u = output.usage(ctx.gpa, ctx.me) catch output.dieOom(ctx);
        const msg = ctx.gpa.print("No such command: {s}\n\n{s}", .{ cmd, u }) catch output.dieOom(ctx);
        output.die(ctx.io, msg);
    }
}

/// The shape every store command shares: open the store, load its sizes,
/// run the command. The command's own argument parsing and rendering live
/// in its file.
fn withStore(ctx: *const context.Context, argv: []const []const u8, comptime Cmd: type) void {
    var store = common.openStore(ctx);
    defer store.close(ctx.io);
    const cfg = common.loadConfig(ctx, &store);
    Cmd.run(ctx, &store, &cfg, argv);
}
