/// The storage layer: an append-only raw memory log, a compact binary
/// offset index, and the summary tree (one file per level, each with its
/// own index). The log is the single source of truth; the indexes and the
/// tree are derived caches. The CLI and the tree logic (cover/pending/nap)
/// depend only on this interface (ADR 0001).
///
/// Record format: newline-terminated variable-length lines.
///
///   LOG            "YYYY-MM-DD <text>\n" per memory (the id is the line's
///                  ordinal, so the line carries no id of its own)
///   INDEX          u32 magic | u32 version | u64 count | u64 log_size |
///                  u64 offsets[count]          (little-endian)
///   TREE/<size>    "<summary>\n" per built block of that size, a dense
///                  prefix: block k is the k-th record
///   TREE/<size>.idx  same 24-byte header + offset prefix as INDEX
///
/// A line is at most 65 535 bytes including its newline. A healthy file
/// ends on a newline; a mid-write crash leaves a final unterminated line,
/// which the next mutation truncates and which no reader counts, so a torn
/// write is never acknowledged as a memory.
const std = @import("std");
const blocks = @import("blocks.zig");
const date = @import("date.zig");

const mem = std.mem;

pub const INDEX_MAGIC: u32 = 0x4C4F4D31; // "LOM1"
pub const INDEX_VERSION: u32 = 1;
pub const INDEX_HDR: u64 = 24;
/// The ceiling for one line, newline included.
pub const LINE_MAX: u64 = 65535;

const LOG_NAME = "LOG";
const INDEX_NAME = "INDEX";
const LOCK_NAME = ".lock";
const TREE_PREFIX = "TREE/";

pub const Store = struct {
    dir: std.Io.Dir,
    /// Absolute path of the store directory, kept for error messages. Must
    /// outlive the store.
    root: []const u8,

    pub const NewMemory = struct {
        date: [10]u8,
        text: []const u8,
    };

    pub const Memory = struct {
        id: u64,
        date: [10]u8,
        text: []const u8,
    };

    pub const MemSlice = struct {
        mems: []Memory,
        gpa: std.mem.Allocator,

        /// Frees each text and the array. The slice itself is never
        /// mutated, so it may be const.
        pub fn deinit(self: *const MemSlice) void {
            for (self.mems) |m| self.gpa.free(m.text);
            self.gpa.free(self.mems);
        }
    };

    /// The summary of a block, in three states. `missing` is the common
    /// case: the level simply has not reached the block yet, so it is
    /// pending work, not damage. `blank` is a record that exists but
    /// carries no text: the one exit for it is `forget <lo>-<hi-1>`.
    pub const Summary = union(enum) {
        missing: void,
        blank: void,
        /// The summary text, newline excluded. The caller owns the bytes
        /// and frees them with the allocator it passed to summaryGet.
        text: []const u8,
    };

    /// The outcome of summaryPut.
    pub const PutResult = enum {
        /// The summary was written as the level's next record.
        appended,
        /// The level was not at this block: it is ahead (settled) or behind
        /// (forgotten). The caller decides which message that is.
        notNext,
    };

    pub const Error = error{
        /// The file, or the store directory, does not exist.
        NotFound,
        NotDirectory,
        PermissionDenied,
        AccessDenied,
        NoSpace,
        AlreadyExists,
        IsDirectory,
        ReadOnly,
        /// A path longer than the filesystem's limit (the in-memory
        /// buffers that hold one are finite).
        PathTooLong,
        /// A filesystem failure with no name of its own.
        IoError,
        /// A line that is not what the store promises: over the ceiling,
        /// missing its date shape, or not UTF-8.
        CorruptRecord,
        /// A write that would exceed the record ceiling.
        TooLong,
    } || std.mem.Allocator.Error;

    // ---------------------------------------------------------------- open

    /// `init`: the one path that may create the store. Creates whatever is
    /// missing — the directory itself (and its ancestors, for a nested
    /// MEMORY_DIR), TREE/, and an empty LOG — and rewrites nothing that is
    /// there.
    pub fn create(io: std.Io, root: []const u8) Error!Store {
        std.Io.Dir.cwd().createDirPath(io, root) catch |e| return mapFs(e);
        return open(io, root);
    }

    /// Every other command: the store directory must already exist (a
    /// missing one is not an empty store; it is a second identity). The
    /// parts the tool needs — TREE/ and LOG — are created when absent: a
    /// hand-made store directory may lack them, and that is not the
    /// command's problem.
    pub fn open(io: std.Io, root: []const u8) Error!Store {
        const dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch |e| return mapFs(e);
        errdefer std.Io.Dir.close(dir, io);
        std.Io.Dir.createDirPath(dir, io, "TREE") catch |e| return mapFs(e);
        const log = dir.createFile(io, "LOG", .{ .truncate = false }) catch |e| return mapFs(e);
        std.Io.File.close(log, io);
        return .{ .dir = dir, .root = root };
    }

    /// True when `root` exists as a directory (a symlink to one counts).
    pub fn isDir(io: std.Io, root: []const u8) Error!bool {
        const st = std.Io.Dir.cwd().statFile(io, root, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return mapFs(e),
        };
        return st.kind == .directory;
    }

    pub fn close(self: *const Store, io: std.Io) void {
        std.Io.Dir.close(self.dir, io);
    }

    // ---------------------------------------------------------------- read

    /// The log's record count — the snapshot T. A torn trailing line (a
    /// crash, or a writer between line and newline) is not counted, so T
    /// never names a memory that is not whole.
    pub fn count(self: *const Store, gpa: std.mem.Allocator, io: std.Io) Error!u64 {
        const v = try self.logView(gpa, io);
        defer v.deinit();
        return v.count();
    }

    /// Memory `id`, in one positional read. The caller owns `text` (free it
    /// with the allocator).
    pub fn get(self: *const Store, gpa: std.mem.Allocator, io: std.Io, id: u64) Error!Memory {
        const v = try self.logView(gpa, io);
        defer v.deinit();
        const line = try v.readLine(gpa, io, id);
        if (line.len < 11 or line[10] != ' ') {
            gpa.free(line);
            return Error.CorruptRecord;
        }
        if (!date.isDateShape(line[0..10])) {
            gpa.free(line);
            return Error.CorruptRecord;
        }
        if (!std.unicode.utf8ValidateSlice(line[11..])) {
            gpa.free(line);
            return Error.CorruptRecord;
        }
        var d: [10]u8 = undefined;
        @memcpy(&d, line[0..10]);
        // The text must outlive line: it is its own allocation, and the
        // caller owns it (free it with the allocator it passed).
        const text = gpa.dupe(u8, line[11..]) catch {
            gpa.free(line);
            return error.OutOfMemory;
        };
        gpa.free(line);
        return .{ .id = id, .date = d, .text = text };
    }

    /// Memories [lo, hi): one positional read per record. wake, nap and
    /// zoom cover at most 16 memories at a time, so this stays a handful of
    /// reads.
    pub fn slice(self: *const Store, gpa: std.mem.Allocator, io: std.Io, lo: u64, hi: u64) Error!MemSlice {
        std.debug.assert(hi >= lo);
        var list = std.ArrayListUnmanaged(Memory).empty;
        errdefer list.deinit(gpa);
        for (lo..hi) |i| try list.append(gpa, try self.get(gpa, io, i));
        return .{ .mems = try list.toOwnedSlice(gpa), .gpa = gpa };
    }

    /// A streaming reader over the whole log, oldest first, for recall.
    /// Ids are the ordinal of the complete line; a torn trailing line is
    /// never yielded. Each yielded line borrows from the scanner and is
    /// valid until the next call to next.
    pub const Scanner = struct {
        const CHUNK = 65536;
        const BUF = 2 * CHUNK;

        store: *const Store,
        gpa: std.mem.Allocator,
        /// Null when the log does not exist: an empty store.
        file: ?std.Io.File,
        buf: []u8,
        start: usize = 0,
        end: usize = 0,
        off: u64 = 0,
        id: u64 = 0,
        data_eof: bool = false,

        pub const Next = union(enum) {
            eof: void,
            mem: struct {
                id: u64,
                /// "YYYY-MM-DD <text>", newline excluded.
                line: []const u8,
            },
        };

        pub fn init(store: *const Store, gpa: std.mem.Allocator, io: std.Io) Store.Error!Scanner {
            const buf = gpa.alloc(u8, BUF) catch return error.OutOfMemory;
            errdefer gpa.free(buf);
            const file = store.openFile(io, LOG_NAME, .read_only) catch |e| switch (e) {
                Store.Error.NotFound => null,
                else => return e, // openFile already maps to Store.Error
            };
            return .{ .store = store, .gpa = gpa, .file = file, .buf = buf };
        }

        pub fn deinit(self: *Scanner, io: std.Io) void {
            if (self.file) |f| std.Io.File.close(f, io);
            if (self.buf.len > 0) self.gpa.free(self.buf);
        }

        pub fn next(self: *Scanner, io: std.Io) Store.Error!Next {
            if (self.file == null) return .{ .eof = {} };
            const file = self.file.?;
            while (true) {
                const avail = self.buf[self.start..self.end];
                if (avail.len > 0) {
                    if (mem.findScalarPos(u8, avail, 0, '\n')) |p| {
                        const line = avail[0..p];
                        if (line.len > LINE_MAX - 1) return Store.Error.CorruptRecord;
                        if (line.len < 11 or line[10] != ' ') return Store.Error.CorruptRecord;
                        if (!date.isDateShape(line[0..10])) return Store.Error.CorruptRecord;
                        if (!std.unicode.utf8ValidateSlice(line[11..])) return Store.Error.CorruptRecord;
                        const my_id = self.id;
                        self.id += 1;
                        self.start += p + 1;
                        return .{ .mem = .{ .id = my_id, .line = line } };
                    }
                    // No newline anywhere in the buffer: the first line is
                    // already longer than any record may be.
                    if (avail.len > LINE_MAX - 1) return Store.Error.CorruptRecord;
                }
                if (self.data_eof) return .{ .eof = {} };
                // Make room, then read more.
                if (self.start > 0) {
                    mem.copyForwards(u8, self.buf[0 .. self.end - self.start], self.buf[self.start..self.end]);
                    self.end -= self.start;
                    self.start = 0;
                }
                const n = std.Io.File.readPositionalAll(file, io, self.buf[self.end..], self.off) catch |e| return Store.mapFs(e);
                self.off += n;
                self.end += n;
                if (n == 0) self.data_eof = true;
            }
        }
    };

    /// How many blocks of this size the tree holds — the length of the
    /// level's dense prefix. One stat and a header read, never a scan.
    pub fn levelCount(self: *const Store, gpa: std.mem.Allocator, io: std.Io, size: u64) Error!u64 {
        const v = try self.levelView(gpa, io, size);
        defer v.deinit();
        return v.count();
    }

    /// The summary of block [lo, hi), or its state.
    pub fn summaryGet(self: *const Store, gpa: std.mem.Allocator, io: std.Io, lo: u64, hi: u64) Error!Summary {
        const size = hi - lo;
        const k = lo / size;
        const v = try self.levelView(gpa, io, size);
        defer v.deinit();
        if (k >= v.count()) return .{ .missing = {} };
        const line = try v.readLine(gpa, io, k);
        const t = rtrim(line);
        if (t.len == 0) {
            if (line.len > 0) gpa.free(line);
            return .{ .blank = {} };
        }
        if (!std.unicode.utf8ValidateSlice(line)) {
            if (line.len > 0) gpa.free(line);
            return Error.CorruptRecord;
        }
        return .{ .text = line };
    }

    // ---------------------------------------------------------------- write

    /// Append memories under the exclusive lock; returns the first id
    /// assigned. Items must already be validated (one line each, within the
    /// ceiling). Ids are assigned inside the lock, so parallel appends
    /// never collide.
    pub fn append(self: *const Store, gpa: std.mem.Allocator, io: std.Io, items: []const NewMemory) Error!u64 {
        std.debug.assert(items.len > 0);
        const lock = try self.lockFile(io);
        defer std.Io.File.close(lock, io);
        const v = try self.reconcile(gpa, io, LOG_NAME, INDEX_NAME);
        defer v.deinit();
        const base = v.count();
        var batch = std.ArrayListUnmanaged(u8).empty;
        errdefer batch.deinit(gpa);
        for (items) |item| {
            if (10 + 1 + item.text.len + 1 > LINE_MAX) return Error.TooLong;
            try batch.appendSlice(gpa, &item.date);
            try batch.append(gpa, ' ');
            try batch.appendSlice(gpa, item.text);
            try batch.append(gpa, '\n');
        }
        var offs = std.ArrayListUnmanaged(u64).empty;
        errdefer offs.deinit(gpa);
        var off: u64 = v.data_size;
        var pos: usize = 0;
        while (pos < batch.items.len) {
            // The batch is built newline-terminated, so the newline is there.
            const nl = mem.findScalarPos(u8, batch.items[pos..], 0, '\n') orelse unreachable;
            try offs.append(gpa, off);
            off += @intCast(nl + 1);
            pos += nl + 1;
        }
        try self.commitLines(io, LOG_NAME, INDEX_NAME, v, batch.items, offs.items);
        batch.deinit(gpa);
        offs.deinit(gpa);
        return base;
    }

    /// Write the summary of block [lo, hi) as the next record of its level.
    /// Returns `.notNext` — without writing — when the level's dense prefix
    /// is not at this block (it is ahead of it: settled, or behind:
    /// forgotten). The caller, which computed pending first, knows which.
    pub fn summaryPut(self: *const Store, gpa: std.mem.Allocator, io: std.Io, lo: u64, hi: u64, text: []const u8) Error!PutResult {
        const size = hi - lo;
        const k = lo / size;
        std.debug.assert((size & (size - 1)) == 0 and lo % size == 0);
        const lock = try self.lockFile(io);
        defer std.Io.File.close(lock, io);
        const paths = try levelPaths(gpa, size);
        const data = paths[0];
        const idx = paths[1];
        defer {
            if (data.len > 0) gpa.free(data);
            if (idx.len > 0) gpa.free(idx);
        }
        const v = try self.reconcile(gpa, io, data, idx);
        defer v.deinit();
        if (v.count() != k) return .notNext;
        if (1 + text.len + 1 > LINE_MAX) return Error.TooLong;
        var line = gpa.alloc(u8, text.len + 1) catch return error.OutOfMemory;
        defer gpa.free(line);
        @memcpy(line[0..text.len], text);
        line[text.len] = '\n';
        try self.commitLines(io, data, idx, v, line, &[_]u64{v.data_size});
        return .appended;
    }

    /// Append several summaries to level `size` in one locked commit: the
    /// records land at blocks k*size..(k+1)*size, where k starts at the
    /// level's current dense prefix. Migration (import-optmem) carries a
    /// source level's prefix in at once; a nap pays one block via
    /// summaryPut. The texts must be within the line ceiling.
    pub fn summaryAppend(self: *const Store, gpa: std.mem.Allocator, io: std.Io, size: u64, texts: []const []const u8) Error!void {
        std.debug.assert(size >= 2 and (size & (size - 1)) == 0);
        if (texts.len == 0) return;
        const lock = try self.lockFile(io);
        defer std.Io.File.close(lock, io);
        const paths = try levelPaths(gpa, size);
        defer {
            if (paths[0].len > 0) gpa.free(paths[0]);
            if (paths[1].len > 0) gpa.free(paths[1]);
        }
        const v = try self.reconcile(gpa, io, paths[0], paths[1]);
        defer v.deinit();
        var batch = std.ArrayListUnmanaged(u8).empty;
        errdefer batch.deinit(gpa);
        var offs = std.ArrayListUnmanaged(u64).empty;
        errdefer offs.deinit(gpa);
        var off: u64 = v.data_size;
        for (texts) |t| {
            if (1 + t.len + 1 > LINE_MAX) return Error.TooLong;
            try offs.append(gpa, off);
            try batch.appendSlice(gpa, t);
            try batch.append(gpa, '\n');
            off += @intCast(t.len + 1);
        }
        try self.commitLines(io, paths[0], paths[1], v, batch.items, offs.items);
        batch.deinit(gpa);
        offs.deinit(gpa);
    }

    /// Drop the summary of block [lo, hi) and every block built from it, by
    /// truncating each affected level back to before that block (later
    /// blocks at those levels go too, and will be rebuilt). The log is
    /// never touched. Returns the dropped blocks, smallest level first; the
    /// caller frees the slice.
    pub fn summaryDrop(self: *const Store, gpa: std.mem.Allocator, io: std.Io, lo: u64, hi: u64) Error![]blocks.Block {
        const lock = try self.lockFile(io);
        defer std.Io.File.close(lock, io);
        const t = try self.count(gpa, io);
        var gone = std.ArrayListUnmanaged(blocks.Block).empty;
        errdefer gone.deinit(gpa);
        var size = hi - lo;
        while (true) {
            if (size > t) break;
            const k = lo / size;
            const v = try self.levelView(gpa, io, size);
            defer v.deinit();
            const n = v.count();
            if (n > k) {
                const data_off: u64 = if (k == 0) 0 else try v.offsetOf(io, k);
                const idx_off = INDEX_HDR + 8 * k;
                try self.truncateFile(io, v.data, data_off);
                try self.truncateFile(io, v.idx, idx_off);
                for (k..n) |i| try gone.append(gpa, .{ .lo = i * size, .hi = (i + 1) * size });
            }
            size = blocks.nextLevel(size, t) orelse break;
        }
        if (gone.items.len == 0) return &[_]blocks.Block{};
        return try gone.toOwnedSlice(gpa);
    }

    // ------------------------------------------------------------- internals

    /// The exclusive lock on .lock; held until the file is closed. The file
    /// is never truncated: truncating a lock file breaks advisory locks held
    /// by other processes.
    fn lockFile(self: *const Store, io: std.Io) Error!std.Io.File {
        return self.dir.createFile(io, LOCK_NAME, .{ .truncate = false, .lock = .exclusive }) catch |e| return mapFs(e);
    }

    fn openFile(self: *const Store, io: std.Io, path: []const u8, mode: std.Io.Dir.OpenFileOptions.Mode) Error!std.Io.File {
        return self.dir.openFile(io, path, .{ .mode = mode }) catch |e| return mapFs(e);
    }

    fn truncateFile(self: *const Store, io: std.Io, path: []const u8, len: u64) Error!void {
        const f = try self.openFile(io, path, .write_only);
        defer std.Io.File.close(f, io);
        std.Io.File.setLength(f, io, len) catch |e| return mapFs(e);
    }

    fn fileSize(self: *const Store, io: std.Io, path: []const u8) Error!u64 {
        const st = self.dir.statFile(io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return mapFs(e),
        };
        return st.size;
    }

    /// gpa-backed path pair for a tree level ("TREE/<size>",
    /// "TREE/<size>.idx"). The caller frees both.
    fn levelPaths(gpa: std.mem.Allocator, size: u64) Error!struct { []const u8, []const u8 } {
        var dbuf: [48]u8 = undefined;
        var ibuf: [48]u8 = undefined;
        const ds = std.fmt.bufPrint(&dbuf, "{s}{d}", .{ TREE_PREFIX, size }) catch unreachable;
        const d = gpa.dupe(u8, ds) catch return error.OutOfMemory;
        errdefer gpa.free(d);
        const is = std.fmt.bufPrint(&ibuf, "{s}{d}.idx", .{ TREE_PREFIX, size }) catch unreachable;
        const i = gpa.dupe(u8, is) catch return error.OutOfMemory;
        errdefer gpa.free(i);
        return .{ d, i };
    }

    /// Reader path: stat the data file, trust the index when it agrees with
    /// it, otherwise rescan read-only (the tail, or everything when the
    /// index is missing or torn). Never mutates anything.
    fn logView(self: *const Store, gpa: std.mem.Allocator, io: std.Io) Error!View {
        const d = gpa.dupe(u8, LOG_NAME) catch return error.OutOfMemory;
        errdefer gpa.free(d);
        const i = gpa.dupe(u8, INDEX_NAME) catch {
            gpa.free(d);
            return error.OutOfMemory;
        };
        errdefer gpa.free(i);
        return View.build(self, gpa, d, i, io);
    }

    fn levelView(self: *const Store, gpa: std.mem.Allocator, io: std.Io, size: u64) Error!View {
        var dbuf: [48]u8 = undefined;
        var ibuf: [48]u8 = undefined;
        const ds = std.fmt.bufPrint(&dbuf, "TREE/{d}", .{size}) catch unreachable;
        const d = gpa.dupe(u8, ds) catch return error.OutOfMemory;
        errdefer gpa.free(d);
        const is = std.fmt.bufPrint(&ibuf, "TREE/{d}.idx", .{size}) catch unreachable;
        const i = gpa.dupe(u8, is) catch {
            gpa.free(d);
            return error.OutOfMemory;
        };
        errdefer gpa.free(i);
        return View.build(self, gpa, d, i, io);
    }

    /// Writer path, under the lock: repair a torn trailing line, then make
    /// the index agree with the data file (full rescan and rewrite when it
    /// does not). Returns a consistent view: tail empty, data_size current.
    fn reconcile(self: *const Store, gpa: std.mem.Allocator, io: std.Io, data: []const u8, idx: []const u8) Error!View {
        const size = try self.repairFile(io, data);
        if (size == 0) {
            // Nothing has ever been written to this file: no index to
            // check, nothing to rescan. The first commit creates both.
            return ownedView(gpa, self, data, idx, 0, &[_]u64{}, 0);
        }
        const f = self.openFile(io, idx, .read_only) catch |e| switch (e) {
            Store.Error.NotFound => return self.rescanRewrite(gpa, io, data, idx, size),
            else => return e, // openFile already maps to Store.Error
        };
        defer std.Io.File.close(f, io);
        var hdr: [INDEX_HDR]u8 = undefined;
        const n = std.Io.File.readPositionalAll(f, io, &hdr, 0) catch return self.rescanRewrite(gpa, io, data, idx, size);
        if (n == INDEX_HDR) {
            const magic = mem.readInt(u32, hdr[0..4], .little);
            const version = mem.readInt(u32, hdr[4..8], .little);
            const recs = mem.readInt(u64, hdr[8..16], .little);
            const hdr_size = mem.readInt(u64, hdr[16..24], .little);
            const idx_size = std.Io.File.length(f, io) catch return self.rescanRewrite(gpa, io, data, idx, size);
            if (magic == INDEX_MAGIC and
                version == INDEX_VERSION and
                idx_size == INDEX_HDR + 8 * recs and
                hdr_size == size)
            {
                return ownedView(gpa, self, data, idx, recs, &[_]u64{}, size);
            }
        }
        return self.rescanRewrite(gpa, io, data, idx, size);
    }

    fn rescanRewrite(self: *const Store, gpa: std.mem.Allocator, io: std.Io, data: []const u8, idx: []const u8, size: u64) Error!View {
        const offs = try rescan(self, gpa, io, data, 0);
        defer if (offs.len > 0) gpa.free(offs);
        try self.writeIndex(io, idx, offs, size);
        return ownedView(gpa, self, data, idx, offs.len, &[_]u64{}, size);
    }

    /// Write `bytes` (one or more complete lines) at the end of the data
    /// file and extend the index with one offset per line. `v` came from
    /// reconcile: consistent, tail empty.
    fn commitLines(self: *const Store, io: std.Io, data: []const u8, idx: []const u8, v: View, bytes: []const u8, offs: []const u64) Error!void {
        // create-or-open: a summary level's files do not exist until its
        // first block is settled.
        const df = self.dir.createFile(io, data, .{ .truncate = false }) catch |e| return mapFs(e);
        defer std.Io.File.close(df, io);
        std.Io.File.writePositionalAll(df, io, bytes, v.data_size) catch |e| return mapFs(e);
        std.Io.File.sync(df, io) catch |e| return mapFs(e);
        const idf = self.dir.createFile(io, idx, .{ .truncate = false }) catch |e| return mapFs(e);
        defer std.Io.File.close(idf, io);
        var hdr: [INDEX_HDR]u8 = undefined;
        mem.writeInt(u32, hdr[0..4], INDEX_MAGIC, .little);
        mem.writeInt(u32, hdr[4..8], INDEX_VERSION, .little);
        mem.writeInt(u64, hdr[8..16], v.count() + offs.len, .little);
        mem.writeInt(u64, hdr[16..24], v.data_size + bytes.len, .little);
        std.Io.File.writePositionalAll(idf, io, &hdr, 0) catch |e| return mapFs(e);
        if (offs.len > 0) {
            const off_bytes = mem.sliceAsBytes(offs);
            std.Io.File.writePositionalAll(idf, io, off_bytes, INDEX_HDR + 8 * v.count()) catch |e| return mapFs(e);
        }
        std.Io.File.sync(idf, io) catch |e| return mapFs(e);
    }

    /// Rewrite an index from scratch: header plus every offset, in chunks
    /// so a long rescan never holds one giant buffer.
    fn writeIndex(self: *const Store, io: std.Io, idx: []const u8, offs: []const u64, data_size: u64) Error!void {
        const f = self.dir.createFile(io, idx, .{ .truncate = true }) catch |e| return mapFs(e);
        defer std.Io.File.close(f, io);
        var hdr: [INDEX_HDR]u8 = undefined;
        mem.writeInt(u32, hdr[0..4], INDEX_MAGIC, .little);
        mem.writeInt(u32, hdr[4..8], INDEX_VERSION, .little);
        mem.writeInt(u64, hdr[8..16], offs.len, .little);
        mem.writeInt(u64, hdr[16..24], data_size, .little);
        std.Io.File.writePositionalAll(f, io, &hdr, 0) catch |e| return mapFs(e);
        const chunk = 8192;
        var pos: usize = 0;
        while (pos < offs.len) {
            const n = @min(chunk, offs.len - pos);
            const b = mem.sliceAsBytes(offs[pos .. pos + n]);
            std.Io.File.writePositionalAll(f, io, b, INDEX_HDR + 8 * @as(u64, @intCast(pos))) catch |e| return mapFs(e);
            pos += n;
        }
        std.Io.File.sync(f, io) catch |e| return mapFs(e);
    }

    /// Drop a torn trailing line, if the file does not end on a newline.
    /// The torn bytes were never acknowledged; the file is then a whole
    /// number of records. Returns the size after repair.
    fn repairFile(self: *const Store, io: std.Io, path: []const u8) Error!u64 {
        const size = try self.fileSize(io, path);
        if (size == 0) return 0;
        const start: u64 = if (size > LINE_MAX + 1) size - (LINE_MAX + 1) else 0;
        const f = try self.openFile(io, path, .read_only);
        defer std.Io.File.close(f, io);
        var buf: [65536]u8 = undefined;
        const n = std.Io.File.readPositionalAll(f, io, &buf, start) catch |e| return mapFs(e);
        const last = mem.findScalarLast(u8, buf[0..n], '\n');
        if (last == n - 1) return size; // healthy: ends on a newline
        if (last == null) {
            if (size <= LINE_MAX + 1) {
                // The whole file is one unterminated line: a torn first
                // record. Nothing was ever acknowledged in it.
                try self.truncateFile(io, path, 0);
                return 0;
            }
            // No newline inside the whole window: one line longer than any
            // record may be.
            return Error.CorruptRecord;
        }
        const new_size = start + @as(u64, @intCast(last.?)) + 1;
        try self.truncateFile(io, path, new_size);
        return new_size;
    }

    /// Map a std filesystem error to the store's named set.
    pub fn mapFs(e: anyerror) Error {
        return switch (e) {
            error.FileNotFound => Error.NotFound,
            error.NotDir => Error.NotDirectory,
            error.IsDir => Error.IsDirectory,
            error.AccessDenied => Error.AccessDenied,
            error.PermissionDenied => Error.PermissionDenied,
            error.NoSpaceLeft => Error.NoSpace,
            error.PathAlreadyExists, error.AlreadyExists => Error.AlreadyExists,
            error.ReadOnlyFileSystem => Error.ReadOnly,
            error.NameTooLong => Error.PathTooLong,
            else => Error.IoError,
        };
    }
};

/// A read-only snapshot of one indexed file (the log, or a summary level):
/// how many records the index covers (`base`), and the offsets of the
/// complete lines beyond that, when the index is behind the data file
/// (`tail`). Owns the two path strings (gpa-allocated); `deinit` frees
/// them.
const View = struct {
    store: *const Store,
    gpa: std.mem.Allocator,
    data: []const u8,
    idx: []const u8,
    /// Records whose offsets live in the index (id < base).
    base: u64,
    /// Offsets of the complete lines beyond base.
    tail: []u64,
    /// The data file's byte size as of this view.
    data_size: u64,

    pub fn count(self: *const View) u64 {
        return self.base + self.tail.len;
    }

    /// Frees the owned paths and the tail (an empty tail is a constant and
    /// is not freed). The view is never mutated, so it may be const.
    pub fn deinit(self: *const View) void {
        self.gpa.free(self.data);
        self.gpa.free(self.idx);
        if (self.tail.len > 0) self.gpa.free(self.tail);
    }

    /// Byte offset of record `id` in the data file: one 8-byte positional
    /// read from the index, or from the tail the rescan computed.
    pub fn offsetOf(self: *const View, io: std.Io, id: u64) Store.Error!u64 {
        if (id < self.base) {
            const f = try self.store.openFile(io, self.idx, .read_only);
            defer std.Io.File.close(f, io);
            var b: [8]u8 = undefined;
            const n = std.Io.File.readPositionalAll(f, io, &b, INDEX_HDR + 8 * id) catch |e| return Store.mapFs(e);
            if (n != 8) return Store.Error.CorruptRecord;
            return mem.readInt(u64, &b, .little);
        }
        return self.tail[id - self.base];
    }

    /// Record `id` as a line, newline excluded. Allocated with `gpa` (free
    /// it); an empty line (a blank record) is a zero-length allocation.
    pub fn readLine(self: *const View, gpa: std.mem.Allocator, io: std.Io, id: u64) Store.Error![]u8 {
        if (id >= self.count()) return Store.Error.NotFound;
        const off = try self.offsetOf(io, id);
        const f = try self.store.openFile(io, self.data, .read_only);
        defer std.Io.File.close(f, io);
        var buf: [65536]u8 = undefined;
        const n = std.Io.File.readPositionalAll(f, io, &buf, off) catch |e| return Store.mapFs(e);
        const nl = mem.findScalarPos(u8, &buf, 0, '\n') orelse return Store.Error.CorruptRecord;
        if (nl >= @min(n, @as(usize, LINE_MAX))) return Store.Error.CorruptRecord;
        return gpa.dupe(u8, buf[0..nl]) catch return error.OutOfMemory;
    }

    /// Reader path: stat the data file; trust the index when it agrees with
    /// it; otherwise rescan read-only. Never mutates anything. Takes
    /// ownership of the gpa-allocated `data` and `idx` paths on success;
    /// on error the caller still owns them.
    fn build(store: *const Store, gpa: std.mem.Allocator, data: []const u8, idx: []const u8, io: std.Io) Store.Error!View {
        const data_size = try store.fileSize(io, data);
        if (data_size == 0) {
            return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = 0, .tail = &[_]u64{}, .data_size = 0 };
        }
        const f = store.openFile(io, idx, .read_only) catch |e| switch (e) {
            Store.Error.NotFound => {
                const tail = try rescan(store, gpa, io, data, 0);
                return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = 0, .tail = tail, .data_size = data_size };
            },
            else => return e, // openFile already maps to Store.Error
        };
        defer std.Io.File.close(f, io);
        var hdr: [INDEX_HDR]u8 = undefined;
        const n = std.Io.File.readPositionalAll(f, io, &hdr, 0) catch {
            const tail = try rescan(store, gpa, io, data, 0);
            return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = 0, .tail = tail, .data_size = data_size };
        };
        if (n != INDEX_HDR) {
            const tail = try rescan(store, gpa, io, data, 0);
            return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = 0, .tail = tail, .data_size = data_size };
        }
        const magic = mem.readInt(u32, hdr[0..4], .little);
        const version = mem.readInt(u32, hdr[4..8], .little);
        const recs = mem.readInt(u64, hdr[8..16], .little);
        const hdr_size = mem.readInt(u64, hdr[16..24], .little);
        const idx_size = std.Io.File.length(f, io) catch {
            const tail = try rescan(store, gpa, io, data, 0);
            return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = 0, .tail = tail, .data_size = data_size };
        };
        // Torn index, or a data file that shrank under the index (a forget
        // between its two truncations): rescan from the start.
        if (magic != INDEX_MAGIC or version != INDEX_VERSION or
            idx_size != INDEX_HDR + 8 * recs or hdr_size > data_size)
        {
            const tail = try rescan(store, gpa, io, data, 0);
            return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = 0, .tail = tail, .data_size = data_size };
        }
        if (hdr_size == data_size) {
            return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = recs, .tail = &[_]u64{}, .data_size = data_size };
        }
        // The index is behind the log: a writer is between the data write
        // and the index update (or crashed there). Count the complete lines
        // past the index; the one it is halfway through has no newline and
        // is not counted.
        const tail = try rescan(store, gpa, io, data, hdr_size);
        return .{ .store = store, .gpa = gpa, .data = data, .idx = idx, .base = recs, .tail = tail, .data_size = data_size };
    }
};

/// A view that owns gpa-allocated copies of the two paths (the caller's
/// borrows stay valid; the copies live until the view's deinit).
fn ownedView(
    gpa: std.mem.Allocator,
    store: *const Store,
    data: []const u8,
    idx: []const u8,
    base: u64,
    tail: []u64,
    data_size: u64,
) Store.Error!View {
    const d = gpa.dupe(u8, data) catch return error.OutOfMemory;
    errdefer gpa.free(d);
    const i = gpa.dupe(u8, idx) catch return error.OutOfMemory;
    return .{ .store = store, .gpa = gpa, .data = d, .idx = i, .base = base, .tail = tail, .data_size = data_size };
}

/// The offsets of every complete line at `from` or later, in file order.
/// The final unterminated line, if any, is not counted: its writer owns it.
/// Returns a gpa-allocated slice, or an empty constant when there are no
/// lines (do not free empty).
fn rescan(store: *const Store, gpa: std.mem.Allocator, io: std.Io, path: []const u8, from: u64) Store.Error![]u64 {
    const f = try store.openFile(io, path, .read_only);
    defer std.Io.File.close(f, io);
    var offs = std.ArrayListUnmanaged(u64).empty;
    errdefer offs.deinit(gpa);
    var buf: [65536]u8 = undefined;
    var carry: [131072]u8 = undefined;
    var clen: usize = 0;
    var off = from;
    while (true) {
        const n = std.Io.File.readPositionalAll(f, io, &buf, off) catch |e| return Store.mapFs(e);
        off += n;
        if (clen + n > carry.len) return Store.Error.CorruptRecord;
        mem.copyForwards(u8, carry[clen .. clen + n], buf[0..n]);
        clen += n;
        var p: usize = 0;
        while (true) {
            // The index is always inside the slice, so a found newline is
            // a complete line: no bounds check beyond the line ceiling.
            const nl = mem.findScalarPos(u8, carry[0..clen], p, '\n') orelse break;
            if (nl - p + 1 > LINE_MAX) return Store.Error.CorruptRecord;
            try offs.append(gpa, from + @as(u64, @intCast(p)));
            p = nl + 1;
        }
        if (p > 0) {
            mem.copyForwards(u8, carry[0 .. clen - p], carry[p..clen]);
            clen -= p;
        }
        if (n == 0) break;
    }
    if (offs.items.len == 0) return &[_]u64{};
    return try offs.toOwnedSlice(gpa);
}

/// Trim ASCII whitespace from the right. (A stored summary never carries
/// trailing whitespace; this only decides whether a hand-written or torn
/// record counts as a blank.)
fn rtrim(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const c = s[end - 1];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
        end -= 1;
    }
    return s[0..end];
}

// Test helpers, at file scope: a 0.17 nested function cannot see block
// scope variables, so io is passed explicitly.
var temp_counter: u64 = 0;

const TempStore = struct {
    path: []u8,
    log: []u8,
    index: []u8,
    tree: []u8,
    tree2: []u8,
    store: Store,
};

fn tempStore(gpa: std.mem.Allocator, io: std.Io) !TempStore {
    temp_counter += 1;
    var buf: [96]u8 = undefined;
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const path_s = std.fmt.bufPrint(&buf, "/tmp/lowmem-store-test-{d}-{d}", .{ ns, temp_counter }) catch unreachable;
    const path = try gpa.dupe(u8, path_s);
    errdefer gpa.free(path);
    // The joined sub-paths 0.17 will not make from runtime slices are
    // built once here, not at every use site.
    const log = try gpa.print("{s}/LOG", .{path});
    errdefer gpa.free(log);
    const index = try gpa.print("{s}/INDEX", .{path});
    errdefer gpa.free(index);
    const tree = try gpa.print("{s}/TREE", .{path});
    errdefer gpa.free(tree);
    const tree2 = try gpa.print("{s}/TREE/2", .{path});
    errdefer gpa.free(tree2);
    std.Io.Dir.createDirAbsolute(io, path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    const store = try Store.open(io, path);
    return .{ .path = path, .log = log, .index = index, .tree = tree, .tree2 = tree2, .store = store };
}

fn cleanup(gpa: std.mem.Allocator, io: std.Io, t: TempStore) void {
    std.Io.Dir.cwd().deleteTree(io, t.path) catch {};
    gpa.free(t.path);
    gpa.free(t.log);
    gpa.free(t.index);
    gpa.free(t.tree);
    gpa.free(t.tree2);
}

fn makeDate(s: []const u8) [10]u8 {
    var d: [10]u8 = undefined;
    @memcpy(&d, s);
    return d;
}

test "empty store: count zero, get not found" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    try testing.expectEqual(@as(u64, 0), try t.store.count(testing.allocator, io));
    const got: Store.Error!Store.Memory = t.store.get(testing.allocator, io, 0);
    try testing.expectError(error.NotFound, got);
}

test "append, get, slice, count" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    const base = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "first memory" },
        .{ .date = makeDate("2020-01-02"), .text = "second memory" },
        .{ .date = makeDate("2020-01-03"), .text = "third memory" },
    });
    try testing.expectEqual(@as(u64, 0), base);
    try testing.expectEqual(@as(u64, 3), try t.store.count(testing.allocator, io));
    const m = try t.store.get(testing.allocator, io, 1);
    try testing.expectEqualStrings("second memory", m.text);
    try testing.expectEqualStrings("2020-01-02", &m.date);
    try testing.expectEqual(@as(u64, 1), m.id);
    testing.allocator.free(m.text);
    const s = try t.store.slice(testing.allocator, io, 0, 3);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.mems.len);
    try testing.expectEqualStrings("first memory", s.mems[0].text);
    try testing.expectEqualStrings("third memory", s.mems[2].text);
}

test "log and index byte format" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "aa" },
        .{ .date = makeDate("2020-01-02"), .text = "bb" },
    });
    const log = try std.Io.Dir.cwd().readFileAlloc(io, t.log, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(log);
    try testing.expectEqualStrings("2020-01-01 aa\n2020-01-02 bb\n", log);
    const idx = try std.Io.Dir.cwd().readFileAlloc(io, t.index, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(idx);
    try testing.expectEqual(@as(usize, 24 + 16), idx.len);
    try testing.expectEqual(@as(u32, 0x4C4F4D31), mem.readInt(u32, idx[0..4], .little));
    try testing.expectEqual(@as(u32, 1), mem.readInt(u32, idx[4..8], .little));
    try testing.expectEqual(@as(u64, 2), mem.readInt(u64, idx[8..16], .little));
    try testing.expectEqual(@as(u64, 28), mem.readInt(u64, idx[16..24], .little));
    try testing.expectEqual(@as(u64, 0), mem.readInt(u64, idx[24..32], .little));
    try testing.expectEqual(@as(u64, 14), mem.readInt(u64, idx[32..40], .little));
}

test "torn trailing line is repaired by the next append" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "whole" },
    });
    // Simulate a crash mid-append: a partial trailing line, no newline,
    // appended after the last complete line.
    {
        const f = try std.Io.Dir.cwd().openFile(io, t.log, .{ .mode = .write_only });
        defer std.Io.File.close(f, io);
        const size = std.Io.File.length(f, io) catch unreachable;
        try std.Io.File.writePositionalAll(f, io, "2020-01-02 torn but never ack", size);
    }
    // A reader never counts the torn line.
    try testing.expectEqual(@as(u64, 1), try t.store.count(testing.allocator, io));
    const base = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-02"), .text = "after the crash" },
    });
    try testing.expectEqual(@as(u64, 1), base);
    const log = try std.Io.Dir.cwd().readFileAlloc(io, t.log, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(log);
    try testing.expectEqualStrings("2020-01-01 whole\n2020-01-02 after the crash\n", log);
    try testing.expectEqual(@as(u64, 2), try t.store.count(testing.allocator, io));
}

test "reader sees the tail when the index is behind the log" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "one" },
        .{ .date = makeDate("2020-01-02"), .text = "two" },
    });
    // A writer that crashed after writing the third line but before
    // updating the index.
    {
        const f = try std.Io.Dir.cwd().openFile(io, t.log, .{ .mode = .write_only });
        defer std.Io.File.close(f, io);
        const size = std.Io.File.length(f, io) catch unreachable;
        try std.Io.File.writePositionalAll(f, io, "2020-01-03 three\n", size);
    }
    try testing.expectEqual(@as(u64, 3), try t.store.count(testing.allocator, io));
    const m = try t.store.get(testing.allocator, io, 2);
    defer testing.allocator.free(m.text);
    try testing.expectEqualStrings("three", m.text);
}

test "a torn index is rewritten by the next append" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "one" },
    });
    {
        var f = try std.Io.Dir.cwd().openFile(io, t.index, .{ .mode = .read_write });
        defer std.Io.File.close(f, io);
        try f.writeStreamingAll(io, "garbage beyond the header");
    }
    const base = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-02"), .text = "two" },
    });
    try testing.expectEqual(@as(u64, 1), base);
    try testing.expectEqual(@as(u64, 2), try t.store.count(testing.allocator, io));
    const m = try t.store.get(testing.allocator, io, 0);
    defer testing.allocator.free(m.text);
    try testing.expectEqualStrings("one", m.text);
}

test "summary put and get roundtrip" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "one" },
        .{ .date = makeDate("2020-01-02"), .text = "two" },
    });
    try testing.expect((try t.store.summaryGet(testing.allocator, io, 0, 2)) == .missing);
    try testing.expectEqual(Store.PutResult.appended, try t.store.summaryPut(testing.allocator, io, 0, 2, "a pair"));
    const s = try t.store.summaryGet(testing.allocator, io, 0, 2);
    switch (s) {
        .text => |txt| {
            defer testing.allocator.free(txt);
            try testing.expectEqualStrings("a pair", txt);
        },
        else => unreachable,
    }
    // Putting the same block again: the level is ahead of it.
    try testing.expectEqual(Store.PutResult.notNext, try t.store.summaryPut(testing.allocator, io, 0, 2, "again"));
    // A level that does not exist yet is missing, not an error.
    try testing.expect((try t.store.summaryGet(testing.allocator, io, 2, 4)) == .missing);
}

test "summary drop truncates the block and everything built on it" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "m0" },
        .{ .date = makeDate("2020-01-01"), .text = "m1" },
        .{ .date = makeDate("2020-01-01"), .text = "m2" },
        .{ .date = makeDate("2020-01-01"), .text = "m3" },
        .{ .date = makeDate("2020-01-01"), .text = "m4" },
        .{ .date = makeDate("2020-01-01"), .text = "m5" },
        .{ .date = makeDate("2020-01-01"), .text = "m6" },
        .{ .date = makeDate("2020-01-01"), .text = "m7" },
    });
    _ = try t.store.summaryPut(testing.allocator, io, 0, 2, "s01");
    _ = try t.store.summaryPut(testing.allocator, io, 2, 4, "s23");
    _ = try t.store.summaryPut(testing.allocator, io, 4, 6, "s45");
    _ = try t.store.summaryPut(testing.allocator, io, 6, 8, "s67");
    _ = try t.store.summaryPut(testing.allocator, io, 0, 4, "s03");
    _ = try t.store.summaryPut(testing.allocator, io, 4, 8, "s47");
    _ = try t.store.summaryPut(testing.allocator, io, 0, 8, "s07");
    // Forget [2,4): [2,4) [4,6) [6,8) at size 2, [0,4) [4,8) at size 4,
    // [0,8) at size 8 go with it. [0,2) survives.
    const gone = try t.store.summaryDrop(testing.allocator, io, 2, 4);
    defer if (gone.len > 0) testing.allocator.free(gone);
    try testing.expectEqual(@as(usize, 6), gone.len);
    try testing.expectEqual(@as(u64, 2), gone[0].lo);
    try testing.expectEqual(@as(u64, 4), gone[0].hi);
    try testing.expectEqual(@as(u64, 0), gone[5].lo);
    try testing.expectEqual(@as(u64, 8), gone[5].hi);
    const s = try t.store.summaryGet(testing.allocator, io, 0, 2);
    switch (s) {
        .text => |txt| {
            defer testing.allocator.free(txt);
            try testing.expectEqualStrings("s01", txt);
        },
        else => unreachable,
    }
    try testing.expect((try t.store.summaryGet(testing.allocator, io, 2, 4)) == .missing);
    try testing.expect((try t.store.summaryGet(testing.allocator, io, 0, 4)) == .missing);
    try testing.expect((try t.store.summaryGet(testing.allocator, io, 0, 8)) == .missing);
    // The log is untouched.
    try testing.expectEqual(@as(u64, 8), try t.store.count(testing.allocator, io));
}

test "summary drop on a fresh store drops nothing" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    const gone = try t.store.summaryDrop(testing.allocator, io, 0, 2);
    try testing.expectEqual(@as(usize, 0), gone.len);
}

test "blank summary record is named blank" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    {
        var f = try std.Io.Dir.cwd().createFile(io, t.tree2, .{ .truncate = false });
        defer std.Io.File.close(f, io);
        try f.writeStreamingAll(io, "\n");
    }
    const s = try t.store.summaryGet(testing.allocator, io, 0, 2);
    try testing.expect(s == .blank);
}

test "invalid utf-8 in a summary is corrupt" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    {
        var f = try std.Io.Dir.cwd().createFile(io, t.tree2, .{ .truncate = false });
        defer std.Io.File.close(f, io);
        try f.writeStreamingAll(io, &[_]u8{ 0xFF, 0xFE, '\n' });
    }
    _ = t.store.summaryGet(testing.allocator, io, 0, 2) catch |e| try testing.expect(e == error.CorruptRecord);
}

test "corrupt log line: bad date shape" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    {
        var f = try std.Io.Dir.cwd().createFile(io, t.log, .{ .truncate = false });
        defer std.Io.File.close(f, io);
        try f.writeStreamingAll(io, "nope-date here\n");
    }
    try testing.expectEqual(@as(u64, 1), try t.store.count(testing.allocator, io));
    _ = t.store.get(testing.allocator, io, 0) catch |e| try testing.expect(e == error.CorruptRecord);
}

test "corrupt log line: over the ceiling" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    const long = try testing.allocator.alloc(u8, 70013);
    defer testing.allocator.free(long);
    @memcpy(long[0..11], "2020-01-01 ");
    for (long[11 .. long.len - 1]) |*c| c.* = 'x';
    long[long.len - 1] = '\n';
    {
        var f = try std.Io.Dir.cwd().createFile(io, t.log, .{ .truncate = false });
        defer std.Io.File.close(f, io);
        try f.writeStreamingAll(io, long);
    }
    _ = t.store.count(testing.allocator, io) catch |e| try testing.expect(e == error.CorruptRecord);
}

test "scanner walks the log oldest first" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "alpha" },
        .{ .date = makeDate("2020-01-02"), .text = "beta" },
        .{ .date = makeDate("2020-01-03"), .text = "gamma" },
    });
    var sc = try Store.Scanner.init(&t.store, testing.allocator, io);
    defer sc.deinit(io);
    const want = [_][]const u8{ "2020-01-01 alpha", "2020-01-02 beta", "2020-01-03 gamma" };
    for (0..3) |i| {
        const r = try sc.next(io);
        switch (r) {
            .mem => |m| {
                try testing.expectEqual(@as(u64, @intCast(i)), m.id);
                try testing.expectEqualStrings(want[i], m.line);
            },
            else => unreachable,
        }
    }
    const r = try sc.next(io);
    try testing.expect(r == .eof);
}

test "scanner never yields the torn tail" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    _ = try t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = "alpha" },
    });
    {
        const f = try std.Io.Dir.cwd().openFile(io, t.log, .{ .mode = .write_only });
        defer std.Io.File.close(f, io);
        const size = std.Io.File.length(f, io) catch unreachable;
        try std.Io.File.writePositionalAll(f, io, "2020-01-02 torn", size);
    }
    var sc = try Store.Scanner.init(&t.store, testing.allocator, io);
    defer sc.deinit(io);
    const r = try sc.next(io);
    switch (r) {
        .mem => |m| try testing.expectEqualStrings("2020-01-01 alpha", m.line),
        else => unreachable,
    }
    const r2 = try sc.next(io);
    try testing.expect(r2 == .eof);
}

test "scanner on an empty store is done at once" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    var sc = try Store.Scanner.init(&t.store, testing.allocator, io);
    defer sc.deinit(io);
    const r = try sc.next(io);
    try testing.expect(r == .eof);
}

test "append refuses over the ceiling" {
    const testing = std.testing;
    const io = testing.io;
    const t = try tempStore(testing.allocator, io);
    defer cleanup(testing.allocator, io, t);
    defer t.store.close(io);
    const too = try testing.allocator.alloc(u8, 65525);
    defer testing.allocator.free(too);
    for (too) |*c| c.* = 'x';
    _ = t.store.append(testing.allocator, io, &[_]Store.NewMemory{
        .{ .date = makeDate("2020-01-01"), .text = too },
    }) catch |e| try testing.expect(e == error.TooLong);
}
