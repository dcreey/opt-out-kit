# Automatic protection: daily scan and weekly opt-out

Status 2026-10-21. Built and tested in the simulator against **local test pages and fakes only**. No real site has been sent
anything by this feature, and no real person's details were used.

## What runs

| Job | When | What it does |
|---|---|---|
| **Scan** | Daily | Searches the sites that can be checked automatically (14 today) for each family member who may be searched. Read-only. |
| **Opt-out** | Weekly | For each directory site where we found the real opt-out form (119 of 214), fills it from the person's profile and sends it, one site at a time. |

Both are off until the person answers a first-run question (last page of the walkthrough, or a banner on the Queue tab if they
skipped it). The page has both switches on by default and says exactly what will be sent. Either can be turned off in
About, and every run is listed under "Automatic activity". "Preview" fills every form and sends nothing.

## Rules the opt-out keeps (tested)

- Only the fields a form asks for are filled (name, email, city, state and so on), taken from the person's own profile.
- A site is sent at most once per week. A failed or stopped attempt does not count as sent.
- If a look in the last 30 days found no listing on a site, nothing is sent there (no handing data to a site that lacks it).
- A visible bot check (reCAPTCHA puzzle or checkbox, hCaptcha, Cloudflare check) or a terms prompt **stops the run for that
  site**. It is never solved or accepted.
- Legal acknowledgement and certification checkboxes are never ticked; a form that requires one is left to the person.
- Logins, ID checks, phone verification, uploads and "agent / on behalf of" forms are left to the person.
- "Sent" is reported only when the site shows a success message. Otherwise the result is "no confirmation" or "refused".
- Minors and public figures are still opted out (an opt-out is not a search) but are never scanned.
- If the person has no email, name or city a form needs, the app says what to add instead of guessing.

## What to expect (measured, not hoped)

For a **complete** profile the field mapper can match **92 of the 119** found forms. That overstates what will be sent:

- **85 of those 92 pages carry a bot-check widget.** Whether it is invisible (passes for a real browser) or a puzzle is only
  known when the page loads. Puzzles stop the run.
- Many "ready" forms are the first step of a longer flow (the CourtRecords.us family asks for name, state and city, then
  needs you to pick the record and pass a check). Submitting only starts it; with no success message it is reported as
  "no confirmation", not as sent.
- 27 of the 119 are left to the person outright (21 ask for something we do not have, 2 need a login, 1 needs a certification, 3 other).
- Some sites email a confirmation link. The click is the person's; the activity list marks those as "sent, confirm the email".

So the real number of requests that go all the way out unattended will be much smaller than 119, and the app says which sites
need the person. It does **not** solve CAPTCHAs; that is a design rule, not a gap to close.

## Background running (unverified)

Two background tasks are registered (`dev.optoutkit.app.scan` daily, `.optout` weekly) and the app also runs anything due
each time it opens, which is the reliable path. iOS decides when background tasks run, and it is **unproven** that the hidden
web view works inside one on a device. Treat open-the-app catch-up as the dependable behaviour until tested on a phone.

## Not built / next

- Multi-step flows (pick your record, then submit).
- A live dry run of the preview against real sites with a made-up profile.
- Reading confirmation emails (no inbox access by design).
