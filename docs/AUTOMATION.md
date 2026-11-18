# Automatic protection: daily scan and weekly opt-out

Status 2026-10-21. Built and tested in the simulator against **local test pages and fakes only**. No real site has been sent
anything by this feature, and no real person's details were used.

## What counts as automatic

A site is automatic only when its form was loaded on a real page and nothing blocked it. If a person might have to solve anything (a human check, a terms prompt, a confirmation box), it is semi-automated. A site whose form has never been loaded is also semi-automated until a real load shows it is clear, and a site where an automatic send was stopped by a check moves to semi-automated by itself. The owner's own plain "I am this person" box is ticked automatically (never for family profiles).

## Measured on real pages (2026-10-22)

All 172 forms the app can fill in were loaded on a real page in the simulator with a made-up profile, filled in, and closed without sending anything: 143 had nothing blocking them, 19 showed a visible human check, 9 a confirmation box and 1 both. These are written to each site's `live_check`. A check that only appears after sending cannot be seen this way; if a send is ever stopped by one, that site moves to semi-automated on its own. Data Axle's family of sites (data-axle.com, donorbase.com, exactdata.com, usadata.com) only has a note that the broker may verify identity and may contact the person about the request; for the account owner that is treated like the plain "I am this person" box, so those sites are automatic for the owner and still semi-automated for family profiles.

## Nothing runs without a profile

Every way of opting someone out (the automatic run, the assisted run, guides, scans) first needs the person's legal name, current address (with ZIP code) and the household email. If any is missing the app shows a "Before we opt anyone out" sheet, asks for them, prompts for previous addresses (as many as the person can remember; optional) and then carries on with what they were doing.

## One site, one group

Groups run in this order: an official removal service for the person's state or country (California DROP today), then our automatic opt-out, semi-automated, guided and manual. A site is listed in the first group that handles it and in no later one; two official services never list the same site. The same order decides what the weekly run skips.

## How sites are grouped

**Forms that need the person (2026-11-09).** A form a real page load showed to ask for an authorized agent's details, questions the app cannot read, or a file or signature is
**semi-automated**, not guided: Solve and send fills in what it can and then never presses send; the person completes the rest in the page and presses the page's own button, and the
confirmation is noticed as usual (`Item.needsPerson` makes it hands-off). Two things stay guided: a **business** form (20 sites; it is a contact form, not a personal opt-out, so nothing
personal is put into it) and any site that carries a caution (Clearview's face photo is never uploaded for the person). Sites on the sign-up survey's list stay guided too (`jungroup.com`'s
recorded form was dropped for that reason). Email-only sites are their own group ("Email only"), not semi-automated.

The Sites tab no longer shows tiers or method groups: it groups sites by where they stand (Done, Skipped, Up next), and who does the work is a filter on its search screen (`docs/UX.md`). The methods are **Automatic opt-out** (121 of 853 sites), **Semi-automated, with
prompts for you** (51 before the change; it now also holds the former Guided group: page-only sites and the hand-written walkthroughs, held for you; sites with a page and an email use the page) and **Later, no route yet** (36 sites with no page and no email, not tasks until a link is found).
The groups come from a real page load of each form with a made-up profile (nothing sent), not from captcha scripts on the page.
See `docs/DIRECTORY.md` and `pipeline/opt-out-methods.md` for how each site was placed and why.

## What runs

| Job | When | What it does |
|---|---|---|
| **Scan** | Daily | Searches the sites that can be checked automatically (14 today) for each family member who may be searched. Read-only. |
| **Opt-out** | Weekly | For each directory site where we found the real opt-out form (270 of 856), fills it from the person's profile and sends it, one site at a time. |

Both are off until the person answers a first-run question (last page of the walkthrough, or a banner on the Queue tab if they
skipped it). The page has both switches on by default and says exactly what will be sent. Either can be turned off in
Settings, and every run is listed under "Automatic activity". "Preview" fills every form and sends nothing.

## Required profile details

Every profile needs a **legal first name and legal last name** (a middle name is optional) and a **current street address, city
and state**, in their own required fields with no "type" to pick. Other names (nicknames, maiden names) and previous addresses are
listed separately below. The owner's profile also needs the **household email**. The editor cannot be closed while anything is
missing, and the daily scan and weekly opt-out skip a profile until it is complete.

## California DROP

California residents get a one-request-for-many-sites walkthrough, and the sites it reaches are skipped for 90 days after they submit
it. See `docs/PLATFORMS.md`.

## One email for every form

The first-run walkthrough has a required "Your email address" page (Next and Start stay disabled until it looks like an address;
there is no Skip). That one address is put on every opt-out form and every data-deletion request, for the
owner and for every family profile; a family member's own address is not used. It can be changed on the owner's profile.

For Gmail (`gmail.com` and `googlemail.com`) the app adds `+optoutkit` before the `@`: `you@gmail.com` becomes
`you+optoutkit@gmail.com`. Mail still arrives in the normal inbox, and searching for `+optoutkit` finds every reply from an opt-out.
An address that already ends in `+optoutkit` is not tagged twice, an existing tag such as `+news` is kept, and other providers are
left alone. The walkthrough and the profile editor say all of this in the same words and show the tagged address that will be used.

## Spokeo without paying

Spokeo's opt-out form only needs the web address of your listing, and the app gets that without buying anything: searching Spokeo
by **name** (`spokeo.com/First-Last`) lists people with links like `spokeo.com/First-Last/State/City/p123456789`, and that link is
what the form wants. Searching by email, phone or address instead leads to a payment page. The links are not guessable (the trailing
`p…` number is opaque), so the app takes them from the results rather than building them. Spokeo's own form also says a payment-page
address (`spokeo.com/purchase?q=…`) is accepted, so a person who lands on a payment page can still use that address. The walkthrough
says "You never need to buy a report". Verified on the real site on 2026-10-22 (below).

Other published guides say the same: [Cloaked](https://help.cloaked.app/hc/en-us/articles/34297441672084-Removing-Your-Data-From-Spokeo),
[DeleteMe](https://joindeleteme.com/help/kb/how-to-remove-yourself-from-spokeo/) and [Incogni](https://blog.incogni.com/spokeo-opt-out/).

## Existing walkthroughs we can lean on

- **EasyOptOuts' list** is already the source of our directory (now 856 sites: EasyOptOuts' 214 plus every broker in the state registries).
- **[Big Ass Data Broker Opt-Out List](https://github.com/yaelwrites/Big-Ass-Data-Broker-Opt-Out-List)** is the best volunteer-maintained
  guide. It is licensed CC BY-NC-SA (non-commercial, attribution, share-alike), so we cite it and cross-check our flows against it
  rather than copying its text into this repository.
- **California DROP** ([privacy.ca.gov/drop](https://privacy.ca.gov/drop/)): since January 2026 a California resident can send one
  deletion request to every registered broker, and brokers have had to process requests since August 2026. It needs state identity
  verification, so the app links to it (Settings, "Also worth doing") instead of automating it.

## Spokeo, end to end (checked 2026-10-22, nothing sent)

On the simulator, against the real site, with a made-up profile (common name, example.com email): the guide searched Spokeo for the
name (`spokeo.com/John-Smith`), a listing was picked from the results and "This is my listing" captured its address, the opt-out
form opened with that address and the email filled in, and the guide stopped at Spokeo's "I'm not a robot" reCAPTCHA. The page's
send was replaced by one that cannot send, and it was never reached. Screenshots: `docs/screens/spokeo-e2e/`. Reproduce with
`TEST_RUNNER_OPTOUT_LIVE=1` and `LiveSpokeoFlowTests`.

## Rules the opt-out keeps (tested)

- Only the fields a form asks for are filled (name, email, city, state and so on), taken from the person's own profile.
- A site is sent at most once per week. A failed or stopped attempt does not count as sent.
- If a look in the last 30 days found no listing on a site, nothing is sent there (no handing data to a site that lacks it).
- A visible human check (reCAPTCHA puzzle or checkbox, hCaptcha, Cloudflare check) or a terms prompt **stops the run for that
  site**. It is never solved or accepted.
- Legal acknowledgement and certification checkboxes are never ticked; a form that requires one is left to the person. The one
  exception is a plain "I confirm that I am the person associated with this email" box on the **account owner's own** profile, and
  only after they turn on "Confirm 'I am this person' boxes for me" in Settings. Never for family profiles or minors.
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

For forms behind a human check the app does everything except the check. **Solve and send** loads each site's real form in a visible
browser and fills it in. It scrolls the check into view and waits. The person solves it (and accepts any terms or ticks any
certification box themselves). The app then sends the form, reads the confirmation and moves on, with the next site already
loading. A check, terms prompt or certification box is detected on the live page, never assumed. Checked on real pages with a
made-up profile and no sending: SmartBackgroundChecks and Spokeo show a reCAPTCHA checkbox, SmartBackgroundChecks also a
certification box, and coloradoarrests.org has no blocker.

**Step-by-step flows (the hand-written walkthroughs, and any page held for you)** (hand-written broker steps, or a directory site) open full screen: the browser takes the top three quarters and
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
- **In the pipeline.** `.github/workflows/profile.yml` runs weekly: it re-profiles all 856 directory sites, then
  `tools/check_links.py` checks every hand-written broker link and every generated form page, crawls for a replacement when one
  is broken, and writes `pipeline/link-health.md`. The job fails if a hand-written broker link is lost and no new one is found.

## What the background run does (2026-11-17)

The run has two kinds, both sending the forms themselves, one site at a time, with nobody on screen:

| Pass | When | Sites | What a site that does not go through does |
|---|---|---|---|
| **Full** | The first run, then every 6 months (`AutoSettings.fullEvery`, two periods; due 3 days early) | Every site that `AutoOptOut.backgroundAttemptable` accepts (about 490 of 829 today; `AppModel.fullPassSize` counts it for the explanation) | Recorded as `failed`, `rejected` or `challenged`; the site is semi-automated, with that as the reason |
| **Repeat** | Every 3 months (`AutoSettings.optOutEvery` = 91 days) between full passes | Only the sites whose latest attempt went through (`AutoOptOut.lastAttemptWentThrough`) | The same: a repeat that does not go through moves the site to semi-automated |

For a new person the first full pass comes before anything else: the Queue shows it as step 1 and holds back the semi-automated queue until it has finished (`AutoSettings.firstPassPending`), so the queue starts with exactly the sites that need a person. See [UX.md](UX.md).

"Run now" (and every run, scheduled or resumed) leaves out the sites already sent in the current period (`AutoOptOut.notSent`), so it only does what is left; only "Re-test all" (`runAutoOptOut(everySite:)`) tries a site sent this period again.

The person can also start a **full** pass by hand at any time (Activity, "Re-test every site now", after a confirmation): `AutoSettings.startFullRetest` marks a full pass as started, so the run is the same as a scheduled one and a cut-off one carries on. When it finishes `lastFullRun` is set, so the next scheduled full re-test is counted from then.

`backgroundAttemptable` is the safety gate and applies to both passes: the site's page mode is `form` (a form is known, read or found live; not a caution or `no_fill` site, no business,
agent, other or file blocker, no reviewed real run that failed), no typed code, no listing for the person to pick, the form-filler's plan is ready (nothing only the person holds), and the
person has not set the site aside. A human check, terms prompt or box to certify that a page shows is **never solved or ticked**: the engine stops there (`challenged`), so a site that
showed one is still tried in a full pass (pages change) and goes to the person's queue if it still does. A site counts done only when the page's confirmation is seen.

Bookkeeping: `AutoSettings.lastFullRun` (when a full pass last finished), `passStarted` and `passKind` (a pass that was cut off carries on with the sites it has not yet tried, whatever their
outcome), and the period (`RunPeriod`, 91 days from the first run) so a site sent in the current period is left alone. Only the automatic group counts in the period's "handled of N", so
a lost site from a full pass never holds the period open. Automatic protection is explained to the person at first use and in Settings (`AutoExplainer`), with the number of sites in a pass.
Tests: `AutoOptOutTests.testABackgroundRunTriesOnlySites...`, `testAFullPassTriesEverySiteAnd...`, `testTheFirstRunAndThenEverySixMonths...`, `BackgroundPassesAppTests`, `AutomaticRunAppTests`.

## Background running (unverified)

Two background tasks are registered (`dev.optoutkit.app.scan` daily, `.optout` weekly) and the app also runs anything due
each time it opens, which is the reliable path. iOS decides when background tasks run, and it is **unproven** that the hidden
web view works inside one on a device. Treat open-the-app catch-up as the dependable behaviour until tested on a phone.

## Not built / next

- Multi-step flows (pick your record, then submit).
- A live dry run of the preview against real sites with a made-up profile.
- Reading confirmation emails (no inbox access by design).
