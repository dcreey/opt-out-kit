# Broker directory: how sites get profiled

`directory/*.yml` has one generated entry per site in `pipeline/census-sites.txt` (856 today: EasyOptOuts' 214 plus 642 more added from the state broker registries, see `docs/JURISDICTIONS.md`; the first 214 came from the EasyOptOuts
list). Entries are provisional guesses written by a tool, not hand-written flows. Real flows live in `brokers/`.

The files are YAML a person can read and edit: single-quoted values and block mappings, linted with `.yamllint.yml` like every YAML file here. The tools
write and change them only through `tools/yamlio.py` (`pip install -r tools/requirements.txt`), which keeps comments and hand edits and changes only the
fields a tool owns, so a person's edit survives the next run.

## The compiled catalog (what the app ships)

The app does not ship or parse any of this YAML, and nothing else it ships is a loose file either (docs/STORAGE.md). At build time the core package's `CatalogPlugin` (a SwiftPM build tool, applied to the app target in
`project.yml`) runs `catalog-builder`, which loads `directory/`, `brokers/`, `platforms/` (with its coverage JSON), `jurisdictions/`,
`registries/summary.json` and `terms/library.yml` with the same loaders the tests use (the `CatalogSource` module: the only code that reads YAML, so the app does not link the YAML reader), adds the page scripts (`App/PageScripts/*.js`, `scripts` table) and the ZIP table (`data/zips-us.tsv`, `zips` table, found by key), and writes them into one read-only SQLite file,
`Catalog.sqlite`, in the app bundle (`Catalog` in `Packages/OptOutKitCore`). The app reads only that (`AppModel`, `Catalog.contents`).

- **Checked at build time.** A file that does not decode, or a repeated id, fails the build; so does a value the catalog cannot carry exactly (the builder
  reads the file back and compares it with what the loaders gave).
- **Layout.** One table per kind (`sites`, `brokers`, `platforms`, `jurisdictions`) and `documents` (the registry counts, the terms library). Each row
  keeps the entry as JSON, its position, and the columns the app looks up by (`id`, `domain`, `excluded`, `code`), indexed; `PRAGMA user_version` is the
  layout's version (`Catalog.schemaVersion`). Excluded sites are in the file (the build checks them) and the app's query leaves them out.
- **Read-only.** It is written as one self-contained file (a rollback journal, not WAL) and opened `immutable`, so SQLite writes nothing beside it inside
  the app's signed bundle.
- **Speed.** Reading the whole catalog takes about 0.02 s (release build, Mac); parsing the same sites from YAML took 0.14 to 0.23 s, on the main thread at
  every launch. 855 sites, 5 flows, 1 platform, 107 places, 55 scripts and 40,977 ZIP codes make a 4.8 MB file with the search index, built in about 0.9 s.
- **Search.** `site_search` is a full-text index (SQLite's FTS5, part of iOS) over each shown site's name, its web address as words, what kind of company
  it is and what it holds and sells (the app's own names for them, in all four languages) and its description; `Catalog.search` ranks a match in the
  name highest, then the address, the kind, the description (BM25). It is what the Sites search screen uses beside its plain name match. It adds about
  1.5 MB (3.8 MB in all).
- **In memory too.** The app keeps every site in memory as well (the plan, the automatic run and the activity page work over all of them), found by
  id, domain or family through `SiteIndex`, built once when the list changes (until 2026-11-20 lookups scanned the list, and the Sites rows took 0.1 s in a
  debug build; 0.017 s with the index).
- **By hand:** `swift run --package-path Packages/OptOutKitCore catalog-builder . /tmp/Catalog.sqlite` (any SQLite tool can open the result).
- Xcode runs the step on every build (about half a second), not only when the data changed: the declared inputs do not stop it yet.

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
| **blocked / robots / unreachable** | A human check page, a robots.txt that disallows the site, or no reply |
| **C** | Phone, ID, file upload, login, or a page built by JavaScript |
| **B** | A bot-check widget (reCAPTCHA, Turnstile, hCaptcha and others) on the opt-out page |
| **A** | An email or listing-URL field and none of the above |
| **D** | No form, with email-only or mail wording |
| **form found** | The fields, method and destination of the real opt-out form, and how many hops it took to reach it |
| **template** | Different sites running the same form (same page path and field names): one flow covers them, one request per site |
| **family** | Two or more sites whose opt-out leads to the same other site (for example 50 court-records sites) |

The hardest requirement wins. Every tier here is a guess from the page's shape. Tiers are internal: the app no longer shows them.
It groups sites by who does the work instead (see "How each site gets opted out" below).

## How each site gets opted out (what the app shows)

`OptOutMethods.classify` (core package) puts every site in one of four groups, using the form the profiler found, the page's
signals, and whether the form filler can map every field for a complete profile. `pipeline/opt-out-methods.md` lists each site
with the reason; regenerate it with `broker-pipeline --directory directory --methods-report pipeline/opt-out-methods.md`.

| Group | Meaning | Sites (2026-10-21) |
|---|---|---|
| Automatic opt-out | A form we fill in and send; nothing blocked it when its real page was loaded | 121 (82 loaded and measured clear, 39 not yet measured but with no bot-check script) |
| Semi-automated, with prompts for you | We fill in and send; a visible human check, terms prompt or confirmation box needs you, or you tap your own listing first (see below) | 51 |
| Semi-automated, page held for you | The page is found but has no readable form, needs login or ID, asks for business details or carries a caution: the app opens it, fills what it can (nothing when `no_fill` or caution), never sends; you finish and tap Mark as done. `Directory.pageMode` is `form`, `fillsAndHolds` or `showsOnly`. The hand-written walkthroughs are in this group too; a site with a page and an email uses the page, the email is its fallback. A link that is only the site's front page is not a page: email-only when there is an address, else manual | most of the former Guided group |
| Later, no route yet | No page and no email after the page, policy and email scans (marked `find_later: true`; a test requires every such site to be marked and no other). Not a task today: its link or address is found by hand and the site unlocked later | 36 |

**Measured, not guessed.** A reCAPTCHA or Turnstile script on a page is only a hint: most are invisible. So
`AppTests/LiveAssistedPreviewTests` loads every fillable form with a made-up profile and sends nothing, and
`tools/apply_live_check.py` records what actually blocked it as a `live_check:` block in the site's file. On 2026-10-21, 82 of 84
forms had nothing blocking them; one showed a visible reCAPTCHA checkbox (smartbackgroundchecks.com) and one a required
"I confirm that I am the person associated with this email" box (searchpeoplefree.com). A site that was never measured with a
captcha script on the page stays Semi-automated until it is. An invisible check can still appear when a form is sent; the app then
stops and asks, and that site moves to Semi-automated.

**Listing-based walkthroughs (Spokeo).** Some opt-out forms want the address of the person's own listing on the site. The app
searches the site for them (never for minors or public figures), the person taps their own result and then "This is my listing"
(it never guesses which one is theirs), and the app fills in the form with that address and their email. They clear the human check,
the app sends it and they confirm the email. Only 3 of the 109 found forms need a listing address (Spokeo, FreePeopleDirectory, which
sends its removals to Spokeo, and yellowbook.com, which has no name search so runs its hand-written steps). Other hand-written walkthroughs stay
step by step (semi-automatic, no separate Guided method): PeopleConnect needs a login-style email step and phone checks, and FastPeopleSearch's form asks who is submitting and
requires a legal acknowledgement box.

**Only for some people.** An `only_for:` block (`who`, `evidence`, `checked`) says the site holds data only on one group of people, so for anyone else
there is nothing to opt out of: agile-ed.com ("people who work in US schools or school districts"; its form says it "only maintains information about people
who are currently employed by schools or school districts", decided 2026-11-24). Such a site counts as done, is left out of the queue and the automatic run,
and its line and page say who it is for ("Only holds data on ... : nothing to do unless that is you"); its page can still open it for someone in that group,
who ticks the form's "this person is ..." box themselves (`OnlyForCheck`).

**One site, several names.** A hand-written flow can clear other sites with `covers:` (Spokeo covers FreePeopleDirectory;
PeopleConnect covers TruthFinder, Instant Checkmate, Intelius and US Search). Covered sites are not listed separately; they appear
under the flow that clears them, and a scan that finds a listing on any of them shows one row for the flow.

**"I am this person" boxes.** The account owner (the "Me" profile) can allow the app to tick a plain box that says they are the
person the request is about (Settings, "Confirm 'I am this person' boxes for me"; off until they turn it on). It never applies to
family profiles, never to minors, and never to legal certifications ("under penalty of perjury"), agent statements or terms.
Those always stay with the person.

A group is a measurement from one run, not a promise.

## From directory to guided flow

1. Pick a site from the directory (prefer families and tier A or B).
2. Walk its real opt-out once and write `brokers/<id>.yml` with steps (docs/DESIGN.md has the format).
3. If its search works with a plain request, add a `recheck:` block with a `calibration:` name.
4. `broker-pipeline` (see docs/TESTING.md) then watches it weekly, and the app stops listing it under "more sites".

## Automation

`.github/workflows/profile.yml` re-profiles monthly and opens a pull request with the changes. A person reviews the
diff; nothing merges itself. `.github/workflows/ci.yml` validates every entry against `schema/directory.schema.json` on every push and pull request.

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
banners, never accepts terms, never tries to pass a human check, and records one of: `calibrated` (with `needs_browser: true`),
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
That cut the found forms from 119 to 102. The full re-profile on 2026-10-21 (with retries, below) found 109.

## Crawler reliability

Every request goes through `Fetcher.get`, which retries transient trouble (timeouts, connection resets, HTTP 408/425/429/500/502/503/504)
up to 4 tries with exponential backoff (2, 4, 8 seconds plus jitter, capped at 60) and honors `Retry-After`. A real 404 or 403 is final.
A robots.txt that cannot be read because of a server error or network failure is treated as "stay out" (RFC 9309), not "allowed";
a missing robots.txt (404) allows. The crawl stays at about one request per second per site. Tests: `python3 -m unittest discover -s tools/tests`
(run in CI).

## Quick checks (the guided fallback)

Taken off on 2026-11-25. The Quick checks screen sent the person to look a site up themselves and asked what they saw (until 2026-11-24 it also paid points
for looking). Looks it saved stay in the person's history and count as any other look; an automatic scan for listings belongs with the automatic run, as future
work (docs/UX.md, "The Sites tab").


## Manual review of the sites with no readable form

`tools/build_site_review.py` builds a one-page review tool (`tools/site_review_template.html`) from `directory/*.yml`: one card per site that has no readable form (267 on 2026-11-11), most important first.
Each card opens the page we have, the site, and a search for its opt-out page, and takes one tag: right page with the form, right site but another page, find my record first, email only, needs login/ID/phone,
no online opt-out, site gone, or skip, plus the right URL, an email address and a note. Tags are kept in the page's shared database (and the browser), so they can be read back and applied to `directory/`.

The same review can be done inside the app, in a debug build (the simulator): launch with `-site-review`, or Settings, "Site review (admin, debug builds only)" (`SiteReviewView`). It looks like a guided flow:
the site's page under the guide, "This is the page" records the page on screen (and moves on), a Kind menu says what it is (a form on the page, search for my record first, email only, needs login/ID/phone,
no online opt-out, site gone), with optional email and note boxes; the … menu has quick "No online opt-out" and "Site gone", Skip, Previous site, the site's home page, a search for its opt-out page, and the export:
Copy all tags as JSON, Share, or read `Documents/site-review.json` in the app's container (`xcrun simctl get_app_container booted dev.optoutkit.app data`). "Import tags from the clipboard" takes the JSON copied from the web
review page, so sites already tagged there are skipped. Both use the same fields: `d`, `tag`, `url`, `email`, `note`, `at`. Covered by `ScreenHelperTests` (Mac: `SiteReviewQueue`).

## The policy crawl and its regression set

`tools/policy_links.py` reads each site's own privacy policy and lists every link, email and frame in it, scored for how much it looks like a request. After the first run missed routes that a person found by
hand, it learned: it scrolls to the very bottom and waits (footers are built late); it reads links inside shadow DOM; it presses "Do Not Sell" and "Your Privacy Choices" buttons and reads what opens; it follows
policy-to-policy links up to four pages deep on the same company's domains (a legal site, a California notice); it records a Contact Us page for sites with no form and no email (`contact_routes`, the request goes in
the contact form) and the sentences that give a postal address, a phone number or a setting in an app (`route_sentences`); it scores a link whose path says do-not-sell, opt-out or remove-my even with no link text; and it
knows more portal vendors (BigID, DataGrail, Clym, Securiti, SayMine and others). `tools/crawl_regression.json` lists sites whose real route a person found (crexi, cyberbackgroundchecks, affordablebackgroundchecks,
applovin, illumin, quotefinders, clearcompany, everyjoe, the BeenVerified family, peoplefinders, familytreenow) and `tools/check_crawl.py` runs the crawl blind (ignoring the page on file) against them; 11 of 11 on
2026-11-11, from 7 of 11 before. Add each site a person corrects to that list, and run the check before trusting a change to the crawl.

Second full crawl (2026-11-11, 227 sites): 90 with a candidate link (87 before), 60 with only an email, 12 with only a Contact Us page, 54 with no policy page, 3 with nothing, 8 timed out. New real finds:
`experience.com` (a SixFifty request portal), `theorg.com/opt-out`, `intalytics.com` (`dilicheckrep.com/data-request/`, a form: semi-automated), plus applovin and everyjoe. The 12 Contact Us pages (the arrest-records family and a few
others) were recorded as each site's page (guided). Left out as not the site's own: Fullstory, Omniture and a state attorney general's portal.

## Reachability audit (does every site have a way in?)

`python3 tools/audit_reachability.py` checks every site on the to-do list (every entry without a `closed:` or `excluded:` block) for at least one working way in, and writes `pipeline/reachability.json`. For each entry it tries the live-form page, `opt_out_url` and the stored form's page (each must load a real page: not an error, not a soft 404 that says "not found", not an unreachable host; a bot wall counts as reachable because a person's browser gets through it), then the contact email's domain on a public resolver (an MX or address record; a null MX fails), and only when all of those fail the site's front page. Result per site: `ok` (a working opt-out page or a mailable address), `weak` (only the front page works) or `none`. It checks that an address's *domain* takes mail, not that the mailbox exists (that only a bounce shows).

2026-11-17: 812 sites on the list at the first run: 777 ok (714 with an opt-out page that loads, 63 more through a bot wall or an email address alone), 32 weak, 3 none. The three with nothing were closed (`usatrace.com` serves "Website Permanently Closed" (410), `candl.app` answers DEPLOYMENT_NOT_FOUND, `date-detective.app` has a certificate for another name and a 404) and now carry a `closed:` block (`CLOSED_SITES.md`), which takes them off the list. `visitiq.io`'s recorded page `/opt-out/` was a 404; its privacy policy's "Opt-Out Form" link is `/data-rights-and-privacy/` (a privacy-portal overlay), which is now its page. Second run, after those fixes: 809 sites, **0 none**, 777 ok, 32 weak. The weak ones are the 31 `find_later` sites below (only a working front page; no route is recorded, the person has to find the way) and `telephonelists.biz`, whose form host `evs7.com` answered Cloudflare 524 (its server not answering) on that day while its front page loads: left as it is, to be checked again. Sites that were ok only through a bot wall (22 with no email) could not be confirmed past the wall.

## find_later

`find_later: true` marks a site (the "Later, no route yet" group; `OptOutMethods` returns manual for exactly these, `testEverySiteWithNoRouteYetIsMarkedToFindLater…` checks it) with no usable page and no email after the email scan (`tools/find_any_emails.py`): its page or address is to be found by hand later. It changes nothing in the app (the site stays manual); `tools/build_site_review.py --hide-later` leaves these out of the review page.

### A home page is never the opt-out form (2026-11-22)

Nine entries had their home page's sales or contact form recorded as the opt-out form (`live_form.page` = the bare home page), so the app filled a sales form
and said "no opt-out form was found". Each was checked by hand: meettie.com now points at its Termly request form and newmexicodatainsights.com at its
"Remove My Information" search page; americantreasurytaxsolutions.com, beeswax.com, decide.co, exactcustomer.com (its DoNotSell.aspx answers 403),
exlservice.com (its portal needs an account), optable.co and redmob.io take requests by email, and their entries are email-only. 01advertising.com and
agile-ed.com were fixed the same day. `tools/tests/test_directory_no_home_page_forms.py` fails on a new one.
