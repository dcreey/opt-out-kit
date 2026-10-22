import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import terms_lang as L

EN = "By using this website you agree to the terms and conditions that apply to your use of the service, and you may not copy or sell any of the content that we provide to you without our permission."
FR = "En utilisant ce site, vous acceptez les conditions générales qui s'appliquent à votre utilisation du service, et vous ne pouvez pas copier ou vendre le contenu que nous vous fournissons sans notre autorisation."
ES = "Al utilizar este sitio usted acepta los términos y condiciones que se aplican a su uso del servicio, y no puede copiar ni vender el contenido que le proporcionamos sin nuestra autorización."
DE = "Wenn Sie diese Website nutzen, stimmen Sie den Geschäftsbedingungen zu, die für Ihre Nutzung des Dienstes gelten, und Sie dürfen die Inhalte, die wir Ihnen zur Verfügung stellen, nicht ohne unsere Erlaubnis kopieren oder verkaufen."


class Detect(unittest.TestCase):
    def test_each_language_is_recognised(self):
        for lang, text in (("en", EN), ("fr", FR), ("es", ES), ("de", DE)):
            self.assertEqual(L.detect_lang(text), lang, lang)

    def test_short_or_unclear_text_is_not_guessed(self):
        self.assertIsNone(L.detect_lang("Accept"))
        self.assertIsNone(L.detect_lang(""))
        self.assertIsNone(L.detect_lang("12345 67890 " * 20))


class Alternates(unittest.TestCase):
    page = "https://example.com/terms"

    def test_the_pages_own_hreflang_wins(self):
        links = [("https://example.com/fr/terms", "Conditions", "fr"), ("https://example.com/switch?lang=fr", "Français", "")]
        self.assertEqual(L.find_alternate(links, "fr", self.page), "https://example.com/fr/terms")
        self.assertEqual(L.find_alternate([("https://example.com/de-at/terms", "", "de-AT")], "de", self.page), "https://example.com/de-at/terms")

    def test_a_language_switcher_by_name(self):
        links = [("https://example.com/", "English", ""), ("https://example.com/es/", "Español", "")]
        self.assertEqual(L.find_alternate(links, "es", self.page), "https://example.com/es/")

    def test_a_language_path_or_parameter(self):
        self.assertEqual(L.find_alternate([("https://example.com/de/datenschutz", "Datenschutz", "")], "de", self.page), "https://example.com/de/datenschutz")
        self.assertEqual(L.find_alternate([("https://example.com/terms?lang=fr", "Terms", "")], "fr", self.page), "https://example.com/terms?lang=fr")

    def test_no_translation_means_none_and_the_current_page_is_never_returned(self):
        self.assertIsNone(L.find_alternate([("https://example.com/about", "About", "")], "fr", self.page))
        self.assertIsNone(L.find_alternate([(self.page, "Français", "fr")], "fr", self.page))
        self.assertIsNone(L.find_alternate([("https://example.com/profile", "Profile", "")], "fr", self.page), "'fr' inside a word is not a path")


if __name__ == "__main__":
    unittest.main()
