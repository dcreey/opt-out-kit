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

The run has two kinds, both sending the forms themselves, one site at a time (`AutoOptOut.appParallel`), with nobody on screen. A run may be slow; the app must stay quick while it works, and every page a run has open shares the main thread and the processor with the screens the person uses. (The engine can work on several sites at once, `AutoOptOut(parallel:)`, each a different site and a shared page sent once; the app does not use it.)

| Pass | When | Sites | What a site that does not go through does |
|---|---|---|---|
| **Full** | The first run, then every 6 months (`AutoSettings.fullEvery`, two periods; due 3 days early) | Every site that `AutoOptOut.backgroundAttemptable` accepts (about 490 of 829 today; `AppModel.fullPassSize` counts it for the explanation) | Recorded as `failed`, `rejected` or `challenged`; the site is semi-automated, with that as the reason |
| **Repeat** | Every 3 months (`AutoSettings.optOutEvery` = 91 days) between full passes | Every site the run has tried (`AutoOptOut.inRepeatPass`): those whose latest attempt went through are sent again, and every one that did not go through (a refusal, no form found, a choice it could not make, given up before sending) is tried again with the build installed now. Decided 2026-11-23: those refused or stopped by the form used to wait for the person or the next full pass, six months on, so a fix in a new build never reached them (about 300 sat that way). Not taken: a site the run is sure it cannot do (`AutoOptOut.lastAttemptNeedsPerson`, decided 2026-11-23: semi-automatic only): a human check (reCAPTCHA, hCaptcha, a Cloudflare check that did not pass by itself, a bot check), a code sent to the person to type, or a field no profile can fill ("something only you can supply", "something we do not have"; matched in the person's language too). Every other failure may be the app's own shortcoming, so a fix in a later build reaches it: taken again are no form found, boxes it could not match, a choice it could not make, a certification box, no confirmation, too slow, the page would not load, the site showed an error. Also not taken: a site sent and not confirmed twice (never sent over and over), one the person emailed instead, and, through `precheck`, one sent this period or not listed within 30 days. Run now after a full pass takes the same sites, less those sent this period: it never sends twice in a period | The same: a repeat that does not go through moves the site to semi-automated |

For a new person the first full pass comes before anything else: the Queue shows it as step 1 and holds back the semi-automated queue until it has finished (`AutoSettings.firstPassPending`), so the queue starts with exactly the sites that need a person. See [UX.md](UX.md).

**A run is finished only when every site has a result.** A run that stopped early (Stop, the app suspended, iOS taking its background time back) stays pending and carries on; it is never recorded as a finished pass. Every run, including a repeat, also takes every site a full pass covers that no run has ever tried (`AppModel.runDomains`), so a site never reached is not left for six months. Stop has its own flag, which coming back to the app does not clear.

**A new person in California** makes the DROP request first: the Queue shows it as step 1, the automatic pass as step 2 and semi-automatic as step 3, and the first pass does not start until the request is made (`AppModel.firstPassWaitsForPlatform`), because until then every site DROP reaches is held. Outside California DROP is not offered, holds nothing and is not in the plan.

**A site whose search finds no record of the person is done.** Some opt-out forms search before they remove ("enter your information to find the data
to remove"); the courtrecords.us sites (about 50 in the catalog) answer "No data was found, try other criteria". The run reads that answer after the press
(`FormRun.saysNoRecordFound`, before the error wording, and only in what appeared after pressing) and records the site as **not listed** (`SubmitOutcome.notListed`,
an attempt with outcome `not_listed` and a "not listed" look, `Progress.notListedRecently`). It is never counted as sent. For `Progress.notListedWindow` (30 days)
the site counts as done on the Sites tab and its own page ("Not listed" with the date), is under "Not listed" on the automatic opt-out page, is left out of the
semi-automated queue and is left alone by the run; then a repeat pass searches it again, since brokers add records. Any look that found no listing (a scan, the
person's own quick check) counts the same way, and a later look that found one wins. Before this, the run pressed the search again and again until the time ran
out, and the site sat in the semi-automated queue as "the form had more steps than the time allowed". In Solve and send the page stays on screen with that
explanation until the person moves on.

**Only what it will really try.** Before a run starts, the sites its own rules leave alone are taken out (`AppModel.willTry`, the same `AutoOptOut.precheck` the engine runs before each site): sites covered by a platform request (California's DROP holds every site it reaches until the person has made that request), sites the person marked not working, sites a recent look showed they are not listed on, sites sent recently, sites missing a detail. So "N of M", "Run now tries N" and the report count only real tries, and the report adds how many were left alone and the commonest reasons. Those sites stay on the activity page under "Not tried or skipped", each with its reason worked out at the time (`AppModel.skipReason`). (Build 46 counted them as part of the run: it showed "1 of 305" for minutes and then "0 of 4 went through", and the page said nothing was left.) **Re-test all** sends again to every site, including the ones sent earlier in the period or the same day (`AutoOptOut.retestMinInterval` is 0; the person confirmed it); a page shared by several sites is still sent once.

**No site can hold up the run.** A site whose page shows **no sign of life for 15 seconds** (`AutoOptOut.idleLimit`) is given up and moved to semi-automatic ("the site stopped answering"). Signs of life are a load starting, redirecting, committing, finishing or failing; the page changing; a request the page made coming back (a script added only to a background run's pages, `WebViewSession.activityScript`, at most one report a second); and the page answering one of the app's own checks during the live form fill. Screens a person uses (Solve and send, guides) do not get that script and are unchanged. Each site also has at most 60 seconds in all (`AutoOptOut.siteLimit`, decided 2026-11-23; 28 seconds from build 49 cut off slow pages that were still working), from loading its page to the screenshot, so with the 2-second pause between sites a run settles at least one site every 62 seconds (`AutoOptOut.progressEvery`). A page that is stuck rather than slow is still dropped after 15 seconds with no sign of life. A site that needs longer is given up (below); the limit was 2.5 minutes until build 48. The progress iOS shows for a run (`ContinuedRun`) moves with every site done and creeps forward every 5 seconds while one is in progress, so with this limit it never stands still long enough for iOS to take the run for stalled. Page loads had their own limits, but a page could wedge a step that has none (a script that never answers, a screenshot that never comes back), and the whole run then sat on that one site with "Working…" showing (seen on build 46). A site that runs out of time, or goes quiet, **before its form was sent** is recorded as failed ("the site took too long to answer") and the run goes on; it is **tried once more after every other site** of the pass (most such pages were only slow for a moment), and that second try is its result: only if it fails again does it stay in the semi-automated queue. Each second try counts as a step of the run, so the progress count only goes up. A site given up **after its send button was pressed** (`SiteRun.markSent`, called where the app presses a form's send button) may have gone through: it is recorded as "the form was sent, but the site did not confirm it in time; check it before sending again" (`AutoOptOut.sentUnconfirmed`), is never sent again in that pass, and the person sees that reason in the semi-automated queue. Build 48 recorded both as "took too long", so a form the site had taken could be filled in again. **The result is read before the time is up.** After pressing send, a background run waits for the page only as long as leaves 5 seconds (`SiteRun.readReserve`) before the site's limit (`SiteRun.deadline`, set by the run's watchdog; Solve and send has none and waits as before), and starts another step of a multi-step form only while there is time to read it ("the form had more steps than the time allowed"). So the confirmation or the error is read and the screenshot taken: build 49 waited the full time after sending and was cut off first, and many sites ended "sent, not confirmed" with nothing to show. For a form that was sent, the text that appeared after sending (or, when nothing new appeared, the text on screen) is kept with the attempt (`OptOutAttempt.pageSaid`) and shown on the site's page; a site stopped before sending keeps none, since its reason says why. A site sent and not confirmed gets one more automatic try in the next repeat pass or Run now (`AutoOptOut.sentUnconfirmedOnce`; a second opt-out request does no harm); unconfirmed twice, it is left for the person.

**A run carried on after a pause counts on.** A run cut off (Stop, the app suspended or closed) carries on with only the sites it had not done, and its count starts from the sites it already did, out of the whole run: "27 of 35", with "It carried on after a pause ... nothing is sent twice" under it (`AppModel.autoCarriedOn`). It restarted at "0 of" the sites left, so "2 of 35" became "0 of 32" and looked like a new run (`ResumeAppTests.testARunCarriedOnCountsFromTheSitesItAlreadyDid`).

**A site whose answer never arrives is given up on time, with a picture.** Reading a page whose answer is still loading can wait until the load ends, so the reading before giving up is raced against its time limit and never waited for past it (`GiveUpCapture.takeNow`; a task group had waited for it and held the run 150 s on one site). In a background run the page is pictured just before send is pressed (`WebViewSession.beforePress`): when the page cannot be read at give-up, that picture and its words are what the site's page shows (`testAPageThatCannotBeReadWhenGivenUpDoesNotHoldTheRun`; end to end `FixtureJourneyUITests.testASiteWhoseAnswerNeverArrivesStillKeepsAScreenshot`, fixture `hang`, whose server never answers the post).

**The screen keeps answering during a run.** Reported on a phone (2026-11-23): scrolling froze for about 5 seconds at a time while a run worked. Each site's screenshot was painted on white and encoded as JPEG on the main thread, at the screen's 3x (a long page is some 8 million pixels); that now happens off the main thread at 2x (`WebViewSession.screenshotJPEG`). Debug builds have a main-thread watchdog (`MainThreadWatch`, launch argument `-uitest-watch-main`) that logs every stall over 250 ms with the run's step ("making a page", "filling", "screenshot", "recording a result") and shows the worst one during a run in a hidden label (stalls while the app launches are logged, not counted: GitHub's runner stalls 1.7 s there); `FixtureJourneyUITests.testTheScreenKeepsAnsweringWhileARunWorks` scrolls through a run of 13 fixture sites and fails on a stall of a second or more. On the simulator no stall was seen during a run either before or after the change (only at launch), so the test guards against a large regression but could not reproduce the phone's freeze; the phone decides whether the change cured it.

**A site given up after its form was sent still shows what it said.** When the run gives a site up (it went quiet, or it ran out of its 60 seconds) after the form was pressed, the page was usually showing something ("Processing your request...") that the run never got to read, because giving up cancels the work. The run now reads the page's text and takes its screenshot before it cancels the site's work (`GiveUpCapture.whenGivingUp`, called by `AutoOptOut.watched` for at most 6 seconds), and saves them as for any other sent form. Reading it from the cancel handler, as before, usually found the page already closed by the cancelled work, so the site showed neither (quad.com; `testAPageThatClosesWhenCancelledIsStillReadBeforeTheSiteIsGivenUp`); the cancel handler stays as a second chance: the site's page shows "What the page said" and the screenshot (a page given up before anything was sent keeps neither, as before). Tested in the core package by `testASiteGivenUpAfterItsFormWasSentKeepsWhatItsPageShowed` and end to end by `FixtureJourneyUITests.testRunNowShowsWhatAPageSaidAndItsScreenshotWhenTheSiteDidNotConfirmInTime`, against a fixture page that posts the form and then says it is processing for ever.

**Where the time goes.** The work on a page takes seconds; what used up the 28 seconds in build 48 was waiting. Every wait now ends as soon as the page is ready, at most the time it used to wait in full: after a click (a request choice, an intro Next, a link to the request) the run waits until the page has changed, then until it settles, where it paused a fixed 2.5 to 4 seconds; a form that appears after a click is looked for every quarter second; frames are read as each reports itself instead of after a fixed 2.5 seconds. A page counts as settled when it is loaded and unchanged for 1.5 seconds, looked at every quarter second (it was two seconds, every half second), and as still loading only when it says "Loading", "Please wait" or "Searching" in whole words (`PageSettle`): build 48 matched any text containing "loading", so a page mentioning "downloading your data" was waited on in full at every step. The background run answers a cookie prompt once the page has settled and settles again only when it answered one, where it always paused and settled twice. Solve and send and the other flows share the same page code, so they get quicker too; nothing they decide changed.

A site given up is also **ended**: its work is cancelled and every web page it opened is stopped and taken out of the window (`SessionBin`, `WebViewSession.abandon`). Until build 48 a given-up page kept running hidden for the rest of the run, and enough of them could use up the memory iOS allows the app. While a run works, **Stop** (`auto-stop`) starts no more sites; the site in progress finishes and everything done is kept. **Stop means stop:** it is written down (`AutoSettings.stoppedByPerson`), and no run starts by itself after it, not on opening the app or going back, and not on schedule (`AutoSettings.startsByItself`), until the person presses Run now or Re-test all, or turns automatic opt-out on again. Run now then carries on with only the sites left: any site with a result since the pass started (sent, stopped by a check, failed, timed out) is left out, and a site that was in progress when the app closed is tried again, since it may not have been sent. A stopped or cut-off **Re-test all** carries on as a re-test (`AutoSettings.passEverySite`), so the sites it had not reached are sent again even though they were sent earlier in the period. (Build 47 carried a stopped run on at every opening, and a first pass that never finished counted as due at every opening, so the run seemed to start over each time.) A run carried on after it was cut off shows the number of sites it really has left from the start; build 47 showed "0 of" every site in the directory until its first site was done.

**The automatic opt-out page is quick.** Which sites a run tries and why the others are left alone depends mostly on how each site's form is filled for the person (`FormFiller.plan`), about a millisecond a form for some 800 sites. That is worked out once per person and kept (`FillPlans`, `AppModel.fillPlans`), first in the background when the app opens, and the page's groups and counts are worked out away from the main thread (`AppModel.activityPage`, the same rules as `willTry` and `skipReason`). Build 47 worked it all out again on the main thread every time the page opened and after every site of a run: about 5 seconds each time on a Mac simulator, longer on a phone.

**A run does not slow the app.** The plan (the Queue's steps) is rebuilt when the progress changes, but a run's own results do not rebuild it: it is rebuilt once when the run ends (`AppModel.household` `didSet`, `endOptOutRun`). A change the person makes, such as their profile, still rebuilds it at once. Building it is quick (about 0.07 s on a Mac simulator): how a site's form fills for a complete profile is worked out once per site and kept (`OptOutMethods.samplePlan`), each site's method once per build, and the tasks' sort keys once. In build 47 every site of a run rebuilt the plan on the main thread, which took about a second each time.

**Working while the phone is locked.** The profile file, the screenshots and the Keychain key are readable once the phone has been unlocked after it starts ("after first unlock"; until build 48 the key and file could be read only while unlocked). So a run in a pocket or overnight keeps what it did; build 47 showed "Could not save: status(-25308)" and then stopped saving at all. The key is read once per launch and kept in memory. A save or load that still meets a locked phone (before the first unlock) is not an error: the save is written at the unlock (`UIApplication.protectedDataDidBecomeAvailableNotification`, or the app coming to the front), and the profiles open then. "Erase saved data and start over" is offered only for data that really cannot be opened, never for a locked phone or a failed save.

**Keeping a run going.** On iOS 26 a run asks for background time (`ContinuedRun`, shown by iOS as a Live Activity), so it carries on while the person uses another app. Its progress moves during a slow site, not only after it, so iOS does not take it for stalled. If iOS takes the time back, the run stops after the current site only when the app is not on screen (`AppModel.continuedRunExpired`) and a notification says it is paused; it resumes when the app is next open. On screen it simply carries on. (Until build 47 it stopped either way, so "Run now" could end after its first site with the person watching.) On older iOS, leaving the app stops the run after the current site, the same way.

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
