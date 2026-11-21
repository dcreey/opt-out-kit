"""The app does no file-system work while it runs (docs/STORAGE.md): what it ships is read from Catalog.sqlite, what it keeps for
the person, including its preferences, is rows in the one SQLite file (UserDatabase), the web view keeps nothing (a non-persistent data store). This fails on any file API in the runtime
sources outside the short allow-list below, so a new `Data(contentsOf:)` or `FileManager` call has to be argued for here, in review, rather than slipping in.

Not scanned: code inside `#if DEBUG` (simulator audit tools: absent from a release build), tests, and the build-time targets (CatalogSource, catalog-builder,
broker-pipeline), which read the repository's files by design."""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
RUNTIME = ["App/Sources", "Shared/AssistedRun", "ShareExtension", "Packages/OptOutKitCore/Sources/OptOutKitCore"]
FORBIDDEN = re.compile(r"FileManager|Data\(contentsOf|String\(contentsOf|contentsOfDirectory|\.write\(to:|Bundle\.(main|module)\.(url|urls|path|paths|resourceURL)|NSFileProtection|fileExists|UserDefaults|@AppStorage|@SceneStorage|NSUbiquitousKeyValueStore")

# file -> (what it may do, the strings that identify the allowed lines)
ALLOWED = {
    "App/Sources/AppCatalog.swift": ("finds the compiled catalog in the bundle and opens it", ["Bundle.main.url(forResource: \"Catalog\""]),
    "App/Sources/OptOutKitApp.swift": ("names the database file's folder (Application Support) and the old files it is moved in from",
                                       [".applicationSupportDirectory"]),
    "App/Sources/Loc.swift": ("iOS's own translated strings (Xcode compiles the catalog into .lproj for the system)", ["ofType: \"lproj\""]),
    "Packages/OptOutKitCore/Sources/OptOutKitCore/L10n.swift": ("the same, and the raw catalog when the package is built without Xcode (tests)",
                                                                ["ofType: \"lproj\"", "withExtension: \"xcstrings\"", "Data(contentsOf: url)"]),
    "Packages/OptOutKitCore/Sources/OptOutKitCore/Preferences.swift": ("the one-time move of an older build's UserDefaults values into the database (importLegacy)",
                                                                      ["from defaults: UserDefaults"]),
    "Packages/OptOutKitCore/Sources/OptOutKitCore/UserDatabase.swift": ("creates the database's folder, and moves the old files in once (importLegacy)",
                                                                       None),          # the whole file: it is the one place user data touches the file system
}


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def without_debug(text):
    """The text with every `#if DEBUG ... #endif` region removed (nesting respected)."""
    out, depth = [], 0
    for line in text.splitlines():
        t = line.strip()
        if depth == 0 and re.match(r"#if\s+DEBUG\b", t): depth = 1; continue
        if depth > 0:
            if t.startswith("#if"): depth += 1
            elif t.startswith("#endif"): depth -= 1
            continue
        out.append(line)
    return "\n".join(out)


class RuntimeFileIO(unittest.TestCase):
    def test_the_app_touches_no_file_outside_the_allow_list(self):
        problems = []
        for folder in RUNTIME:
            for dirpath, _, files in os.walk(os.path.join(ROOT, folder)):
                for name in files:
                    if not name.endswith(".swift"): continue
                    path = os.path.join(dirpath, name)
                    rel = os.path.relpath(path, ROOT)
                    allowed = ALLOWED.get(rel)
                    if allowed and allowed[1] is None: continue
                    for i, line in enumerate(without_debug(read(path)).splitlines(), 1):
                        code = line.split("//")[0]
                        if FORBIDDEN.search(code) and not (allowed and any(a in line for a in allowed[1])):
                            problems.append(f"{rel}: {line.strip()[:110]}")
        self.assertEqual(problems, [], "file-system work at runtime: read it from the catalog or keep it in the user database, or add it to ALLOWED with the reason")

    def test_every_allow_list_entry_is_still_needed(self):
        for rel, (why, needles) in ALLOWED.items():
            text = without_debug(read(os.path.join(ROOT, rel)))
            self.assertTrue(FORBIDDEN.search(text), f"{rel} no longer uses a file API: remove it from ALLOWED ({why})")
            for n in needles or []: self.assertIn(n, text, f"{rel}: '{n}' is not there any more")

    def test_the_web_view_keeps_nothing_on_disk(self):
        text = read(os.path.join(ROOT, "App/Sources/WebViewFetcher.swift"))
        self.assertIn("websiteDataStore = .nonPersistent()", text)
        self.assertNotIn("defaultDataStore", text)

    def test_the_network_keeps_nothing_on_disk(self):
        """URLSession's default configuration keeps a disk cache and cookies; the app's fetcher is ephemeral and nothing uses the shared or default session."""
        for folder in RUNTIME:
            for dirpath, _, files in os.walk(os.path.join(ROOT, folder)):
                for name in files:
                    if not name.endswith(".swift"): continue
                    text = without_debug(read(os.path.join(dirpath, name)))
                    self.assertNotIn("URLSession.shared", text, name)
                    self.assertNotIn("URLSessionConfiguration.default", text, name)
                    self.assertNotIn("URLCache", text, name)
        self.assertIn("URLSessionConfiguration.ephemeral", read(os.path.join(ROOT, "Packages/OptOutKitCore/Sources/OptOutKitCore/URLSessionFetcher.swift")))

    def test_the_yaml_reader_is_not_linked_into_the_app(self):
        manifest = read(os.path.join(ROOT, "Packages/OptOutKitCore/Package.swift"))
        core = re.search(r'\.target\(name: "OptOutKitCore"[^\n]*\)', manifest).group(0)
        self.assertNotIn("Yams", core)
        for dirpath, _, files in os.walk(os.path.join(ROOT, "Packages/OptOutKitCore/Sources/OptOutKitCore")):
            for name in files:
                self.assertNotIn("import Yams", read(os.path.join(dirpath, name)), name)


if __name__ == "__main__":
    unittest.main()
