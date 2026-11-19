#!/usr/bin/env python3
"""Splits the app's test classes (unit and UI together) into shards for CI, so each shard runs on its own machine and all of them end at about the
same time.

  ci_shards.py --shards 5 --index 0          the -only-testing: arguments for shard 0, one per line
  ci_shards.py --shards 5 --list             every shard, its classes and its expected seconds
  ci_shards.py --timings-from-log LOG        the seconds each class took in an xcodebuild log, as one line of JSON (CI prints it as a notice)
  ci_shards.py --failures-from-log LOG      each failed test and its message, as annotations (CI prints them)
  ci_shards.py --fetch-run RUN_ID            reads those notices from a finished GitHub run (public API, no login) into tools/ci_timings.json

Classes are found by reading the test sources (`class Name: XCTestCase`), so a new class is picked up with no change here. A class weighs the
seconds it took in the last measured run (tools/ci_timings.json); a class never measured is estimated from its number of tests. Shards are filled
longest class first, each class going to the shard with the least so far. UI tests are handed out one test at a time, unit tests one class at a time. `--skip Target/Class/testMethod` leaves a test out;
used for tests known to fail, which are listed in docs/TESTING.md.
"""
import argparse, glob, json, os, re, sys, urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SUITES = [("OptOutKitTests", "AppTests"), ("OptOutKitUITests", "AppUITests")]
TIMINGS = os.path.join(ROOT, "tools", "ci_timings.json")
# Seconds a test is guessed to take before it has been measured: a UI test launches the app and taps through screens.
GUESS = {"OptOutKitTests": 2.0, "OptOutKitUITests": 40.0}

CLASS = re.compile(r'^\s*(?:@MainActor\s+)?(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase', re.M)
TEST = re.compile(r'^\s*(?:@MainActor\s+)?func\s+(test\w*)\s*\(', re.M)
CASE = re.compile(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (?:passed|failed|skipped) \((\d+(?:\.\d+)?) seconds\)")


def methods(directory):
    """Test classes in a folder of sources, with their test methods."""
    out = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.swift"))):
        src = open(path, encoding="utf-8").read()
        found = list(CLASS.finditer(src))
        for i, m in enumerate(found):
            end = found[i + 1].start() if i + 1 < len(found) else len(src)
            tests = TEST.findall(src[m.end():end])
            if tests: out[m.group(1)] = tests
    return out


def classes(directory):
    """Test classes in a folder of sources, with their number of test methods."""
    return {c: len(t) for c, t in methods(directory).items()}


# UI tests are shared out one test at a time (each launches the app afresh anyway, and one class of them can take ten minutes); unit tests one class
# at a time (they are quick, and a class's tests share their setup).
BY_TEST = {"OptOutKitUITests"}


def work(timings, root=ROOT):
    """Everything to run, as "Target/Class" or "Target/Class/test", with its expected seconds."""
    out = {}
    for target, folder in SUITES:
        for cls, tests in methods(os.path.join(root, folder)).items():
            if target in BY_TEST:
                for t in tests: out[f"{target}/{cls}/{t}"] = float(timings.get(f"{target}/{cls}/{t}", GUESS[target]))
            else:
                out[f"{target}/{cls}"] = float(timings.get(f"{target}/{cls}", len(tests) * GUESS[target]))
    return out


def split(weights, shards, reserve=None):
    """`reserve`: seconds a shard already spends on other work (shard 0 runs the Swift packages' tests), so it gets that much less."""
    bins = [[] for _ in range(shards)]; load = [0.0] * shards
    for i, secs in (reserve or {}).items(): load[i] += secs
    for name, w in sorted(weights.items(), key=lambda kv: (-kv[1], kv[0])):
        i = load.index(min(load)); bins[i].append(name); load[i] += w
    return bins, load


def timings_from_log(text):
    out = {}
    for target, cls, test, secs in CASE.findall(text):
        key = f"{target}/{cls}/{test}" if target in BY_TEST else f"{target}/{cls}"
        out[key] = out.get(key, 0.0) + float(secs)
    return {k: round(v, 1) for k, v in out.items()}          # rounded once, at the end


FAIL = re.compile(r"(?:([\w./-]+\.swift):(\d+): )?error: -\[(\w+)\.(\w+) (\w+)\] : (.*)")


def failures_from_log(text):
    """Each failed test's assertion messages, as GitHub annotation commands. GitHub shows only 10 errors per step, so all of them also go in one
    notice; both can be read from a public run without logging in (`--fetch-run` style)."""
    seen = {}
    for path, line, target, cls, test, msg in FAIL.findall(text):
        where = f"{os.path.basename(path)}:{line}: " if path else ""          # which assertion, so a failure can be found without the log
        seen.setdefault(f"{target}/{cls}/{test}", []).append(where + msg.strip()[:300])
    lines = [f"::error title={k}::{' | '.join(v)}" for k, v in seen.items()]
    if seen: lines.append("::notice title=Failed tests::" + " || ".join(f"{k}: {' | '.join(v)}" for k, v in seen.items())[:60000])
    return lines


STEP = re.compile(r"^(.+?) \((\d+) tasks?\) \| (\d+(?:\.\d+)?) seconds$", re.M)


def build_summary(text, cache="", folder=None):
    """One notice from an xcodebuild log built with -showBuildTimingSummary: the slowest kinds of step, the Swift files compiled, the cache used and the
    build folder's size, so a run shows where its build time went."""
    steps = sorted(((float(sec), name, int(n)) for name, n, sec in STEP.findall(text)), reverse=True)
    compiled = len(re.findall(r"^SwiftCompile normal ", text, re.M))          # not the summary's own "SwiftCompile (n tasks)" line
    top = ", ".join(f"{name} {sec:.0f} s ({n})" for sec, name, n in steps[:6]) or "no timing summary"
    size = ""
    if folder and os.path.isdir(folder):
        total = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(folder) for f in fs if not os.path.islink(os.path.join(r, f)))
        size = f"; build folder {total / 1e6:.0f} MB"
    return f"::notice title=Build::{compiled} Swift files compiled (cache: {cache or '?'}){size}. Slowest: {top}"


def load_timings():
    return json.load(open(TIMINGS)) if os.path.exists(TIMINGS) else {}


def fetch_run(run_id, repo="dcreey/opt-out-kit"):
    """Reads every shard's timing notice from a finished run and merges it into tools/ci_timings.json."""
    get = lambda url: json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})))
    jobs = get(f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/jobs?per_page=50")["jobs"]
    merged = load_timings(); found = 0
    for j in jobs:
        for a in get(f"https://api.github.com/repos/{repo}/check-runs/{j['id']}/annotations"):
            if a.get("title") == "Shard timings":
                merged.update(json.loads(a["message"])); found += 1
    if not found: sys.exit("no timing notices in that run")
    json.dump(dict(sorted(merged.items())), open(TIMINGS, "w"), indent=1); open(TIMINGS, "a").write("\n")
    print(f"merged {found} shards' timings into {os.path.relpath(TIMINGS, ROOT)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", type=int); ap.add_argument("--index", type=int)
    ap.add_argument("--list", action="store_true"); ap.add_argument("--skip", action="append", default=[])
    ap.add_argument("--reserve", action="append", default=[], help="SHARD:SECONDS of other work on that shard")
    ap.add_argument("--build-summary"); ap.add_argument("--cache", default=""); ap.add_argument("--folder")
    ap.add_argument("--timings-from-log"); ap.add_argument("--failures-from-log"); ap.add_argument("--fetch-run")
    a = ap.parse_args()
    if a.timings_from_log: print(json.dumps(timings_from_log(open(a.timings_from_log, errors="replace").read()), sort_keys=True, separators=(",", ":"))); return
    if a.build_summary: print(build_summary(open(a.build_summary, errors="replace").read(), a.cache, a.folder)); return
    if a.failures_from_log: print("\n".join(failures_from_log(open(a.failures_from_log, errors="replace").read()))); return
    if a.fetch_run: fetch_run(a.fetch_run); return
    if not a.shards: sys.exit("--shards is required")
    weights = work(load_timings())
    if not weights: sys.exit("no XCTestCase classes found")
    reserve = {int(r.split(":")[0]): float(r.split(":")[1]) for r in a.reserve}
    bins, load = split(weights, a.shards, reserve)
    if a.list:
        for i, (b, w) in enumerate(zip(bins, load)): print(f"shard {i}: about {w / 60:.1f} min, {len(b)} classes: {', '.join(sorted(b))}")
        return
    if a.index is None or not 0 <= a.index < a.shards: sys.exit("--index is required (0 to shards-1)")
    mine = sorted(bins[a.index])
    args = [f"-only-testing:{k}" for k in mine]
    # A known-failing test is skipped where its class runs, or is left out where it was handed out on its own.
    args = [x for x in args if x[len("-only-testing:"):] not in a.skip]
    args += [f"-skip-testing:{s}" for s in a.skip if "/".join(s.split("/")[:2]) in mine]
    print("\n".join(args))          # one argument per line, so no shell splits or joins them


if __name__ == "__main__":
    main()
