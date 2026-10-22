"""Canonical form of terms text, shared by the Python tools and the Swift app (OptOutKitCore.TermsText).
The two implementations MUST agree: terms/canonicalization-fixtures.json holds input/expected pairs that both test.

canonical(paragraph, domain):
  1. Unicode NFKC, lowercase, curly quotes and dashes to ASCII, whitespace collapsed to single spaces.
  2. Any web address (word.tld, optional www.) becomes {domain}.
  3. The site's own name becomes {site}: its domain label, and the label split before its suffix word
     (alabamaarrests -> "alabama arrests").
  4. US state names, in English, French, Spanish and German (longest first) and the site's own short prefix (ct, ny ...) become {state}.
  5. Four-digit years 1990-2039 become {year}; "(c)" and the copyright sign are dropped.
A paragraph is "substantial" when it has at least 12 words; shorter lines are page chrome (menus, buttons, footers).
"""
import hashlib, re, unicodedata

STATES = ["alabama","alaska","arizona","arkansas","california","colorado","connecticut","delaware","district of columbia","florida","georgia","hawaii",
          "idaho","illinois","indiana","iowa","kansas","kentucky","louisiana","maine","maryland","massachusetts","michigan","minnesota","mississippi",
          "missouri","montana","nebraska","nevada","new hampshire","new jersey","new mexico","new york","north carolina","north dakota","ohio","oklahoma",
          "oregon","pennsylvania","rhode island","south carolina","south dakota","tennessee","texas","utah","vermont","virginia","washington",
          "west virginia","wisconsin","wyoming"]
# State names as they appear in French, Spanish and German text, so sister sites in any of those languages cluster too.
STATES += ['californie', 'caroline du nord', 'caroline du sud', 'dakota du nord', 'dakota du sud', 'virginie-occidentale', 'virginie', 'floride', 'géorgie', 'hawaï', 'louisiane', 'pennsylvanie', 'nouveau-mexique', 'nouveau-hampshire', 'rhode island', 'carolina del norte', 'carolina del sur', 'dakota del norte', 'dakota del sur', 'virginia occidental', 'nueva york', 'nueva jersey', 'nuevo méxico', 'nuevo hampshire', 'luisiana', 'hawái', 'misisipi', 'misuri', 'oregón', 'míchigan', 'pensilvania', 'kalifornien', 'nordkarolina', 'südkarolina', 'norddakota', 'süddakota', 'westvirginia']
SUFFIXES = ["courtrecords", "arrestwarrants", "warrantroundup", "arrests", "arrest", "warrants", "records", "residentdatabase"]
MIN_WORDS = 12


def _norm(text):
    t = unicodedata.normalize("NFKC", text).lower()
    t = t.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"').replace("–", "-").replace("—", "-")
    return re.sub(r"\s+", " ", t).strip()


def site_tokens(domain):
    label = domain.lower().split(".")[0]
    names, prefix = {label}, None
    for suf in SUFFIXES:
        if label.endswith(suf) and len(label) > len(suf):
            prefix = label[: -len(suf)]
            names.add(f"{prefix} {suf}")
            break
    return sorted(names, key=len, reverse=True), prefix


def canonical(paragraph, domain):
    t = _norm(paragraph)
    t = re.sub(r"\b(?:www\.)?[a-z0-9][a-z0-9-]*\.(?:org|com|net|us|gov|edu|io|info|fr|es|de|ca|uk|mx|eu|ch|at|be|nl|it)\b", "{domain}", t)
    names, prefix = site_tokens(domain)
    for n in names: t = t.replace(n, "{site}")
    for st in sorted(STATES, key=len, reverse=True): t = t.replace(st, "{state}")
    if prefix and len(prefix) <= 3: t = re.sub(rf"\b{re.escape(prefix)}\b", "{state}", t)
    t = re.sub(r"\b(?:19[9][0-9]|20[0-3][0-9])\b", "{year}", t)
    t = t.replace("(c)", "").replace("©", "")
    t = re.sub(r"(\{state\} ?){2,}", "{state} ", t)
    return re.sub(r"\s+", " ", t).strip()


def paragraph_hash(canon):
    return hashlib.sha256(canon.encode()).hexdigest()[:16]


def substantial(text):
    return [p for p in (x.strip() for x in re.split(r"\n+", text)) if len(p.split()) >= MIN_WORDS]


def paragraph_hashes(text, domain):
    """Hashes of the substantial paragraphs of a document, for comparison against a reviewed set."""
    return {paragraph_hash(canonical(p, domain)) for p in substantial(text)}
