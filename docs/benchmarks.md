# Benchmarks: LowMem (Zig) vs OptMem (Python)

Measured with `test/bench.py` on a MacBook Pro (Apple silicon, macOS).
Seeds: `test/data/seed_{100,1000,10000,100000,1000000}.txt` (deterministic,
~203-byte dated lines). Raw results: `test/bench/python.json`,
`test/bench/zig.json`.

**Measurement notes**

- Wall time comes from the system `time` tool, which reports centiseconds
  on macOS: every figure is quantized to 10 ms, and any value printed as
  0–10 ms is "under 20 ms, startup-dominated".
- `wake part1`, `note`, and the `zoom` navigation are medians of 5
  subprocess calls; `recall` and `config` are single calls (the 1 M
  recall figures were re-measured as medians of 5 — stable within 10 ms —
  because the single shot is noisy there).
- "wake full" is the *whole memory document* (the `WAKE_LINES` cover,
  paged), not the whole log: the memory context, at most a few tens of KB.
- Settling the summary tree above 10 000 memories would take hours through
  the CLI in either tool, so those stores are prebuilt directly in each
  tool's on-disk format (`prebuild_python` / `prebuild_zig`); the
  *measured* rebuild cost is the ≤ 10 000 CLI settle below. The steady
  state metrics (footprint, wake, recall, zoom) are what matter at those
  sizes, and both tools hold the same T = N+1 memories in the store.

## Storage

| N | OptMem | LowMem | saving |
|---:|---:|---:|---:|
| 100 | 60 KB | 49 KB | 18 % |
| 1 000 | 610 KB | 496 KB | 18 % |
| 10 000 | 6.08 MB | 4.99 MB | 18 % |
| 100 000 | 60.80 MB | 49.99 MB | 18 % |
| 1 000 000 | 608.00 MB | 500.89 MB | 18 % |

LowMem footprint at 1 M (OptMem in parentheses):

| component | LowMem | OptMem |
|---|---:|---:|
| log (`LOG` / `LOG.txt`) | 203.9 MB | 320.0 MB |
| offsets (`INDEX` + `TREE/*.idx`) | 16.0 MB | — |
| summaries (`TREE/*`) | 281.0 MB | 288.0 MB |

- The log saves 36 %: variable-length 204-byte lines instead of fixed
  320-byte records.
- The summary tree saves 2.4 % *here* because the bench summaries are all
  truncated to the 280-byte ceiling (281 bytes each vs 288); on real data
  with shorter summaries the saving grows proportionally.
- Index overhead is 8 bytes per record (log and summaries): 1.6 % of the
  log, and it buys O(1) direct access for `zoom`/`wake` (ADR 0001).

## Latency (median, per subprocess)

| N | wake part 1 | wake full | note | recall hit | recall miss | zoom nav | startup |
|---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| | Py / Zg | Py / Zg | Py / Zg | Py / Zg | Py / Zg | Py / Zg | Py / Zg |
| 100 | 20/10 | 20/10 | 20/0 | 20/0 | 20/10 | 140/0 | 20/0 |
| 1 000 | 20/10 | 40/20 | 20/10 | 20/10 | 20/0 | 200/0 | 20/0 |
| 10 000 | 20/10 | 40/20 | 20/10 | 30/20 | 30/10 | 280/0 | 20/0 |
| 100 000 | 20/10 | 40/20 | 20/10 | 160/150 | 150/80 | 340/0 | 20/0 |
| 1 000 000 | 20/10 | 40/20 | 20/10 | 1330/1470 | 1260/710 | 400/30 | 20/0 |

All values in ms. "zoom nav" descends the summary tree from the root to
one raw memory (7–20 zooms, one subprocess each).

- Every command is at or under the reference at every size, except
  **recall hit at 1 M** — analyzed below.
- At small sizes the Python numbers are interpreter-startup-dominated
  (~20 ms floor); the LowMem floor is ~10 ms.
- `recall miss` is 1.8× faster at 1 M: the scan itself is cheap in both;
  the hit case pays pattern cost (below).

## Peak RSS

| N | OptMem | LowMem |
|---:|---:|---:|
| 100 … 100 000 | ~18.2 MB | ~3.3 MB |
| 1 000 000 | 18.3 MB | 3.3 MB |

Both stream; LowMem's peak is a flat ~3.3 MB at every size (5.5× less):
the scanner reads the log in 64 KB chunks and never maps or buffers it
whole.

## Rebuild (settle) cost, real CLI

| N | OptMem | LowMem |
|---:|---:|---:|
| 100 (96 naps) | 5.4 s | 2.5 s |
| 1 000 (993 naps) | 55.5 s | 25.5 s |

~2.2× faster per nap (each nap is two subprocesses: prompt, then pay).
Import of the 20 MB / 1 M-memory seed: 3.62 s (Python) vs 1.08 s (LowMem).

## The one regression: recall hit at 1 M

`recall "memory number 7,"` over the 1 M store: 1470 ms (LowMem) vs
1330 ms (OptMem) — 10 % slower, while the same scan on a non-matching
pattern is 710 ms here vs 1260 ms there.

Root cause (measured, stable across reps and order): the pattern is a
case-insensitive literal, searched per line. The reference engine's
literal path is roughly O(lines) regardless of the pattern; LowMem's
search walks first-byte candidates and compares the needle at each.
"memory number 7," starts with a common byte (`m` — every line begins
with "memory…") and shares a 15-byte prefix with a million near-miss
candidates, so each line pays several long compares. A pattern whose
first byte is absent from the text (the miss case) pays only the scan.

What was done: `core/regex.zig` now rejects a candidate on a one-byte
last-needle-byte check before the full compare (zero behavior change;
the parity gate and the regex tests pass unchanged). That cut the 1 M
hit from 1690 ms to 1470 ms and the 100 k hit from 170 ms to 150 ms.

What remains: the per-line candidate scan. Beating the reference at
1 M would take a two-way (or equivalent amortized-linear) literal search,
~100 lines of carefully tested code — deferred: the gain is ~10 % on a
size that is unrealistic for the target machine (a 1 M-memory log is
204 MB; OptMem's agent-memory use case stays in the low thousands, where
LowMem is at or faster on every metric).

## Raspberry Pi fit

- Peak RSS is a flat ~3.3 MB at every store size — it fits a 512 MB
  Pi Zero 2 W with room for the OS, and the binary is a static ~1 MB.
- A 100 k-memory store is 50 MB on disk (61 MB in OptMem); 1 M is
  501 MB (608 MB).
- The steady-state commands (wake/note/zoom) are 10 ms-class at every
  size; full-history recall over 100 k memories is 150 ms.
