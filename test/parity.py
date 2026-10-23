#!/usr/bin/env python3
"""LowMem parity gate: the same steps, both tools, byte-level diff.

Drives the OptMem reference (.scratch/optmem/memo) and LowMem
(zig-out/bin/lowmem) through identical step sequences against fresh
stores (every step is a new process, so persistence across restarts is
exercised all the way through) and diffs stdout, stderr, and exit code
after normalizing the documented differences (docs/behavior.md section 9):

  - the tool's self-path (<me>) and the store directory (<mem>);
  - the tool name and template naming (OptMem/memo -> LowMem/lowmem),
    the default directory name in the usage block, and the reference
    repo line the usage prints;
  - the ENTRY_CHARS ceiling line (280 fixed-width vs 64 KiB record,
    difference 3) is canonicalized to one shared form;
  - steps the two tools are documented to handle differently (difference
    4: the recall regex subset; the entry-ceiling consequence) are marked
    as such and reported, not failed.

Anything else that differs is a bug and fails the gate.

  python3 test/parity.py [--list] [--only NAME] [--keep]

Exit 0 all match, 1 mismatches, 2 usage.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEMO = os.path.join(HERE, ".scratch", "optmem", "memo")
LOWMEM = os.path.join(HERE, "zig-out", "bin", "lowmem")
STEP_TIMEOUT = 60  # a step that hangs this long is a bug (the flock class)

# ------------------------------------------------------------------ naming

PY_TOOL = [sys.executable, MEMO]
ZIG_TOOL = [LOWMEM]


def fold(p):
    """The $HOME -> ~ fold both tools apply when naming paths."""
    h = os.path.expanduser("~")
    if p == h:
        return "~"
    if p.startswith(h + os.sep):
        return "~" + p[len(h):]
    return p


def me_python():
    return fold(os.path.abspath(MEMO))


def me_zig():
    return fold(os.path.abspath(LOWMEM))


ENTRY_CAP_RE = re.compile(
    r"ENTRY_CHARS is at most \d+: a memory has to fit (?:the fixed-width )?records?\."
)


def normalize(text, side, store_dir):
    """The shared form of one tool's output: paths and names folded so the
    documented differences do not shadow the real comparison."""
    t = text.replace(me_python() if side == "python" else me_zig(), "<me>")
    t = t.replace(store_dir, "<mem>")
    if side == "python":
        t = re.sub(r"^See github\.com/VictorTaelin/OptMem\.\n?", "", t, flags=re.M)
        t = t.replace("~/.optmem/memory", "~/.lowmem/memory")
        t = t.replace("OptMem", "LowMem")
        t = re.sub(r"\bmemo\b", "lowmem", t)
    else:
        # The two migration commands the reference tool does not have
        # appear only in the usage block; drop them so the shared lines
        # compare (behavior.md section 9, difference 10).
        t = re.sub(r"^  <me> (?:import-optmem|export-optmem) <dir>.*\n?", "", t, flags=re.M)
    t = ENTRY_CAP_RE.sub(
        "ENTRY_CHARS is at most <MAX>: a memory has to fit the record.", t)
    return t

# ------------------------------------------------------------------ steps


def step(argv, label=None, diff=None):
    return {"argv": argv, "label": label or (" ".join(argv) or "<no args>"),
            "diff": diff}


SCENARIOS = []


def scenario(name, steps, store_kind="dir"):
    SCENARIOS.append({"name": name, "steps": steps, "store_kind": store_kind})


scenario("first-session", [
    step([], "no args: usage to stdout, exit 0"),
    step(["frobnicate"], "unknown command: refusal plus usage to stderr"),
    step(["wake"], "wake with no store: the no-memory refusal"),
    step(["init"]),
    step(["init"], "init on an existing store: Found, not Created"),
    step(["wake"], "wake with no memories"),
    step(["note", "hello world"]),
    step(["note", "the cat sat on the mat"], "second note offers the nap"),
    step(["wake"], "wake: raw lines, then the nap on a blank line"),
    step(["nap"], "nap with no args: the prompt"),
    step(["nap", "0-1", "a hello and a cat"]),
    step(["wake"], "settled: no nap tail"),
    step(["recall", "cat"]),
    step(["recall", "zzz"], "recall miss"),
    step(["recall", "h"], "recall, both directions of the case fold"),
    step(["zoom", "0-1"]),
    step(["zoom", "0-0"], "zoom a size-1 node: the raw memory"),
    step(["zoom", "1-1"]),
    step(["zoom", "2-3"], "zoom beyond the log"),
    step(["config"], "config: the defaults"),
])

scenario("entry-errors", [
    step(["init"]),
    step(["note", ""]),
    step(["note", "   "], "all whitespace is empty"),
    step(["note", "  x  "], "edges are trimmed, not rejected"),
    step(["note", "a\nb"]),
    step(["note", "a\nb\nc"]),
    step(["note", "a\r\nb"]),
    step(["note", "x" * 280], "exactly the limit fits"),
    step(["note", "\u00e9" * 140], "two-byte characters: 280 bytes fits"),
    step(["note", "\u00e9" * 140 + "y"], "281 bytes: too long"),
    step(["note", "x" * 100 + "\n"], "a trailing break is trimmed away"),
])

scenario("arg-errors", [
    step(["init"]),
    step(["note", "one"]),
    step(["note", "two"], "pay the pair so later checks have a log"),
    step(["nap", "0-1", "1+2"]),
    step(["note", "three"]),
    step(["wake", "x"], "non-digit part"),
    step(["wake", "1", "2", "3"], "three args"),
    step(["wake", "007"], "leading zeros print normalized"),
    step(["wake", "0"], "part 0"),
    step(["wake", "2", "1"], "a part past the last, as of T=1"),
    step(["wake", "1", "2"], "as of T=2: one part, part 1 valid"),
    step(["wake", "1", "000000000000000000000000000000000000000000000001"],
         "T past u64 prints normalized"),
    step(["zoom", "5"], "not an id at all"),
    step(["zoom", "0-2"], "not a block: odd size"),
    step(["zoom", "1-2"], "not a block: unaligned"),
    step(["zoom", "0--1"]),
    step(["zoom", "-0-1"]),
    step(["zoom", "0-1-x"]),
    step(["zoom", "9-3"], "backwards range"),
    step(["zoom", "0016-0031"], "leading zeros parse like the reference int"),
    step(["zoom", "0-99999999999999999999"],
         "an id past 2^64 memories",
         diff="the reference int is unbounded: NotBlock there, NotId here"),
    step(["nap", "0-1"], "one arg"),
    step(["nap", "0-1", "x", "y"], "three args"),
    step(["forget"]),
    step(["forget", "0-1", "2-3"]),
    step(["recall"]),
    step(["recall", "a", "b"]),
    step(["note"]),
    step(["note", "a", "b"]),
    step(["import"]),
    step(["config", "FOO=1"]),
    step(["config", "WAKE_LINES"]),
])

scenario("config", [
    step(["init"]),
    step(["config"]),
    step(["config", "WAKE_LINES=2"]),
    step(["config", "wake_lines = 4"], "lowercase name, padded value"),
    step(["config", "WAKE_LINES=0"]),
    step(["config", "WAKE_LINES=abc"]),
    step(["config", "WAKE_LINES=-1"]),
    step(["config", "WAKE_LINES=1.5"]),
    step(["config", "WAKE_LINES=1000000000000000000"],
         "a 19-digit budget is a size (a reading budget), and it echoes back"),
    step(["config", "WAKE_LINES=2"]),
    step(["note", "one"]),
    step(["note", "two"], "nap offered"),
    step(["wake"], "WAKE_LINES=2: the context needs #0-1: refusal, exit 1, stdout"),
    step(["nap", "0-1", "1+2"]),
    step(["wake"], "the context renders from the summary"),
    step(["note", "three"]),
    step(["note", "four"], "the next pair is offered"),
    step(["wake"], "refusal names #2-3 and counts the rest"),
    step(["nap", "2-3", "3+4"]),
    step(["nap", "0-3", "1+2+3+4"]),
    step(["wake"], "both summaries in the context"),
    step(["config", "WAKE_LINES="], "restore the default"),
    step(["config", "PART_CHARS=15"]),
    step(["wake"], "paged: part 1 of 2"),
    step(["wake", "2", "4"], "part 2, the last: awake"),
    step(["wake", "1", "4"], "part 1 again, as of T=4"),
    step(["wake", "3", "4"], "part past the last"),
    step(["wake", "1", "99"], "T past the log"),
    step(["config", "PART_CHARS=20000"]),
    step(["config", "PART_LINES=2"]),
    step(["wake"], "paged by lines: 4 raw lines in two parts"),
    step(["wake", "2", "4"]),
    step(["config", "PART_LINES="]),
    step(["config"]),
])

scenario("forget-and-rebuild", [
    step(["init"]),
    step(["config", "WAKE_LINES=1"], "force the context onto the top summary"),
    step(["note", "one"]),
    step(["note", "two"]),
    step(["nap", "0-1", "1+2"]),
    step(["note", "three"]),
    step(["note", "four"]),
    step(["nap", "2-3", "3+4"]),
    step(["wake"], "the top summary is missing: refusal"),
    step(["nap", "0-3", "all four"]),
    step(["wake"], "the context is one summary line"),
    step(["zoom", "0-3"], "zoom the top node: its halves"),
    step(["forget", "0-3"]),
    step(["wake"], "refusal again: the work comes back"),
    step(["nap"], "the prompt offers the forgotten block"),
    step(["forget", "2-3"], "forgetting a half drops the built top too"),
    step(["nap"], "the next pending is the dropped half"),
    step(["nap", "0-1", "x"], "the settled block is reported, not an error"),
    step(["nap", "2-3", "c+d"]),
    step(["forget", "0-1"]),
    step(["nap"], "the tail now counts two remaining"),
    step(["nap", "0-1", "a+b"]),
    step(["nap", "2-3", "c+d"]),
    step(["nap", "0-3", "everything"]),
    step(["wake"], "rebuilt: one summary line"),
    step(["config", "WAKE_LINES="]),
])

scenario("recall", [
    step(["init"]),
    step(["note", "the cat sat on the mat"]),
    step(["note", "a CAT in a hat"]),
    step(["note", "no matches here"]),
    step(["recall", "cat"], "case-insensitive: both cats"),
    step(["recall", "CAT"], "the other direction of the fold"),
    step(["recall", "^#1 "], "anchored: only the first column"),
    step(["recall", "zzz"], "miss"),
    step(["recall", "#"], "every line starts with #"),
    step(["config", "PART_CHARS=30"]),
    step(["recall", "#"], "capped: the newest that fit"),
    step(["config", "PART_CHARS=15"]),
    step(["recall", "#"], "capped below one line: the window empties"),
    step(["config", "PART_CHARS="]),
    step(["recall", "a.b"], "a metacharacter pattern",
         diff="difference 4: the reference engine reads a.b as a regex"),
    step(["recall", "((("], "an invalid pattern",
         diff="difference 4: the reference engine dies, this one searches literally"),
])

scenario("import", [
    step(["init"]),
    step(["import", "{good1}"], "three memories, one compression pending"),
    step(["import", "{good2}"], "one more, an equal date is allowed"),
    step(["import", "{good3}"], "blank lines are skipped"),
    step(["import", "{bad_format}"], "the shape is wrong"),
    step(["import", "{bad_month}"], "the shape is right, the date is not"),
    step(["import", "{old_date}"], "a date before the last memory"),
    step(["import", "{too_long}"], "the text is over the limit"),
    step(["import", "{empty_text}"], "a date with nothing after it"),
    step(["import", "{empty_file}"], "no memories at all"),
    step(["import", "{not_utf8}"], "not UTF-8"),
    step(["wake"], "the imported memories are the log"),
])

scenario("entry-ceiling", [
    step(["init"]),
    step(["config", "ENTRY_CHARS=281"],
         "the reference caps at 280 (fixed-width); the record ceiling is higher",
         diff="difference 3: the reference dies at most 280, this one stores 281"),
    step(["note", "x" * 281],
         "consequence of the ceiling: 281 bytes fits here, not there",
         diff="difference 3: Too long there, Saved here"),
    step(["config", "ENTRY_CHARS="], "restore: the table is back to defaults"),
])

scenario("created", [
    step(["init"], "a truly fresh store: Created, not Found"),
    step(["init"], "re-init on the fresh store: Found now"),
    step(["wake"], "and it wakes empty"),
], store_kind="absent")

scenario("not-a-dir", [
    step(["wake"], "MEMORY_DIR is a regular file: the no-memory refusal"),
    step(["config"]),
    step(["note", "x"]),
], store_kind="file")

# ------------------------------------------------------------------ driver


def make_fixtures(root):
    fx = {}

    def w(name, data):
        p = os.path.join(root, name)
        mode = "wb" if isinstance(data, bytes) else "w"
        with open(p, mode) as f:
            f.write(data)
        fx[name] = p

    w("good1", "2020-01-01 first day\n2020-01-02 second day\n2020-01-03  two spaces after the date\n")
    w("good2", "2020-01-03 same day again\n")
    w("good3", "2020-01-04 after a blank\n\n   \n2020-01-05 after whitespace\n")
    w("bad_format", "2020-1-1 wrong shape\n")
    w("bad_month", "2020-13-01 no such month\n")
    w("old_date", "2020-01-01 old news\n")
    w("too_long", "2020-01-01 " + "x" * 281 + "\n")
    w("empty_text", "2020-01-06   \n")
    w("empty_file", "")
    w("not_utf8", b"2020-01-01 ok\n\xff\xfe broken\n")
    return fx


def run_step(tool, store_dir, argv, fixture_map):
    argv = [a.format(**fixture_map) for a in argv]
    env = dict(os.environ, MEMORY_DIR=store_dir)
    try:
        p = subprocess.run(tool + argv, env=env, capture_output=True,
                           timeout=STEP_TIMEOUT)
        return p.returncode, p.stdout.decode("utf-8", "replace"), \
            p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT after %ds" % STEP_TIMEOUT


class Side(object):
    def __init__(self, name, tool, store_dir, fixture_map):
        self.name = name
        self.tool = tool
        self.store_dir = store_dir
        self.fixture_map = fixture_map
        self.results = []

    def run(self, steps):
        for st in steps:
            rc, out, err = run_step(self.tool, self.store_dir, st["argv"],
                                    self.fixture_map)
            self.results.append((rc, out, err))

    def norm(self, i):
        rc, out, err = self.results[i]
        return rc, normalize(out, self.name, self.store_dir), \
            normalize(err, self.name, self.store_dir)


def show(step_no, st, a, b):
    print("  step %2d: %s" % (step_no, st["label"]))
    for tag, side in (("python", a), ("zig", b)):
        rc, out, err = side
        print("  %s %s: exit %d" % ("-" * 6, tag, rc))
        for line in out.splitlines():
            print("  %s%s %s" % ("|", tag, line))
        for line in err.splitlines():
            print("  %s%s %s" % ("!", tag, line))


def main():
    args = [a for a in sys.argv[1:] if a.startswith("--")]
    only = None
    keep = False
    if "--list" in args:
        for sc in SCENARIOS:
            print("%-22s %3d steps" % (sc["name"], len(sc["steps"])))
        return
    if "--only" in args:
        i = sys.argv.index("--only")
        only = sys.argv[i + 1] if i + 1 < len(sys.argv) else None
    if "--keep" in args:
        keep = True

    if not os.path.exists(MEMO):
        sys.exit("reference tool missing: %s" % MEMO)
    if not os.path.exists(LOWMEM):
        sys.exit("lowmem not built: run `zig build` first")

    fixtures_root = tempfile.mkdtemp(prefix="lowmem-parity-fixtures-")
    fixture_map = make_fixtures(fixtures_root)

    failures = 0
    diffs = 0
    steps_total = 0
    keep_stores = []
    try:
        for sc in SCENARIOS:
            if only and sc["name"] != only:
                continue
            if sc["store_kind"] == "absent":
                # A path that does not exist yet: init must create it.
                root = tempfile.mkdtemp(prefix="lowmem-parity-root-")
                py_dir = os.path.join(root, "store-py")
                zig_dir = os.path.join(root, "store-zig")
            else:
                py_dir = tempfile.mkdtemp(prefix="lowmem-parity-py-")
                zig_dir = tempfile.mkdtemp(prefix="lowmem-parity-zig-")
                if sc["store_kind"] == "file":
                    for d in (py_dir, zig_dir):
                        os.rmdir(d)  # mkdtemp made a directory; we want a file
                        open(d, "w").close()
            py = Side("python", PY_TOOL, py_dir, fixture_map)
            zig = Side("zig", ZIG_TOOL, zig_dir, fixture_map)
            py.run(sc["steps"])
            zig.run(sc["steps"])

            bad = []
            for i, st in enumerate(sc["steps"]):
                steps_total += 1
                a = py.norm(i)
                b = zig.norm(i)
                if a != b:
                    if st["diff"]:
                        diffs += 1
                        print("  [documented diff] %s: %s" % (sc["name"], st["label"]))
                    else:
                        bad.append(i)
            if bad:
                failures += len(bad)
                print("FAIL %-22s (%d/%d steps)" % (sc["name"], len(bad), len(sc["steps"])))
                for i in bad:
                    show(i, sc["steps"][i], py.norm(i), zig.norm(i))
            else:
                print("ok   %-22s (%d steps)" % (sc["name"], len(sc["steps"])))
            if keep:
                keep_stores.append((sc["name"], py_dir, zig_dir))
            else:
                shutil.rmtree(py_dir, ignore_errors=True)
                shutil.rmtree(zig_dir, ignore_errors=True)
    finally:
        shutil.rmtree(fixtures_root, ignore_errors=True)

    if keep:
        print("stores kept under:")
        for name, py_d, zig_d in keep_stores:
            print("  %s: %s | %s" % (name, py_d, zig_d))
    print()
    if failures:
        print("%d mismatching step(s) across %d steps (%d documented diffs reported)"
              % (failures, steps_total, diffs))
        sys.exit(1)
    print("parity: %d steps, all match (%d documented diffs reported)"
          % (steps_total, diffs))


if __name__ == "__main__":
    main()
