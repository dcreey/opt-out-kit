# Testing (placeholder)

Deliberately thin until the app works end to end. Layers, cheapest first:

| Layer | Where | Runs |
|---|---|---|
| Broker YAML vs `schema/broker.schema.json` | CI `registry` job | `check-jsonschema --schemafile schema/broker.schema.json brokers/*.yml` |
| Core logic (decode, queue, progress) | `Packages/OptOutKitCore/Tests` | `swift test` in that folder |
| Assisted run logic (runner, email handoff, page-text reading) | `Packages/AssistedRunLogic/Tests`, on the app's own sources in `Shared/AssistedRun` | `swift test --package-path Packages/AssistedRunLogic` (Mac, no simulator) |
| App unit tests (anything that needs UIKit or a web view) | `AppTests` | `xcodebuild test` (needs a simulator) |
| UI tests | `AppUITests` | same |

## User flows and where each is tested

Notes about how a test works live in the test file itself. This is the list of what a person can do and which test pins it.
"Mac" means it runs with `swift test` and no simulator. "Sim" needs the iOS simulator.

### Assisted run ("Solve and send")

| Flow | Expected | Test | Runs |
|---|---|---|---|
| Site with no bot check | Form is filled and sent with no help; the site ends Sent | `AssistedRunnerTests.testASiteWithNoBlockerIsFilledAndSentWithoutAnyHelp` | Mac |
| Bot check, terms, certification box | The person clears them; the app sends only after, and never ticks or accepts for them | `AssistedRunnerTests` (check, terms, certification, timeout, check after send) | Mac |
| No confirmation after sending | Waits for the person, then records the site as incomplete | `testASiteThatShowsNoConfirmationWaits...` | Mac |
| Same company's sites in a row | The second waits so the shared rate limit is not hit | `RateLimitTests` | Mac |
| Next site loads while the person works | No wait between sites | `testTheNextSiteLoadsWhileThePersonStillWorks...` | Mac |
| Previous site (… menu) | Reopens the earlier site shown as it is; nothing is sent for the person; leaving either site records nothing. Going back twice walks back two sites. Not offered on the first site | `EmailAndSkipFlowTests.testBack...`, `testGoingBackTwice...`, `testTheFirstSiteHasNothingBefore` | Mac |
| Finish a site after going back | A site that was skipped and is then done (sent or marked done) is recorded as done. A site only looked at keeps its result: Skip or Next on it is not a skip, no email offer | `testASkippedSiteDoneNowAfterGoingBack...`, `testSkippingOrLeavingASiteVisitedAgain...` | Mac |
| Back from the email screen | The no-form or offer screen is left untouched and comes back when moving forward | `testBackFromTheEmailOffer...` | Mac |
| Skip this site | Moves on at once from the form page, while still loading, and from the last site (run ends) | `testSkipMovesOnWithoutSending`, `testSkippingWhileAPageIsStillLoading...`, `testSkippingTheLastSiteEndsTheRun` | Mac |
| Page will not load | Skipped after retries, shown as skipped, run continues | `testAPageThatWillNotLoad...` | Mac |
| Site has no form, only an email address | The no-form screen waits; "No" to the mail prompt keeps waiting; Skip moves on | `NoFormReasonTests`, `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| Send an email from a form page | Ends as Emailed (green check), never Skipped; next site runs | `EmailAndSkipFlowTests.testEmailingFromTheFormPage...` | Mac |
| Other mail app (Gmail, Outlook, ...) | "Did you send it?" appears as soon as the app opens and nothing covers it; Yes saves, No saves nothing | `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| In-app Mail composer | Send saves and finishes the site; Cancel saves nothing | `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| Site failed or "Not working" | A site with an address offers email; Mark as done saves it as emailed; Skip moves on; no address means no offer | `EmailInsteadTests`, `EmailAndSkipFlowTests` | Mac |
| Stray or double email answers | Ignored; saved once | `EmailAndSkipFlowTests.testAnswersWithNothingOpen...` | Mac |
| Choices the person makes on the page (request-type tiles, boxes, radios, menus) | The app chooses once, before the person acts, and never again on a refill. A tile, box or menu the person tapped is theirs: adding a second tile, unselecting ours or picking another is never undone, and a toggling tile is never tapped twice | `LiveFormTests.testTilesTheAppChoseOnce...`, `testAPersonAddingAnotherTile...`, `testAPersonUnselecting...`, `testATileTheAppHasNotYetChosen...`, `testBoxesAndMenusTheAppSet...`, `testABoxTheAppTicked...` | Sim |
| Only one request can be chosen (tiles, radios, a request-type menu) | Deletion is picked over opt-out, whichever comes first; a page that starts on opt-out is moved to deletion unless the person chose it. Where several can be ticked (checkboxes) both are ticked | `LiveFormTests.testASingleChoiceOf...`, `testAPageThatStartsOnOptOut...` | Sim |
| Filling a form whose code names mislead (usmarketinggrp.com: the box labelled Phone is named `email`; a "Full Address" box) | The visible label wins over the code name: Phone gets the phone, Full Address gets the whole address, never the name | `CoreTests.testTheVisibleLabelBeatsTheCodeName...`, `testAnEmailBoxNamedPhone...` | Mac |
| Accepting site terms for you | Off until the person taps Allow. When on, a prompt whose every paragraph is on the reviewed list is accepted once per page and logged; anything else, a risk-flagged paragraph, or the setting off leaves it to the person. The shipped list reviews nothing risk-flagged | `CoreTests.testTheGeneratedLibrary...`, `TermsAcceptanceTests` (render, Solve-and-send page), `TermsSettingsTests` | Mac / Sim |
| Settings: California DROP link | Shown only when California is the chosen state | none yet (view only) | n/a |
| Opening the right form is not "done" | Instructions on a form page ("your request is submitted only after you enter the code") are never a confirmation; real confirmations ("Thank you. Your request has been received.") still count, even below the instructions | `AssistedRunnerTests.PrematureDoneTests` (Melissa's consumer privacy page) | Mac |
| Never the deceased-person form | No directory opt-out page is a deceased list; Melissa uses its consumer privacy form; the live form picker scores a deceased form down | `CoreTests.testNoOptOutPageIsAListForDeceased...`, `LiveFormPickerTests.testAFormForADeceasedPersonIsScoredBelow...` | Mac |
| Send it for me (guides) | On by default; the box in a guide changes it for the session; Settings changes the default. Off: the form is filled, nothing is pressed, the person presses the page's button, and a confirmation is noticed or they tap Mark as done or Next (not recorded as sent or failed) | `EmailAndSkipFlowTests` (three tests), `WorkflowGapTests`, `SolveAndSendUITests` | Mac / Sim |
| A page with several opt-out forms (nordicdataresources.com: email, cookie button, device ID) | The person is told "This page has 3 opt-out forms… form 2 of 3". Every form whose own words say opt-out or delete is filled and sent in turn, a sign-up, newsletter or contact form never is, the device-ID form gets this phone's IDFA (not the Android GAID), a later form that fails does not undo the earlier ones, the site is recorded once | `EmailAndSkipFlowTests` (three multi-form tests), `LiveFormTests.testOnlyFormsThatAreSpecificallyOptOuts...`, `AssistedAppTests.testEveryOptOutFormOnAPageIsFilledAndSentIncludingTheDeviceIDOne` | Mac / Sim |
| A check already passed | The page's own "please wait for the anti-spam check" line, left on screen from an early press, no longer keeps a solved check alive | sim only; covered by the multi-form page test | Sim |
| Auto-send ON: a confirmation is noticed (the app sent the form, or the person pressed the page's button) | One rule: Auto-send on, the app moves on to the next site by itself, as before | `EmailAndSkipFlowTests.testAConfirmationOnAFormTheAppSentItselfStillMovesOn...`, `testAutoSendOnMovesOnByItself...` | Mac |
| Auto-send OFF: a confirmation is noticed | The site is saved and the green check shows, but the screen stays until the person taps Next site or Mark as done; the app never moves on by itself | `EmailAndSkipFlowTests` (two tests) | Mac |
| Several boxes of one kind (emails, phones, previous addresses, other names) and an opt-out email with the full history | Boxes are filled in profile order; leftovers go in the message; the email lists other names, emails, phones and past addresses | `CoreTests` (`testSeveralBoxes...`, `testPreviousAddresses...`, `testWhatTheFormHasNoBoxFor...`, `testAnEmailCarries...`) | Mac |
| Every kind of form box (text, email, tel, number, date, month, date-time, select, age brackets, textarea, contenteditable) | Each is filled in its own shape and limit; identifiers (SSN), someone else's names and other dates stay empty; a before/after comparison over every recorded directory form guards the rules | `CoreTests` (the "field-by-field robustness" group), `LiveFormTests.testEveryKindOfBoxIsFilledInItsOwnShape...` | Mac / Sim |
| A page that ships a State/Country default ("CA"); "Is this for yourself?"; a phone list | The page default gives way to the profile's state, a matching country and a pre-filled name stay, a State the person typed survives; the self question is answered Yes; the phone list keeps both numbers | `LiveFormTests.testAStateOrCountryThePageShipsWith...`, `testForYourselfIsAnsweredYes...` | Sim |
| Forms built with Tally and similar (realsourcedata.com): the question is a heading and each box points at it with aria-labelledby | Every such box is filled: first and last name, street, city, state, zip, phone, email | `LiveFormTests.testBoxesLabelledByAHeadingThroughAriaLabelledby...` | Sim |
| Menus stay steady while the run waits | The run no longer tells the screen "changed" every second with the same status, which made an open … menu blink | none yet (visual); the screens use the same values as before | n/a |
| A page with no form and no address on file (redidata.com) | The page's own privacy address (same domain, privacy@ before info@, never noreply or another company) is offered for the email, with "We found this address on the site's own page. Check it before you send."; with none, the skip says there is no address | `EmailAndSkipFlowTests` (two tests), `ContactEmailPickerTests`, `WebAssistedDriverTests.testANoFormPageThatLinksAPrivacyAddress...` | Mac / Sim |
| A multi-step form (statara.com: Next, then choices, then Submit) | Next is a step, not a result; the choices are picked on the new step (opt-out, not limit-use or opt-in); only the last Submit counts. Consent wording ("you state that this request has been submitted…", "will be processed within 15 days") is never a confirmation | `WebAssistedDriverTests.testAMultiStepForm...`, `AssistedRunnerTests.testConsentAndChoicesWording...`, `EmailAndSkipFlowTests.testMultiStepForms...` | Mac / Sim |
| A reCAPTCHA that rejects the app's press ("response was missing or invalid") | The app does not keep pressing; it tells the person to press the page's Submit themselves and notices the result (moves on if Auto-send is on) | `EmailAndSkipFlowTests.testAReCAPTCHAThatRejects...` | Mac |
| Email links: Fill in my details on a privacy portal that grows as it is answered (OneTrust: pick the state from a type-ahead, then the rest appears) | The state is picked from the list (not just typed), the questions it reveals are filled in rounds, a typed captcha is left for the person; the same type-ahead is answered in Solve and send; a portal whose only form asks State and Captcha is recognised from the page's intro | `LiveFormTests.testTheEmailLinksFillAnswersAStateTypeAhead...`, `LiveFormPickerTests.testAPortalFormThatOnlyAsksForTheState...` | Sim / Mac |
| Email links uses the same page code as Solve and send | Finding forms (frames, folded sections), choices, tiles, device ID, terms, several forms on a page, Next then Submit, the reCAPTCHA handoff and the Auto-send box all work the same in both. Sending from a pasted link waits for checks, sends each opt-out form, notices a confirmation when Auto-send is off | `EmailAndSkipFlowTests` (six "Email links" tests, through `PageSender`), `LiveFormTests.testTheEmailLinksFill...` | Mac / Sim |
| Sending a form from a pasted link marks the site done | A site waiting on its email just finishes that step; a site that was not waiting on anything is recorded as sent now and counts as done | `OverdueFollowUpAppTests.testSendingAFormFromAPastedLink...` | Sim |
| Reading a confirmation page | Real thanks and receipts count; plain "thanks" and hidden templates do not | `LooksFinishedTests`, `EmailFollowUpWordingTests`, `WebFormSubmitterTests` | Mac / Sim |
| Real web view against a local page | Fills, waits for the person, sends, reads the result | `WebAssistedDriverTests` | Sim |
| Today's queue | Only sites the app can fill and has not sent to recently | `AssistedQueueTests` | Sim |

### Skipped sites coming back

| Flow | Expected | Test | Runs |
|---|---|---|---|
| Skip leaves the batch | The next site takes its place | `CoreTests.testASkippedSiteLeavesTheBatch...` | Mac |
| Return after a week | The site comes back with a reminder | `CoreTests.testASkipWaitsAWeek...` | Mac |
| Skip again / forever | Again restarts the week; forever never returns | `CoreTests.testSkippingAgainRestartsTheWeek...` | Mac |
| Finish a skipped site | Ends the skip | `CoreTests.testFinishingASkippedSiteEndsTheSkip` | Mac |
| Skip in the run saves to the profile, returns the next plan after a week | **Not tested end to end yet** | none | n/a |

### First run, profile and safety

| Flow | Test | Runs |
|---|---|---|
| Walkthrough on first install; finish it; does not return; replay from About | `OnboardingAndSitesUITests` | Sim |
| Walkthrough of the guided flows (Solve and send, manual): opens before the first site, nothing runs behind it, skip, replay from About; the walkthrough's last pages are the advertising ID and the pointer to About | `SolveAndSendUITests`, `OnboardingAndSitesUITests` | Sim |
| Law pages for California, other states and countries; language switch | `OnboardingAndSitesUITests` | Sim |
| Both switches on by default; declining turns both off; skipping leaves a banner | `AutoProtectionUITests` | Sim |
| Birthdate required; legal name and address required to close the editor | `AutoProtectionUITests`, `ProfileEditorUITests` | Sim |
| Add a relative, switch accounts, profile survives relaunch | `ProfileEditorUITests` | Sim |
| Minor or public figure is never searched | `SafetyFlagsUITests` | Sim |
| Sites tab: search, grouping, status page, scan | `OnboardingAndSitesUITests`, `BrokerListUITests` | Sim |
| Guided flow: steps advance, Cancel, Not working, site view links | `GuidedFlowUITests`, `GuidedRunnerTests` | Sim |
| Run now shows what was sent and what needs you, with no network | `AutoProtectionUITests`, `DryRunUITests` | Sim |
| Spokeo, FastPeopleSearch, PeopleConnect flows | `BrokerFlowUITests` | Sim |

## Workflow audit (2026-11-01)

Every workflow a person can do in the app, with the tests that pin it. **Mac** = `swift test` in `Packages/OptOutKitCore` or
`Packages/AssistedRunLogic`, no simulator. **Sim** = `xcodebuild test` on the iPhone 17 Pro simulator. A workflow is only "covered
without a simulator" when its rules live in the Mac packages; the SwiftUI wiring itself (what is drawn, which alert shows) can only be
checked in the simulator.

| # | Workflow | Mac tests | Simulator tests | Status |
|---|---|---|---|---|
| 1 | First run: walkthrough once, replay from About, language, place, both auto switches | Core: `FreshInstallGetsWalkthrough`, `UpdateWith...Message`, translation and country tests, `OptOutIsMonthlyNothingScansAndBothStartOffUntilThePersonDecides`, `DecliningTurnsEverythingOff...` | `OnboardingAndSitesUITests`, `AutoProtectionUITests`, `AppModelTests.WalkthroughOnFirstInstall...` | Covered |
| 2 | Profile: complete before anything runs, editor, relatives and switching, minor and public-figure flags, tagged email, encryption | Core: profile completeness, flags, Gmail tag, `RoundTrip`, `TamperingIsDetected`, `RemovingPersonDeletesTheirData` | `ProfileEditorUITests`, `SafetyFlagsUITests`, `ContactEmailAppTests`, `PlatformAppTests` (gate) | Covered |
| 3 | Queue and daily batch: 15 sites, kinds, rollover, goals | Core: `Daily`, batch and kind tests, queue order and bands | `AppModelTests.AFreshPick...`, `PlatformAppTests` queue tests, `BrokerListUITests` | Covered |
| 4 | Sites tab: search, groups, status, scan, look-yourself and points | Core: scan, points, grouping tests | `OnboardingAndSitesUITests` (Sites tab, scan, points) | Covered |
| 5 | Site page: guide, email, heal a moved link, report a problem, skip, skip forever, bring back | Core: skip and return after a week, forever, report, healing, closed sites carry evidence | `LinkHealingTests`, `AppModelTests.ASkippedSite...`, `GuidedFlowUITests` | Covered; the lists of closed and locked sites are view-only (not tested) |
| 6 | Automatic protection: monthly run, run now, activity, run report, review and reject a result | Core: run period, one send a month, dry run, evidence screenshots | `AutoProtectionTests`, `AutoProtectionUITests`, `PlatformAppTests` | Covered |
| 7 | Solve and send: check, terms, send, no confirmation, rate-limit pacing, skip, Mark as done, Previous site | AssistedRunLogic: `AssistedRunnerTests`, `EmailAndSkipFlowTests`, `EmailHandoffTests` | `SolveAndSendUITests` (skip, Previous site, Next site on the real screen), `AssistedAppTests` | Covered |
| 8 | Email an opt-out: batches, Bcc, mail apps, in-app composer, "Did you send it?" | Core: batch and mail-link tests; AssistedRunLogic: handoff | none for the Opt-out email screen's own alert | **Gap**: that screen's alert is wired in the view (same logic as the assisted run, which is tested) |
| 9 | Verify queue (forms that need only a bot check ticked) | Core: `FormsThatOnlyNeedABotCheck...`; AssistedRunLogic | `SolveAndSendUITests` shares the screen | Covered |
| 10 | Email links tab: paste a link, safety check, fill, send, follow-ups, link shared from a mail app | Core: link check and follow-up tests | `AppModelTests` (link taken from the share, follow-ups after 45 days), `WorkflowGapTests` (pasted address rules) | **Gap**: filling and sending on the loaded page needs a live https page |
| 11 | Guided flow for sites needing a person | Core: guided plan tests | `GuidedRunnerTests`, `GuidedFlowUITests` | Covered |
| 12 | Live forms: picking the form, choices the person made, deletion over opt-out | Core: `FormFiller` tests (labels beat code names) | `LiveFormTests`, `WebFormSubmitterTests` | Covered |
| 13 | Settings: language, place, California link, Global Privacy Control, advertising ID, terms | Core: language and place tests, terms rules | `WorkflowGapTests` (California link, Global Privacy Control), `TermsAcceptanceTests`, `PlatformAppTests` | Covered; the advertising ID read needs a device |
| 14 | Accepting site terms for you | Core: `TermsGate` tests, library has no risk-flagged approvals | `TermsAcceptanceTests` | Covered |
| 15 | Background runs, reminders, notifications | Core: reminder schedule tests (08:01-08:15 next calendar day, stable on replanning, a 21:00 opt-out still gets next morning's) | none | **Gap**: iOS background scheduling and notification permission need a device |
| 16 | Share extension (send a link to Exnay) | Core: none | `AppModelTests.OnlyAWebAddress...` covers the app side | **Gap**: the extension itself needs a device |

### One set of rules for every flow

Solve and send, Email links, the monthly automated run and the guide all find forms, fill them, press send and read the result with the same code
(`Shared/AssistedRun`): `WebAssistedDriver.prepareLoaded` and `WebAssistedPage` for the page, `PageFlow.sendOnce` for what a press of send meant,
`PageFlow.watch` for what the person did, `PageFlow.reloadThenRefill`, the tap check (`AssistedPage.pressesSinceFill` + `SentQuestion`: a confirmation with no button, link or Enter pressed by the person since the fill is asked about, "Was this sent?", not assumed; `testAConfirmationTheyDidNotPressAnythingForIsAskedAboutNotAssumed`), the typing guard (`AssistedPage.userIsTyping`: while the person has the cursor in a box nothing is clicked, scrolled or filled; `testNothingIsFilledClickedOrScrolledWhileThePersonTypesInABox`), a verification-code sub-form (`FormRun.asksForCode`, `AssistedPage.awaitingCode`: "Verify Email" sends a code, the site is not finished until the person types it; `testAVerifyEmailSubFormIsAStepNotTheEndInEveryFlow`) for Refresh the page, `PageMenu.items` (which also carries "My data": each of the person's details listed in a submenu, tap to copy; `DetailChoices` tested on Mac, the menu by `testMyDataIsInTheMenuAndOffersEachDetailToCopy`) for the … menu's page actions (Copy link, Refresh the page, fill), `LiveFormPicker` for which form is the opt-out. What differs between flows is only the surroundings: the buttons,
whether a next site exists (Solve and send), whether a person is there to ask (the monthly run gives up on a check, the others wait for it), and the
guide's steps. The semi-automated flow is pinned the hardest: `SemiAutomatedFlowTests` (28), `EmailAndSkipFlowTests`, `EmailHandoffTests`,
`AssistedRunnerTests`, `PageFlowTests` run on the Mac in a few seconds.

Not yet on the shared code: the guide's flows built from a stored form or a person's own listing (Spokeo and similar) still fill from the stored form, because the
shared page code does not take a listing address yet.

### What can and cannot be tested without a simulator

Everything that decides something is plain Swift and runs on the Mac: the runner and its screens' state, the email handoff, which form on a page is
the opt-out (`LiveFormPicker`), what counts as a confirmation, which address to email, the form filler and the directory data, and the translation
catalogs (`python3 -m unittest discover -s tools/tests`, 22 tests). Only the page-side JavaScript needs a web view, so it is tested in the simulator on
local pages: reading a box's label (`aria-labelledby`), the tiles, radios and menus the app picks, whether a check is solved, pressing Next then Submit,
and finding an address on a page. The SwiftUI wiring (what is drawn) is checked by `SolveAndSendUITests` and the screenshots in `docs/screens`.

Known simulator failures that are not from recent changes: most of `AppUITests` that open the Sites tab or the profile editor (BrokerListUITests,
GuidedFlowUITests, ProfileEditorUITests, SafetyFlagsUITests, OnboardingAndSitesUITests) fail identically on Build 18, before this audit, on the
iPhone 17 Pro simulator (iOS 26.5). All unit tests (142) and the new Solve-and-send UI test pass. Fixing those UI tests is separate work.

Run everything:

```bash
swift test --package-path Packages/OptOutKitCore
swift test --package-path Packages/AssistedRunLogic
xcodebuild test -scheme OptOutKit -destination 'id=<iPhone 17 Pro UDID>'   # unit and UI tests
```

Human-only steps (CAPTCHA, phone, ID) are never automated; see docs/DESIGN.md.
TODO: mock broker site for UI flow tests, fake inbox for `wait_for_email`, live-page drift check.

Build locally: `brew install xcodegen && xcodegen generate`, then open `OptOutKit.xcodeproj`
(generated, git-ignored).

## Broker pipeline (live, read-only)

`broker-pipeline` dry-runs every `brokers/*.yml` against the live web and reports PASS, FAIL, BLOCKED or NEEDS RESEARCH
(see `.github/workflows/pipeline.yml`, weekly and on broker changes). For each broker it loads every step page and,
when the broker has a `recheck:` block, searches a made-up name (must read as removed) and a known common name
(must read as still listed). That pair is how it tells a working check from a silently broken one.

It also runs a reachability census over `pipeline/census-sites.txt`, to size how many sites a plain request can reach.

```bash
cd Packages/OptOutKitCore
swift run broker-pipeline --brokers ../../brokers --census ../../pipeline/census-sites.txt
# Optional local scan of a real person, never for CI or commits:
swift run broker-pipeline --brokers ../../brokers --person "First Last|City|ST"
```

To bring a site into the pipeline, add a `recheck:` block with a `calibration:` name to its YAML.

## Translations, registries and the pipeline's own tools

```bash
python3 -m unittest discover -s tools/tests
```

Covers the crawler's retries and backoff, registry parsing and joining (California CSV, Texas rows, Oregon's names-only file), the
terms census's language detection and alternate-page discovery, and that every string is translated with matching placeholders and
the shipped catalogs are current. The core package tests cover state and country facts, the rules text in every language, and the
multilingual link and form patterns. The UI tests launch the app in French and switch language from the walkthrough.
