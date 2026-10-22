"""Language handling for the terms census: what language a text is in, and where a site keeps its other-language pages.

The master terms list is never translated. It holds each site's own words, so the census asks a site for its terms in the person's
language (a site that has them gets read in that language) and records the language it actually got. A site with no translation is
recorded as such and keeps its original, which is what the person is shown.
"""
import re

LANGUAGES = ["en", "fr", "es", "de"]

# Words that are common in running text of each language and rare in the others. Enough to tell legal prose apart.
STOPWORDS = {
    "en": "the and of to in you is that for with this are your may we our not or by be as on at from will any use".split(),
    "fr": "le la les de des et du un une vous que est pour dans nous votre sur ne pas par au aux ces ou qui sont avec peut".split(),
    "es": "el la los las de y que en un una usted para por con su no se es del al sus este esta como puede nos".split(),
    "de": "der die das und nicht ist zu den mit sie von ein eine für auf wir sich dem des werden oder bei kann sind".split(),
}
_SETS = {k: set(v) for k, v in STOPWORDS.items()}

ENDONYMS = {"en": ["english", "en"], "fr": ["français", "francais", "french", "fr"],
            "es": ["español", "espanol", "spanish", "es"], "de": ["deutsch", "german", "de"]}


def detect_lang(text, minimum=0.08):
    """The language of `text` among LANGUAGES, or None when it is too short or too mixed to say."""
    words = re.findall(r"[a-zà-ÿœ']+", (text or "").lower())
    if len(words) < 25: return None
    scores = {lang: sum(1 for w in words if w in s) / len(words) for lang, s in _SETS.items()}
    best = max(scores, key=scores.get)
    runner = max(v for k, v in scores.items() if k != best)
    if scores[best] < minimum or scores[best] < runner * 1.4: return None
    return best


def find_alternate(links, lang, current_url=""):
    """Where a page keeps its `lang` version. `links` are (href, text, hreflang) triples from the page: its
    <link rel="alternate" hreflang> tags first, then anchors. Returns an absolute URL or None."""
    code = lang.lower()
    def matches(h): h = (h or "").lower(); return h == code or h.startswith(code + "-") or h.startswith(code + "_")
    cur = current_url.split("#")[0]
    for href, _text, hreflang in links:                          # 1. the page says so itself
        if matches(hreflang) and href.startswith("http") and href.split("#")[0] != cur: return href
    names = ENDONYMS.get(code, [code])
    for href, text, _ in links:                                  # 2. a language switcher
        t = (text or "").strip().lower()
        if href.startswith("http") and href.split("#")[0] != cur and t in names and len(t) > 2: return href
    for href, _text, _ in links:                                 # 3. a language path or parameter
        if href.startswith("http") and href.split("#")[0] != cur and re.search(rf"(/{code}(/|$)|[?&](lang|locale|hl)={code}\b)", href.lower()): return href
    return None
