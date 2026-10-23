/// LowMem core: the memory tree and its storage, with no CLI knowledge.
///
/// This file re-exports every core module so the CLI imports one name
/// (`core`) and never reaches into the files. The layering gate
/// (test/structure.py) keeps it one-way: nothing here imports the CLI, and
/// nothing here prints.
pub const blocks = @import("core/blocks.zig");
pub const config = @import("core/config.zig");
pub const cover = @import("core/cover.zig");
pub const date = @import("core/date.zig");
pub const entry = @import("core/entry.zig");
pub const ingest = @import("core/ingest.zig");
pub const nap = @import("core/nap.zig");
pub const optmem = @import("core/optmem.zig");
pub const regex = @import("core/regex.zig");
pub const store = @import("core/store.zig");
pub const text = @import("core/text.zig");
