#!/usr/bin/env python3
"""Splits a test target's XCTestCase classes into shards for CI, so each shard runs on its own machine.

  ci_shards.py --target OptOutKitTests --dir AppTests --shards 3 --index 0     prints the -only-testing: arguments for shard 0, one per line
  ci_shards.py --target OptOutKitTests --dir AppTests --shards 3 --list        shows every shard and its weight

Classes are found by reading the test sources (`class Name: XCTestCase`), so a new test class is picked up with no change here. Each class weighs
its number of test methods, and shards are filled heaviest first, each class going to the lightest shard (the same split on every run).
`--skip Class/testMethod` leaves a test out (passed through as -skip-testing:); used for tests known to fail, which are listed in docs/TESTING.md.
"""
import argparse, glob, os, re, sys

CLASS = re.compile(r'^\s*(?:@MainActor\s+)?(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase', re.M)
TEST = re.compile(r'^\s*(?:@MainActor\s+)?func\s+(test\w*)\s*\(', re.M)


def classes(directory):
    out = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.swift"))):
        src = open(path, encoding="utf-8").read()
        found = list(CLASS.finditer(src))
        for i, m in enumerate(found):
            end = found[i + 1].start() if i + 1 < len(found) else len(src)
            n = len(TEST.findall(src[m.end():end]))
            if n: out[m.group(1)] = n
    return out


def split(weights, shards):
    bins = [[] for _ in range(shards)]; load = [0] * shards
    for name, w in sorted(weights.items(), key=lambda kv: (-kv[1], kv[0])):
        i = load.index(min(load)); bins[i].append(name); load[i] += w
    return bins, load


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True); ap.add_argument("--dir", required=True)
    ap.add_argument("--shards", type=int, required=True); ap.add_argument("--index", type=int)
    ap.add_argument("--list", action="store_true"); ap.add_argument("--skip", action="append", default=[])
    a = ap.parse_args()
    weights = classes(a.dir)
    if not weights: sys.exit(f"no XCTestCase classes found in {a.dir}")
    bins, load = split(weights, a.shards)
    if a.list:
        for i, (b, w) in enumerate(zip(bins, load)): print(f"shard {i}: {w} tests in {len(b)} classes: {', '.join(sorted(b))}")
        return
    if a.index is None or not 0 <= a.index < a.shards: sys.exit("--index is required (0 to shards-1)")
    args = [f"-only-testing:{a.target}/{c}" for c in sorted(bins[a.index])]
    args += [f"-skip-testing:{a.target}/{s}" for s in a.skip if s.split("/")[0] in bins[a.index]]
    print("\n".join(args))          # one argument per line, so no shell splits or joins them


if __name__ == "__main__":
    main()
