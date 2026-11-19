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

    def test_a_shard_with_other_work_gets_less(self):
        weights = {f"T/C{i}": 10.0 for i in range(10)}
        bins, load = S.split(weights, 2, {0: 30.0})
        self.assertLess(len(bins[0]), len(bins[1]), "the shard with other work gets fewer tests")
        self.assertLessEqual(abs(load[0] - load[1]), 10.0, "and the totals, its other work included, stay within one test")

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


class BuildSummary(unittest.TestCase):
    def test_the_slowest_steps_and_the_files_compiled_are_reported(self):
        log = ("SwiftCompile normal arm64 /x/A.swift\nSwiftCompile normal arm64 /x/B.swift\nBuild Timing Summary\n\n"
               "SwiftCompile (2 tasks) | 2.387 seconds\n\nCodeSign (3 tasks) | 0.264 seconds\n\nLd (1 task) | 9.5 seconds\n")
        line = S.build_summary(log, "exact")
        self.assertTrue(line.startswith("::notice title=Build::2 Swift files compiled (cache: exact)"))
        self.assertIn("Slowest: Ld 10 s (1), SwiftCompile 2 s (2), CodeSign 0 s (3)", line)


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

    def test_a_shallow_checkout_gives_files_not_changed_in_it_the_oldest_time(self):
        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "src"), os.path.join(d, "dst")
            os.mkdir(src)
            git = lambda where, *a, **k: subprocess.run(["git", "-C", where, *a], check=True, capture_output=True, **k)
            git(src, "init", "-q"); git(src, "config", "user.email", "t@example.com"); git(src, "config", "user.name", "t")
            for i, name in enumerate(["old.txt", "mid.txt", "new.txt"]):
                open(os.path.join(src, name), "w").write(name)
                when = f"200{i + 1}-01-01T00:00:00Z"
                git(src, "add", "."); git(src, "commit", "-qm", name, env=dict(os.environ, GIT_COMMITTER_DATE=when, GIT_AUTHOR_DATE=when))
            subprocess.run(["git", "clone", "-q", "--depth", "2", "file://" + src, dst], check=True, capture_output=True)
            script = os.path.abspath(os.path.join(ROOT, "tools", "ci_restore_mtimes.py"))
            subprocess.run([sys.executable, script], cwd=dst, check=True, capture_output=True)
            t = lambda n: int(os.path.getmtime(os.path.join(dst, n)))
            self.assertLess(t("old.txt"), t("new.txt"), "a file older than the fetched commits is not taken as new")
            self.assertLessEqual(t("old.txt"), t("mid.txt"))


if __name__ == "__main__":
    unittest.main()
