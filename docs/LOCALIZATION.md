# Languages and countries

The app is translated into **English, French, Spanish and German**. Everything a person reads is translated, including what the
app builds in code (status messages, reasons, what a country's or state's law means). The one thing never translated is the master
terms list (below). Adding a language is a data change plus a review, not a code change.

## How a language is chosen

The device's language when the app has it, else English. The first page of the walkthrough has a language menu, and changing it
switches the whole app at once (the choice is remembered). The same words are used on the profile editor, the Sites tab and
everywhere else. Dates and country names come from the system's own formatting for that language, so "Germany" is "Deutschland"
in German with no translation file.

## Where the words live

| Words | Source of truth | Compiled into |
|---|---|---|
| App screens (`Text("Next")`, `Loc.t("...")`, `Loc.f("...", args)`) | `l10n/fr.json`, `es.json`, `de.json` | `App/Resources/Localizable.xcstrings` |
| Words the core package builds (`L10n.t`, `L10n.f`, `L10n.noun`) | the same files | `Packages/OptOutKitCore/.../Resources/Localizable.xcstrings` |

English is the key: the English wording in the code is the string. A translation file is `{"English text": "Translated text"}`, and
placeholders (`%@`, `%lld`, `%1$@`) must be kept. `tools/l10n.py` does the plumbing:

```bash
python3 tools/l10n.py extract   # find every string in the code (SwiftUI literals via Xcode's own export, the rest by scanning)
python3 tools/l10n.py check     # missing translations and placeholder mismatches, per language
python3 tools/l10n.py build     # write both catalogs from the translation files
```

`python3 -m unittest discover -s tools/tests` fails if any string lacks a translation, if a placeholder differs, or if a shipped
catalog is out of date. If a translation ever has the wrong number of placeholders the app still cannot crash: a placeholder with no
argument is filled with nothing.

## Adding a language

1. Add its code to `LANGS` in `tools/l10n.py`, to `AppModel.languages` and to `L10n.supported`, and to `knownRegions` in `project.yml`.
2. Write `l10n/<code>.json` for every key in `l10n/keys.json` (a draft by machine is fine; a native speaker should read it).
3. `l10n.py build`, then `check`. Add the language to the UI test that switches languages.
4. Words on sites differ by language too: add that language's opt-out, privacy, error-page and form-field words to `LinkRules`
   (`LinkFinder.swift`), `FormFiller.swift`, `tools/profile_brokers.py` and the web-view patterns in `WebViewFetcher.swift`.
   French, Spanish and German are in already.

## The master terms list is not translated

The list holds each site's own words, as the site shows them, in the language the site shows them. A translation of a legal text is
not the text a person agrees to, so we never translate it and never match a translation against it.

- `tools/terms_census.py --lang fr` asks a site for its pages in French: `Accept-Language`, then the page's own `hreflang` links,
  a language switcher, or a language path. It checks the text really is French (word statistics, not the request) and stores it
  under `.terms-cache/<site>/fr/`. A site with no French version is reported as having none, and nothing is stored: its original
  wording stays what it is.
- `tools/terms_library.py` records each paragraph's language (`lang: fr`). A person reviewing a French paragraph reads French.
  The risk words that mark a paragraph (automated access, payment, arbitration, indemnity ...) are searched in all four languages.
- Matching is the same as for English: the canonical form of a paragraph is hashed (state names in all four languages are replaced
  by `{state}`, so sister sites cluster in any language) and compared with the reviewed list. Nothing is accepted for a paragraph
  nobody has reviewed, in any language.
- The app asks each site for its pages in the person's language (an `Accept-Language` header on every page load), so a site with
  translations shows them, and a terms prompt is matched in the language it appears in.
- Our own plain-English summary of the sites' terms is translated; it is a summary of the English originals and says so.

Run it for another language with `python3 tools/terms_census.py --lang es`. Almost all the sites the census reads are US sites
with English terms, so expect most to report "no translation". That is the right answer, not a failure.

## Countries

"Where do you live?" is country first, then (for the United States) state. For each country the app shows its data protection law,
what it gives residents (deletion, objection, direct-marketing opt-out), the regulator and a link to it, whether the country runs a
registry of data brokers, and, where its rules are weaker, what stronger rules look like elsewhere. See `docs/JURISDICTIONS.md`.
