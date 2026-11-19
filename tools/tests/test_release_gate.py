import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import release_gate as G

SHA = "a" * 40


def api(runs):
    """A stand-in for GitHub: each workflow's runs for the commit."""
    def get(url):
        for wf, rs in runs.items():
            if f"/workflows/{wf}/" in url: return {"workflow_runs": rs}
        return {"workflow_runs": []}
    return get


def run(conclusion="success", status="completed", created="2026-11-19T10:00:00Z"):
    return {"status": status, "conclusion": conclusion, "created_at": created, "html_url": "https://github.com/x"}


class ReleaseGate(unittest.TestCase):
    def test_a_commit_that_passed_ci_and_integration_may_be_released(self):
        self.assertEqual(G.check(SHA, dirty=False, on_main=True, get=api({"ci.yml": [run()], "integration.yml": [run()]})), [])

    def test_without_an_integration_run_it_may_not(self):
        problems = G.check(SHA, dirty=False, on_main=True, get=api({"ci.yml": [run()]}))
        self.assertEqual(len(problems), 1)
        self.assertIn("integration.yml has not run", problems[0])

    def test_a_failed_or_running_integration_stops_it(self):
        self.assertIn("did not pass", G.check(SHA, False, True, api({"ci.yml": [run()], "integration.yml": [run("failure")]}))[0])
        self.assertIn("still running", G.check(SHA, False, True, api({"ci.yml": [run()], "integration.yml": [run(None, "in_progress")]}))[0])

    def test_the_latest_run_decides(self):
        rs = [run("failure", created="2026-11-19T09:00:00Z"), run("success", created="2026-11-19T11:00:00Z")]
        self.assertEqual(G.check(SHA, False, True, api({"ci.yml": [run()], "integration.yml": rs})), [], "a rerun that passed counts")
        rs = [run("success", created="2026-11-19T09:00:00Z"), run("failure", created="2026-11-19T11:00:00Z")]
        self.assertTrue(G.check(SHA, False, True, api({"ci.yml": [run()], "integration.yml": rs})), "a later failure stops it")

    def test_uncommitted_changes_or_a_commit_not_on_main_stop_it(self):
        ok = api({"ci.yml": [run()], "integration.yml": [run()]})
        self.assertIn("uncommitted", G.check(SHA, dirty=True, on_main=True, get=ok)[0])
        self.assertIn("not on GitHub's main", G.check(SHA, dirty=False, on_main=False, get=ok)[0])

    def test_failed_unit_tests_stop_it_too(self):
        self.assertIn("ci.yml did not pass", G.check(SHA, False, True, api({"ci.yml": [run("failure")], "integration.yml": [run()]}))[0])


if __name__ == "__main__":
    unittest.main()
