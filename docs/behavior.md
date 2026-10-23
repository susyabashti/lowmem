# LowMem behavioral specification

This is the authoritative spec of the user-visible behavior LowMem must
preserve. It is written from the original Python implementation
(`.scratch/optmem/memo`) and its test suite (`.scratch/optmem/test.py`,
109,099 checks, all passing on the reference machine). Every fixture in
`test/parity.py` traces back to a section of this document.

Sections: [1. Global contract](#1-global-contract),
[2. Store layout](#2-store-layout),
[3. Block math](#3-block-math),
[4. Commands](#4-commands),
[5. Nap prompt](#5-nap-prompt),
[6. Output rules](#6-output-rules),
[7. Crash and corruption semantics](#7-crash-and-corruption-semantics),
[8. Concurrency](#8-concurrency),
[9. Documented differences](#9-documented-differences).

## 1. Global contract

- **Store location.** `$MEMORY_DIR` (tilde-expanded) if set and non-empty,
  else `~/.lowmem/memory`. Only `init` may create the store directory. Every
  other command, run against a missing store, prints to stderr:

  ```
  No memory at <dir>.
  To create one, run: <me> init
  To use an existing one, point MEMORY_DIR at it.
  ```

  and exits 1. A typo in `MEMORY_DIR` must never silently open an empty
  second store (the directory must not be created).
- **Encoding.** The store is UTF-8 by construction; the tool reads and
  prints UTF-8 regardless of the machine locale.
- **Self-naming.** Every command the tool prints must be runnable as printed
  on the machine that printed it. The tool embeds its own path (`<me>` =
  absolute path of the running binary, with `$HOME` folded to `~`) in every
  command it offers. Nothing is ever assumed to be on `PATH`.
- **Errors.** Failures print one human-readable line to stderr and exit 1.
  Filesystem errors are reported in the tool's voice
  (`<path>: <errno message>.`), never as a stack trace or panic dump.
- **Mutations are locked.** All mutating operations (and repairs) hold an
  exclusive advisory lock on `<store>/.lock` for their duration. Readers do
  not lock; the log is append-only, so a concurrent reader always sees a
  consistent prefix.
- **No background work.** Merges arrive one at a time, in the output of
  `note`/`wake`/`nap`. Nothing is ever scheduled.

## 2. Store layout

```
<store>/
  LOG        every memory, one per line, append-only, never edited
  INDEX      compact binary index over LOG (LowMem; OptMem has none)
  TREE/      the summaries: one file per level, a cache over LOG
  config     optional size overrides, written by `lowmem config`
  .lock      advisory lock file
```

LowMem's record format is variable-length (see ADR
`docs/adr/0001-variable-length-store.md`); the logical record is identical
to OptMem's:

- A **raw memory** is the line `#<id> <YYYY-MM-DD> <text>`.
  `id` is the memory's stable sequential id (0-based, assigned under the
  lock at append time). `text` is one line of at most `ENTRY_CHARS` bytes,
  no embedded newlines.
- A **block** is an aligned power-of-two range of memories `[lo, hi)`,
  `size = hi - lo >= 2`, `lo % size == 0`. A **summary** is the one-line
  compression of a block. Level `size` of the tree holds the summaries of
  all size-`size` blocks as a *dense prefix*: block `k` (i.e. `[k*size,
  (k+1)*size)`) is the k-th record of `TREE/size`. Anything after the
  prefix is unbuilt.
- The tree is a **cache**: its complete set of records is determined by
  LOG, but its *content* is LLM-generated. Rebuilding a summary requires
  re-running the nap for that block; the tool must never present a missing
  or torn summary as if it existed.

## 3. Block math

- `complete(T)`: every block buildable from `T` memories — all aligned
  power-of-two blocks of size `2, 4, …` up to the largest power of two ≤ T —
  listed smallest first. `complete(T)` is the oracle for what a fully
  settled store of size T holds.
- `cover(T, budget)`: a partition of `[0, T)` into aligned power-of-two
  blocks with at most `budget` blocks, sizes non-increasing toward `T`
  (coarse in the past, finest detail near the present). If `T <= budget`
  every memory is its own block (verbatim).
- `pending(T)`: `complete(T)` minus the blocks already built, smallest
  first. "Built" is read from each level's record count — one stat per
  level, never a scan. A level may hold *more* blocks than a smaller T
  needs (T is a snapshot; memories keep arriving); per-level work is
  clamped at zero, never negative.
- `RAW_MAX = 16`: blocks of at most 16 memories are compressed from the raw
  log; bigger blocks are compressed from their two halves' summaries.
- Work per appended memory is bounded: `len(complete(T)) -
  len(complete(T-1)) <= 16` for all T (verified to 2000 in the reference
  tests; a structural property of aligned power-of-two tiling).

## 4. Commands

### 4.0 `lowmem` (no command)

Prints the usage block to stdout, exit 0. Unknown command:
`No such command: <cmd>` + usage to stderr, exit 1.

### 4.1 `init`

- Takes no arguments (anything else: usage error).
- The one command that may create the store. It creates what is missing and
  rewrites nothing: `TREE/` directory, empty `LOG`, and `config` (default
  knobs, all commented out) only if absent.
- Output, fresh store:

  ```
  Created <dir>: this machine's memory, one identity, forever.
  Sizes live in <dir>/config; the defaults are fine.

  Paste this at the top of your agent's AGENTS.md (or CLAUDE.md), done:

  <TEMPLATE>
  ```

  Existing store: first line is `Found <dir>: <N memory|memories>.`
- `<TEMPLATE>` is the `## Memory` integration block (see reference
  `TEMPLATE`); paths and `ENTRY_CHARS` are substituted.
- Re-running `init` on a lived-in store changes no byte of it.

### 4.2 `wake [part [T]]`

`T` defaults to the current log length. Arguments must be non-negative
integers; `T > now` is a usage error naming the actual size.

- `T = 0`:

  ```
  No memories yet. Record the first with: <me> note "<one line>"
  You are awake.
  ```

- Otherwise the document is `cover(T, WAKE_LINES)` rendered oldest first:
  a size-1 block renders as its raw memory `#<i> <date> <text>`; a bigger
  block renders as `#<lo>-<hi-1> <summary>`.
- **Missing summary.** If a covered block has no summary:
  - while any nap is pending, `wake` *refuses*: it prints to stdout

    ```
    Cannot wake: the memory context needs #<lo>-<hi-1>, which is not compressed yet.
    Do the <N compression|compressions> below, then run <me> wake again.

    <nap prompt>
    ```

    and exits 1. (This is the only refusal; work the document does not need
    is not the reason to refuse.)
  - if nothing is pending, the record is corrupt/blank: `die("The summary
    of #<lo>-<hi-1> is blank. Run: <me> forget <lo>-<hi-1>")`.
- **Pagination.** The document is split into parts of at most
  `PART_CHARS` bytes and `PART_LINES` lines. Part `k` (1-based):
  - unknown part: `No part <k>: the memory has <N part|parts>. Run: <me> wake` (exit 1).
  - first line when there is more than one part:
    `Your memory, part <k> of <total>, oldest first (<T memory|memories>).`
  - then the part's lines, one per line.
  - footer: last part always ends with `You are awake.`; a non-last part
    ends with `Not awake yet. Run: <me> wake <k+1> <T>`.
  - after `You are awake.` on the last part, if a nap is pending, the nap
    prompt follows on a blank line.
- **Snapshot semantics.** A part is rendered *as of T*: a memory appended
  between two `wake` calls must not shift an already-rendered part, and
  compressions paid mid-wake must not break the rest of the read.

### 4.3 `note "<one line>"`

- Exactly one argument.
- Validation (in order): strip whitespace; empty → `Empty. A memory is one
  line of text.`; contains a newline → `<n> lines. A memory is one line:
  merge them, or note them separately.`; byte length > `ENTRY_CHARS` →
  `Too long: <n> bytes, limit <max>. Accented characters cost 2 bytes.
  Compress it further.` (bytes, not chars: `150 × 'ã'` is 300 bytes).
- Appends the memory dated with today's local date; prints `Saved as #<id>.`
- If a nap is pending *after* the append (T = id+1), the nap prompt follows
  on a blank line.
- Ids are assigned under the lock: parallel `note`s never collide.

### 4.4 `nap [id "<one line>"]`

- No arguments: nothing pending → `Nothing left to compress.`; otherwise
  print the nap prompt.
- Two arguments (`<lo>-<hi>` and the summary):
  - id must parse as a block (section 5.3), else the block-id errors.
  - nothing pending → `Nothing left to compress.` (writes nothing).
  - id is the next pending block → write it, print `<lo>-<hi-1> saved.`
  - id is already settled → `<lo>-<hi-1> is already settled.` (writes
    nothing; two sessions paying the same nap is not an error).
  - id is neither → exit 1: `Wrong block: <arg>. Blocks are built in order;
    the next is <lo>-<hi-1>. Run: <me> nap`
  - the summary text is validated like a note (section 4.3).
  - if the write loses the race, `<lo>-<hi-1> was settled or forgotten
    meanwhile.`
- After any `nap` with arguments, the *next* nap prompt follows on a blank
  line (or `Nothing left to compress.`).
- `nap` must never print `You are awake.`; only `wake` may.

### 4.5 `recall <regex>`

- Exactly one argument; matched case-insensitively over the pattern's
  literal text (section 9, difference 4: a literal subset, not a full regex
  engine — a pattern the reference would reject is searched literally here
  and never an error).
- One streaming pass over the whole log; a memory matches if the pattern is
  found anywhere in its *full line* `#<id> <date> <text>` — id and date
  included, not just the text. Recall reaches memories that summaries lost.
- Only the **newest** matches that fit in `PART_CHARS` bytes are returned
  (a vague regex matches the whole log, and the whole log does not fit in a
  harness's output).
- Output:
  - no hits: `No match.`
  - capped: the kept lines, then `Newest <kept> of <total match|matches>.
    Narrow the regex.`
  - not capped: all lines, then `<n> match|matches.` (n=1 → `1 match.`)

### 4.6 `zoom <lo>-<hi>`

- Exactly one argument, a block id (section 5.3).
- `lo >= T` (T = log length): `#<arg> is beyond the memory: it holds <T
  memory|memories>. Run: <me> wake` (exit 1).
- Prints the node's two halves `[lo, mid)` and `[mid, hi)`, oldest half
  first, each rendered the way `wake` renders a covered block:
  - a half beyond T (no memories there yet) is omitted, not printed.
  - a size-1 half prints the raw memory.
  - a bigger half prints `#<a>-<b> <summary>` or `#<a>-<b> not compressed
    yet` if the summary is missing.
- The tool only reads; navigation is the agent's job: it descends from a
  `wake` line by halving, or leaps to any block id it can name.

### 4.7 `forget <lo>-<hi>`

- Exactly one argument, a block id.
- Drops the summary and **every block built from it**, by truncating each
  affected level file back to before that block (later blocks at those
  levels go too and will be rebuilt). The log is never touched.
- Nothing dropped: `No summary at <arg>.` (exit 1).
- Prints `Forgot <n summary|summaries>, from <lo>-<hi-1> up. Run: <me> nap`
  where `lo-hi` is the first dropped block.

### 4.8 `config [NAME=VALUE ...]`

Knobs, with defaults:

| Knob        | Default | Meaning                                      |
|-------------|---------|----------------------------------------------|
| `WAKE_LINES`| 96      | how many lines `wake` prints (~8k tokens)    |
| `ENTRY_CHARS`| 280    | longest one memory, in bytes                 |
| `PART_CHARS`| 20000   | output paging: largest part, in bytes        |
| `PART_LINES`| 500     | output paging: largest part, in lines        |

- No arguments: show all knobs with their effective values; an overridden
  knob is annotated `(default <d>)`.
- `NAME=VALUE`: sets the knob (positive integer); `NAME=` restores the
  default. Unknown name, missing `=`, or an invalid value: usage error
  listing the knob names (exit 1).
- The `config` file stores one `NAME = VALUE` line per knob; a commented
  line means "follow the tool's default". A size is a *reading* budget:
  changing one never recomputes anything.
- A malformed hand-written config line stops **every** command, and the
  error must name the file and the line: `<path> line <n>: <message>`
  (e.g. `WAKE_LNES is not a size. Delete the line, or name one of: …`).

### 4.9 `import <file>`

- Bulk-append historical memories, one `YYYY-MM-DD <text>` per line.
  Bootstrap-only, used once.
- Line validation, per line (first failure wins, line number reported):
  not UTF-8 → the whole file is refused (`<file> is not UTF-8 text.
  Convert it, then import again.`); empty/blank lines are skipped; the
  date must match `\d{4}-\d{2}-\d{2}` *and* be a real calendar date; dates
  must not precede the last existing memory (or the previous imported
  line); text must be non-empty and ≤ `ENTRY_CHARS` bytes.
- An empty result set: `<file> has no memories.` (exit 1).
- All-or-nothing append under the lock; prints `Imported <n
  memory|memories>, #<first> to #<last>.` and, if any nap is pending,
  `<n> compression|compressions pending. Run: <me> nap`.

### 4.10 `import-optmem <dir>`

Adopt an OptMem store (fixed-width `LOG.txt` and `TREE/` files): its
memories *and* its summaries, into this memory. A migration, used once
when moving off OptMem (difference 2, 10).

- The source must be a readable directory with a `LOG.txt`; anything
  else is the filesystem refusal `<path>: <errno>.` (exit 1). A missing
  `LOG.txt` is named as `<dir>/LOG.txt`.
- The log is read whole before the store is touched. A record that is
  not `#<id> YYYY-MM-DD <text>`, or whose id does not equal its
  position: `The OptMem log at <dir> is corrupt at record #<id>; the
  import stopped before touching the store.` (exit 1). A date that goes
  backwards: `The OptMem log at <dir> goes backwards at record #<id>;`
  the same tail. Zero complete records: `<dir> has no memories.` (exit
  1). A torn trailing record is not a record: the records before it
  still import.
- The target must be empty: the carried summaries are aligned to #0,
  and appending onto an existing log would set them adrift: `This memory
  already holds <n memory|memories>. import-optmem imports into an empty
  store: the carried summaries are aligned to #0.` (exit 1).
- The memories are appended in one locked batch. Then the summaries are
  carried level by level (2, 4, …): each level contributes its dense
  prefix — the read stops at the first missing, blank, or undecodable
  record and later records of the level are dropped (they rest on a
  hole; the next `nap` recomputes them). A missing level file is a gap,
  not a failure.
- The source's `config` is not carried over: this memory keeps its own
  knobs. Imported text is not checked against this memory's
  `ENTRY_CHARS`: the budget gates new entries, and an OptMem record
  holds at most 319 bytes of `#<id> YYYY-MM-DD <text>`, far inside the
  LowMem record ceiling.
- Prints `Imported <n memory|memories>, #0 to #<n-1>.`; when summaries
  were carried, `Carried <m summary|summaries>.`; when compressions are
  pending, `<k> compression|compressions pending. Run: <me> nap`.

### 4.11 `export-optmem <dir>`

Write this memory as an OptMem store: a fresh `LOG.txt` of 320-byte
records and one `TREE/<size>` file of 288-byte records per level that
carries a summary. The source store is never touched.

- The target directory is created when missing; a path that is a file
  is the filesystem refusal; a directory that already holds a
  `LOG.txt` refuses: `<dir> already has a LOG.txt: export to an empty
  or new directory.` (exit 1).
- All-or-nothing: every record's fit is checked before the first byte is
  written. A memory whose `#<id> YYYY-MM-DD <text>` is over 319 bytes:
  `Cannot export: memory #<id> is <len> bytes; an OptMem record holds
  319.` (exit 1). A summary over 287 bytes: `Cannot export: the summary
  of #<lo>-<hi> is <len> bytes; an OptMem record holds 287.` (exit 1).
  Both are only reachable with `ENTRY_CHARS` raised past OptMem's 280.
- Each level contributes its dense prefix, the same rule as 4.10: a
  blank, missing, or undecodable record ends that level.
- No `config` is written. When this memory overrides any knob, the
  result line is followed by: `The size knobs were not carried over:
  the new store follows the OptMem defaults.`
- Prints `Exported <n memory|memories> and <m summary|summaries> to
  <dir>.` An OptMem store that passes through `import-optmem` and back
  through `export-optmem` comes out byte-identical (`LOG.txt` and every
  `TREE` file).

## 5. Nap prompt

For a pending block `[lo, hi)` with `left` other pending blocks:

```
Compress memories #<lo>-<hi-1> into one line of at most <ENTRY_CHARS> bytes.
Keep what has lasting effect, drop what does not. Invent nothing.

<body>
<tail>
Run: <me> nap <lo>-<hi-1> "<your line>"
```

- `<body>`: for `hi - lo <= RAW_MAX`, the raw memories, one per line,
  two-space-indented: `  #<id> <date> <text>`. For bigger blocks, the two
  half-summaries: `  #<a>-<b-1> <summary>` (a missing or blank half here is
  a corrupt write: `The summary of #<a>-<b-1> is blank. Run: <me> forget
  <a>-<b-1>`, exit 1).
- `<tail>`: absent when `left == 0` — in that case a single blank line
  separates body and the `Run:` line; otherwise it occupies its own line
  between them: `1 compression remains after this one.` / `<n>
  compressions remain after this one.`.
- The offered line must start with `Run: ` — every command the tool
  prints is an order, not a label.

### 5.3 Block id parsing

`<lo>-<hi>` is inclusive at both ends and must name a real block: an
aligned power-of-two range (`n = hi - lo + 1`, `n >= 2`, power of two,
`lo % n == 0`). Failures:

- not `<digits>-<digits>` → `'<arg>' is not a block id. Copy it from the prompt.`
- a number but not a block → `<arg> is not a block. Copy the id printed by wake, like 16-31.`

## 6. Output rules

- **Pluralization** (applied to `memory`, `part`, `match`, `compression`,
  `summary`): n=1 → `1 <word>`; word ending in `y` → replace with `ie`
  (`memories`); word ending in `s`, `h`, or `x` → append `es`
  (`matches`); otherwise append `s`.
- **`<me>`** = absolute path of the running binary, with the `$HOME` prefix
  folded to `~` (symlinks kept).
- stdout is UTF-8, one message per line, no extra blank lines beyond the
  ones shown in this spec.
- Exit codes: 0 success (including `nap` with nothing to do); 1 every
  error, including `wake`'s pending-work refusal.

## 7. Crash and corruption semantics

The log is the single source of truth. Everything else is derived.

- **Torn trailing raw record** (crash mid-append): the next mutation
  truncates the incomplete trailing record before appending. The truncated
  bytes were never acknowledged. After repair the file is a whole number of
  records, and the id assigned to the *next* memory is the count of
  complete records — a torn write is never counted as a memory.
- **Torn trailing summary record**: same rule per level file. The block
  simply does not exist; `nap` will offer it again. Losing a torn summary
  costs one re-summarization — the raw memories are untouched.
- **Blank summary** (a record of nothing): `wake`/`nap` must name the one
  exit, `forget <lo>-<hi>`, and exit 1 — never refuse forever, never print
  `None`.
- **Invalid-UTF-8 summary record**: treated as corrupt; same `forget` exit.
- **Unreadable level file**: a filesystem failure, surfaced as one
  (`<path>: Permission denied.`) — never read as "not compressed yet",
  which would offer work that cannot be done.
- **Index (LowMem)**: derived from LOG; any mismatch (stale, torn, missing)
  triggers a rescan under the lock. A crash can at most leave the index
  behind the log; recovery is a bounded sequential rescan of the tail.
- **Rebuild of the summary tree**: the *structure* of pending work is
  always derivable from LOG (level lengths). The *content* of summaries is
  LLM-generated and is **not** freely rebuildable: a lost summary requires
  re-running its nap. Migration (import) must therefore carry existing
  summaries over, not discard them.

## 8. Concurrency

- N parallel `note`s on a fresh store leave exactly N memories with ids
  `0..N-1`, no collisions, no lost writes (real processes, cross-process
  lock).
- A `note` landing between two `wake` parts must not shift a rendered part
  (snapshot T, section 4.2).
- Two sessions paying the same nap: the loser reports `already settled` /
  `was settled or forgotten meanwhile`, writes nothing, exits 0.
- Readers (`wake`, `recall`, `zoom`, `config`) never block on writers and
  never see torn records.

## 9. Documented differences

Deliberate differences from OptMem, each with its justification. Anything
else that differs is a bug.

1. **Storage format** — variable-length records with a compact binary
   index (ADR `docs/adr/0001-variable-length-store.md`), instead of fixed
   320/288-byte records. Internal only: record *semantics*, ids, the tree
   structure, and every command's I/O are unchanged.
2. **Default store directory** — `~/.lowmem/memory` instead of
   `~/.optmem/memory`. LowMem is a new tool with a new format; sharing a
   directory with OptMem would let the two formats interleave. `lowmem
   import-optmem` / `export-optmem` move data between formats.
3. **`ENTRY_CHARS` ceiling** — OptMem caps the knob at 280 because a record
   must fit 320 bytes; LowMem caps it at the record ceiling (64 KiB).
   The default (280) is unchanged.
4. **`recall` regex** — OptMem uses Python's full `re` engine; LowMem
   implements a zero-dependency subset (literals, `^` anchor, case-
   insensitivity; `.` `*` `+` `?` `[...]` `(...)` `|` to be added as the
   parity harness demands). Invalid-pattern messages are not byte-identical
   to Python's.
5. **Blank-summary dead end** — in OptMem, an all-whitespace tree record is
   a corrupt write that must be `forget`-ed. In LowMem, repair truncates
   torn records, so a missing summary is simply a pending block; the
   `forget`-pointing error remains for the case where a *complete but
   empty* record is deliberately written.
6. **Tool name and self-path** — `lowmem` instead of `memo`; `<me>` is the
   lowmem binary path. The `## Memory` template says "Your memory is
   LowMem".
7. **Locale pinning** — OptMem reconfigures Python's streams to UTF-8;
   LowMem writes UTF-8 unconditionally (no locale involvement).
8. **Windows** — OptMem ships a Windows fallback (`msvcrt` locks); LowMem
   targets POSIX (macOS/Linux; Raspberry Pi). `lowmem` on Windows is not
   supported and is not claimed.
9. **u64 ceiling** — block ids and size-knob values above 2^64-1 are
   refused; the reference's Python `int` is unbounded. A log or a reading
   budget that large does not exist (2^64 one-line memories is exabytes);
   an over-long id is read as not-an-id rather than not-a-block.
10. **Migration commands** — `import-optmem <dir>` and `export-optmem
   <dir>` (sections 4.10, 4.11) have no reference counterpart: the two
   formats are separate tools and the commands move data between them.
   The usage block carries their two lines; the parity gate strips them
   from the LowMem side before comparing.
