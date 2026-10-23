#!/usr/bin/env python3
"""LowMem migration gate: OptMem -> LowMem -> OptMem, end to end.

Builds a real OptMem store with the reference tool (init, six notes,
naps paying real summaries, one block left pending), imports it into a
fresh LowMem store, checks that the imported memory reads the same
(wake, zoom), exports it back, and requires the export to be
byte-identical to the source (LOG.txt and every TREE file). The
refusals (non-empty target, missing source, no log, empty log, an
export target that already has a LOG.txt) are asserted too, and the
exported store is re-imported to prove the second hop.

  python3 test/migration.py [--keep]

Exit 0 all pass, 1 a failure.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "test"))

from parity import PY_TOOL, ZIG_TOOL, normalize  # noqa: E402

TIMEOUT = 60  # a step that hangs this long is a bug (the flock class)
FAILURES = []


def check(name, cond, detail=""):
    if cond:
        print("ok   " + name)
    else:
        print("FAIL " + name)
        if detail:
            for line in detail.strip().splitlines():
                print("       " + line)
        FAILURES.append(name)


def run(tool, args, memory_dir):
    env = dict(os.environ, MEMORY_DIR=memory_dir)
    return subprocess.run(
        tool + args, capture_output=True, text=True, env=env, timeout=TIMEOUT)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def main():
    keep = "--keep" in sys.argv[1:]
    root = tempfile.mkdtemp(prefix="lm-mig-")
    src = os.path.join(root, "src")
    tgt = os.path.join(root, "tgt")
    tgt2 = os.path.join(root, "tgt2")
    out = os.path.join(root, "out")
    out2 = os.path.join(root, "out2")

    try:
        # 1. The source: a real OptMem store, built by the reference
        #    tool. Six memories; the three level-2 pairs settled in
        #    order (naps pay blocks smallest first), 0-3 left pending, so
        #    the import has a pending block to keep.
        r = run(PY_TOOL, ["init"], src)
        check("source: init", r.returncode == 0, r.stderr)
        for m in ["first", "second", "third", "fourth", "fifth", "sixth"]:
            r = run(PY_TOOL, ["note", m], src)
            check("source: note " + m, r.returncode == 0, r.stderr)
        for block, line in [
            ("0-1", "the first pair"),
            ("2-3", "the second pair"),
            ("4-5", "the third pair"),
        ]:
            r = run(PY_TOOL, ["nap", block, line], src)
            check(
                "source: nap " + block,
                r.returncode == 0 and (block + " saved.") in r.stdout,
                r.stdout + r.stderr)

        # 2. The import: into a fresh, empty LowMem store.
        r = run(ZIG_TOOL, ["init"], tgt)
        check("target: init", r.returncode == 0, r.stderr)
        before = read(os.path.join(tgt, "LOG"))
        r = run(ZIG_TOOL, ["import-optmem", src], tgt)
        check("import: exit 0", r.returncode == 0, r.stderr)
        check(
            "import: reported",
            "Imported 6 memories, #0 to #5." in r.stdout
            and "Carried 3 summaries." in r.stdout
            and "1 compression pending." in r.stdout,
            r.stdout)
        after = read(os.path.join(tgt, "LOG"))

        # 3. The refusals, and that they touch nothing.
        r = run(ZIG_TOOL, ["import-optmem", src], tgt)
        check(
            "refusal: non-empty target",
            r.returncode == 1 and "already holds" in r.stderr, r.stderr)
        r = run(ZIG_TOOL, ["import-optmem", os.path.join(root, "nope")], tgt)
        check(
            "refusal: missing source",
            r.returncode == 1 and "No such file or directory" in r.stderr,
            r.stderr)
        nol = os.path.join(root, "nolog")
        os.makedirs(nol)
        r = run(ZIG_TOOL, ["import-optmem", nol], tgt)
        check(
            "refusal: source without a LOG.txt",
            r.returncode == 1 and "LOG.txt" in r.stderr
            and "No such file or directory" in r.stderr,
            r.stderr)
        zerolog = os.path.join(root, "zerolog")
        os.makedirs(zerolog)
        open(os.path.join(zerolog, "LOG.txt"), "w").close()
        r = run(ZIG_TOOL, ["import-optmem", zerolog], tgt)
        check(
            "refusal: empty log",
            r.returncode == 1 and "has no memories" in r.stderr, r.stderr)
        check("refusals touched nothing", read(os.path.join(tgt, "LOG")) == after)

        # 4. The imported memory reads the same as the source: wake and
        #    zoom, normalized the way the parity gate normalizes.
        for label, args in [
            ("wake", ["wake"]),
            ("zoom 0-1", ["zoom", "0-1"]),
            ("zoom 0-3", ["zoom", "0-3"]),
        ]:
            a = run(PY_TOOL, args, src)
            b = run(ZIG_TOOL, args, tgt)
            check(
                "read parity: " + label,
                a.returncode == b.returncode
                and normalize(a.stdout, "python", src)
                == normalize(b.stdout, "zig", tgt),
                "python:\n" + a.stdout + "\nzig:\n" + b.stdout)

        # 5. The export: back to the OptMem format, byte-identical.
        r = run(ZIG_TOOL, ["export-optmem", out], tgt)
        check("export: exit 0", r.returncode == 0, r.stderr)
        check(
            "export: reported",
            r.stdout.startswith("Exported 6 memories and 3 summaries to "),
            r.stdout)
        for sub in ["LOG.txt", os.path.join("TREE", "2")]:
            check(
                "byte-identical: " + sub,
                read(os.path.join(src, sub)) == read(os.path.join(out, sub)))
        check(
            "no TREE/4: 0-3 is unsettled, in source and export",
            not os.path.exists(os.path.join(src, "TREE", "4"))
            and not os.path.exists(os.path.join(out, "TREE", "4")))
        check("export: no config carried", not os.path.exists(os.path.join(out, "config")))
        r = run(ZIG_TOOL, ["export-optmem", src], tgt)
        check(
            "refusal: export into a LOG.txt directory",
            r.returncode == 1 and "already has a LOG.txt" in r.stderr,
            r.stderr)

        # 6. The second hop: the export imports like the source did.
        r = run(ZIG_TOOL, ["init"], tgt2)
        check("re-target: init", r.returncode == 0, r.stderr)
        r = run(ZIG_TOOL, ["import-optmem", out], tgt2)
        check(
            "re-import: exit 0",
            r.returncode == 0
            and "Imported 6 memories, #0 to #5." in r.stdout
            and "Carried 3 summaries." in r.stdout
            and "1 compression pending." in r.stdout,
            r.stdout)
        r = run(ZIG_TOOL, ["export-optmem", out2], tgt2)
        check("re-export: exit 0", r.returncode == 0, r.stderr)
        for sub in ["LOG.txt", os.path.join("TREE", "2")]:
            check(
                "stable round trip: " + sub,
                read(os.path.join(out, sub)) == read(os.path.join(out2, sub)))

    finally:
        if keep:
            print("kept: " + root)
        else:
            shutil.rmtree(root, ignore_errors=True)

    if FAILURES:
        print("migration: " + str(len(FAILURES)) + " failure(s): " + ", ".join(FAILURES))
        return 1
    print("migration: all pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
