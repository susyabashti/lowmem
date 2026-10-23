#!/usr/bin/env python3
"""LowMem benchmark harness: measures any tool that speaks the OptMem CLI.

Procedure per dataset size N (documented in docs/adr/0001 and the final
report, docs/benchmarks.md):

  1. Generate a deterministic seed (test/gen_data.py) and `import` it.
  2. Measure `note` latency on the fresh store (includes the nap prompt
     when a merge is due; the offered merge is paid to keep the store
     consistent).
  3. Settle the summary tree:
     - N <= --settle-cap: drive the real CLI nap loop (subprocesses, like
       an agent would). This is the measured *rebuild cost*.
     - N >  --settle-cap: prebuild a settled store directly in the tool's
       file format (a reference format writer; the steady-state metrics
       below are what matter at these sizes, and a full nap chain at 1M
       would take hours in either tool).
  4. Measure the store footprint (every file, bytes).
  5. Measure steady-state latencies (subprocess per call, median of
     --reps): cold/warm `wake` (part 1 and full), `recall` hit/miss, a
     `zoom` navigation from the top of the tree to one raw memory, and
     startup (`config`, minimal work). Peak RSS is captured per call with
     the system `time` tool.

Usage:

  python3 test/bench.py --tool python --out test/bench/python.json
  python3 test/bench.py --tool zig    --out test/bench/zig.json

`--tool python` runs .scratch/optmem/memo; `--tool zig` runs
zig-out/bin/lowmem. Both are compared on byte-identical seeds.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEMO = os.path.join(HERE, ".scratch", "optmem", "memo")
LOWMEM = os.path.join(HERE, "zig-out", "bin", "lowmem")
DATA = os.path.join(HERE, "test", "data")

# LowMem index header: u32 magic 'LOM1', u32 version, u64 count, u64 log_size
INDEX_MAGIC = 0x4C4F4D31
INDEX_VERSION = 1


def template(i):
    return (
        "memory number %d, a thing that happened, was weighed against the "
        "rest of the week, turned out to matter more than anyone guessed at "
        "the time, and left a mark on every plan that followed it" % i
    )


def seed_date(i):
    return (datetime.date(2020, 1, 1) + datetime.timedelta(days=i // 5)).isoformat()


def seed_file(n):
    path = os.path.join(DATA, "seed_%d.txt" % n)
    if not os.path.exists(path):
        os.makedirs(DATA, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            for i in range(n):
                f.write("%s %s\n" % (seed_date(i), template(i)))
    return path


def fake_summary(body_lines):
    """The deterministic compressor the reference test suite uses."""
    line = " ".join(b.strip() for b in body_lines)[:280]
    return line or "empty"


# ---------------------------------------------------------------- tools


def time_bin():
    """The system time tool and its max-RSS flag, per platform."""
    if sys.platform == "darwin" and os.path.exists("/usr/bin/time"):
        return ["/usr/bin/time", "-l"], "maximum resident set size"
    if os.path.exists("/usr/bin/time") and subprocess.run(
        ["/usr/bin/time", "-v", "/usr/bin/true"], capture_output=True
    ).returncode == 0:
        return ["/usr/bin/time", "-v"], "Maximum resident set size"
    return None, None


def timed_run(cmd, store):
    """(rc, stdout, stderr, wall_s, peak_rss_kb) for one CLI call."""
    env = dict(os.environ, MEMORY_DIR=store)
    tbin, rss_key = time_bin()
    if tbin:
        with tempfile.NamedTemporaryFile("r", delete=False, suffix=".time") as tf:
            tname = tf.name
        try:
            p = subprocess.run(tbin + ["-o", tname] + cmd, env=env,
                               capture_output=True, text=True)
            text = open(tname, encoding="utf-8", errors="replace").read()
            os.unlink(tname)
        except OSError:
            os.unlink(tname) if os.path.exists(tname) else None
            text = ""
        wall, rss = 0.0, 0
        lines = text.splitlines()
        if lines and sys.platform == "darwin":
            # "0.00 real  0.00 user  0.00 sys"
            wall = float(lines[0].split()[0])
        for line in lines:
            if rss_key in line:
                # macOS -l: value precedes the label, in bytes.
                before = re.match(r"\s*([\d.]+)\s+" + re.escape(rss_key), line)
                if before:
                    rss = int(float(before.group(1))) // 1024
                else:
                    # Linux -v: "Maximum resident set size (kbytes): N"
                    after = re.search(re.escape(rss_key) + r".*?:\s*([\d.]+)", line)
                    if after:
                        rss = int(float(after.group(1)))
                break
            if line.strip().startswith("Elapsed") and "wall clock" in line:
                m = re.search(r":\s*([\d:.]+)\s*$", line)
                if m:
                    wall = 0.0
                    for part in m.group(1).split(":"):
                        wall = wall * 60 + float(part)
        return p.returncode, p.stdout, p.stderr, wall, rss
    import time as _t
    t0 = _t.monotonic()
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr, _t.monotonic() - t0, 0


# ---------------------------------------------------------------- settle

def prebuild_summary(lo, size, recs, memo_map):
    """Fake summary for block [lo, lo+size), mirroring the CLI nap loop."""
    key = (lo, size)
    if key in memo_map:
        return memo_map[key]
    if size <= 16:
        body = ["#%d %s %s" % (i, d, t) for i, (d, t) in enumerate(recs[lo:lo + size], lo)]
    else:
        half = size // 2
        body = ["#%d-%d %s" % (lo, lo + half - 1, prebuild_summary(lo, half, recs, memo_map)),
                "#%d-%d %s" % (lo + half, lo + size - 1, prebuild_summary(lo + half, half, recs, memo_map))]
    s = fake_summary(body)
    memo_map[key] = s
    return s


BENCH_NOTE = "a benchmark memory, worth keeping"


def records(n):
    """The (date, text) pairs of the store after import + the benchmark note,
    so prebuilt stores hold exactly the same T = n+1 memories the CLI path
    leaves behind."""
    return [(seed_date(i), template(i)) for i in range(n)] + [
        (seed_date(n), BENCH_NOTE)
    ]


def prebuild_python(store, n):
    """Write a settled OptMem store directly (320/288 fixed records)."""
    recs = records(n)
    os.makedirs(os.path.join(store, "TREE"), exist_ok=True)
    with open(os.path.join(store, "LOG.txt"), "wb") as f:
        for i, (date, text) in enumerate(recs):
            rec = ("#%d %s %s" % (i, date, text)).encode()
            f.write(rec + b" " * (319 - len(rec)) + b"\n")
    memo_map = {}
    size = 2
    while size <= len(recs):
        with open(os.path.join(store, "TREE", str(size)), "wb") as f:
            for k in range(len(recs) // size):
                s = prebuild_summary(k * size, size, recs, memo_map).encode()
                f.write(s + b" " * (287 - len(s)) + b"\n")
        size *= 2


def prebuild_zig(store, n):
    """Write a settled LowMem store (ADR 0001 layout) directly."""
    recs = records(n)
    os.makedirs(os.path.join(store, "TREE"), exist_ok=True)
    off = 0
    offsets = []
    with open(os.path.join(store, "LOG"), "wb") as f:
        for date, text in recs:
            line = ("%s %s\n" % (date, text)).encode()
            offsets.append(off)
            off += len(line)
            f.write(line)
    _write_index(os.path.join(store, "INDEX"), off, offsets)
    memo_map = {}
    size = 2
    while size <= len(recs):
        toff = 0
        toffs = []
        with open(os.path.join(store, "TREE", str(size)), "wb") as f:
            for k in range(len(recs) // size):
                s = prebuild_summary(k * size, size, recs, memo_map).encode()
                toffs.append(toff)
                toff += len(s) + 1
                f.write(s + b"\n")
        _write_index(os.path.join(store, "TREE", str(size) + ".idx"), toff, toffs)
        size *= 2


def _write_index(path, log_size, offsets):
    import struct
    with open(path, "wb") as f:
        f.write(struct.pack("<IIQQ", INDEX_MAGIC, INDEX_VERSION, len(offsets), log_size))
        f.write(struct.pack("<%dQ" % len(offsets), *offsets))


def settle_cli(tool, store):
    naps = 0
    while True:
        rc, out, err, wall, rss = timed_run(tool + ["nap"], store)
        if "Nothing left to compress" in out:
            return naps, wall
        m = re.search(r"nap (\d+)-(\d+) \"<your line>\"", out)
        if not m:
            raise RuntimeError("no nap offered:\n" + out + err)
        body = [l for l in out.splitlines() if l.startswith("  #")]
        rc, out2, err2, wall, rss = timed_run(
            tool + ["nap", "%s-%s" % (m.group(1), m.group(2)), fake_summary(body)], store)
        if rc != 0:
            raise RuntimeError("nap rejected: " + err2)
        naps += 1


# ---------------------------------------------------------------- metrics

def store_bytes(store):
    total, files = 0, {}
    for root, _, names in os.walk(store):
        for name in sorted(names):
            p = os.path.join(root, name)
            sz = os.path.getsize(p)
            files[os.path.relpath(p, store)] = sz
            total += sz
    return total, files


def wake_parts(tool, store, reps):
    """Return (part1 walls, part1 rss list, n_parts, full walls list)."""
    part1_walls, rss, n_parts = [], [], None
    for _ in range(reps):
        rc, out, err, wall, rss_kb = timed_run(tool + ["wake"], store)
        if rc != 0:
            raise RuntimeError("wake failed: " + out + err)
        part1_walls.append(wall)
        rss.append(rss_kb)
        m = re.search(r"part 1 of (\d+)", out)
        if m:
            n_parts = int(m.group(1))
        else:
            n_parts = 1
    full = []
    T = log_len(store)
    for k in range(1, n_parts + 1):
        rc, out, err, wall, _ = timed_run(tool + ["wake", str(k), str(T)], store)
        if rc != 0:
            raise RuntimeError("wake %d failed: %s%s" % (k, out, err))
        full.append(wall)
    return part1_walls, rss, n_parts, full


def log_len(store):
    """T from the store's own format (the bench knows both)."""
    if os.path.exists(os.path.join(store, "LOG.txt")):
        return os.path.getsize(os.path.join(store, "LOG.txt")) // 320
    if os.path.exists(os.path.join(store, "INDEX")):
        # The header is 24 bytes (u32 magic, u32 version, u64 count,
        # u64 log size) — see _write_index.
        return (os.path.getsize(os.path.join(store, "INDEX")) - 24) // 8
    raise RuntimeError("unknown store format")


def nav_zooms(tool, store, n):
    """Zoom from the top of the tree down to one raw memory; wall per level."""
    t = n // 3
    size = 1
    while size < n:
        size *= 2
    lo, hi = 0, size
    walls = []
    while hi - lo > 1:
        rc, out, err, wall, _ = timed_run(tool + ["zoom", "%d-%d" % (lo, hi - 1)], store)
        if rc != 0:
            raise RuntimeError("zoom failed: " + out + err)
        walls.append(wall)
        mid = (lo + hi) // 2
        lo, hi = (mid, hi) if t >= mid else (lo, mid)
    return walls, t


def med(xs):
    return statistics.median(xs)


# ---------------------------------------------------------------- driver

def args_tool_is_zig(tool):
    return os.path.basename(tool[0]) == "lowmem"


def bench_size(tool, n, settle_cap, reps):
    store = tempfile.mkdtemp(prefix="lowmem-bench-")
    rec = {"size": n, "reps": reps}
    try:
        seed = seed_file(n)
        t0 = _wall()
        rc, out, err, wall, rss = timed_run(tool + ["import", seed], store)
        if rc != 0:
            raise RuntimeError("import failed: " + out + err)
        rec["import_s"] = wall

        # note latency on the fresh (unsettled) store, then pay the merge
        rc, out, err, wall, rss = timed_run(tool + ["note", "a benchmark memory, worth keeping"], store)
        if rc != 0:
            raise RuntimeError("note failed: " + out + err)
        rec["note_s"] = wall
        m = re.search(r"nap (\d+)-(\d+) \"<your line>\"", out)
        if m:
            body = [l for l in out.splitlines() if l.startswith("  #")]
            rc2, out2, err2, wall2, rss2 = timed_run(
                tool + ["nap", "%s-%s" % (m.group(1), m.group(2)), fake_summary(body)], store)
            rec["note_plus_nap_s"] = wall + wall2
            if rc2 != 0:
                raise RuntimeError("nap after note failed: " + err2)
        T = n + 1
    except Exception:
        shutil.rmtree(store, ignore_errors=True)
        raise

    # settle
    t0 = _wall()
    if T <= settle_cap:
        naps, _ = settle_cli(tool, store)
        rec["settle"] = {"method": "cli", "naps": naps, "s": _wall() - t0}
    else:
        # the CLI path above left T = n+1 memories (import + note); the
        # prebuilt store holds exactly those same T records
        if args_tool_is_zig(tool):
            prebuild_zig(store, n)
        else:
            prebuild_python(store, n)
        rec["settle"] = {"method": "prebuilt", "naps": 0, "s": _wall() - t0}

    total, files = store_bytes(store)
    rec["store_bytes"] = {"total": total, "files": files}

    p1, rss, n_parts, full = wake_parts(tool, store, reps)
    rec["wake"] = {
        "part1_ms": med(p1) * 1000, "part1_cold_ms": p1[0] * 1000,
        "peak_rss_kb": max(rss), "parts": n_parts, "full_ms": sum(full) * 1000,
    }

    rc, out, err, wall, _ = timed_run(tool + ["recall", "memory number 7,"], store)
    rec["recall_hit_ms"] = wall * 1000
    rec["recall_hit_out"] = out.strip().splitlines()[-1] if out.strip() else ""
    rc, out, err, wall, rss_kb = timed_run(tool + ["recall", "zzz-no-match-anywhere"], store)
    rec["recall_miss_ms"] = wall * 1000
    rec["recall_miss_rss_kb"] = rss_kb

    zwalls, t = nav_zooms(tool, store, T)
    rec["zoom_nav"] = {"levels": len(zwalls), "total_ms": sum(zwalls) * 1000,
                       "per_level_ms": med(zwalls) * 1000, "target": t}

    rc, out, err, wall, rss_kb = timed_run(tool + ["config"], store)
    rec["startup_config_ms"] = wall * 1000

    return rec


def _wall():
    import time as _t
    return _t.monotonic()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tool", choices=["python", "zig"], required=True)
    ap.add_argument("--sizes", default="100,1000,10000,100000,1000000")
    ap.add_argument("--settle-cap", type=int, default=10000,
                    help="settle via the real CLI up to this size")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.tool == "python":
        tool = [sys.executable, MEMO]
    else:
        if not os.path.exists(LOWMEM):
            sys.exit("zig binary not built: run `zig build` first")
        tool = [LOWMEM]

    recs = []
    for n in [int(s) for s in args.sizes.split(",")]:
        print("== %s: %d memories ==" % (args.tool, n), flush=True)
        r = bench_size(tool, n, args.settle_cap, args.reps)
        recs.append(r)
        print("   store %8.1f MB | wake part1 %8.1f ms (cold %8.1f) | full %8.1f ms"
              % (r["store_bytes"]["total"] / 1e6, r["wake"]["part1_ms"],
                 r["wake"]["part1_cold_ms"], r["wake"]["full_ms"]), flush=True)
        print("   note %8.1f ms | recall hit %8.1f miss %8.1f | zoom nav %8.1f ms (%d levels)"
              % (r["note_s"] * 1000, r["recall_hit_ms"], r["recall_miss_ms"],
                 r["zoom_nav"]["total_ms"], r["zoom_nav"]["levels"]), flush=True)

    outdir = os.path.dirname(args.out)
    if outdir:
        os.makedirs(outdir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump({"tool": args.tool, "sizes": [r["size"] for r in recs],
                   "results": recs}, f, indent=1)
    print("wrote %s" % args.out)


if __name__ == "__main__":
    main()
