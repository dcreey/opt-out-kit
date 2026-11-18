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
