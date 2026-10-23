#!/usr/bin/env python3
"""Deterministic benchmark datasets for LowMem.

Generates `YYYY-MM-DD <text>` seed files in OptMem's import format, using
the same template the reference test suite uses, so the Python and Zig
implementations are always measured on byte-identical data.

    python3 test/gen_data.py --n 100000 --out test/data/seed_100000.txt

Dates advance one day every five memories (5 memories/day), starting
2020-01-01. The text embeds the memory number, so `recall "memory number
7,"` has exactly one hit in any dataset.
"""

import argparse
import datetime


def template(i):
    return (
        "memory number %d, a thing that happened, was weighed against the "
        "rest of the week, turned out to matter more than anyone guessed at "
        "the time, and left a mark on every plan that followed it" % i
    )


def generate(n, out):
    day = datetime.date(2020, 1, 1)
    with open(out, "w", encoding="utf-8") as f:
        for i in range(n):
            f.write("%s %s\n" % ((day + datetime.timedelta(days=i // 5)).isoformat(), template(i)))
    print("wrote %s: %d memories" % (out, n))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    generate(args.n, args.out)


if __name__ == "__main__":
    main()
