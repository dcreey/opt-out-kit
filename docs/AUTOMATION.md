# Automatic protection: daily scan and weekly opt-out

Status 2026-10-21. Built and tested in the simulator against **local test pages and fakes only**. No real site has been sent
anything by this feature, and no real person's details were used.

## How sites are grouped

The Sites tab no longer shows tiers. Each section says who does the work: **Automatic opt-out** (82 sites), **Semi-automated, with
prompts for you** (3), **Guided, you do the steps** (104, including the hand-written walkthroughs) and **Manual, you find the page** (25).
The groups come from a real page load of each form with a made-up profile (nothing sent), not from captcha scripts on the page.
See `docs/DIRECTORY.md` and `pipeline/opt-out-methods.md` for how each site was placed and why.

## What runs

| Job | When | What it does |
|---|---|---|
| **Scan** | Daily | Searches the sites that can be checked automatically (14 today) for each family member who may be searched. Read-only. |
| **Opt-out** | Weekly | For each directory site where we found the real opt-out form (109 of 214), fills it from the person's profile and sends it, one site at a time. |

Both are off until the person answers a first-run question (last page of the walkthrough, or a banner on the Queue tab if they
skipped it). The page has both switches on by default and says exactly what will be sent. Either can be turned off in
About, and every run is listed under "Automatic activity". "Preview" fills every form and sends nothing.

## Rules the opt-out keeps (tested)

- Only the fields a form asks for are filled (name, email, city, state and so on), taken from the person's own profile.
- A site is sent at most once per week. A failed or stopped attempt does not count as sent.
- If a look in the last 30 days found no listing on a site, nothing is sent there (no handing data to a site that lacks it).
- A visible bot check (reCAPTCHA puzzle or checkbox, hCaptcha, Cloudflare check) or a terms prompt **stops the run for that
  site**. It is never solved or accepted.
- Legal acknowledgement and certification checkboxes are never ticked; a form that requires one is left to the person. The one
  exception is a plain "I confirm that I am the person associated with this email" box on the **account owner's own** profile, and
  only after they turn on "Confirm 'I am this person' boxes for me" in About. Never for family profiles or minors.
- Logins, ID checks, phone verification, uploads and "agent / on behalf of" forms are left to the person.
- "Sent" is reported only when the site shows a success message. Otherwise the result is "no confirmation" or "refused".
- Minors and public figures are still opted out (an opt-out is not a search) but are never scanned.
- If the person has no email, name or city a form needs, the app says what to add instead of guessing.

## What to expect (measured, not hoped)

For a **complete** profile the field mapper can match **85 of the 109** found forms. That overstates what will be sent:

- **83 of those 85 pages mention a bot-check script, but only 2 of the 84 we loaded showed anything blocking the form** (a visible
  reCAPTCHA checkbox, and a required "I am this person" box). Most scripts are invisible. A check can still appear when the form is
  sent; the run then stops for that site and it moves to Semi-automated. Puzzles are never solved.
- Many "ready" forms are the first step of a longer flow (the CourtRecords.us family asks for name, state and city, then
  needs you to pick the record and pass a check). Submitting only starts it; with no success message it is reported as
  "no confirmation", not as sent.
- 24 of the 109 are left to the person outright (18 ask for something we do not have, 5 other, 1 needs a certification).
- The form filler never reuses a name for a middle-name field, and a form that needs the link to your own listing (Spokeo) is left to you.
- Some sites email a confirmation link. The click is the person's; the activity list marks those as "sent, confirm the email".

So the real number of requests that go all the way out unattended will be much smaller than 109, and the app says which sites
need the person. It does **not** solve CAPTCHAs; that is a design rule, not a gap to close.

## Solve and send, and the guided screen

For forms behind a bot check the app does everything except the check. **Solve and send** loads each site's real form in a visible
browser and fills it in. It scrolls the check into view and waits. The person solves it (and accepts any terms or ticks any
certification box themselves). The app then sends the form, reads the confirmation and moves on, with the next site already
loading. A check, terms prompt or certification box is detected on the live page, never assumed. Checked on real pages with a
made-up profile and no sending: SmartBackgroundChecks and Spokeo show a reCAPTCHA checkbox, SmartBackgroundChecks also a
certification box, and coloradoarrests.org has no blocker.

**Guided flows** (hand-written broker steps, or a directory site) open full screen: the browser takes the top three quarters and
the app's panel the bottom quarter, showing "Step N of M", the current step, and Cancel, Back, Next step and Not working. Where it
can, the app finishes a step by itself when it sees the page load, a copy, or a navigation (`done_when:` in a broker file); steps it
cannot detect, such as clicking an emailed link, use the Next button. "Not working" records why (broken link, needs a login,
payment, ID or phone call, site blocked me, other) and leaves that site alone for 30 days.

## Moved links heal themselves

- **In the app.** Before a guide runs, the page it opens is checked. If it is an error page the app crawls the site (home page,
  then the most promising privacy and opt-out links, at most 6 pages and 3 hops) for the real opt-out form, saves the new link on
  the phone, and loads it. If nothing is found the guide says so: the person has to find the page on the site themselves.
  "Report: link broken" and the weekly opt-out (a page that is gone is searched again and the site retried once) do the same.
  The site page has "Find the current opt-out page" and "Go back to the recorded link". No personal data is used for the search.
- **In the pipeline.** `.github/workflows/profile.yml` runs weekly: it re-profiles all 214 directory sites, then
  `tools/check_links.py` checks every hand-written broker link and every generated form page, crawls for a replacement when one
  is broken, and writes `pipeline/link-health.md`. The job fails if a hand-written broker link is lost and no new one is found.

## Background running (unverified)

Two background tasks are registered (`dev.optoutkit.app.scan` daily, `.optout` weekly) and the app also runs anything due
each time it opens, which is the reliable path. iOS decides when background tasks run, and it is **unproven** that the hidden
web view works inside one on a device. Treat open-the-app catch-up as the dependable behaviour until tested on a phone.

## Not built / next

- Multi-step flows (pick your record, then submit).
- A live dry run of the preview against real sites with a made-up profile.
- Reading confirmation emails (no inbox access by design).
