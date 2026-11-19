#!/usr/bin/env python3
"""The release gate: a build goes to TestFlight or the App Store only from a commit whose unit tests (CI) and integration tests (Integration) passed.

  release_gate.py            checks the commit checked out here; exits 0 when it may be released, 1 with the reason when not
  release_gate.py --sha SHA  checks that commit

tools/release_testflight.sh runs this first and stops when it fails. It checks, from GitHub's public API (no login):
  - the working copy has no uncommitted change (what is built is what was tested),
  - the commit is on GitHub's main,
  - the CI workflow (.github/workflows/ci.yml, unit tests) succeeded for exactly this commit,
  - the Integration workflow (.github/workflows/integration.yml: the UI tests and the run over every site) succeeded for exactly this commit.
Integration runs when a GitHub release is published for the commit, or by hand (Actions, Integration, Run workflow, on main). docs/TESTING.md, "Releasing".
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


def check(sha, dirty, on_main, get=fetch):
    """Every reason the commit may not be released (empty: it may)."""
    problems = []
    if dirty: problems.append("the working copy has uncommitted changes; commit and push them, and test that commit")
    if not on_main: problems.append(f"{sha[:7]} is not on GitHub's main; push it first")
    for wf in ["ci.yml", "integration.yml"]:
        ok, why = workflow_passed(wf, sha, get)
        if not ok: problems.append(why)
    return problems


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--sha")
    a = ap.parse_args()
    sha = a.sha or git("rev-parse", "HEAD")
    dirty = bool(git("status", "--porcelain", "--untracked-files=no"))
    subprocess.run(["git", "fetch", "-q", "origin", "main"], check=False)
    on_main = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"]).returncode == 0
    problems = check(sha, dirty, on_main)
    if problems:
        print("Release gate: not released.")
        for p in problems: print("  - " + p)
        print("To release: push the commit, then publish a GitHub release for it (Releases, Draft a new release, tag it; the Integration workflow runs on it)\n"
              "or run Integration by hand (Actions, Integration, Run workflow, on main). When both CI and Integration pass for it, run this again.")
        sys.exit(1)
    print(f"Release gate: {sha[:7]} passed CI and Integration.")


if __name__ == "__main__":
    main()
