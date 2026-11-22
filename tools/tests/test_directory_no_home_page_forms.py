"""A site's opt-out form is never just its home page. Nine entries (01advertising, beeswax, decide.co, exactcustomer, ...) had the home page's sales or contact
form recorded as their opt-out form, so the app filled a sales form and said "no opt-out form was found". Each now points at its real request form, or is
email-only. A new home-page form found by the crawler has to be checked by hand and moved here as an exception if it really is the opt-out."""
import os, re, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import yamlio  # noqa: E402

EXCEPTIONS = set()          # domains whose home page really is the opt-out form


class NoHomePageForms(unittest.TestCase):
    def test_no_live_form_is_the_bare_home_page(self):
        bad = []
        for path, d in yamlio.entries(os.path.join(os.path.dirname(__file__), "..", "..", "directory")):
            live = d.get("live_form") or {}
            page = (live.get("page") or "").rstrip("/")
            if live.get("found") and re.fullmatch(r"https?://(www\.)?" + re.escape(d["domain"]), page) and d["domain"] not in EXCEPTIONS:
                bad.append(d["domain"])
        self.assertEqual(bad, [], "these entries record their home page as the opt-out form")


if __name__ == "__main__":
    unittest.main()
