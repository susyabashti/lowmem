# ADR 0001 — Variable-length store with a rebuildable offset index

Status: **accepted** (2026-10-22)

## Context

OptMem stores raw memories in 320-byte fixed records (`LOG.txt`) and
summaries in 288-byte fixed records (`TREE/<size>`). Padding costs ~2x on
disk for typical short notes and is the single largest storage item in the
system (a million memories occupy 608 MB whether the notes are 40 or 280
bytes). LowMem's primary goal is dramatically lower disk usage with the
same fast operations, on a Raspberry Pi.

Requirements (from the architectural direction):

1. No fixed-width padding; stable sequential memory ids preserved.
2. `zoom`/`wake` stay fast: candidates are (A) variable-length records +
   full 64-bit offset index, (B) variable-length records + sparse offset
   checkpoints, (C) page-based packed format with an in-page record
   directory and a compact page index.
3. The raw log stays append-only and recoverable after interruption:
   explicit record validation, commit ordering, index recovery,
   concurrent-writer behavior.
4. Summaries are LLM-generated and **not** freely rebuildable: migration
   must preserve them; crash loss must be documented and bounded.
5. Uncompressed packed baseline first; compression evaluated only after
   measurement.

## The measured options

Record framing considered for the log (and reused verbatim for each tree
level):

- **F1**: `u32 len` + payload.
- **F2**: payload + terminator newline (plain-text lines).

F2 is chosen. `note`/`nap` reject embedded newlines, so a line's bytes are
unambiguous under the rule *a valid file ends every line with `\n`*; a torn
write is a prefix of `payload + "\n"` and therefore can only leave a final
line without a terminator. Repair is "truncate to the last `\n`" — the
same rule as OptMem's fixed-record repair, with no length arithmetic. F1's
4-byte prefix buys nothing F2 lacks (the newline already delimits) and it
makes the log unreadable by `grep`, `less`, and a human — a real property
of OptMem's log that is worth keeping. Both framings have identical
corruption behavior for a *mid-file* bad byte (loss of synchronization);
F2's rule is simpler, so F2.

Record ceiling: **65 535 bytes** per line (raw memory or summary).
Enforced at write time; at read time a longer line is reported as a corrupt
record (named error, not silent skip — the log is machine-managed and the
contract forbids hand edits). `ENTRY_CHARS` is capped at this ceiling.

### Candidate A — full u64 offset index

```
<store>/
  LOG              "YYYY-MM-DD <text>\n" per memory, append-only
  INDEX            u32 magic | u32 version | u64 count | u64 log_size | u64 offset[count]
  TREE/<size>      "<summary>\n" per built block of that size, dense prefix
  TREE/<size>.idx  same 16-byte header + u64 offset prefix as INDEX
  config, .lock
```

- The **log is the single source of truth**; the index is a derived cache.
  Every level file and its `.idx` follow the same pair-of-files pattern.
- Lookup: read the index (one sequential read), seek `offset[k]`, read one
  line. O(1) per memory, same as OptMem's one-seek lookups.
- Storage overhead (measured above): log gains 8 B/record + 1 B newline
  (vs 320 B flat); the index is 8 B/record. At 1 M memories:

  | avg text | OptMem  | A        | saving  | index share of store |
  |----------|---------|----------|---------|----------------------|
  | 80 B     | 608 MB  | 178 MB   | **3.4x** | 9.0 %               |
  | 130 B    | 608 MB  | 278 MB   | **2.2x** | 5.8 %               |
  | 190 B    | 608 MB  | 398 MB   | **1.5x** | 4.0 %               |

  The saving grows as real notes get shorter than the 280-byte default
  ceiling; the 190 B row is the worst case the seed data produces.

### Candidate B — sparse checkpoints

Checkpoints every K = 1024 records (12 B each: u32 id, u64 offset).
Random access: seek the last checkpoint, scan up to K lines (~K × (L+1)
bytes worst case). Saves `8 − 12/1024 ≈ 7.99 B`/record — **4.4 % of the
store at 1 M / 80 B** — at the cost of: a scan on the random path (tens of
KLines per wake in the worst case), checkpoint torn-write repair, and a
second resync rule (checkpoint file vs log vs record count). Not worth 4 %.

### Candidate C — page-based packed format

Pages of 16 KiB; in-page u16 offset directory; global page index
(8 B/page: cumulative record count + offset). Saves ~2 B/record of framing
and 1 B/record of newline — **~4–5 % over A** — at the cost of: page
lifecycle (last-page-append, full-page rotation, torn-page semantics), an
in-page directory that must be written before the records it describes
(two-phase page commit), cumulative-count bookkeeping for id→page mapping,
and loss of plain-text readability of the log. Not worth 5 %.

### Decision: Candidate A

A is the only candidate whose design is a *direct simplification* of
OptMem's (same append-only file, same one-seek lookups, same
truncate-to-repair rule) with the padding removed. B and C each save
≤ 5 % of the store — below the noise of text-length variance — for
multiple new invariants to maintain on a Pi where simplicity is the goal.
A's index is 4–9 % of the store; if it ever measures as a problem (it
won't, at target scale: 1 M memories ≈ 8 MB), switching to u32 offsets or
checkpoints is a storage-layer change behind the interface, with no CLI or
tree-logic change.

**Memory cost note.** A cold `wake` loads the whole index: 8 MB at 1 M
memories. That is the price of O(1) random access and is linear and
predictable in T — acceptable on a Pi (the log itself is 89–199 MB there).

## Commit ordering and recovery

### Writer path (`note`, `nap`, `forget`, `import`; under the exclusive
lock on `.lock`)

1. **Repair the log**: if `LOG` does not end in `\n`, truncate to the last
   `\n`. A torn trailing record was never acknowledged; the next id is the
   count of complete records.
2. **Reconcile the index** (the log is authoritative):
   - `INDEX` missing / bad magic / bad version / `header.log_size !=
     actual log size` / `file size != 16 + 8·count` → **full rescan** of
     the log, rewrite `INDEX`.
   - otherwise: consistent; proceed.
   (The log can only ever be *behind* its index via a crash between the
   log fsync and the index update, or *ahead* of it via the reverse
   ordering bug; both are caught by the `log_size` check. A torn `INDEX`
   is caught by the size check. Full rescan is the only repair — one
   code path.)
3. **Append** `YYYY-MM-DD <text>\n` to `LOG` (one write), `fsync(LOG)`.
4. **Update the index**: write `count+1` / `log_size+len` into the header,
   append the new offset (8 B) at the end, `fsync(INDEX)`.
5. Release the lock.

Each step's crash outcome is recoverable by step 1–2 of the next writer:
after 3 → index is behind the log → rescan the tail; after 4 → nothing to
do. No step can leave the log misaligned: the log is only ever extended
(by one complete line) or truncated to a line boundary.

Tree levels follow the identical protocol per level file (a `nap` appends
to exactly one `TREE/<size>` and its `.idx`; a `forget` truncates one or
more level files *and* their indexes to the same record boundary, under
the same lock).

### Reader path (`wake`, `recall`, `zoom`, `config`; no lock)

- Read the `INDEX` header; if consistent with the log size, use it.
- If inconsistent (a writer is between steps 3 and 4, or a crash left the
  index stale), the reader **rescans read-only**: it counts complete
  lines past `header.log_size` (or from the start, if the index is ahead)
  and keeps those offsets in memory. A line a writer is halfway through
  has no trailing `\n` and is not counted, so a reader never sees a torn
  record and never blocks on the lock.
- `T` (the snapshot length) is captured once, at command start, as the
  number of complete records — same semantics as OptMem's `log_len`.

### Concurrent writers

One exclusive `flock` on `.lock` serializes all mutations; ids are
assigned under the lock from the repaired count, so N parallel `note`s
yield exactly ids `0..N-1` (the reference test runs 16 real processes).
The lock file is opened append-only and never truncated (truncating a lock
file breaks advisory locks held by other processes on some platforms).

### What a crash can lose

- **At most one raw memory** (the in-flight `note`), and only if the
  process died before the log `fsync` — its record is torn and truncated.
  This matches OptMem exactly (its torn record is likewise never counted).
- **At most one summary** per level (the in-flight `nap`), plus whatever
  higher-level summaries had not been built yet. **Summaries are
  LLM-generated: a lost summary means re-running that nap — it cannot be
  recomputed from the log for free.** The raw memories are never lost, and
  the pending-work structure is always derivable, so the tool degrades to
  "offer the merge again", never to data loss. Migration (`import-optmem`)
  copies every existing summary record, so an upgrade never discards paid
  merges.

## Interface (sketch)

The storage layer sits behind a small interface in `src/core` (no printing,
no CLI knowledge). The CLI and the tree logic (cover/pending/nap) depend
only on it; the file layout above is a private detail.

```zig
pub const Store = struct {
    // raw memories
    count:                  (io) !u64,
    append:                 (io, alloc, items: []const Memory) !u64,   // first id; locked
    get:                    (io, alloc, id: u64) !Memory,
    slice:                  (io, alloc, lo: u64, hi: u64) ![]Memory,
    scan:                   (io) Scan,                                 // streaming, for recall
    // summary levels
    levelCount:             (io, size: u64) !u64,
    summaryGet:             (io, alloc, lo: u64, hi: u64) !?[]const u8,
    summaryPut:             (io, alloc, lo: u64, hi: u64, text: []const u8) !SummaryPut,
    summaryDrop:            (io, lo: u64, hi: u64) ![]BlockRange,
    // maintenance (locked)
    reconcile:              (io, alloc) !void,
};
pub const Memory = struct { date: [10]u8, text: []const u8 };
```

`summaryPut` returns `.appended | .settled | .forgotten` so the nap
command can say "saved" / "already settled" / "settled or forgotten
meanwhile" exactly as specified. Errors are named (`Store.Error`); a
corrupt mid-log line is `error.CorruptRecord` with the id attached at the
call site, not a silent skip.

## Rejected alternatives

- **Fixed-width records (OptMem's)**: 2.2–3.4x waste for short notes; the
  ADR's whole point. Rejected.
- **No index, on-demand scan**: a random `zoom` at 1 M memories would scan
  up to the whole log (~100–200 MB sequential read per level); cold `wake`
  becomes 96 such scans. Rejected on the latency budget.
- **F1 length-prefixed binary records**: no measurable benefit over F2,
  loses human readability. Rejected.
- **Compression (LZ4/zstd over pages)**: deferred per requirement 5. The
  packed baseline is measured first; compression must preserve O(1)
  random access and cheap append (a per-page scheme keeps both) and must
  beat the baseline on measured storage at Pi-realistic text lengths — it
  will be revisited only with that evidence.
