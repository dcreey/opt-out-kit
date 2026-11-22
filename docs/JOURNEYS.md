# Integration test audit: the journeys we test, and the ones we do not

> **Status (updated after the fixture conversion):** sections 1 to 5 are the audit as it was written, when the UI tests ran on fakes. Section 0 says what has since been
> moved to end-to-end tests against fixture brokers, and which findings it fixed. The numbers in the short version are from before.

Audit of the UI tests (`AppUITests`, target `OptOutKitUITests`, run by `.github/workflows/integration.yml`) on 2026-11-20. Method: every one of the 45 tests was
read; every control the app labels for testing (258 accessibility ids) was compared with the ones any test touches; each user story below was matched to the tests
that exercise it. Stories are written as "As a user I want to...". `docs/TESTING.md` still holds the per-rule map (which unit test pins which rule); this page is
about **what a person can do and whether a test walks it**.

## The short version

- **45 tests in 13 files**. 35 are behavioural (a person does something, the screen shows the result); 8 check layout or that an element exists; 1 pins a fixed
  bug; 1 needs a live site and a real person's details and is skipped everywhere it runs.
- **97 of the 258 labelled controls are touched** by any UI test (38%). 161 are not.
- **Of 54 user stories, 16 are walked end to end, 16 are walked in part, and 22 are not walked at all** by a UI test (counts at the end of the matrix). Most of the
  untested ones have strong Mac or simulator unit tests behind them; what they lack is a test that proves the *screens are wired to the rules*.
- **The engine is faked in the UI tests** (`-uitest-fake-submit`, `-fake-hold`, `-fake-guided`, `-fake-scan`, `-demo-run`). So the UI tests prove the screens and
  the navigation, and none proves that a form is really filled, a check is cleared, a send is confirmed and the next site comes up. That is covered in pieces
  by `AppTests` (real WebKit against local pages: `LiveFormTests`, `WebAssistedDriverTests`) and the Mac suites, but never as one journey.
- **The biggest gaps** are the whole Email links tab, the email opt-out, the end of the semi-automated send (check, send, confirmation, "is it completely
  done?"), skipping and bringing sites back, reviewing what the automatic run did, and an upgrade test for the new database.

## 0. Now end to end against fixture pages

See docs/TESTING.md, "End-to-end tests against fixture pages". These run the real engine against a local web server of fixture brokers, nothing faked (run only
for a release): `FixtureJourneyUITests` (Run now over every kind of page; stopping a run and carrying on; a site that never confirms; a site that answers with an
error; the run's report leading to the semi-automated sites; Solve and send through a plain form, a Cloudflare box, an "I'm not a robot" box, a choice that reveals
the form, an email promise, an emailed code and a wrong one, a page with no form and a page that is down; skipping a site and bringing it back; marking a site done
by hand), `FixtureGuideUITests` (a hand-written guide, to the end), `SolveAndSendUITests`, `ExposureScanUITests` and the first-pass / status-page tests of
`AutoProtectionUITests`. The only fake left is the weekly job's sending over the real catalog (`-uitest-fake-submit`). This covers stories 11 (part), 12, 14, 15, 16,
20, 21, 24, 25 (part), 26, 29, 30 (part), 31, 32, 38, 39 and 40 (part); stories 43 to 47 (follow-ups, email opt-out, Email links, GPC, mail app), 49 and 50
(erase and upgrade), 51 to 54 are still to do. The profile, onboarding and settings screens need no broker, so they are unchanged.

Scrolling a long page (`FixtureScrollUITests`, a page of about 7000 px with its form at the very end): the suspicion that the app fights the person's scrolling while
it fills the form was **not confirmed** in Solve and send. While the app prepares the page a "Loading the form…" cover hides it (1 to 10 s: the longer the page's
quiet time and its late content, the longer), so the person cannot scroll yet. The app then scrolls the page to the form once (and, on a page with an opt-out link near
its top, first to that link), reveals it already at the form, and for a form it can send, presses send about 50 ms later, which is the one visible "jump" (the page opens
at its bottom and is gone at once). Once the person has touched the page the app made no move on its own in 20 s of continuous scrolling, with the form waiting for a
missing detail and with a fixed "opt out" banner arriving mid-page (`scrollToOptOutControl` reads only the text in the screen, which the banner did not change enough
to trigger it). What is left unproved is the guard: `scrollToOptOutControl` (up to twice, on a change in the visible text that mentions opting out, with the control off
screen) is held back only while the person is typing, not while they scroll.

Against the recorded sites (docs/PAGE-TYPES.md): the pages with a search first, several addresses, and exactly one request to choose each have a fixture and an end-to-end
test, and driving them found three bugs (below). Still without a fixture: an hCaptcha, a third-party privacy portal, a bot check on the home page, a terms prompt, and a
business form; the table lists their counts.

Things the fixtures showed that the fakes could not (all fixed; the tests that pin them are named in docs/TESTING.md):
- A group of radios with no "delete" choice (know / opt out / limit) had **"Know what personal information you hold about me"** chosen instead of the opt-out: the rule for answering "who is this
  for? myself" matched any label with the word "me". Fixed in `choose-request-options.js`.
- On a live form a **previous-address box got no address, or the wrong one** (a box tokenised `f0-9` read as "previous address 9"; `f0-12` as "2"). Fixed in `FormFiller.plan`.
- **"Add another email / phone" buttons were not pressed** on a form's first fill (only for a form that appeared later). Fixed in `WebAssistedPage.refill`.
- A site given up after its form was sent (it went quiet while saying "Processing your request") kept no page text and no screenshot, because giving up cancelled the
  work before it read the page. Fixed: the page is read and photographed as the site is given up (docs/AUTOMATION.md). And the screenshot, once saved, never appeared on the
  site's page (its loader sat on a view that is empty until the picture arrives, so it never ran), and tapping it could not open it full size. Both fixed.
- A form whose code box is hidden until "Email me a verification code" was sent with an empty code, and the broker's "that code is not right" page was counted as sent. Fixed in
  `empty-code-field.js` (a hidden code box beside a button that emails a code is a code to type); the journey is `testSolveAndSendIsNotDoneUntilIHaveEnteredTheCodeFromTheEmail`.
  And a site that rejected the code after the app pressed send was still shown as "Sent.": the "the site took it" shortcut treated a page that said "That code is not right" as
  taken. Fixed: a page that rejects or asks for a code is not the site taking the request (`FormRun.rejectsCode`, `testAWrongEmailedCodeIsNotCountedAsSent`).
- The automatic run did not find a form that only appears after a choice ("Who is this request for?"); Solve and send did. The run now fills again (which answers the choice) before it judges the form on screen.
- A page with no form at all, and a page that is down (503), got the same words as a page that was sent without a confirmation: "We pressed Send on this page
  but saw no confirmation". Fixed: "We could not find a form to fill in on this page, so nothing was sent..." (translated).

## 1. The journeys tested today

Each line: the story, the test, what it proves.

### First run and setup

| Journey | Test | What it proves |
|---|---|---|
| **A new user walks the first run**: reads each page to its end, gives an email and a place, passes the advertising ID, leaves automatic opt-out on, completes the profile, lands on the queue with the automatic pass first, finds it on in Settings, and does not see the walkthrough again | `OnboardingAndSitesUITests.testTheFirstRunFromWalkthroughToQueue` | The spine of the app, start to finish, including a relaunch |
| **I choose where I live and learn what protects me**: California (its registry law, DROP offered first), another country (its law and regulator), a state with no law (what California offers instead); reading is required before Next works | `testChoosingCalifornia...`, `testChoosingAnotherCountry...`, `testAStateWithNoLaw...` | Place-specific rules and wording reach the screen; Next waits for the end of the page |
| **I read it in my language**: the phone's language is used, and the first page switches language in place | `testTheDeviceLanguageIsUsed...` | The first page in French, Spanish and German (only that page) |
| **I decline automatic opt-out, or skip the walkthrough and turn it on later from the banner** | `AutoProtectionUITests.testDeclining...`, `testSkipping...` | The answer is kept; the banner appears and disappears correctly |
| **I get short tips the first time I open a tab**, only once | `testFirstVisitsShowAShortGuide...` | The Sites tab tip shows once |
| **I replay the walkthroughs from Settings** (the first-run one and the guided-sites one) | `testAboutTabReplaysWalkthrough`, `SolveAndSendUITests.testTheGuidedWalkthroughIsReplayedFromAbout` | Both are reachable and closable |
| **I am not in California, so California's service is not offered** | `testNotLivingInCaliforniaHidesIt` | The queue starts with the app's own run |

### My profile

| Journey | Test | What it proves |
|---|---|---|
| **I fill in my profile**: a legal name and current address are required before the editor can close; the screen says what is missing; I can add more names and previous addresses | `ProfileEditorUITests.testALegalName...`, `testProfileButtonOpensEditor...` | Required fields gate the Done button; rows can be added |
| **My profile is still there after I quit and reopen the app** | `testProfileSurvivesRelaunch` | The real database and Keychain across a relaunch |
| **I give my birthdate (year, then month, then day) and it is required** | `AutoProtectionUITests.testTheBirthdate...` | The staged picker and the requirement |
| **I mark a profile as a minor or a public figure and searching stops, and stays stopped after a relaunch** | `SafetyFlagsUITests` (2) | The flags default to off, save, and switch searching off with the reason shown |

### The automatic run

| Journey | Test | What it proves |
|---|---|---|
| **I press Run now and see what was sent and what needs me** | `AutoProtectionUITests.testRunNowShowsWhatWasSent...` | A run over a representative sample of 40 sites (every site in the weekly job) finishes, reports, and the counts move |
| **As a new person, the automatic pass runs first and the semi-automated queue opens after it** | `testANewPersonGetsTheAutomaticPassFirst...` | Step 2 waits for step 1; the queue opens with the sites that need me |
| **I open a site from the status page and stay on it** | `testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere` | Regression of a navigation bug (the push bounced back) |

### Solve and send (the semi-automated queue)

| Journey | Test | What it proves |
|---|---|---|
| **I go through the sites that need me: skip one, go back to the earlier one, and come forward again** | `SolveAndSendUITests.testPreviousSiteReopens...` | Previous and Next site, nothing sent on a revisit, "Send it for me" can be switched off for the session |
| **I copy my details when a form needs them** | `testMyDataIsInTheMenu...` | "My data" lists my email and my advertising ID to copy |
| **The app asks "Was this sent?" when it is unsure** | `testAConfirmationNobodyPressed...` | The alert is shown and can be answered No |
| **The first time, a walkthrough explains guided sites; I can page through or skip it** | `testTheFirstGuidedFlowOpensWithAWalkthrough...` | Shown once, before the first site, with the email follow-ups explained |

### Hand-written guides (Spokeo, FastPeopleSearch, PeopleConnect)

| Journey | Test | What it proves |
|---|---|---|
| **I walk a guide step by step to done** | `BrokerFlowUITests` (3) | Steps unlock in order and the site shows as done |
| **Steps move on by themselves when the app sees them done, and with Next when it cannot** | `GuidedFlowUITests.testStepsAdvance...` | Auto-advance after the page loads and after copying |
| **I cancel a guide, or report a site as not working, with a reason** | `testCancelLeaves...`, `testNotWorkingOffers...` | Cancelling is not a report; a report shows on the site |
| **The guide opens from the site's page** | `SiteViewLayoutUITests.testTheGuideOpensFromTheSiteView` | The entry point |

### The Sites tab

| Journey | Test | What it proves |
|---|---|---|
| **I see ten sites per group (Up next, Done, Skipped), open "See all", and narrow by region** | `testTheSitesTabShowsTenPerGroup...` | Status pre-chosen, chips present, the list narrows |
| **I search for a brand (TruthFinder) and land on the flow that handles it** | `testSitesTabSearchAndStatus` | The search matches by the handling flow's name |
| **I search for a site, open it, and read how it is opted out** (shared opt-out, where the form posts) | `DirectoryUITests.testSitesTabListsAndSearches...` | Site page details |
| **I check whether I am listed** (scan), and **answer a quick check for points** | `ExposureScanUITests`, `QuickCheckUITests`, `testBlockedByPaymentIsAnAnswer...` | The scan shows a summary (fake); two quick-check answers award points |
| **The queue shows what to tackle and where to start** | `BrokerListUITests` | The list of broker kinds and "Start here" exist |

### Checks of layout and affordances (not journeys)

`testThePageDotsSit...`, `testEveryKeyboardHasOnlyTheKeyboardDownButton...`, `testTheSitesTabShowsNoTiers`, `testTheGuideSitsOnTop...`, `testABrokerSiteViewLeads...`,
`testADirectorySiteViewHasTheSiteLink...`, `testProfileButtonOpensEditor...` (existence), `testBrokerListShowsQueue` (existence). They assert where things sit or
that an element exists. Useful as guards, but they would pass on a screen a person could not use.

## 2. How behavioural the tests are

| Kind | Count | Examples |
|---|---|---|
| Behavioural journey: a person acts, the result is checked | 35 | first run, California, profile survives relaunch, Run now, Previous site |
| Layout or existence: where something sits, or that it is there | 8 | page dots, guide frame, the keyboard-down button, queue list exists |
| Regression of one fixed bug | 1 | status page push bounced back |
| Live only (a real person's details, a real site), skipped in CI | 1 | `DryRunUITests` |

What weakens even the behavioural ones:

1. **A faked engine.** The UI never sees a real page. `-uitest-fake-hold` stops a site at "waiting for you", so no UI test sends a form, clears a check, or sees
   a confirmation. Nothing proves that the screens and the engine work together.
2. **Existence over outcome.** Several end on "an element appears": the scan test ends on `scan-summary` existing, not on what it says; the run test checks the
   sent count is not "0", not that the right sites are in it.
3. **Boilerplate and sleeps.** Five tests repeat the same onboarding taps; four use fixed sleeps (`Thread.sleep(2.5)`, `sleep(5)`) where a wait on a condition belongs.
4. **Names describe mechanics, not intent** in about a third of the tests (`testTheGuideSitsOnTop...`). A journey name should read as the story.
5. **Launch flags carry the story.** Most journeys start from `-uitest-seed-profile` plus a fake. That is sensible, but it means "a new user types a profile and
   then runs" is never one test.

## 3. User-story coverage

Key: ✅ walked end to end by a UI test · 🟡 walked in part (what is missing is named) · ❌ no UI test (the unit tests behind it are named where they exist).

### First run and setup

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 1 | learn what the app promises and choose my language | ✅ | first run; device language; switch on page one |
| 2 | give my email and place, and read what the law gives me before continuing | ✅ | California, a country, a state with no law |
| 3 | decide whether the app may accept site terms for me | 🟡 | the page and its status are shown; Allow, Review and Turn off are never tapped (`terms-*`) |
| 4 | decide whether to share my advertising ID | 🟡 | only "pass without sharing"; sharing, refusing and Open Settings are not driven (iOS owns the prompt) |
| 5 | turn automatic opt-out on or off at the start, and later from the banner | ✅ | |
| 6 | create my profile and be unable to finish it incomplete | ✅ | |
| 7 | add other names, addresses, phones and emails, and delete them | 🟡 | adding names and addresses only |
| 8 | have my city and state filled from my ZIP code | ❌ | `ZipLookupTests`, `CatalogTests` (Mac) |
| 9 | not lose what I typed if I quit, and be asked to finish an incomplete setup | 🟡 | typing survives a relaunch; the "finish your profile" gate (`profile-gate-*`) is untested; `FirstRunResumeTests` |
| 10 | mark a profile as a minor or public figure so it is never searched | ✅ | |

### The automatic run

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 11 | in California, make the one DROP request first, and say I made it | 🟡 | DROP appears first; making the request and its effect on the plan are untested (`california-drop`, `platform-cover`); `AutomaticRunAppTests` |
| 12 | run it now and see what was sent and what needs me | ✅ | fake engine |
| 13 | after the first pass, work the semi-automated queue | ✅ | |
| 14 | stop a run, carry on later with only what is left, and re-test everything | ❌ | no `auto-stop`, `auto-retest-all`; `ResumeAppTests`, `AutomaticRunAppTests` |
| 15 | see what each site showed after sending: its screenshot and what the page said | ❌ | `RunReviewView`, `site-page-said` untouched |
| 16 | see why a site moved to semi-automatic, and have it retried | ❌ | `CoreTests` (the retry rules) |
| 17 | open a site from the status page and come back | ✅ | |
| 18 | change automatic opt-out later in Settings | 🟡 | the switch's value is read, never flipped |
| 19 | see the progress while the app is in the background | ❌ | not reachable with UI tests (system Live Activity) |

### Semi-automated sites (Solve and send)

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 20 | go through the sites that need me: skip, go back, come forward | ✅ | |
| 21 | have a site's form filled, clear its check, have it sent, see the confirmation, and move on | ❌ | the core of the app: only pieces are tested (`AssistedRunnerTests` on the Mac, `WebAssistedDriverTests` on real WebKit) |
| 22 | turn "Send it for me" off for a session, and for good in Settings | 🟡 | session toggle ✅; Settings default ❌ |
| 23 | copy my details when a form needs them | ✅ | |
| 24 | be asked "Was this sent?" and answer yes or no | 🟡 | the alert and No; Yes (saves the site) ❌ |
| 25 | mark a site done by hand, email the site instead, or be told it has no form | ❌ | `assisted-mark-done`, `assisted-email-*`; `EmailAndSkipFlowTests` |
| 26 | be asked "Is it completely done?" and answer an email is still to come | ❌ | `finish-*`; `FollowUpDetectionTests` |
| 27 | open the site in my own browser and confirm later | ❌ | `browser-handoff-*` |
| 28 | roll the guide up out of the way | ❌ | `guide-collapse` |
| 29 | see a short walkthrough the first time, skip it, replay it | ✅ | |
| 30 | report a site as not working | 🟡 | from the hand-written guide ✅; from Solve and send ❌ |

### Hand-written guides

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 31 | follow a guide step by step to done, with steps that unlock in order | ✅ | three guides |
| 32 | cancel a guide without it counting | ✅ | |

### The Sites tab

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 33 | see what is up next, done and skipped | ✅ | |
| 34 | search by name, address, company or the flow that handles it | ✅ | |
| 35 | search by what a company holds or sells, in my language | ❌ | new: `CatalogTests`, `CatalogAppTests` |
| 36 | filter by status, region, type, what they track, who they sell to, and method | 🟡 | status and region; the other four chips are checked only for existing |
| 37 | open a site and understand it: who they are, where they operate, what they hold, whether an opt-out lasts | 🟡 | details and shared opt-out ✅; the who, region, tracks, sells-to and lasts rows (`site-*`) ❌ |
| 38 | skip a site for now or for good, and bring it back | ❌ | `skipped-*`, `site-bring-back`; `CoreTests` (the skip rules) |
| 39 | mark a site done by hand and undo it | ❌ | |
| 40 | check whether I am listed, and answer quick checks | 🟡 | scan shows a summary (fake); two of the quick-check answers |
| 41 | see the sites that no longer respond or unlock later | ❌ | `closed-sites`, `locked-sites` |

### Queue, follow-ups and email

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 42 | see what to tackle today and where to start | 🟡 | the list and "Start here"; the day's card, goals and summary (`today-*`, `goal-*`, `daily-summary`) ❌ |
| 43 | come back to finish the email follow-ups | ❌ | `followup-*`; `OverdueFollowUpAppTests` |
| 44 | set up Global Privacy Control | ❌ | `gpc-*` |
| 45 | opt out by email: prepare messages, open my mail app (or another), confirm I sent them | ❌ | `email-open-*`; `EmailHandoffTests` (Mac) |
| 46 | paste a link from a confirmation email, have the site recognised, fill my details and send | ❌ | the whole Email links tab (`link-*`, 14 controls); `LinkCheckTests`, `WebAssistedDriverTests` |
| 47 | choose which mail app opens | ❌ | `mail-app-picker` |

### Settings, privacy and robustness

| # | As a user I want to... | | Notes |
|---|---|---|---|
| 48 | replay either walkthrough | ✅ | |
| 49 | erase my saved data and start over | ❌ | and see **Product gaps** below |
| 50 | trust that my data survives a relaunch, and an upgrade from the old files | 🟡 | relaunch ✅; **the move from build 51's files and UserDefaults has no UI test** |
| 51 | put the keyboard away with one keyboard-down button, on every keyboard | ✅ | `UITestCase` checks it in every UI test |
| 52 | get reminders to come back | ❌ | system notifications: not drivable |
| 53 | use it with large text, dark mode, VoiceOver, on iPad | ❌ | no accessibility or appearance test exists |
| 54 | use it with no network | 🟡 | every UI test is offline by construction, so nothing tests the offline *message* |

**Totals: ✅ 16 · 🟡 16 · ❌ 22.** (Stories 19 and 52 cannot be driven by UI tests at all; the rest can.)

## 4. Product gaps the audit found (not test gaps)

- **No ordinary way to erase my data.** "Erase saved data and start over" appears only when saved data cannot be opened. For a privacy-first app a person should be
  able to delete everything from Settings without deleting the app.
- **No way to change the language after the first run.** The first page offers a picker; Settings does not.

## 5. What I would do about it

1. **One real end-to-end journey with a real engine.** Serve fixture broker pages from a local test server (a form, a form behind a check, a confirmation, a
   confirmation that promises an email) and drive Solve and send through them in the UI: filled, check cleared by the test, sent, confirmation noticed, "is it
   completely done?", next site. This replaces the fake engine for the one journey that matters most, and also gives the Email links tab a real page to paste.
2. **Cover the whole queue/email/skip surface** with journeys written as stories: skip and bring back (38), mark done by hand (39), email opt-out (45), Email
   links (46), follow-ups (43), review what the run did (15), stop and resume (14). Each is small; the fakes are fine for these.
3. **An upgrade journey** (50): a debug launch flag writes build 51's files and UserDefaults values with the real Keychain key, the test relaunches without it,
   and the profile, a screenshot and the settings are all there, and the old files are gone. This is the one test that protects people's real history.
4. **Name tests as stories** (`testIcanSkipASiteAndBringItBackLater`) and keep a short **P0 list** that must pass for every TestFlight build: first run, profile
   survives a relaunch, run now, work the queue, upgrade. Everything else runs weekly.
5. **Drop duplication and sleeps**: one `Journey` helper for "a new user with a profile", conditions instead of sleeps, one test per story.
6. **Add `performAccessibilityAudit()`** to the main screens (Xcode 15 and later), and one test each in dark mode and with the largest text size: cheap, and it
   covers a whole category nothing covers today.
7. **Treat the layout checks as guards**, moved to their own `LayoutUITests` class so a journey failure and a layout failure are told apart; remove
   `DryRunUITests` from this target (it is a live-site tool, skipped in CI).
8. **Product:** add "Erase all my data" and a language picker to Settings, each with a journey test.
