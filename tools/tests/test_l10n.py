import json, os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import l10n as L

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


class Translations(unittest.TestCase):
    def setUp(self):
        os.chdir(ROOT)
        self.keys = json.load(open("l10n/keys.json"))
        self.all = sorted(set(self.keys["app"]) | set(self.keys["core"]))
        self.tr = L.load_translations()

    def test_every_string_is_translated_into_every_language(self):
        for lang in L.LANGS:
            missing = [k for k in self.all if not self.tr[lang].get(k)]
            self.assertEqual(missing, [], f"{lang} is missing {len(missing)} strings, e.g. {missing[:3]}")

    def test_placeholders_match_the_english_in_number_and_kind(self):
        for lang in L.LANGS:
            bad = [k for k in self.all if L.placeholders(k) != L.placeholders(self.tr[lang][k])]
            self.assertEqual(bad, [], f"{lang}: {bad[:3]}")

    def test_the_shipped_catalogs_are_up_to_date_with_the_translation_files(self):
        for path, key_set in ((L.APP_CATALOG, self.keys["app"]), (L.CORE_CATALOG, self.keys["core"])):
            catalog = json.load(open(path))["strings"]
            self.assertEqual(sorted(catalog), sorted(key_set), path)
            for k in key_set:
                have = {lang: e["stringUnit"]["value"] for lang, e in catalog[k].get("localizations", {}).items()}
                self.assertEqual(have, {lang: self.tr[lang][k] for lang in L.LANGS}, k)

    def test_the_languages_the_app_offers_are_the_ones_translated(self):
        self.assertEqual(L.LANGS, ["fr", "es", "de"])


if __name__ == "__main__":
    unittest.main()
