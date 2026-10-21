# Automatic opt-out verification

Goal: confirm a person is gone from a broker with no input from the user, and never claim more than we can prove.

## Rules the engine follows

1. **Three results, never two.** A check says *removed*, *still listed* or *inconclusive*. Blocked, changed, offline
   or missing data is always inconclusive, never "removed".
2. **Prove the page is real.** Each broker defines `valid_page` markers. If none appear, the site probably changed
   or blocked us, so the result is inconclusive. This is what stops a redesign from reading as "all clear".
3. **Match the whole person.** Every name the person has (legal, previous, maiden, nickname) is searched. One hit
   under any of them, with a matching city when we know it, means still listed.
4. **Two checks, two days.** "Verified removed" needs two conclusive *removed* results on different days. One odd
   page cannot mark someone safe. Any later *still listed* result flips the status to "Listed again".
5. **Schedule.** First check after the site's `processing_days`, then every 2 days until verified, then every
   `recheck_days`. Inconclusive results are ignored for verification but still retried.
6. **No evasion.** We send ordinary requests. If a site blocks them, the result is inconclusive and the app says
   "can't verify automatically"; it does not rotate identities or solve challenges.

## Status the user sees

Not started → In progress → **Submitted, verifying** → **Verified removed** (or **Listed again**).

## Broker YAML

```yaml
processing_days: 3
recheck:
  search_url: "https://example.com/search?first={first}&last={last}&city={city}&state={state}"
  valid_page: ["results for"]        # proves we got a real results page
  no_results: ["no records found"]   # optional
  needs_browser: false               # true when the page is built by JavaScript
```

Placeholders: `{first}` `{last}` `{full}` `{city}` `{state}`. A broker with no `recheck:` block is inconclusive.

## What this cannot do

- Sites that block scripted requests (about 14% in the 2026-10-20 probe) or gate search behind a CAPTCHA cannot be
  verified automatically. They stay "Submitted, verifying" and show why.
- The check searches the person's name and city on the broker. The broker already holds that data, but the screen
  that lists what each site receives should include re-checks.
- iOS decides when background work runs, so checks can be late. The app also checks when opened.

## Built and not built

**Built and tested:** the check logic, result handling, verification rules and schedule (core package, fake pages);
a plain HTTPS fetcher with an honest user agent, no cookies and a size cap; the runner that finds due checks and
records results; the app wiring (checks run when the app opens, plus a best-effort background task every ~6 hours);
generic local notifications ("1 opt-out confirmed"), asked for only when the first opt-out is submitted; and a
weekly GitHub job that checks live pages for drift.

**One real broker:** Spokeo. Checked on 2026-10-20 with a made-up name (reads as removed) and "John Smith" in
Springfield, IL (reads as still listed) through the real fetcher.

**Known limit:** a common name also matches other people with that name in the same city, so it reads as still
listed. Matching on age or relatives would fix it. Spokeo's multi-word city and state URL forms (New-York) are
assumed, not yet checked.

**Not built yet:** a web-view fetcher for sites that need JavaScript or a real browser, `recheck:` blocks for any
other broker (most probed sites block plain requests), and a screen showing each check's history.
