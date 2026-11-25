#!/usr/bin/env python3
"""The release gate. A GitHub release (and the Integration workflow it starts) is for releasing the app on the App Store, not for TestFlight.

  release_gate.py                         App Store: the commit checked out here passed CI (unit tests) and Integration (UI tests, every site)
  release_gate.py --for testflight        TestFlight: only CI (unit tests) is required; Integration is not
  release_gate.py --sha SHA [...]         checks that commit (for the App Store: the commit a TestFlight build was made from, before submitting it for review)
  release_gate.py --confirmed SHA [...]   the owner saw the required workflows pass for SHA on GitHub themselves: GitHub's API is not asked (it answers 60
                                          requests an hour without a login, and refuses the rest). SHA must be the commit being released (7 or more characters);
                                          the working copy and main are still checked.

Exits 0 when it may go out, 1 with the reasons when not. tools/release_testflight.sh runs it with --for testflight and stops when it fails. It checks,
from GitHub's public API (no login):
  - the working copy has no uncommitted change (what is built is what was tested),
  - the commit is on GitHub's main,
  - the CI workflow (.github/workflows/ci.yml, unit tests) succeeded for exactly this commit,
  - for the App Store only: the Integration workflow (.github/workflows/integration.yml) succeeded for exactly this commit.
TestFlight is the owner's own test channel, and builds go there to try a fix on a phone within minutes; Integration takes up to two hours. A build is
submitted for App Store review only after this gate passes for its commit without --for testflight. docs/TESTING.md, "Releasing".
"""
import argparse, json, subprocess, sys, urllib.request

REPO = "dcreey/opt-out-kit"
API = "https://api.github.com/repos/" + REPO


def fetch(url):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "release-gate"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout.strip()


def workflow_passed(workflow, sha, get=fetch):
    """(passed, why): whether the latest run of this workflow for exactly this commit succeeded."""
    runs = get(f"{API}/actions/workflows/{workflow}/runs?head_sha={sha}&per_page=20").get("workflow_runs", [])
    if not runs:
        return False, f"{workflow} has not run for {sha[:7]}"
    runs.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    latest = runs[0]
    if latest.get("status") != "completed":
        return False, f"{workflow} is still running for {sha[:7]} ({latest.get('html_url')})"
    if latest.get("conclusion") != "success":
        return False, f"{workflow} did not pass for {sha[:7]}: {latest.get('conclusion')} ({latest.get('html_url')})"
    return True, f"{workflow} passed for {sha[:7]} ({latest.get('html_url')})"


TARGETS = {"app-store": ["ci.yml", "integration.yml"], "testflight": ["ci.yml"]}


def confirmed_matches(confirmed, sha):
    """Whether a by-hand confirmation names this commit: at least 7 characters of its hash, from the start."""
    c = (confirmed or "").strip().lower()
    return len(c) >= 7 and sha.lower().startswith(c)


def check(sha, dirty, on_main, get=fetch, target="app-store", confirmed=None):
    """Every reason the commit may not go to `target` (empty: it may). With `confirmed` (the commit the owner saw pass on GitHub), the workflows are
    not looked up; it must name this commit."""
    problems = []
    if dirty: problems.append("the working copy has uncommitted changes; commit and push them, and test that commit")
    if not on_main: problems.append(f"{sha[:7]} is not on GitHub's main; push it first")
    if confirmed is not None:
        if not confirmed_matches(confirmed, sha):
            problems.append(f"--confirmed {confirmed} does not name {sha[:7]}, the commit being released; confirm that commit's runs")
        return problems
    for wf in TARGETS[target]:
        try:
            ok, why = workflow_passed(wf, sha, get)
        except Exception as e:          # the API refused (its hourly limit without a login) or could not be reached
            ok, why = False, (f"GitHub's API did not answer about {wf} ({e}); look at the run for {sha[:7]} yourself and, if it passed, "
                              f"run again with --confirmed {sha[:7]}")
        if not ok: problems.append(why)
    return problems


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--sha"); ap.add_argument("--for", dest="target", choices=sorted(TARGETS), default="app-store")
    ap.add_argument("--confirmed", metavar="SHA", help="the commit whose required workflows you saw pass on GitHub yourself (GitHub's API is not asked)")
    a = ap.parse_args()
    sha = a.sha or git("rev-parse", "HEAD")
    dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
    subprocess.run(["git", "fetch", "-q", "origin", "main"], check=False)
    on_main = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"]).returncode == 0
    problems = check(sha, dirty, on_main, target=a.target, confirmed=a.confirmed)
    if problems:
        print(f"Release gate ({a.target}): not released.")
        for p in problems: print("  - " + p)
        if a.target == "testflight":
            print("To upload to TestFlight: push the commit and wait for CI to pass for it, then run this again.")
        else:
            print("To release on the App Store: push the commit, then publish a GitHub release for it (Releases, Draft a new release, tag it; the Integration\n"
                  "workflow runs on it) or run Integration by hand (Actions, Integration, Run workflow, on main). When both CI and Integration pass, run this again.")
        sys.exit(1)
    what = "CI" if a.target == "testflight" else "CI and Integration"
    if a.confirmed is not None:
        print(f"Release gate ({a.target}): {sha[:7]} released on the owner's word that {what} passed (--confirmed; GitHub's API was not asked).")
    else:
        print(f"Release gate ({a.target}): {sha[:7]} passed {what}.")


if __name__ == "__main__":
    main()
