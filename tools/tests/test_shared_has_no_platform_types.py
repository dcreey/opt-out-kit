"""The model and the run logic (Shared/) are compiled into the Mac test packages too, so they name no UIKit or WebKit type. A WebKit type in a published
property of GuidedRunner crashed the whole Mac test process on Xcode 26 as XCTest read the classes (Published<WKWebView?> metadata), on GitHub's runner
only. The app's own sources (App/) hold every such type; the model reaches them through AppPlatform."""
import glob, os, re, unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
FORBIDDEN = re.compile(r"^\s*import\s+(UIKit|WebKit)\b|\b(WKWebView|UIImage|UIApplication|UIViewController)\b")


class SharedHasNoPlatformTypes(unittest.TestCase):
    def test_no_uikit_or_webkit_in_shared_code(self):
        bad = []
        for path in glob.glob(os.path.join(ROOT, "Shared", "**", "*.swift"), recursive=True):
            for n, line in enumerate(open(path, encoding="utf-8"), 1):
                code = line.split("//")[0]
                if FORBIDDEN.search(code):
                    bad.append(f"{os.path.relpath(path, ROOT)}:{n}: {line.strip()}")
        self.assertEqual(bad, [], "Shared/ must not name UIKit or WebKit types (they belong in App/, behind AppPlatform)")


if __name__ == "__main__":
    unittest.main()
