import json, os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ci_crash_frames as C


class CrashFramesTests(unittest.TestCase):
    def test_the_crashed_thread_is_printed_with_its_images(self):
        report = {"exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"}, "usedImages": [{"name": "xctest"}, {"name": "AssistedRunLogicPackageTests"}],
                  "threads": [{"frames": [{"imageIndex": 0, "symbol": "main"}]},
                              {"triggered": True, "frames": [{"imageIndex": 1, "symbol": "AppModel.init", "symbolLocation": 12}, {"imageIndex": 0, "symbol": "main"}]}]}
        lines = C.frames('{"app_name":"xctest"}\n' + json.dumps(report))
        self.assertEqual(lines[0], "EXC_BAD_ACCESS SIGSEGV")
        self.assertEqual(lines[1], "AssistedRunLogicPackageTests  AppModel.init +12")
        self.assertEqual(len(lines), 3, "only the thread that crashed")


if __name__ == "__main__":
    unittest.main()
