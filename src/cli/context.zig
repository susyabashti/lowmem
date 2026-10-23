/// The per-process context every command runs with: the I/O backend, the
/// general allocator, and the two strings the tool's voice embeds — its
/// own path and the store directory. Both are resolved once here, so the
/// commands print paths that run as printed (spec: self-naming).
const std = @import("std");

pub const Error = std.mem.Allocator.Error ||
    std.process.ExecutablePathAllocError ||
    std.process.CurrentPathAllocError;

pub const Context = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// The running binary, absolute, with $HOME folded to ~.
    me: []const u8,
    /// The store directory, absolute and expanded ($MEMORY_DIR, or
    /// $HOME/.lowmem/memory). Used for I/O and in messages that must show
    /// the path as it is on disk.
    store_dir: []const u8,
    /// The same directory with $HOME folded to ~, for messages.
    store_dir_tilde: []const u8,
    /// $HOME, for folding other paths the tool names (import's file).
    home: ?[]const u8,

    /// Resolve the context from the process init. Everything it allocates
    /// goes to the process arena: it lives until exit and is freed with it.
    /// `gpa` is the arena too — every command allocates one-shot print
    /// strings and file reads it never frees individually (an arena free is
    /// a no-op; the leak-checking debug gpa would flag them all).
    pub fn make(init: std.process.Init) Error!Context {
        const arena = init.arena.allocator();
        const abs = try std.process.executablePathAlloc(init.io, arena);
        const home = init.environ_map.get("HOME");
        const me = try tilde(arena, abs, home);
        const dir = try storeDir(init.io, arena, init.environ_map);
        const dir_tilde = try tilde(arena, dir, home);
        return .{ .io = init.io, .gpa = arena, .me = me, .store_dir = dir, .store_dir_tilde = dir_tilde, .home = home };
    }

    /// $MEMORY_DIR if set and non-empty, else $HOME/.lowmem/memory. A
    /// leading ~ is expanded against $HOME (a missing $HOME keeps the ~),
    /// and a relative result is anchored at the working directory, so
    /// every downstream path is absolute.
    fn storeDir(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map) Error![]const u8 {
        const raw = blk: {
            if (env.get("MEMORY_DIR")) |v| {
                if (v.len > 0) break :blk v;
            }
            break :blk "~/.lowmem/memory";
        };
        const expanded = try blk: {
            if (std.mem.startsWith(u8, raw, "~")) {
                const home = env.get("HOME") orelse return arena.dupe(u8, raw);
                break :blk arena.print("{s}{s}", .{ home, raw[1..] });
            }
            break :blk arena.dupe(u8, raw);
        };
        if (std.fs.path.isAbsolute(expanded)) return expanded;
        const cwd = try std.process.currentPathAlloc(io, arena);
        return arena.print("{s}/{s}", .{ cwd, expanded });
    }

    /// $HOME folded to ~, the way the user would type the path: symlinks
    /// kept, a leading $HOME/ rewritten to ~/.
    pub fn tilde(arena: std.mem.Allocator, p: []const u8, home: ?[]const u8) std.mem.Allocator.Error![]const u8 {
        if (home) |h| {
            if (p.len > h.len + 1 and std.mem.startsWith(u8, p, h) and p[h.len] == '/') {
                return arena.print("~/{s}", .{p[h.len + 1 ..]});
            }
        }
        return arena.dupe(u8, p);
    }
};

test "storeDir: the documented resolution" {
    // A missing HOME must not break the resolution: the ~ stays.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const dir = try Context.storeDir(std.testing.io, std.testing.allocator, &env);
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("~/.lowmem/memory", dir);
}

test "tilde folds only a whole home prefix" {
    const gpa = std.testing.allocator;
    const p1 = try Context.tilde(gpa, "/home/u/bin/lowmem", "/home/u");
    defer gpa.free(p1);
    try std.testing.expectEqualStrings("~/bin/lowmem", p1);
    const p2 = try Context.tilde(gpa, "/home/ux/bin/lowmem", "/home/u");
    defer gpa.free(p2);
    try std.testing.expectEqualStrings("/home/ux/bin/lowmem", p2);
    const p3 = try Context.tilde(gpa, "/home/u/bin/lowmem", null);
    defer gpa.free(p3);
    try std.testing.expectEqualStrings("/home/u/bin/lowmem", p3);
}
