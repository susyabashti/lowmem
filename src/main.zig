/// The entry: build the per-process context, hand the arguments to the
/// dispatcher. Nothing else lives here.
const std = @import("std");
const cli = @import("cli");

pub fn main(init: std.process.Init) void {
    const ctx = cli.context.Context.make(init) catch std.process.exit(1);
    // toSlice includes the program name; the dispatcher starts at the
    // command.
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(1);
    cli.run(&ctx, argv[1..]);
}
