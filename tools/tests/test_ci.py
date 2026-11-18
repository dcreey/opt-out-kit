import os, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ci_shards as S

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


class Shards(unittest.TestCase):
    def test_every_test_class_is_in_exactly_one_shard(self):
        for d, n in [("AppTests", 3), ("AppUITests", 4)]:
            weights = S.classes(os.path.join(ROOT, d))
            bins, load = S.split(weights, n)
            flat = [c for b in bins for c in b]
            self.assertEqual(sorted(flat), sorted(weights), d)
            self.assertEqual(len(flat), len(set(flat)), d)
            self.assertLessEqual(max(load) - min(load), max(weights.values()), "shards are balanced to within one class")

    def test_classes_and_their_tests_are_read_from_the_sources(self):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, "A.swift"), "w").write(
                "@MainActor\nfinal class OneTests: XCTestCase {\n    func testA() {}\n    func testB() async throws {}\n    func helper() {}\n}\n"
                "class Empty: XCTestCase {}\nstruct NotATest {}\nprivate final class TwoTests: XCTestCase { }\n")
            self.assertEqual(S.classes(d), {"OneTests": 2})


class Balance(unittest.TestCase):
    def test_everything_runs_exactly_once_and_ui_tests_are_handed_out_one_at_a_time(self):
        weights = S.work({})
        units = {k for k in weights if k.startswith("OptOutKitTests/")}
        ui = {k for k in weights if k.startswith("OptOutKitUITests/")}
        self.assertTrue(all(k.count("/") == 1 for k in units), "unit tests by class")
        self.assertTrue(all(k.count("/") == 2 for k in ui), "UI tests one by one")
        bins, load = S.split(weights, 5)
        flat = [k for b in bins for k in b]
        self.assertEqual(sorted(flat), sorted(weights))
        self.assertLessEqual(max(load) - min(load), max(weights.values()))

    def test_measured_seconds_beat_the_guess(self):
        key = next(k for k in S.work({}) if k.startswith("OptOutKitUITests/"))
        self.assertEqual(S.work({key: 123.0})[key], 123.0)

    def test_a_known_failing_test_is_left_out_wherever_it_lands(self):
        skip = "OptOutKitUITests/AutoProtectionUITests/testBlockedByPaymentIsAnAnswerInQuickChecks"
        out = []
        for i in range(5):
            out += subprocess.run([sys.executable, os.path.join(ROOT, "tools", "ci_shards.py"), "--shards", "5", "--index", str(i), "--skip", skip],
                                  capture_output=True, text=True, check=True).stdout.split()
        self.assertNotIn("-only-testing:" + skip, out)
        self.assertTrue(any("AutoProtectionUITests/" in x for x in out), "the rest of that class still runs")

    def test_seconds_are_read_from_an_xcodebuild_log(self):
        log = ("Test Case '-[OptOutKitTests.PeopleTests testA]' passed (1.25 seconds).\n"
               "Test Case '-[OptOutKitTests.PeopleTests testB]' failed (0.75 seconds).\n"
               "Test Case '-[OptOutKitUITests.DryRunUITests testRun]' passed (40.5 seconds).\n")
        self.assertEqual(S.timings_from_log(log), {"OptOutKitTests/PeopleTests": 2.0, "OptOutKitUITests/DryRunUITests/testRun": 40.5})


class Failures(unittest.TestCase):
    def test_each_failed_test_becomes_an_annotation_with_its_message(self):
        log = ("/x/A.swift:12: error: -[OptOutKitUITests.DryRunUITests testRun] : XCTAssertTrue failed - the report shows\n"
               "Test Case '-[OptOutKitUITests.DryRunUITests testRun]' failed (3.0 seconds).\n")
        lines = S.failures_from_log(log)
        self.assertEqual(lines[0], "::error title=OptOutKitUITests/DryRunUITests/testRun::XCTAssertTrue failed - the report shows")
        self.assertTrue(lines[-1].startswith("::notice title=Failed tests::"))
        self.assertEqual(S.failures_from_log("Test Case '-[A.B testC]' passed (1.0 seconds)."), [])


class FileTimes(unittest.TestCase):
    def test_files_get_their_last_commits_time(self):
        with tempfile.TemporaryDirectory() as d:
            git = lambda *a, **k: subprocess.run(["git", "-C", d, *a], check=True, capture_output=True, **k)
            git("init", "-q"); git("config", "user.email", "t@example.com"); git("config", "user.name", "t")
            open(os.path.join(d, "a.txt"), "w").write("1")
            env = dict(os.environ, GIT_COMMITTER_DATE="2001-01-01T00:00:00Z", GIT_AUTHOR_DATE="2001-01-01T00:00:00Z")
            git("add", "."); git("commit", "-qm", "one", env=env)
            open(os.path.join(d, "b.txt"), "w").write("2")
            git("add", "."); git("commit", "-qm", "two")
            script = os.path.abspath(os.path.join(ROOT, "tools", "ci_restore_mtimes.py"))
            subprocess.run([sys.executable, script], cwd=d, check=True, capture_output=True)
            self.assertEqual(int(os.path.getmtime(os.path.join(d, "a.txt"))), 978307200, "set to its commit's time")
            self.assertGreater(os.path.getmtime(os.path.join(d, "b.txt")), 978307200)


if __name__ == "__main__":
    unittest.main()
