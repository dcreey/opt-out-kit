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
                "class Empty: XCTestCase {}\nstruct NotATest {}\nprivate final class TwoTests: XCTestCase { }\nfinal class ThreeTests: UITestCase {\n    func testC() {}\n}\n")
            self.assertEqual(S.classes(d), {"OneTests": 2, "ThreeTests": 1})


class Balance(unittest.TestCase):
    def test_everything_runs_exactly_once_and_ui_tests_are_handed_out_one_at_a_time(self):
        weights = S.work({})
        units = {k for k in weights if k.startswith("OptOutKitTests/")}
        ui = {k for k in weights if k.startswith("OptOutKitUITests/")}
        self.assertTrue(all(k.count("/") in (1, 2) for k in units), "unit tests by class, a slow class test by test")
        whole = {k for k in units if k.count("/") == 1}
        self.assertFalse(any("/".join(k.split("/")[:2]) in whole for k in units if k.count("/") == 2), "a class is never both whole and split")
        self.assertTrue(all(k.count("/") == 2 for k in ui), "UI tests one by one")
        bins, load = S.split(weights, 5)
        flat = [k for b in bins for k in b]
        self.assertEqual(sorted(flat), sorted(weights))
        self.assertLessEqual(max(load) - min(load), max(weights.values()))

    def test_a_suite_can_be_chosen(self):
        unit = S.work({}, suites={"OptOutKitTests"}); ui = S.work({}, suites={"OptOutKitUITests"})
        self.assertTrue(unit and all(k.startswith("OptOutKitTests/") for k in unit))
        self.assertTrue(ui and all(k.startswith("OptOutKitUITests/") for k in ui))
        self.assertEqual(set(unit) | set(ui), set(S.work({})), "together they are everything")

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
        self.assertEqual(S.timings_from_log(log), {"OptOutKitTests/PeopleTests": 2.0, "OptOutKitTests/PeopleTests/testA": 1.2, "OptOutKitTests/PeopleTests/testB": 0.8,
                                                   "OptOutKitUITests/DryRunUITests/testRun": 40.5})

    def test_a_slow_unit_test_class_is_handed_out_test_by_test(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "AppTests")); os.makedirs(os.path.join(d, "AppUITests"))
            open(os.path.join(d, "AppTests", "A.swift"), "w").write("final class SlowTests: XCTestCase {\n    func testA() {}\n    func testB() {}\n}\nfinal class QuickTests: XCTestCase {\n    func testC() {}\n}\n")
            w = S.work({"OptOutKitTests/SlowTests": 200.0, "OptOutKitTests/SlowTests/testA": 150.0, "OptOutKitTests/QuickTests": 3.0}, root=d)
            self.assertEqual(w, {"OptOutKitTests/SlowTests/testA": 150.0, "OptOutKitTests/SlowTests/testB": 100.0, "OptOutKitTests/QuickTests": 3.0},
                             "measured tests keep their time, the others share the class's")


class Failures(unittest.TestCase):
    def test_each_failed_test_becomes_an_annotation_with_its_message(self):
        log = ("/x/A.swift:12: error: -[OptOutKitUITests.DryRunUITests testRun] : XCTAssertTrue failed - the report shows\n"
               "Test Case '-[OptOutKitUITests.DryRunUITests testRun]' failed (3.0 seconds).\n")
        lines = S.failures_from_log(log)
        self.assertEqual(lines[0], "::error title=OptOutKitUITests/DryRunUITests/testRun::A.swift:12: XCTAssertTrue failed - the report shows")
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
    """tools/ci_file_times.py: a file's time comes from its contents, so a restored build folder rebuilds only what changed, with no history needed."""

    def _repo(self, d):
        git = lambda *a, **k: subprocess.run(["git", "-C", d, *a], check=True, capture_output=True, **k)
        git("init", "-q"); git("config", "user.email", "t@example.com"); git("config", "user.name", "t")
        return git

    def _run(self, cwd):
        script = os.path.abspath(os.path.join(ROOT, "tools", "ci_file_times.py"))
        subprocess.run([sys.executable, script], cwd=cwd, check=True, capture_output=True)

    def test_the_same_contents_get_the_same_time_in_any_checkout_and_changed_contents_another(self):
        with tempfile.TemporaryDirectory() as d:
            src, one, two = (os.path.join(d, n) for n in ("src", "one", "two"))
            os.mkdir(src); git = self._repo(src)
            for name, text in [("a.txt", "kept"), ("b.txt", "before")]: open(os.path.join(src, name), "w").write(text)
            git("add", "."); git("commit", "-qm", "one")
            subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + src, one], check=True, capture_output=True)
            self._run(one)
            open(os.path.join(src, "b.txt"), "w").write("after"); git("commit", "-qam", "two")
            subprocess.run(["git", "clone", "-q", "--depth", "1", "file://" + src, two], check=True, capture_output=True)   # one commit: no history
            self._run(two)
            t = lambda where, n: int(os.path.getmtime(os.path.join(where, n)))
            self.assertEqual(t(one, "a.txt"), t(two, "a.txt"), "unchanged: the time the last build saw, so it is not rebuilt")
            self.assertNotEqual(t(one, "b.txt"), t(two, "b.txt"), "changed: a new time, so it is rebuilt")
            self.assertLess(t(two, "a.txt"), 978307200 + 5 * 365 * 86400 + 1)

    def test_a_file_with_uncommitted_changes_keeps_its_own_time(self):
        with tempfile.TemporaryDirectory() as d:
            git = self._repo(d)
            open(os.path.join(d, "a.txt"), "w").write("1"); git("add", "."); git("commit", "-qm", "one")
            open(os.path.join(d, "a.txt"), "w").write("2")
            before = os.path.getmtime(os.path.join(d, "a.txt"))
            self._run(d)
            self.assertEqual(os.path.getmtime(os.path.join(d, "a.txt")), before)


if __name__ == "__main__":
    unittest.main()
