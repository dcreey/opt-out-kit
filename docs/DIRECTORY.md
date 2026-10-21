# Broker directory: how sites get profiled

`directory/*.yml` has one generated entry per site in `pipeline/census-sites.txt` (214 today, from the EasyOptOuts
list). Entries are provisional guesses written by a tool, not hand-written flows. Real flows live in `brokers/`.

## The repeatable process

```bash
python3 tools/profile_brokers.py            # profile new or stale sites (cached 30 days) and rewrite directory/
python3 tools/profile_brokers.py --refresh  # re-fetch everything
python3 tools/profile_brokers.py --only spokeo.com,courtrecords.us
```

For each site the tool: checks `robots.txt` (bare and `www` host), fetches the home page, then **follows the most
promising privacy and opt-out links up to three hops (six pages at most)** until it finds the real opt-out form. A page
counts only if it is about opting out (its address, title or opening text) and holds a form that asks for an email, a
listing link, or posts to a removal address; home-page search boxes, newsletter boxes and logins are rejected. It records
the form's page, method, destination and fields, and **structure only**: form fields, bot-check widgets, wording about
phone, ID, mail or email requests, and where the opt-out leads. It copies no prose. Requests use an honest user agent
and wait one second between fetches to the same site. It never submits a form.

| Result | How it is decided |
|---|---|
| **blocked / robots / unreachable** | A bot check page, a robots.txt that disallows the site, or no reply |
| **C** | Phone, ID, file upload, login, or a page built by JavaScript |
| **B** | A bot-check widget (reCAPTCHA, Turnstile, hCaptcha and others) on the opt-out page |
| **A** | An email or listing-URL field and none of the above |
| **D** | No form, with email-only or mail wording |
| **form found** | The fields, method and destination of the real opt-out form, and how many hops it took to reach it |
| **template** | Different sites running the same form (same page path and field names): one flow covers them, one request per site |
| **family** | Two or more sites whose opt-out leads to the same other site (for example 50 court-records sites) |

The hardest requirement wins. Every tier here is a guess from the page's shape; the app labels it that way.

## From directory to guided flow

1. Pick a site from the directory (prefer families and tier A or B).
2. Walk its real opt-out once and write `brokers/<id>.yml` with steps (docs/DESIGN.md has the format).
3. If its search works with a plain request, add a `recheck:` block with a `calibration:` name.
4. `broker-pipeline` (see docs/TESTING.md) then watches it weekly, and the app stops listing it under "more sites".

## Automation

`.github/workflows/profile.yml` re-profiles monthly and opens a pull request with the changes. A person reviews the
diff; nothing merges itself. `.github/workflows/ci.yml` validates every entry against `schema/directory.schema.json`.

## Limits

- A form is "found" for about 56% of sites. Misses are mostly sites that block the crawl, build the page with JavaScript,
  or hide the form behind a modal, a login or a multi-step wizard.
- A found form has not been submitted or tested; its fields come from the page's markup.
- Tiers are guesses. A bare name box is treated as a search form, so tier A needs an email or listing-URL field.
- Pages built by JavaScript (about 10%) show as `needs_browser`; reading them needs a real browser, which isn't built.
- Sites that block plain requests cannot be profiled from here and stay `blocked`.
- Family detection follows links, so it can miss shared opt-outs and can't confirm that one request clears every site.

## Is this person listed? (search checks)

`tools/profile_search.py` does for the check side what `profile_brokers.py` does for the opt-out side. For each site it
finds a name search (the site's own GET or POST form, then common URL patterns), then learns what "no results" looks
like by searching a made-up name ("Zzyzx Qwertyuiop") and a known common name ("John Smith", then two fallbacks) and
comparing the two pages. If they can be told apart, the entry gets a `search_check:` block in the same shape as a
broker's `recheck:` (search URL, GET or POST body, page markers, calibration name). It never uses a real person's data.

| `search_check.status` | Meaning |
|---|---|
| calibrated | A check can tell a listing from no listing; the app can scan this site |
| blocked / robots_disallowed | The site refuses plain requests, or asks bots not to search it. We do not scan these |
| needs_browser | The search page is built by JavaScript |
| undifferentiated | The pages look the same for both names, or the search needs something we cannot fill in |
| no_search | No name search found |

```bash
python3 tools/profile_search.py             # learn searches for new or stale sites (cached 30 days)
python3 tools/profile_search.py --refresh
```

The app's **Scan where you appear** button runs every calibrated site's search for the selected person. Nothing is
submitted or saved. `broker-pipeline --directory directory` re-tests every learned search weekly, so a site whose page
changed shows up as a FAIL.

## Browser pass (headless Chromium)

`tools/browser_profile.py` re-tests every site that has a `candidate` search but could not be read with a plain request, using
headless Chromium (Playwright, installed in git-ignored `.tools-venv` and `.tools-browsers`; setup:
`python3 -m venv .tools-venv && .tools-venv/bin/pip install playwright && PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers
.tools-venv/bin/playwright install chromium`). It runs the made-up and known-name searches in a real browser, declines cookie
banners, never accepts terms, never tries to pass a bot check, and records one of: `calibrated` (with `needs_browser: true`),
`terms_gate`, `blocked` or `undifferentiated`.

Result on 2026-10-21 for the 108 sites tried: **0 calibrated, 64 still not distinguishable** (the first pass also reported 44 as
"behind a terms prompt"; see the correction below).

**Correction (2026-10-21).** An earlier version of this tool and of the app treated acceptable-use text as a terms prompt. The
arrests, warrants and records network prints that text in the footer of every page, so 45 sites were wrongly labelled
`terms_gate`. A real prompt has an "I agree" button beside the text; the detector now requires one (in the tool and in the app).
Re-tested with the fix: **0 of the 45 are gated**, all 45 are plain `undifferentiated`, and the `terms_gate` status is kept for
sites that really have a prompt (CourtRecords.us shows one on its home page).

The same lesson applies to opt-out forms: guessed paths such as `/optout` often return a "page not found" screen that still has a
search box, and privacy-policy pages can embed affiliate search boxes. The profiler now skips error pages, takes the page's
context from its title and opening text only, and rejects forms that post to another company unless the address is a removal portal.
That cut the found forms from 119 to 102.

## Quick checks (the guided fallback)

For every site without an automatic check, the app's Quick checks screen sends the person to look for themselves and asks
what they saw. It pays points for looking, not for the answer (5 for "not found", 3 for an honest "I'm listed"), keeps
only the latest look per site, and never leaves the phone. Levels run from Exposed to Off the Grid.
