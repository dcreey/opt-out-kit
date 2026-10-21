# Terms library: matching site terms against text a person has reviewed

Status 2026-10-21: the matching and decision logic is built and tested. **Nothing presses "I agree" for anyone.** The step
that would do that (the web view clicking the button) is not built, and building it was blocked by this session's permission
system, so it needs an explicit decision (see "Open decision").

## Idea

Some sites put an "I agree to our terms" prompt in front of search results. Instead of a blanket proxy accept, keep a
library of **paragraphs a person has read and judged**, and consider acting only when a site's text is made of paragraphs
already on that list.

## How matching works (built)

1. A document is split into paragraphs; lines under 12 words are page chrome (menus, buttons) and are ignored.
2. Each paragraph is canonicalized: Unicode NFKC, lowercase, quotes and dashes normalized, whitespace collapsed, web
   addresses to `{domain}`, the site's own name to `{site}`, US state names to `{state}`, four-digit years to `{year}`.
3. The canonical text is hashed (SHA-256, first 16 hex characters). The library stores only hashes, never site text.
4. `tools/terms_canon.py` and `OptOutKitCore.TermsText` implement the same steps. `terms/canonicalization-fixtures.json`
   holds input and expected output; both languages test against it, so they cannot drift apart unnoticed.

Measured on the 45 terms-gated sites (2026-10-21): 396 distinct paragraphs. Treating paragraphs seen on two or more
sites as a stand-in for a reviewed set, 10 of 13 prompts, 37 of 45 terms pages and 36 of 56 privacy pages were fully
covered. A person would review roughly 55 terms paragraphs, 55 privacy paragraphs and 2 prompt paragraphs, not 122 documents.
42 paragraphs carry an automatic high-risk flag (automation, payment, arbitration, indemnity).

## The decision rule (built, `TermsGate.decide`)

Acceptance would be allowed only if **all** hold:

- every substantial paragraph in the prompt and the linked terms pages is in the library with `reviewed: true` and `verdict: ok`;
- none is flagged as banning or implying automated access (never overridable: the web view is itself automated) or excluded;
- the person approved this exact library version (any change to the list asks again).

Otherwise the answer is one of: not approved, unreviewed paragraphs, excluded, nothing to judge. The shipped library has
**zero reviewed paragraphs**, so the rule never says accept today (a test pins this).

## Process (built)

```bash
PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/terms_census.py   # read-only: captures prompt and terms text into .terms-cache (git-ignored)
python3 tools/terms_library.py                                                              # writes terms/library.yml (hashes only), fixtures, and .terms-review/review-sheet.txt
```

A reviewer reads `.terms-review/review-sheet.txt` (full canonical paragraphs, with flags) and sets `reviewed` and `verdict`
in `terms/library.yml`. Re-running keeps existing verdicts.

## Open decision

To act on a decision, the app's hidden web view would have to press "I agree" on a third party's terms. That is the
step this session's permission system refused. Before anyone builds it:

1. **Legal read.** Accepting terms through software changes who took the action. Several terms ban automated access, and
   some require certifications (permitted uses of the results). A lawyer should say whether a reviewed-text, user-approved
   click is acceptable, and for which sites.
2. **Explicit go-ahead** from the project owner that this feature should exist, since it is not something an assistant
   should add on its own.
3. Even then: off by default; per-device approval tied to the library version; a visible log of every acceptance;
   revocation in one tap; never for automation-banning terms; never in tests against live sites.

Until then, terms-gated sites stay guided (the person accepts the terms themselves) and show "Results are behind terms
you must accept yourself".
