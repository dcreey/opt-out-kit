"""The built app holds the compiled catalog and no data files (tools/check_bundle.py, run on CI's build)."""
import os, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import check_bundle as C


def app(files):
    d = tempfile.mkdtemp(suffix=".app")
    for f in files:
        p = os.path.join(d, f)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").close()
    return d


class CheckBundleTests(unittest.TestCase):
    def test_an_app_with_the_catalog_and_nothing_else_passes(self):
        self.assertEqual(C.problems(app(["Catalog.sqlite", "Info.plist", "en.lproj/Localizable.strings"])), [])

    def test_a_missing_catalog_a_shipped_folder_or_a_data_file_fails(self):
        self.assertTrue(any("Catalog.sqlite" in p for p in C.problems(app(["Info.plist"]))))
        self.assertTrue(any("directory/" in p for p in C.problems(app(["Catalog.sqlite", "directory/a.yml"]))))
        self.assertTrue(any("x.js" in p for p in C.problems(app(["Catalog.sqlite", "Frameworks/x.js"]))))


if __name__ == "__main__":
    unittest.main()
