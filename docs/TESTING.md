# Testing

Layers, cheapest first:

| Layer | Kind | Where | Runs |
|---|---|---|---|
| Broker and directory YAML vs `schema/*.schema.json`, the Python tools, translations | check | CI `checks` job | every push |
| Core logic (decode, queue, plan, rules) | **unit** | `Packages/OptOutKitCore/Tests` | `swift test` in that folder (Mac, no simulator); every push |
| Assisted run logic and the app model (the runner, email handoff, page-text reading; `AppModel`: its queue, plan, skipping, runs, language, terms settings, the guided runner; the catalog) | **unit** | `Packages/AssistedRunLogic/Tests` (`Model/` for the model), on the app's own sources in `Shared/AssistedRun` and `Shared/Model` | `swift test --package-path Packages/AssistedRunLogic` (Mac, no simulator); every push |
| Page scripts (the JavaScript the app runs in web pages) | **unit** | `tools/pagescripts` (headless DOM) | `npm test` in that folder; every push |
| UI tests: the real app driven on a simulator, mostly against fixture brokers (every rule that needs a real web view, the Keychain or the bundle is proved here, end to end) | **integration** | `AppUITests` (target `OptOutKitUITests`) | for an App Store release (`.github/workflows/integration.yml`); not needed for TestFlight |
| The automatic run over every site, sending faked | **integration** | `AutoProtectionUITests` with `OPTOUT_ALL_SITES=1` | for an App Store release, and weekly |
| Live sites (read-only probes that feed `tools/apply_live_check.py` and `tools/apply_live_forms.py`) | live | `AppTests/Live*` (target `OptOutKitTests`, its only tests) with `OPTOUT_LIVE=1`; `pipeline.yml` | by hand only; skipped otherwise, and no workflow runs them |
| What the built app contains (the compiled catalog, no data file) | check | `tools/check_bundle.py`, on CI's build of the app | every push |

## What runs where: rules on the Mac, the phone end to end

`AppModel` (the household, queue, plan, runs, skipping, language, terms, scans) no longer touches UIKit, UserNotifications, WebKit or the Keychain itself. Everything it
needs from the phone goes through `AppPlatform` (`Shared/Model/AppPlatform.swift`): the screen's idle timer, background time, notifications and reminders, the advertising
ID, the Keychain key, the clipboard, and the web views that fill and send forms. The app gives it the real one at launch (`IOSPlatform`, `App/Sources`); the Mac tests run it on
`HeadlessPlatform`, which does nothing and sends nothing (a test that needs a site hands the run its own submitter). Code in `Shared/` names no UIKit or WebKit type (`tools/tests/test_shared_has_no_platform_types.py`): a `WKWebView` in a published property of `GuidedRunner` crashed the whole Mac test process on GitHub's Xcode 26 as XCTest read the classes. The model's sources live in `Shared/Model`, compiled into the
app and, through links, into `Packages/AssistedRunLogic` (one module with `Shared/AssistedRun`), so `swift test --package-path Packages/AssistedRunLogic` runs them in a few
seconds on a Mac. The catalog those tests read is built from the repository's own data on the first test (`MacCatalog`). A new rule's test goes on the Mac
(`Packages/AssistedRunLogic/Tests/AssistedRunLogicTests/Model`, or the core package, or `tools/pagescripts` for a page script); what only a real web view, the Keychain or the
phone can show is an end-to-end journey in `AppUITests`, against a fixture broker where a page is involved. There are no simulator unit tests: `AppTests` holds only the
by-hand live probes.

**Where the 206 simulator unit tests went (2026-11-22).** 273 Mac tests in `AssistedRunLogic` and 405 in `OptOutKitCore`, the page-script unit tests (114, jsdom) and the
fixture journeys now cover them:

| Former simulator tests | Now |
|---|---|
| The app model's tests (115: queue, plan, runs, skipping, terms settings, the guided runner, link healing, the catalog...) | Mac (`AssistedRunLogicTests/Model`) |
| `AssistedQueueTests`, `BrowserHandoffTests`, `ScreenHelperTests` (Mac), `EditorPruneTests`, `SiteReviewTests`, `LanguageAppTests` | Mac, `ScreenHelperTests` (`BrowserHandoff`, `RowField`, `Person.prunedForSave`, `SiteReviewQueue` moved to `Shared/Model`). That every app string is translated is `tools/l10n.py check`; that the app speaks the chosen language is `testTheDeviceLanguageIsUsedAndTheWalkthroughCanSwitchLanguage` |
| `EvidenceImageTests` | Mac, `EvidencePictureTests` (the picture work is `EvidencePicture`, CoreGraphics); that a real screenshot is saved, shown and not blank is the "did not confirm in time" journey |
| `CatalogBundleTests` | `tools/check_bundle.py` on CI's build of the app (`test_check_bundle.py`) |
| `KeychainKeyTests` | The sealed profile opened again after a relaunch with the same key: `ProfileEditorUITests.testProfileSurvivesRelaunch` |
| `LiveFormTests` (29): finding, filling and pressing in a real web view | Each rule is a page-script unit test (fill shapes, person's edits, tiles, add-another, checks, navigation); the law box is `CoreTests.testTheLawBoxGets...`; the flows are fixture journeys: `phoneformat`, `phonecountry`, `dateformat`, `bottrap`, `introcontinue`, `recaptchafail`, `arialabel`, `multi`, `multiadd`, `choose*`, `checkboxes`, `tiles`, `cookie`, `steps`, `jsform`, `twoforms`, `selfstatement`, `emaillink`, and "a word I change is not undone" (`turnstile`) |
| `WebFormSubmitterTests` (12), `GivenUpPageTests` (2): the background run's web views | Run now against fixture brokers (`plain`, `errorpage`, `slow`, `noform`, `turnstile`, `robot`, `agent`); the `slow` page pings the server while it is open, and the journey checks the pings stop once the run gave it up; dry run: `DryRunUITests` |
| `WebAssistedDriverTests` (6): the Solve-and-send page | `turnstile`, `plain`, `steps`, `noformemail`, `terms`, `twoforms` journeys; that nothing is judged before the page is on screen is `AssistedRunnerTests.testNothingIsJudgedOrSentUntilThePageIsOnScreen` |
| `TermsGate` tests (core), page scripts `click-agree`, end to end `terms` / `termsok` (7) | The decision is `TermsGate` (core) and `click-agree` (page scripts); end to end: `terms` (never accepted for me; sent after I agree), `termsok` with `-uitest-approve-terms` (a prompt whose paragraphs a person reviewed is accepted for me), `terms` with that allowance (an unreviewed one still is not) |
| `IdentityConfirmationTests` (3) | `selfstatement` with and without `-uitest-seed-family`; the model rule in `WorkflowGapTests` |
| `WebViewFetcherTests` (3), `WebPageInspectorTests` (1), `GuidedWebPageTests` (1) | The scan of a page whose results are built by script (`scriptlisted`), the guide to the end and a broken link looking for the new page (`FixtureGuideUITests`) |
| `Live*` (5) | Kept as by-hand probes (`OPTOUT_LIVE=1`); the weekly all-sites job reads the real pages |

## Page scripts

The JavaScript the app runs inside web pages (finding forms and their boxes, filling them, choosing request options, spotting checks, terms prompts and
confirmations, declining cookie prompts, telling the app what the person touched) lives in `App/PageScripts/`, one file per script, compiled into the
app's catalog at build time and read from it by `App/Sources/PageScript.swift` (the app ships no script file: docs/STORAGE.md). A plain script is one expression, run as it is; a script that takes values is a function expression called with its values
as JSON (`PageScript.call`), so an apostrophe or quote in a name arrives as typed and nothing is left on the page. `//#include name` shares a fragment
(`ownership.js`). Moved there from Swift strings on 2026-11-19: the plain scripts were checked byte for byte against what Swift produced, and every
web-view test passed before and after. `PageScriptTests` checks that each one loads, is valid JavaScript and receives its values intact.

**Unit tests** (`tools/pagescripts`, `npm test`, in CI's `checks` job on every push; about 1 second): each script runs against small test pages in a
headless DOM (jsdom), loaded and called exactly as the app does it (`harness.js`). jsdom has no layout, so the harness stands in for what the scripts read
from it, from the page's own markup: an element that is hidden (or inside a hidden one, a closed `<details>`, a zero-height box) has no size, one placed
far off screen (a bot trap) is off screen, a frame is 300 x 150, anything else is 200 x 30; `innerText` is the shown text. What a real browser does with
layout, input masks and real taps is covered end to end by the fixture journeys (`FixturePageTypeUITests` and the others), which run in the integration workflow.
`coverage.test.js` fails when a script has no test.

| Test file | Scripts |
|---|---|
| `discover-forms.test.js` | `discover-forms` (tokens, where a label comes from, required, visible, kinds of box, buttons, loose boxes, headings) |
| `fill-live.test.js` | `fill-live` (events, exact values, the person's boxes, kept and replaced values, page defaults, length limits, menus, age brackets, phones, split phones, birthdates, rich text) |
| `choose-request-options.test.js` | `choose-request-options` (removal and deletion first, never access, agent and self questions, IDFA, self-declarations only when allowed, menus, what the person set) |
| `fill-helpers.test.js` | `add-another-boxes`, `phone-format-step`, `date-format-step`, `align-date-formats`, `empty-required-choice`, `choose-tile-buttons` |
| `checks-and-prompts.test.js` | `visible-challenge`, `pending-certification`, `tick-identity-boxes`, `find-terms-gate`, `click-agree` (with the app's own `gatePattern`) |
| `navigation.test.js` | `deny-cookies`, `decline-consent-banner`, `hide-consent-overlays`, `press-intro-next`, `advance-to-request-form`, `open-request-links`, `open-request-links-follow`, `press-confirm-step`, `confirm-button-label`, `choose-name-tab`, `choose-rights-picker` |
| `menus-and-sending.test.js` | `custom-menus-open`, `custom-menus-pick`, `type-ahead-open`, `type-ahead-choose`, `press-live-submit` (never a sign-up or agree button), `fill-fields`, `press-submit`, `submit-form` |
| `page-reading-and-person.test.js` | `describe-page`, `describe-form`, `form-state`, `form-top`, `page-emails`, `visible-fields`, `viewport-text`, `page-changed`, `user-is-typing`, `code-box-in-use`, `empty-code-field`, `empty-verification-code-box`, `global-privacy-control`, `frame-reporter`, `touch-tracker`, `activity`, the scroll helpers |
| `coverage.test.js` | every script has a test; `ownership` (the fragment) on its own |

**Audit findings (2026-11-19), all fixed**, each with a test that pins the corrected behaviour:

1. `discover-forms`: a box with no label of its own borrowed the label of the box before it (and so its kind, and "required" from its star). The element
   before a box is now its label only when it belongs to no other box (not a `<label>` holding a box or pointing at another box on the page; one pointing
   at an id that does not exist is still taken, as the page's own mistake), and a parent's text only when the parent holds no other box.
2. `fill-live`: `hasCountryCode`, defined and never called, is gone (the number alone was typed anyway).
3. `choose-tile-buttons` could tap a tile twice when a heading and the block around it both read "I am a ..."; on a toggling tile that undid the app's
   choice. A group whose tile the app already tapped is skipped.
4. `empty-required-choice`: the name of a box inside a wrapping `<label>` carried a menu's options ("State Choose IL"); it is now the label's shown words
   without them. (Shown words: a first fix used the label's full text, which read a bot trap's hidden "Send confirmation to *" as a required menu; the
   WebKit test `testBoxesInAnOffScreenBotTrapAreNeverFilled` caught it.)
5. `decline-consent-banner` presses only a shown element (a hidden "Decline" in a closed menu is not the prompt's).
6. `press-submit`, `fill-fields`: a field name is escaped for its selector (`CSS.escape`), so a name holding a quote or backslash is found.
7. `touch-tracker`: a press reported by message counts only when it comes from one of the page's own frames; a page's script posting `ookPress` itself
   no longer looks like the person's press.

## Unit and integration tests

For what a person can do and which UI test walks it (the journeys, the gaps, the plan), see `docs/JOURNEYS.md`.

**Unit tests run on every push (and gate TestFlight); integration tests run for an App Store release.** Unit tests are everything in the two Swift packages (Mac, no simulator, a minute): they check a rule (what is sent, what is skipped, what is saved, what a screen is given to show) without driving the app's screens, and
they run in `.github/workflows/ci.yml` on every push and pull request, which also builds the whole app and every test target (no simulator is booted). Integration tests are the UI tests in `OptOutKitUITests`: they drive the real app
on a simulator, tap through its screens and check what a person sees, mostly against fixture brokers; everything that needs a real web view, the Keychain or the bundle is proved there, end to end. They take far longer (a UI test walks every screen in its way), so they run in
`.github/workflows/integration.yml` when a GitHub release is published, by hand from the Actions tab (Integration, Run workflow), and on a push to a branch named
`integration/...` (never main): `git push -f origin HEAD:integration/check` checks a fix on GitHub's slower machines without a release or a click, and a
run there counts for the release gate when its commit is the one released. The run over every site runs there too, and weekly.

**Every rule an integration test checks has a unit test.** A UI test is the end-to-end proof that the screens are wired to the rules; the rule itself is
proved by a unit test, so a push that breaks a rule fails at once, not at the next release. A test that only checks layout (where something sits on the
screen, that a sheet stays open, that a keyboard has its one keyboard-down button) has no rule behind it and is integration only. When a UI test is added, the unit test
for its rule is added with it, and both go in the table below.

**Releasing (the gate). The release workflow is for releasing the app on the App Store (iOS), not for TestFlight.** A GitHub release, and the
Integration workflow it starts, is the step before a build is submitted for App Store review. TestFlight is the owner's own test channel, used to try a
fix on a phone within minutes, so a TestFlight upload needs only the unit tests: Integration takes up to two hours.

- **TestFlight:** `tools/release_testflight.sh` runs `tools/release_gate.py --for testflight` first and stops unless the working copy is clean, the
  commit is on GitHub's `main` and the CI workflow (unit tests) succeeded for exactly that commit. Push, wait for CI, run the script.
- **App Store:** a build is submitted for review only after `tools/release_gate.py --sha <the build's commit>` passes (without `--for testflight`): the same
  checks, and the Integration workflow (the UI tests and the run over every site) also succeeded for exactly that commit. To get there, publish a GitHub
  release for the commit (Releases, Draft a new release, a tag such as `v1.0-49`), which starts Integration on it, or start Integration by hand
  (Actions, Integration, Run workflow, on `main`). A failing integration test is fixed, or the release held, before the build goes to review.

The gate reads GitHub's public API (no login); its rules are tested in `tools/tests/test_release_gate.py`. Only the repository's admin can create, move
or delete tags (a tag ruleset), so only they can publish a release. Integration takes the UI tests about 15 minutes and the run over every site up to two
hours.

| Integration test (`OptOutKitUITests`) | The rules it checks, and their unit tests |
|---|---|
| `OnboardingAndSitesUITests.testTheFirstRunFromWalkthroughToQueue` | Walkthrough shown once: `CoreTests.testFreshInstallGetsWalkthrough`, `testUpdateWithNoNewMessageShowsNothing`. The answer saved: `AutoProtectionTests.testSayingYesTurnsOnBothAndNoTurnsBothOff`. The profile asked for: `CoreTests.testAProfileNeedsALegalFirstAndLastNameAndACurrentAddress`. First pass first: `CoreTests.testTheSemiAutomatedQueueWaitsOnlyForTheVeryFirstAutomaticPass`, `BackgroundPassesAppTests`. Page order, scroll-to-unlock: layout |
| `…testChoosingCaliforniaExplainsItsLawsAndOffersDropInTheQueue`, `testChoosingAnotherCountryShowsItsLawsAndRegulatorAndNeedsReadingToo`, `testAStateWithNoLawPointsToStrongerStatesWithExamples`, `testNotLivingInCaliforniaHidesIt` | Each place's rules and examples: `CoreTests.testEachCountryIsToldItsOwnRulesAndStrongPlacesAreOfferedAsExamples`, `testTheCountriesLoadWithTheEUAndEveryMemberAndAreUniqueByID`. DROP only in California, sites it covers not separate work: `AutomaticRunAppTests.testDROPComesFirstInCaliforniaAndIsLeftOutEverywhereElse`, `PlatformAppTests.testASiteDropHandlesIsListedOnceAndIsNotSeparateWork` |
| `…testTheDeviceLanguageIsUsedAndTheWalkthroughCanSwitchLanguage` | `PlatformAppTests.testTheAppSpeaksTheChosenLanguageEverywhereItBuildsWords`, `testAnUnsupportedLanguageIsIgnoredAndTheChoiceIsRemembered`, `L10nTests` |
| `…testFirstVisitsShowAShortGuideOnceInsteadOfWalkthroughPages` | `PlatformAppTests.testAGuideIsShownOnceAndOnlyForTasksAPersonTakesPartIn` |
| `…testTheSitesTabShowsTenPerGroupAndSeeAllOpensTheSearchWithThatStatus`, `testSitesTabSearchAndStatus`, `DirectoryUITests.*` | `SiteFilterTests`, `CoreTests.testEachFilterNarrowsAndTextMatchesAddressOrName`; the site page's shared opt-out: `DirectoryTests.testTheCourtRecordsSitesShareOneOptOutThatSubmitsToTheMembersHost` |
| `…testAboutTabReplaysWalkthrough`, `testThePageDotsSitBelowTheContentNotOnTopOfIt`, `testEveryKeyboardHasOnlyTheKeyboardDownButtonThatPutsItAway`, `SiteViewLayoutUITests.*`, `GuidedFlowUITests.testTheGuideSitsOnTopInAColouredFrameAndShowsTheWholeStep`, `AutoProtectionUITests.testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere` | Layout and navigation only |
| `AutoProtectionUITests.testDecliningAtFirstRunTurnsItOffAndTheQueueBannerDisappears`, `testSkippingTheWalkthroughLeavesAQueueBannerThatOffersToTurnItOn` | `AutoProtectionTests.testNothingRunsUntilThePersonSaysYes`, `testSayingYesTurnsOnBothAndNoTurnsBothOff`, `CoreTests.testDecliningTurnsEverythingOffButRemembersTheAnswer` |
| `AutoProtectionUITests.testRunNowShowsWhatWasSentAndWhatNeedsYouWithoutTouchingTheInternet`, `testANewPersonGetsTheAutomaticPassFirstAndTheSemiAutomatedQueueAfterIt`, `DryRunUITests.testDryRunForRealPerson` | `AutoProtectionTests.testOptOutRunSendsToSitesWithAFormAndRecordsOnlyWhatWasSent`, `testPreviewFillsFormsButRecordsNothingAndKeepsTheClockStopped`, `AutomaticRunAppTests`, `BackgroundPassesAppTests`, `ResumeAppTests`, `ActivityPageSpeedTests`, `CoreTests.testDryRunFillsButNeverSends` |
| `AutoProtectionUITests.testBlockedByPaymentIsAnAnswerInQuickChecks`, `QuickCheckUITests.testLookingAtASiteEarnsPoints` | `CoreTests.testBlockedByPaymentEarnsPointsButIsNeverAVerdict`, `testAPaywalledLookCannotVerifyOrRelistAnOptOut` |
| `ExposureScanUITests.testScanShowsGroupedResultsWithoutTouchingTheNetwork` | `CoreTests.testScanCoversOnlyCalibratedSitesAndReportsEachOutcome`, `testRechecksAndScansNeverRunForAMinorOrPublicFigure` |
| `AutoProtectionUITests.testTheBirthdateIsChosenYearThenMonthThenDayAndIsRequired`, `ProfileEditorUITests.*` | `CoreTests.testAProfileNeedsALegalFirstAndLastNameAndACurrentAddress`, `testANicknameOrAPreviousAddressDoesNotMakeAProfileComplete`, `testBlankSpacesDoNotCount`, `testABirthdateUnderEighteenCountsAsAMinorEvenWithTheFlagOff`; saved and encrypted: `PeopleTests.testProfileEditsPersistAcrossLaunchesEncrypted`. The year-month-day picker: layout |
| `SafetyFlagsUITests.*` | `CoreTests.testBothFlagsDefaultToNoAndAnAdultCanBeSearched`, `testEitherFlagStopsSearching`; the reason shown: `PeopleTests.testSearchingIsOffForAPublicFigureOrAMinorWithTheReason` |
| `GuidedFlowUITests.testStepsAdvanceByThemselvesWhenSeenAndWithNextWhenNot`, `testCancelLeavesTheGuideAndGoesBackToTheSite`, `testNotWorkingOffersTheReasonsAndRecordsOne`, `BrokerFlowUITests.*`, `SiteViewLayoutUITests.testTheGuideOpensFromTheSiteView` | `GuidedRunnerTests.testLoadingThePageFinishesTheOpenStepAndTheCountIsShown`, `testCopyingTheValueFinishesTheCopyStepAndPutsItOnTheClipboard`, `testStepsItCannotDetectNeedTheNextButtonAndTheFlowFinishes`, `testCancelClosesThePageAndRecordsNothingElse`, `testNotWorkingRecordsTheReasonAndClosesTheFlow`; every broker file loads and is valid: `CoreTests` (registry) and the `checks` schema job |
| `SolveAndSendUITests.testPreviousSiteReopensTheEarlierSiteAndNextSiteBringsYouForwardAgain` | `EmailAndSkipFlowTests.testBackReopensThePreviousSiteWithoutChangingEitherSiteAndNothingIsSentForThePerson`, `testASkippedSiteDoneNowAfterGoingBackIsRecordedAsDone` |
| `SolveAndSendUITests.testMyDataIsInTheMenuAndOffersEachDetailToCopy` | `DetailChoicesTests.testEveryDetailOfThePersonIsOfferedOnceInTheOrderAPersonLooksForIt`, `testAProfileWithLittleOnlyOffersWhatItHas` |
| `SolveAndSendUITests.testAConfirmationNobodyPressedAnythingForAsksWasThisSent` | `PageFlowTests` (the "Was this sent?" question) |
| `SolveAndSendUITests.testTheFirstGuidedFlowOpensWithAWalkthroughThatCanBePagedThroughOrSkipped`, `testTheGuidedWalkthroughIsReplayedFromAbout` | `PeopleTests.testTheGuidedWalkthroughIsShownOnceThenRemembered`; paging: layout |
| `BrokerListUITests.testBrokerListShowsQueue` | `CoreTests.testEveryTaskIsInExactlyOneBandOfTheRealQueue` |

## The keyboard in every UI test

Whenever a keyboard is on screen the app shows one control for it: a keyboard-down symbol (`keyboard-hide`, `App/Sources/Keyboard.swift`), over every screen. There is no
"Done" for a keyboard, and no bar of the system's own (previous / next / done) over a web page's boxes (`NoAccessoryWebView`). Every UI test class inherits `UITestCase`
(`AppUITests/UITestCase.swift`): `typeTextChecked` types and then checks it, and so does the end of every test, so it is asserted in every journey: the keyboard-down
button exists, there is no `keyboard-done`, no toolbar is attached to the keyboard, and no Done / Next / Previous button sits just above it. A new UI test class extends
`UITestCase`, and types with `typeTextChecked`, never `typeText`.

## End-to-end tests against fixture pages

The direction for every integration test: run the app's real code against fixture brokers, a real local web server, with nothing faked (docs/JOURNEYS.md
lists the journeys and what is still on the older fakes). The app is not changed to fit them: it loads fixture *sites* from a catalog exactly as it loads
real ones, and the engine, web view and page scripts do the same work they do on a real broker.

- `fixtures/sites/*.yml`: the fixture brokers, in the directory's own format (so the same loader reads them), each with its opt-out page on
  `http://127.0.0.1:8765`. A site's id names its page kind: `fx_<kind>_<n>` is shown `fixtures/pages/<kind>.html`.
- `fixtures/server.py`: the web server (Python's standard library, nothing to install). It serves the pages, records what each form posted, and tells the
  tests (`GET /__received`, `POST /__reset`). It keeps a backlog of 128 waiting connections (the standard 5 overflows when a
  web view loads a page while a test asks what was received, and macOS refuses the rest); a test asks for it for up to 30 seconds before saying it is gone,
  the Integration shard stops at once if it never comes up, and a shard with a failed test prints the end of the server's log.
- `fixtures/build_catalog.sh`: compiles a catalog from the app's real laws, platforms, terms, page scripts and ZIP table with the fixture sites in place of
  the directory, using the same `catalog-builder` as the app's build.
- `tools/run_e2e.sh`: builds that catalog, starts the server, runs `FixtureJourneyUITests` (or the tests named in its arguments) and stops the server. `OPTOUT_FIXTURE_PORT` (default 8765) puts the server on another port, with a catalog pointing there, so two runs on two simulators do not share one server.
  Run it with the usual `-destination`; it passes the catalog and server address to the tests. In the Integration workflow (`integration.yml`) shard 0 compiles
  the catalog into the build it hands over, and every shard starts the server before its tests. The other shards wait up to 45 minutes for that build (the job
  allows 75): when GitHub is short of macOS machines shard 0 can start long after them, and at 15 minutes two shards gave up and ran no tests (2026-11-23).
- `App/Sources/Fixtures.swift` (debug builds only): `-uitest-catalog <path>` opens that catalog in place of the bundled one, and lets the web view load the
  loopback server (`URL.isSecureWebPage`; a loopback IP address is outside App Transport Security). The shipped app opens only its bundled catalog.
- `AppUITests/FixtureBrokers.swift`: the tests' side: the launch arguments, and what the server received (`sentSites`, `requests`).

Page kinds so far (`fixtures/pages`; each is a site in `fixtures/sites`): `plain` (a form that confirms), `turnstile` (a Cloudflare box only the person can
tap), `robot` ("I'm not a robot" tick box), `tiles` (request-type buttons that reveal the form), `reveal` ("Who is this request for?" that shows the form),
`cookie` (a consent banner over the form), `iframe` (the form in a frame), `emaillink` (a confirmation that says an email is coming), `selfconfirm` (a page that
says "received" by itself, with nothing pressed), `noform` (no form, post only), `down` (503), `slow` (posts the form, then says it is processing for ever; while open it pings `/__ping` with an image request, which the app does not count as a sign of life, so the test can see the page ended once the run gave it up),
`errorpage` (answers a send with an error), `code` (a page that emails a code before it accepts a request: an "Email me a verification code" button reveals the
code box; the server takes the request only with the code, 750439, and records a wrong or empty one as `rejected`), `guide` (a broker with a hand-written guide,
`fixtures/flows/fxguide.yml`), `longform` / `longneeds` / `longdynamic` (a very long page with its request form at the very end: one the app sends, one that needs a case number it lacks, one that also gets a fixed "opt out" banner after it loads; they report every scroll position and whether a finger moved it to `/__scroll`, and every call that can move the page: `scrollIntoView`, a `focus()` without `preventScroll`, `scrollTo`, a form the browser refused for an empty required box. That reporter is shared, `fixtures/pages/_scroll-report.js` at `/__scroll-report.js`. `FixtureScrollUITests` counts those calls after the person's first touch, plus any sizeable scroll with no finger near; a big jump during the person's own flick is not counted, because a fast flick on a slow machine jumps that far too), `search` (find your listing, then a form wants its link), `multi` / `multiadd` (boxes for previous addresses, a second email and phone, other names; "Add another" buttons), `choose` / `chooseoptout` / `chooseselect` / `checkboxes` (choose exactly one request, from radios with and without a delete, a menu, or tick the right ones), `recaptcha` (a real-shaped reCAPTCHA frame), `certify`, `jsform` (a form built by script), `steps` (Next, then Submit), `upload` (needs an ID photo), `agent` ("Are you an authorized agent?"), `login`, `terms` (an "I Agree" gate the app never accepts unreviewed), `termsok` (a gate in front of the form whose paragraphs `fixtures/add_terms.py` adds to the catalog's terms library as reviewed; with `-uitest-approve-terms` the app accepts it for the person), `phonecountry` (a +1 country menu beside the phone box), `phoneformat` / `dateformat` (boxes that only take one shape), `bottrap` (off-screen, hidden and invisible boxes), `introcontinue` (a bare Continue before any box), `recaptchafail` (refuses a press a script made), `arialabel` (boxes named only by `aria-labelledby`), `selfstatement` ("I am the person" plus an agent box; run with `-uitest-seed-family` for a family profile, which gets no ticks), `noformemail` (no form, an address to write to), `requestmenu` (type-to-search menus for "I am" and the request type), `customeronly` ("I am a (an)": Customer / Authorized Agent), `slowtiles` (a form built seconds after load, with tile questions), `stateunlisted` (a state list without the person's state), `agentradio` (a required "Authorized agent? No / Yes" as radios), `dependentstate` (a State menu built only once Country is set), `customstate` (a home-made "Choose state" menu, as saymine draws it), `blanklink` (a "Submit a Privacy Request" link that opens a new tab), `hang` (a form posted the ordinary way to a server that does not answer for 150 s: the page is still loading when the run gives up), `countryreset` / `hubspot` / `klear` / `cmplz` / `residentof` (the pages reported on 2026-11-23, one shape each: comscore.com's State menu rebuilt after Country and labels that float on focus and blur; datatowin.com's HubSpot form with nameless radios and a flag-only US phone entry; klear.com's title-named boxes, example placeholders and shadow-root banner; focus-usa.com's and cashmereai.com's bot trap and cookie-service toggles; dnb.com's aria-labelledby "Resident of" and company country menus), `gatemenus` / `gatelaw` (no form until a country menu, a state menu and a "delete and opt out" link are answered; `gatelaw` lists only states with a privacy law, not the person's), `turnstilepass` (a Cloudflare check that shows "Verifying..." and passes by itself after 4 seconds), `wizard` (a request wizard with no `<form>`: what to do, who is asking, then the details and Submit, as privacy.datarate.ai's), `nodata` (a form that searches first and answers "No data was found, try other criteria", as the courtrecords.us sites do), `nodatacheck` (the same behind a "Verify you are human" box only a person ticks, with Submit off until then, as those sites show it in the app), `autofocus` (a page that focuses its own boxes: `autofocus`, on load and a moment later), `twoforms` (two opt-out forms on a page that stays when one is sent; avoid field names with "mobile" in them, which read as a phone box), and `listed` / `unlisted` / `scriptlisted` (only a name search, for the exposure scan: `listed` finds anyone named Pat; `scriptlisted` builds its results by script after a moment). To add, from the real
kinds (the page scripts in `App/PageScripts`, the rules in docs/FORM-FILLING.md): an image-puzzle check, custom menus, a phone or date box that rejects a
format, a disabled email box, a listing to pick from, a block widget, an emailed link to paste. A new kind is a page, a site file, and a journey. The fakes the
UI tests used to launch with (`-uitest-fake-hold`, `-fake-guided`, `-uitest-fake-heal`, `-uitest-fake-listing`, `-show-sent-question`) are gone; the Core fetcher
may read the fixture server's loopback address in a debug build only (`URLSessionFetcher.allowLoopback`, set by `-uitest-catalog`).

| Journey | Test |
|---|---|
| Run now sends every broker whose page can be completed without me (plain, tiles, cookie banner, frame, email promise) and leaves the ones that need me (checks, a form that only appears after a choice, no form, down) | `FixtureJourneyUITests.testRunNowFillsAndSendsTheFormOnEachBrokerPage` |
| Solve and send fills and sends a form with no check, waits for my check on the next, sends it when I clear it (the broker gets the token), and asks "Is it completely done?" after each | `FixtureJourneyUITests.testSolveAndSendFillsTheFormWaitsForMyCheckThenSendsAndMovesOn` |
| Solve and send waits for an "I'm not a robot" box, and sends when I tick it | `testSolveAndSendWaitsForTheNotARobotBoxAndSendsWhenITickIt` |
| Solve and send sees that a site promises an email, and lists it as sent with the email still to confirm | `testSolveAndSendSeesThatASitePromisesAnEmailAndListsItForTheFollowUp` |
| Solve and send answers "Who is this request for?" and fills the form that appears | `testSolveAndSendAnswersWhoTheRequestIsForAndFillsTheFormThatAppears` |
| Solve and send sends nothing to a page with no form, and I can mark it done | `testSolveAndSendSendsNothingToAPageWithNoFormAndLetsMeMarkItDone` |
| Solve and send leaves a broker that is down unsent, and I can skip it | `testSolveAndSendLeavesABrokerThatIsDownUnsentAndLetsMeSkipIt` |
| Solve and send is not done until I have entered the code the site emailed: nothing is sent while the code is missing, the broker never sees an empty code, and once I type it the form is sent and the app asks whether it is done | `testSolveAndSendIsNotDoneUntilIHaveEnteredTheCodeFromTheEmail` (page-script rule: `tools/pagescripts`, "a code box that is hidden until a button emails the code") |
| Scrolling on a very long page with the form at the end (auto-sent; needs a missing detail; gets an opt-out banner late): the app moves the page by itself only once, before the page is shown, and never after the person has touched it; the timeline (what the app and the person scrolled, and when the broker received the form) is attached; no page script focuses a box in a way that scrolls, and a touched form with a required box still empty is not pressed (the browser would jump to it) | `FixtureScrollUITests` (3 tests); page scripts `menus-and-sending.test.js` ("a script that focuses a box never lets the browser scroll to it", "once the person has touched the page, a form with a required box still empty is not pressed") |
| Every kind of recorded page below: search first (find my listing, its link goes into the form), several addresses / emails / phones / names (including "Add another" buttons), choose exactly one request (radios with and without a delete, a menu, checkboxes), a reCAPTCHA, a certification, a script-built form, a two-step form, an ID upload, an agent question, a sign-in page, a terms gate, phone and date shapes, bot-trap boxes, a bare Continue, a check that refuses a script, aria-labelled boxes, the owner's self-statement, a no-form page with an address. `docs/PAGE-TYPES.md` counts each kind in the recorded sites and says which fixture and test covers it (`tools/page_type_coverage.py`; `tools/tests/test_page_type_coverage.py` keeps it true) | `FixturePageTypeUITests` (27 tests); `-uitest-seed-multi` gives the person several addresses, emails, phones and names; `-uitest-seed-family` runs Solve and send for a parent's profile instead of the owner's |
| Guide: it sits on the page with the whole step, advances by itself when it sees a step done, is cancelled without a report, can be reported as not working (broken link: it looks for the new page), and walking it to the end sends my request and shows the site as submitted | `FixtureGuideUITests` (6 tests) |
| Solve and send: Previous / Next site and the "Send it for me" switch; My data to copy; a page that says "received" with nothing pressed asks "Was this sent?"; the first-time walkthrough | `SolveAndSendUITests` |
| Exposure scan over two fixture brokers: it says it found a listing on 1 of 2 sites and shows which | `ExposureScanUITests` |
| The first pass sends the plain form and leaves the one behind a check; the queue opens after it; a site opens from the status page and stays | `AutoProtectionUITests` |
| A wrong emailed code is not counted as sent or done | `FixtureJourneyUITests.testAWrongEmailedCodeIsNotCountedAsSent` |
| Run now over a site that posts the form and then says it is processing for ever: the run reports it, the review says "the site did not confirm in time", the site's page shows what the page said and its screenshot, and the screenshot opens full size | `testRunNowShowsWhatAPageSaidAndItsScreenshotWhenTheSiteDidNotConfirmInTime` |
| Run now sends what it can, then the report's semi-automated start leads to the site it could not send: its page says "Blocked by a human check: only you can clear it" with a screenshot of the filled form, "Opt out" opens it, and clearing the check sends it | `testRunNowThenTheSemiAutomatedQueueFinishesWhatTheRunCouldNot` |
| I stop a run part way (what was sent stays sent); Run now carries on with only what is left and sends nothing twice | `testIStopTheRunPartWayAndRunNowCarriesOnWithOnlyWhatIsLeft` |
| A run that stopped while I was away waits: back in the app I am asked "Carry on with the opt-out run?", nothing was sent while I was away or before I answered, and Carry on finishes it | `testARunThatStoppedWhileIWasAwayAsksMeBeforeCarryingOn` |
| I skip a site for now and bring it back from its page | `testISkipASiteForNowAndBringItBackFromTheSkippedList` |
| I mark a site done by hand, and nothing is sent | `testIMarkASiteDoneByHandAndItShowsAsDone` |

## Continuous integration

Two workflows (and the lint jobs in the first), on GitHub's hosted runners (free for a public repository). Neither contacts a real broker site: the live tests skip unless `OPTOUT_LIVE=1`,
and the UI tests use the app's fake sites.

**`.github/workflows/ci.yml`: the unit tests and the build, on every push to `main` and every pull request.**

| Job | Machine | What it runs |
|---|---|---|
| `lint-actions`, `lint-swift`, `lint-yaml`, `lint-json`, `lint-python`, `lint-shell` | Linux, one each | The linters (below, "Lint"); seconds each |
| `checks` | Linux | Broker and directory files against their schemas; `tools/tests` (the Python tools); `tools/l10n.py check`; the page-script unit tests (`tools/pagescripts`); the shard split |
| `packages` | macOS | `swift test` in `Packages/OptOutKitCore` and `Packages/AssistedRunLogic` |
| `build` | macOS | `xcodebuild build-for-testing` for the app and every test target (`OptOutKitTests`, `OptOutKitUITests`), cached by source hash; then `tools/check_bundle.py` on the built app (the compiled catalog, no data file). Nothing is run and no simulator is booted, so a compile error in the app or a UI test still fails the push |

**Lint** (jobs `lint-*` in `ci.yml`, each on its own Linux machine, versions pinned so a new release of a linter never fails a push by itself; part
of CI, so the TestFlight gate needs them too). They look for what is wrong, not for style: the code's own style (one-line statements, flow-style YAML,
long lines) is deliberate.

| Job | Tool | Checks | Run it here |
|---|---|---|---|
| `lint-actions` | actionlint (with shellcheck) | Every workflow: expressions and the outputs they read, job and step keys, each `run:` script | `actionlint` |
| `lint-swift` | SwiftLint 0.65.1 (its Linux image), `.swiftlint.yml` | Only rules that catch mistakes: force casts, doc comments attached to nothing, discarded notification observers, duplicate keys, cases and imports, identical operands, unused bindings and setters, XCTFail without a message, stray whitespace; warnings fail too. Left out: `force_try` (each `try!` builds a constant regular expression) and the layout rules | `swiftlint lint --strict` |
| `lint-yaml` | yamllint, `.yamllint.yml` | **Every YAML file**, hand-written or written by the tools: the rules of [abcxyz/actions](https://github.com/abcxyz/actions/blob/main/.yamllint.yml) unchanged (every string value single-quoted, no inline `{ }` mappings, 2-space indentation, sequences indented, only `true` / `false` / `on`). The tools write this style themselves (`tools/yamlio.py`) | `yamllint $(git ls-files '*.yml')` |
| `lint-json` | Python | Every `.json` file and string catalog parses | |
| `lint-python` | ruff, rules `E9,F,B018` | Syntax errors, unused imports and variables, undefined names, statements that do nothing | `ruff check --isolated --select E9,F,B018 .` |
| `lint-shell` | shellcheck | Every `.sh` script | `shellcheck tools/*.sh` |

What they found when they were added (2026-11-20), all fixed: Norway's country code was an unquoted `NO` in `jurisdictions/countries.yml`, which a YAML 1.1
reader (PyYAML, as in the Python tools) takes for `false` (the app's decoder reads it into a text field, so the app most likely read it right); it and the `YES` / `NO` build settings in `project.yml` are quoted (the generated project is byte for byte the
same); the build notice always said "cache: none" because it read a `cache-matched-key` output `actions/cache` does not have (it now looks for a restored
build folder); 16 unused imports, variables and a repeated import in the Python tools; unquoted variables and unused loop counters in the workflows' scripts; in Swift, two doc comments that had come apart from their declarations, a force cast,
keyboard observers thrown away (now kept for the app's life), ternaries that call functions, nine `XCTFail()` with no message and a `try!` in a test.
All YAML was rewritten to the abcxyz rules on 2026-11-20 by a round-trip converter that kept comments and checked each file's data was unchanged:
the hand-written files first (the generated Xcode project and Info.plist came out byte for byte the same), then `directory/` and `terms/library.yml`
(the app catalog built from them was byte for byte the same; it caught a terms hash written unquoted, `4783098342e69647`, which YAML reads as a number,
infinity, so every hash is now quoted). The 33 tools that write or read those files go through `tools/yamlio.py` (ruamel.yaml, `tools/requirements.txt`),
which keeps comments and hand edits and writes this style; each reader was checked to return exactly what it returned from the old files.
`l10n.py` and `check_jurisdictions.py` stay standard-library only (everyone runs them) and read the hand-written files in either quote style. Swift is linted with SwiftLint, not swift-format: swift-format's layout checks cannot be turned off and would mean reformatting every file.

**`.github/workflows/integration.yml`: the integration tests, for a release.** On a published GitHub release and by hand: the UI tests (`OptOutKitUITests`)
in 5 shards, built and handed over the same way. On a release, by hand and weekly (Mondays): the automatic run over every site (see below).

`tools/ci_shards.py` shares the tests out (`--suite` picks the unit or the UI tests) so the shards end at about the same time: unit tests a class at a time (a class measured over 45 seconds, such as the
web-view classes, one test at a time), UI tests one test at a time (one UI class can take ten minutes). Each is weighed by the seconds it took in the last measured run (`tools/ci_timings.json`); one never measured is estimated
from its number of tests, and shard 0 is given less, since it boots only after building (`--reserve`, `PACKAGES_SECONDS`). Every shard prints its timings as a notice, and
`python3 tools/ci_shards.py --fetch-run RUN_ID` reads them back from a finished run (public API, no login) into that file, so the split stays balanced as
tests change. Every failed test and its message is an annotation too, readable without logging in. Tests are read from the sources, so a new class needs
no change to the workflow (`--list` shows the split; `tools/tests/test_ci.py` checks that everything runs exactly once, a known-failing test is left out
wherever it lands, a shard with other work gets less, failures become annotations, and the file times are set from the commits). The free plan runs at
most 5 macOS jobs at once, which is why the unit tests have 4 shards beside the package job, the UI tests 5, and the build is done by one of the shards
rather than a job of its own: nothing waits for a free machine.
Building once instead of in every shard was measured to matter: these machines have three cores, and five shards each compiling while their simulator
booted slowed both (the tests started 8 to 9 minutes in). A failing shard keeps its result
bundle as an artifact for a week.

Between runs it keeps four things in GitHub's cache: the app's build folder (`DerivedData`, saved by `actions/cache`'s post step at the end of shard 0's job, after its tests, because saving it takes minutes; without its logs; started afresh each week so stale build products never pile up in it), the two packages'
`.build` folders, the generated Xcode project (XcodeGen runs only when `project.yml` or the list of files changed: the project carries a hash of the file
list), and XcodeGen itself (downloaded from its release rather than installed with Homebrew, which is slow there). The app build also compiles the data into `Catalog.sqlite` (the core package's `CatalogPlugin`; builds pass `-skipPackagePluginValidation`). Every checkout is one commit with no
history (the file times come from contents). The packages' `Package.resolved` files are committed: they pin Yams, and the CI build copies the core package's into the
generated project and builds with `-disableAutomaticPackageResolution` (no package resolution over the network), `-skipPackagePluginValidation` and
`-skipMacroValidation`; `swift test` runs with `--disable-automatic-resolution`. The CI test build leaves out the app icon
(`ASSETCATALOG_COMPILER_APPICON_NAME=`): rendering its appearance variants took over three minutes on those machines, and no test looks at it. The build
cache's key comes from git's tree hashes of the source folders (hashing every file with `hashFiles` took over two minutes and timed out). Code signing stays on (ad hoc): the app's encryption key lives in the
Keychain, which needs a signed app on the simulator. Xcode and SwiftPM decide what to rebuild by file times, and a fresh checkout
gives every file the time of the checkout, so before building `tools/ci_file_times.py` gives each file a time worked out from git's hash of its
contents (the same contents, the same time; changed contents, another), and only what changed since the cached build is compiled. It reads the hashes
from the checkout itself, so every job checks out one commit with no history (it used each file's last commit time until 2026-11-20, which needed the
last 100 commits, and a cache older than those rebuilt more). Checked on the core package: a fresh checkout with the build folder restored rebuilt nothing
(0.2 s), and one changed file rebuilt only that. Each shard's build posts a notice with the Swift files it compiled, the cache it started from, the build
folder's size and its slowest kinds of step (`-showBuildTimingSummary`, read by `ci_shards.py --build-summary`). The caches are keyed by the Xcode version and the sources, so a new
Xcode starts clean; one shard saves each cache. Raising `CACHE_VERSION` in the workflow throws every cached build away. Timings that a test checks have
room for slower CI machines.

**Habits for GitHub's slower simulator** (each one a failure seen there and never locally):
- Tabs by `tab(name, index)`: there the tab buttons are named after their icons ("magnifyingglass").
- `searchSites` closes a run's summary sheet first, because it covers the tab bar.
- Menu items by `chooseMenuItem(menu, item, until:)`. It opens the menu again when the item never comes to rest on screen, because a tap that opens a menu
  can be lost. It taps where the item was seen to rest twice in a row (`tapWhenResting`), because XCTest's own hit point is "invalid" while a menu slides in.
  It also finds a menu item by its identifier, since an open submenu's header shares its label.
- What a tap changes (a switch's value, a button's label or whether it is enabled, a box that goes away) is waited for with `becomes(predicate)` or
  `waitForNonExistence`, never read at once. Where a lost tap must be retried, the test taps again only while the change has not shown, so nothing is tapped
  twice (`BrokerFlowUITests`, the auto-send switch).
- A queried element gets its type (`staticTexts[...]`), not `descendants(matching: .any)`, where the type is known: a query over every element timed out.
- The fixture server keeps a backlog of 128 connections.
- A scroll test's failure lists the app's moves on its first line, which is the only line an annotation keeps (`ci_shards.py` keeps 800 characters of it).

**UI tests are quick on purpose.** The app turns animations off when launched with a `-uitest` flag (debug builds only). The weekly job's test of a whole automatic
run over the real catalog (sending faked: `-uitest-fake-submit`, the only fake left) uses `-uitest-sites 40` (`XCUIApplication.fewSites`) outside that job: a representative sample of 40 sites (`SiteSample`: some of every kind of site, the same every time; `SiteSampleTests`) with a known form, so the run finishes in seconds and the test checks the
finished run and its report. Every other UI test runs against the fixture brokers (below). Long lists build their rows only as they scroll into view, so a test scrolls to what it needs (`scrollUntilExists`); the
profile editor's own Done is `editor-done` (the keyboard has its own keyboard-down button, `keyboard-hide`, never a Done); the profile gate after the walkthrough is `completeProfileGate`; a toggle is set with `setSwitch` (where its switch sits depends on the phone). Under a
`-uitest` flag a run never asks iOS for the advertising ID: on a fresh simulator (as in CI) the tracking prompt came up at an unpredictable moment and the
run waited for it for ever. The walkthrough's advertising-ID page has its own test (`testWalkthroughOffersTheAdvertisingIDAndLetsYouPassIt`). `-uitest-reset` also marks the first-visit guide cards and the once-only explainers (email links, follow-ups) as seen unless a test asks for them
(`-uitest-coach`, `-uitest-explainers`), so a fresh simulator, as in CI, behaves like a used one: on CI the email-links explainer covered the run report.
A UI test that only needs a complete profile starts with `-uitest-seed-profile` instead of typing one (typing is tested in `ProfileEditorUITests`).
A test that relaunches the app to check what was kept opens it again with `-uitest-relaunch` (it keeps the data): a launch with no `-uitest` flag behaves like
a real one, so it resumed the first-run setup over the half-typed profile and started the automatic run, and on CI the profile editor never showed.

**The run over every site** (`integration.yml`, job `all-sites`: on a release, Mondays and by hand): the same automatic-run UI tests over every site
(`TEST_RUNNER_OPTOUT_ALL_SITES=1` lifts the 40-site sample), waiting for the whole run to finish. Sending is faked; no broker site is contacted.

Family profiles are switched off (`Features.otherProfiles`), so they have no UI test (the tests that added relatives were removed on 2026-11-18); their
rules (relationships, minors and public figures are never searched) are Mac tests in `CoreTests`. No test is left out of CI (`KNOWN_FAILING` is empty).

The broker pipeline (`pipeline.yml`) and the directory refresh (`profile.yml`) visit real sites, so they stay manual (Actions tab).

## User flows and where each is tested

Notes about how a test works live in the test file itself. This is the list of what a person can do and which test pins it.
"Mac" means it runs with `swift test` and no simulator. "Sim" needs the iOS simulator.

### Assisted run ("Solve and send")

| Flow | Expected | Test | Runs |
|---|---|---|---|
| Site with no human check | Form is filled and sent with no help; the site ends Sent | `AssistedRunnerTests.testASiteWithNoBlockerIsFilledAndSentWithoutAnyHelp` | Mac |
| Human check, terms, certification box | The person clears them; the app sends only after, and never ticks or accepts for them | `AssistedRunnerTests` (check, terms, certification, timeout, check after send) | Mac |
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
| Other mail app (Gmail, Outlook, ...) | "Did you send it?" appears as soon as the app opens and nothing covers it; Yes saves, No saves nothing and never moves the run on (on a failed site the offer comes back, asked as often as needed, until the person taps Mark as done, Not now or Skip) | `EmailHandoffTests.testNoAfterAFailedSiteStaysUntilThePersonMarksItDone`, `EmailAndSkipFlowTests` | Mac |
| In-app Mail composer | Send saves and finishes the site; Cancel saves nothing | `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| Site failed or "Not working" | A site with an address offers email; Mark as done saves it as emailed; Skip moves on; no address means no offer | `EmailInsteadTests`, `EmailAndSkipFlowTests` | Mac |
| Stray or double email answers | Ignored; saved once | `EmailAndSkipFlowTests.testAnswersWithNothingOpen...` | Mac |
| Choices the person makes on the page (request-type tiles, boxes, radios, menus) | The app chooses once, before the person acts, and never again on a refill. A tile, box or menu the person tapped is theirs: adding a second tile, unselecting ours or picking another is never undone, and a toggling tile is never tapped twice | page scripts `choose-tile-buttons` ("tiles the person tapped... are not tapped again"), end to end `tiles`, `testAPersonAddingAnotherTile...`, `testAPersonUnselecting...`, `testATileTheAppHasNotYetChosen...`, `testBoxesAndMenusTheAppSet...`, `testABoxTheAppTicked...` | Sim |
| Only one request can be chosen (tiles, radios, a request-type menu) | Deletion is picked over opt-out, whichever comes first; a page that starts on opt-out is moved to deletion unless the person chose it. Where several can be ticked (checkboxes) both are ticked | page scripts `choose-request-options`, end to end `choose` / `chooseselect`, `testAPageThatStartsOnOptOut...` | Sim |
| Filling a form whose code names mislead (usmarketinggrp.com: the box labelled Phone is named `email`; a "Full Address" box) | The visible label wins over the code name: Phone gets the phone, Full Address gets the whole address, never the name | `CoreTests.testTheVisibleLabelBeatsTheCodeName...`, `testAnEmailBoxNamedPhone...` | Mac |
| Accepting site terms for you | Off until the person taps Allow. When on, a prompt whose every paragraph is on the reviewed list is accepted once per page and logged; anything else, a risk-flagged paragraph, or the setting off leaves it to the person. The shipped list reviews nothing risk-flagged | `CoreTests.testTheGeneratedLibrary...`, `TermsGate` tests (core), page scripts `click-agree`, end to end `terms` / `termsok` (render, Solve-and-send page), `TermsSettingsTests` | Mac / Sim |
| Settings: California DROP link | Shown only when California is the chosen state | none yet (view only) | n/a |
| Opening the right form is not "done" | Instructions on a form page ("your request is submitted only after you enter the code") are never a confirmation; real confirmations ("Thank you. Your request has been received.") still count, even below the instructions | `AssistedRunnerTests.PrematureDoneTests` (Melissa's consumer privacy page) | Mac |
| Never the deceased-person form | No directory opt-out page is a deceased list; Melissa uses its consumer privacy form; the live form picker scores a deceased form down | `CoreTests.testNoOptOutPageIsAListForDeceased...`, `LiveFormPickerTests.testAFormForADeceasedPersonIsScoredBelow...` | Mac |
| Send it for me (guides) | On by default; the box in a guide changes it for the session; Settings changes the default. Off: the form is filled, nothing is pressed, the person presses the page's button, and a confirmation is noticed or they tap Mark as done or Next (not recorded as sent or failed) | `EmailAndSkipFlowTests` (three tests), `WorkflowGapTests`, `SolveAndSendUITests` | Mac / Sim |
| A form whose email box is switched off (peoplefinders.com's record form) | Never filled; the intro's Next button is pressed and the form that asks for the email is filled instead | `LiveFormPickerTests.testAFormWhoseEmailBoxIsSwitchedOffIsNotFilled` (the Next press is page script: checked by hand in Chrome on the live page) | Mac |
| Contact, report, quote, consultation, newsletter, sign-in, navigation and jump-to-menu forms on a privacy page | Never picked; a masked social-security box and a request-type menu under a privacy heading still are | `LiveFormPickerTests.testContactQuoteNewsletterLoginAndNavigationFormsAreNotOptOutForms` | Mac |
| A business footer form (business email, industry) on a do-not-sell page | Never filled; the page's real request form is picked instead | `LiveFormPickerTests.testABusinessFooterFormIsNotFilledOnADoNotSellPage` | Mac |
| A page with several opt-out forms (nordicdataresources.com: email, cookie button, device ID) | The person is told "This page has 3 opt-out forms… form 2 of 3". Every form whose own words say opt-out or delete is filled and sent in turn, a sign-up, newsletter or contact form never is, the device-ID form gets this phone's IDFA (not the Android GAID), a later form that fails does not undo the earlier ones, the site is recorded once | `EmailAndSkipFlowTests` (three multi-form tests), `LiveFormPickerTests.testOnlyFormsThatAreSpecificallyOptOutsAreSentAfterTheFirst`, end to end `twoforms`, `AssistedAppTests.testEveryOptOutFormOnAPageIsFilledAndSentIncludingTheDeviceIDOne` | Mac / Sim |
| A check already passed | The page's own "please wait for the anti-spam check" line, left on screen from an early press, no longer keeps a solved check alive | sim only; covered by the multi-form page test | Sim |
| Auto-send ON: a confirmation is noticed (the app sent the form, or the person pressed the page's button) | Auto-send on moves on by itself only when the page says with confidence that everything is finished and no email follows (`finishIsCertain`); otherwise "Is it completely done?" is asked first (see the next rows) | `EmailAndSkipFlowTests.testAConfirmationOnAFormTheAppSentItselfStillMovesOn...`, `testAutoSendOnMovesOnByItself...` | Mac |
| Auto-send OFF: a confirmation is noticed | The site is saved and the green check shows, but the screen stays until the person taps Next site or Mark as done; the app never moves on by itself | `EmailAndSkipFlowTests` (two tests) | Mac |
| "Is it completely done?" (every flow with a person on screen) | Asked after a send is confirmed, or after Mark as done / Mark completed, unless the page says with confidence it is finished and mentions no email. Answers: completely done; an email is still to come; I am not sure (both of these keep the site on the waiting list); Not yet (always offered: after a send it keeps the person on the site and asks again on Next site; after Mark as done it changes nothing). Skipping or stopping while asked counts as not sure. The background run never asks | `SemiAutomatedFlowTests` (`testMarkAsDoneOnAPageThatMentionsAnEmailAsksWhetherAnEmailFollows`, `testMarkAsDoneThenNotYetKeepsTheSiteOpen`, `testNotYetAfterASendKeepsThePersonOnTheSiteAndAsksAgainOnNext`, `testAPageThatSaysItIsEntirelyDoneIsNotAskedAbout`, `testASendWithNoWordOnWhatFollowsIsAskedAboutWhereAPersonIsOnScreen`, `testSkippingWhileAskedCountsAsNotSure`, `testTheBackgroundRunNeverAsksAnything`) | Mac |
| A site with a page and an email; one with only an email | Page first (semi-automatic) with the email as fallback in the reason and the … menu; only a site with no page is email-only | `EmailOnlyAndAddressTests.testASiteWithAPageAndAnEmail…` (Core) | Mac |
| A link that is only a front page | Email-only with an address, manual without; a deeper path stays semi-automatic | `CoreTests.testALinkThatIsOnlyTheFrontPage…` | Mac |
| A page that loads but whose form cannot be read, with no email | Opened and held for the person instead of skipped with "no online form"; nothing is sent on it | `SemiAutomatedFlowTests.testAPageWhoseFormCannotBeRead…` | Mac |
| A page with no readable form, or a held page | Held for the person, never sent; show-only pages fill nothing | `NeedsPersonTests.testAPageWithNoReadableForm…` (AssistedRunLogic), `FormsNeedingThePersonTests` | Mac |
| A form that needs the person (agent, unreadable questions, file) | Semi-automated: filled in, never sent for the person, who finishes and presses the page's button. Business forms and caution sites (Clearview) show the page and fill nothing (`pageMode == .showsOnly`); pages with no readable form are opened, clicked through and held (`.fillsAndHolds`); none is ever sent for the person | `FormsNeedingThePersonTests` (Core), `NeedsPersonTests` | Mac |
| LinkedIn box on a recruiting form | The optional LinkedIn address on the profile fills only a LinkedIn box; none entered leaves a required one to the person | `CoreTests.testALinkedInBoxTakesTheProfilesLinkedInAddressOnlyWhenOneWasEntered` | Mac |
| Profile editor rows (other names, previous addresses, phones, other emails) deleted while on screen | A row removed under its own binding gives the default and ignores a late store instead of trapping with "Index out of range" | `ScreenHelperTests` (Mac) | Simulator unit test (SwiftUI bindings) |
| Closing the app while editing a profile | What is typed is saved when the app goes to the background (home), and is there after the app is killed and reopened | `ProfileEditorUITests.testProfileSurvivesRelaunch` | Simulator UI test |
| Applicable law on a page that hides it (forewarn.com) | The basis checkbox is never ticked by the app; once the person ticks it the law box is filled with the plain applicable-law sentence; the threat-of-harm box stays empty; "My data" offers the same sentence | `CoreTests.testTheLawBoxGetsTheApplicableLawAndTheBasisAndThreatBoxesAreNeverFilled`, `DetailChoicesTests` | Simulator unit test, Mac |
| ZIP code fills city and state | A five-digit (or ZIP+4) US ZIP gives its city and state; anything else gives nothing; every state code is one the state menu knows | `ZipLookupTests` (Core) | Mac |
| Email sent instead while the site's form had not gone through (send failed, waiting on the person): "Yes, I sent it" | The site is recorded as emailed, not failed, and no second "This site did not go through" offer | `SemiAutomatedFlowTests.testEmailingASiteWhoseFormDidNotGoThroughRecordsItAsEmailedAndOffersNothing` | Mac |
| Fields in an off-screen, zero-height bot-trap block (ididata.com) are left empty | A field off-screen or inside a clipped zero-height parent is not visible, so never filled | page scripts `discover-forms` ("off screen (a bot trap)"), end to end `bottrap` | Simulator |
| A fill (Fill again, first fill, before a send) finds boxes that appeared after the first look and fills them, even with the person's cursor in a box; what they typed stays | `refill()` rescans with `adoptNewForm(force: true)`; the typing pause still holds for the page watcher's own rescans | `SemiAutomatedFlowTests` (the refill), page scripts `fill-live` | Simulator |
| A people-search removal page that opens on a "Search Now" form (peoplewhiz.com) is filled; the same search box on a policy page is not | A search button is not marketing when the heading or page says remove my information / opt out | `LiveFormPickerTests.testASearchStepUnderARemoveYourInformationHeadingIsFilledButAPlainSearchBoxIsNot` | Mac |
| No-form screen for a site whose address came from its own page (socialcatfish.com): Write the email works | The screen uses the offer's entry (with the found address), not the directory entry with none | `EmailAndSkipFlowTests.testASiteWithNoFormAndNoAddressOnFileIsOfferedTheAddressItsPageGives` (`noFormEntry`) | Mac |
| Guide for a site with no recorded form opens the live-check page, not the home page | `live_form.page` wins over `opt_out_url` when `found` | `CoreTests.testAGuideWithNoKnownFormOpensThePageTheLiveCheckFoundTheFormOn` | Mac |
| After a guide is finished, the next Up next site is offered (skipping the one just done and rows with no page) | The first todo site with a page that was not walked through; none left means no question | `NextSiteOfferTests` | Simulator (the dialog itself is not driven) |
| Guided flow ends (Next tapped) while its first page is still loading: no crash (builds 37 and 40) | The runner finishes cleanly instead of unwrapping a step that is gone | `GuidedRunnerTests.testTheFlowEndingWhileTheFirstPageLoadsDoesNotCrash` | Simulator |
| Profile draft kept for a crash | A draft is sealed, comes back after the app closes, is cleared once saved, and an unreadable one is ignored | `ProfileDraftTests` (Core) | Mac |
| First-run setup resumes | An incomplete profile after the walkthrough reopens the profile screen at every launch until it is completed; not over the walkthrough; "Not now" is for the session only | `FirstRunResumeTests` | Simulator unit test |
| Empty rows dropped on save | A name, phone, email or earlier address added and left empty is removed when the profile is saved | `FirstRunResumeTests.testEmptyRowsAreDroppedWhenAProfileIsSaved` | Simulator unit test |
| Detecting an email follow-up | A real confirmation that promises an email is detected; boilerplate ("we may send you emails", "confirm your identity") and plain thanks are not; only a page that says it is finished and mentions no email is certain | `FollowUpDetectionTests` | Mac |
| Several email steps for one site | "There is another email step" (the … menu of Solve and send, the guided steps and Email links) and the Email links list's "Done, and another email step is coming" put the site back on the waiting list; finished steps are counted and kept; a new plain send starts the count again; two notes written together are never a tie | `FollowUpStepsTests` (Core), `SemiAutomatedFlowTests` | Mac |
| Several boxes of one kind (emails, phones, previous addresses, other names) and an opt-out email with the full history | Boxes are filled in profile order; leftovers go in the message; the email lists other names, emails, phones and past addresses | `CoreTests` (`testSeveralBoxes...`, `testPreviousAddresses...`, `testWhatTheFormHasNoBoxFor...`, `testAnEmailCarries...`) | Mac |
| Every kind of form box (text, email, tel, number, date, month, date-time, select, age brackets, textarea, contenteditable) | Each is filled in its own shape and limit; identifiers (SSN), someone else's names and other dates stay empty; a before/after comparison over every recorded directory form guards the rules | `CoreTests` (the "field-by-field robustness" group), page scripts `fill-live`, the `FormFiller` tests | Mac / Sim |
| A page that ships a State/Country default ("CA"); "Is this for yourself?"; a phone list | The page default gives way to the profile's state, a matching country and a pre-filled name stay, a State the person typed survives; the self question is answered Yes; the phone list keeps both numbers | page scripts `fill-live` ("a State or Country the page ships with gives way"), `testForYourselfIsAnsweredYes...` | Sim |
| Forms with an "Add another email" / "+ Add phone" button | The buttons are pressed until each email and phone has a box, the new boxes get the next values, nothing is sent, a Remove button is never pressed, a type-less button that would submit the form is left alone | page scripts `add-another-boxes`, end to end `multiadd`, `testAnAddButtonThatWouldSubmitTheFormIsNotPressed`, `testAPageThatCapsItsExtraBoxes...` (a capped page, a wrapper around the button, boxes named `emails`), `CoreTests.testABoxClonedByAddAnotherTakesTheNextValue` | Sim / Mac |
| Forms built with Tally and similar (realsourcedata.com): the question is a heading and each box points at it with aria-labelledby | Every such box is filled: first and last name, street, city, state, zip, phone, email | page scripts `discover-forms` (labels), end to end `arialabel` | Sim |
| Menus stay steady while the run waits | The run no longer tells the screen "changed" every second with the same status, which made an open … menu blink | none yet (visual); the screens use the same values as before | n/a |
| A page with no form and no address on file (redidata.com) | The page's own privacy address (same domain, privacy@ before info@, never noreply or another company) is offered for the email, with "We found this address on the site's own page. Check it before you send."; with none, the skip says there is no address | `EmailAndSkipFlowTests` (two tests), `ContactEmailPickerTests`, end to end `noformemail` | Mac / Sim |
| A multi-step form (statara.com: Next, then choices, then Submit) | Next is a step, not a result; the choices are picked on the new step (opt-out, not limit-use or opt-in); only the last Submit counts. Consent wording ("you state that this request has been submitted…", "will be processed within 15 days") is never a confirmation | end to end `steps`, `AssistedRunnerTests.testConsentAndChoicesWording...`, `EmailAndSkipFlowTests.testMultiStepForms...` | Mac / Sim |
| A reCAPTCHA that rejects the app's press ("response was missing or invalid") | The app does not keep pressing; it tells the person to press the page's Submit themselves and notices the result (moves on if Auto-send is on) | `EmailAndSkipFlowTests.testAReCAPTCHAThatRejects...` | Mac |
| Email links: Fill in my details on a privacy portal that grows as it is answered (OneTrust: pick the state from a type-ahead, then the rest appears) | The state is picked from the list (not just typed), the questions it reveals are filled in rounds, a typed captcha is left for the person; the same type-ahead is answered in Solve and send; a portal whose only form asks State and Captcha is recognised from the page's intro | page scripts `type-ahead-open` / `type-ahead-choose`, `LiveFormPickerTests.testAPortalFormThatOnlyAsksForTheState...` | Sim / Mac |
| Email links uses the same page code as Solve and send | Finding forms (frames, folded sections), choices, tiles, device ID, terms, several forms on a page, Next then Submit, the reCAPTCHA handoff and the Auto-send box all work the same in both. Sending from a pasted link waits for checks, sends each opt-out form, notices a confirmation when Auto-send is off | `EmailAndSkipFlowTests` (six "Email links" tests, through `PageSender`), page scripts `type-ahead-*` | Mac / Sim |
| Sending a form from a pasted link marks the site done | A site waiting on its email just finishes that step; a site that was not waiting on anything is recorded as sent now and counts as done | `OverdueFollowUpAppTests.testSendingAFormFromAPastedLink...` | Sim |
| Reading a confirmation page | Real thanks and receipts count; plain "thanks" and hidden templates do not | `LooksFinishedTests`, `EmailFollowUpWordingTests`, the `errorpage` and `slow` journeys | Mac / Sim |
| Real web view against a local page | Fills, waits for the person, sends, reads the result | `FixtureJourneyUITests.testSolveAndSendFillsTheFormWaitsForMyCheckThenSendsAndMovesOn` (fixture broker) | Sim |
| Today's queue | Only sites the app can fill and has not sent to recently | `ScreenHelperTests.testTheAppModelQueuesOnlySitesItCanFillAndHasNotSentRecently` | Mac |

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
| Walkthrough on first install; finish it; does not return; replay from Settings | `OnboardingAndSitesUITests` | Sim |
| Walkthrough of the guided flows (Solve and send, manual): opens before the first site, nothing runs behind it, skip, replay from Settings; the walkthrough's last pages are the advertising ID and the pointer to About | `SolveAndSendUITests`, `OnboardingAndSitesUITests` | Sim |
| Law pages for California, other states and countries; language switch | `OnboardingAndSitesUITests` | Sim |
| Both switches on by default; declining turns both off; skipping leaves a banner | `AutoProtectionUITests` | Sim |
| Birthdate required; legal name and address required to close the editor | `AutoProtectionUITests`, `ProfileEditorUITests` | Sim |
| Add a relative, switch accounts, profile survives relaunch | `ProfileEditorUITests` | Sim |
| The editor's single write saves the profile and the household email together | `ContactEmailAppTests.testTheProfileEditorsSingleWriteSavesTheProfileAndTheEmailTogether` | Sim |
| A phone is shown as (773) 633-1564 while typed; the state menu lists 51 states | `PhoneFormatTests` | Mac |
| Minor or public figure is never searched | `SafetyFlagsUITests` | Sim |
| Sites tab: search, grouping, status page, scan | `OnboardingAndSitesUITests`, `BrokerListUITests` | Sim |
| Sites tab shows ten per group (Done, Skipped, Up next); See all opens the search screen with that status chosen; the chips narrow the list; the tab's search field opens it focused | `SiteFilterTests` (status rules, every filter, clearing keeps the text); `OnboardingAndSitesUITests.testTheSitesTabShowsTenPerGroupAndSeeAllOpensTheSearchWithThatStatus`, `testEveryKeyboardHasOnlyTheKeyboardDownButtonThatPutsItAway` | Mac + Sim |
| Hand-written walkthrough flow (semi-automatic since the guided method was removed): steps advance, Cancel, Not working, site view links | `GuidedFlowUITests`, `GuidedRunnerTests` | Sim |
| Run now shows what was sent and what needs you, with no network | `AutoProtectionUITests`, `DryRunUITests` | Sim |
| A site the run's rules leave alone (DROP hold) is not counted as tried, never sent, kept on the page with its reason, and counted in the report; Re-test all really re-sends to sites sent this period | `AutomaticRunAppTests.testSitesTheRunLeavesAloneAreNotCountedAsTriedAndKeepTheirReason`, `BackgroundPassesAppTests` (re-test checks the pages sent) | Sim |
| A page with no sign of life for 15 s is moved to semi-automatic; a busy one is waited for | `CoreTests.testASiteWhosePageGoesQuietIsMovedToSemiAutomaticAndABusyOneIsWaitedFor` | Mac |
| A run cut off and brought back to the front stays pending; a site never tried is in every run, even a repeat | `AutomaticRunAppTests.testARunCutOffAndThenBroughtBackToTheFrontIsNotTakenAsFinished`, `testEverySiteNeverTriedIsInEveryRunEvenARepeat` | Sim |
| In California DROP is step 1 and the first pass waits for it; elsewhere DROP is not in the plan and holds nothing | `AutomaticRunAppTests.testDROPComesFirstInCaliforniaAndIsLeftOutEverywhereElse` | Sim |
| The engine can work on several sites at once (the app uses one): never more than asked, results in the order given, a shared page sent once, Stop starts no more sites | `CoreTests.testTheRunWorksOnThreeSitesAtOnceInOrderAndSendsASharedPageOnce`, `InterruptedRunTests` (one at a time) | Mac |
| A site the run gives up on has its work cancelled and its hidden pages ended; pages outside a background run are never touched | `CoreTests.testASiteTheRunGivesUpOnHasItsWorkCancelled`; end to end the `slow` journey (its page stops pinging once given up) | Mac, Sim |
| A locked phone: a save waits for the unlock instead of stopping all saves; profiles opened while locked open at the unlock, and erasing is offered only for data that really cannot be opened | `CoreTests.testAFailureFromALockedPhoneIsToldApartFromDamagedData`, `PeopleTests.testASaveWhileThePhoneIsLockedIsWrittenAtTheUnlock`, `testProfilesThatCouldNotBeOpenedWhileLockedOpenAtTheUnlockAndAreNeverOfferedForErasing`, `testUnreadableDataIsNeverOverwritten` | Mac, Sim |
| A run rebuilds the plan once when it ends, not after every site; rebuilding it takes under 0.2 s | `ResumeAppTests.testARunRebuildsThePlanOnceWhenItEndsNotAfterEverySite`, `ActivityPageSpeedTests` | Sim |
| A stopped run carries on with only the sites left, never sending one twice; a stopped Re-test all carries on as a re-test | `ResumeAppTests` | Sim |
| Stop means stop: a stopped run is not carried on or started on schedule until the person starts one; Run now then carries on with only the sites left, counting on from the ones already done out of the whole run (`testARunCarriedOnCountsFromTheSitesItAlreadyDid`) | `CoreTests.testARunThatStoppedIsNeverCarriedOnByItself`, `AutomaticRunAppTests.testStopEndsTheRunPartWayAndLeavesTheRestForLater` | Mac, Sim |
| A run that stopped before finishing (iOS took back its time, the app left the screen, the app was closed) never carries on by itself, not even when the due-check comes; back on screen the person is asked "Carry on with the opt-out run?" with why it stopped; Not now leaves it waiting and asks again next time; Carry on runs it; a run the person stopped is not asked about | `CoreTests.testARunThatStoppedIsNeverCarriedOnByItself`, `RunPauseTests.testAPausedRunAsksBeforeCarryingOnAndTheLogSaysWhy`, `…testARunCutOffByAClosedAppAsksWhenTheAppOpensAgain`, `…testEveryStopThePersonDidNotAskForEndsInTheQuestion` (a scheduled task ended mid-run: asked at once on screen, memory warning logged, Carry on starts the run); end to end `FixtureJourneyUITests.testARunThatStoppedWhileIWasAwayAsksMeBeforeCarryingOn` (leave during a run, nothing sent while away or before the answer, Carry on, the rest sent) | Mac + Sim |
| The run log: every start, end, pause and why, background time granted, refused and taken back, the app leaving and coming back, the question and its answer, a run found cut off, and each site's result with whether the app was on screen and for how long it was away; a site given up says the step it was on; kept sealed (no site name in the file), the newest 2000; the export carries it from the run's start, with each screenshot's date | `RunPauseTests.testAPausedRunAsksBeforeCarryingOnAndTheLogSaysWhy`, `CoreTests.testTheRunLogKeepsTheNewestEntriesAndGivesThoseOfARun`, `CoreTests.testTheRunLogIsSealedInTheDatabase`, `RunExportTests` | Mac |
| A site blocked by a human check says so first ("Blocked by a human check (a reCAPTCHA checkbox): only you can clear it") wherever its line shows, in the sites that need the person and in the ones the run leaves to them; a site sent twice unconfirmed and a field no profile fills say what they are, not "Waits for the next full re-test"; a page that answers a send with "Please complete the verification challenge" (and the like) is a human check, and a form held behind a visible check is not "no form found" (that last branch runs only in a real web view; its check, `visible-challenge`, has page-script tests, and the branch itself has none yet) | `RunPauseTests.testEverySiteBlockedByAHumanCheckSaysSo`, `…testAPageAskingForAHumanCheckAfterSendingIsAHumanCheck`, `CoreTests.testWhatCountsAsAHumanCheck` | Mac |
| The automatic opt-out page is worked out off the main thread, each form's fill once, with the same counts as the run's own rules | `ActivityPageSpeedTests.testTheActivityPageIsWorkedOutQuickly` (equal rows and Run now count, under 0.3 s after the first time) | Sim |
| A site that never answers is given up as too slow and the run goes on; a run settles a site at least every 62 s; Stop ends a run part-way and keeps the rest for later | `CoreTests.testASiteThatNeverAnswersIsGivenUpAndTheRunGoesOnToTheNext`, `AutomaticRunAppTests.testStopEndsTheRunPartWayAndLeavesTheRestForLater` | Mac, Sim |
| A site given up after its form was sent is recorded as sent and not confirmed and never sent again in the pass; one that ran out of time before sending is tried once more at the end, and the progress count never stands still or goes back | `CoreTests.testASiteGivenUpAfterItsFormWasSentIsRecordedAsSentUnconfirmedAndNotSentAgain`, `CoreTests.testASiteThatRanOutOfTimeBeforeSendingIsTriedOnceMoreAtTheEndAndProgressKeepsMoving`, `FixtureJourneyUITests.testRunNowShowsWhatAPageSaidAndItsScreenshotWhenTheSiteDidNotConfirmInTime` (a real page: pressing send reaches the watchdog, and the page is read in time) | Mac, Sim |
| What the person keeps is rows of one SQLite file, sealed: nothing in plaintext, replaced and deleted by kind and key, still there after a relaunch, a deleted screenshot overwritten and the file shrunk, a file the system will not open reported as locked, opening and reading leave the file byte for byte as it was | `UserDatabaseTests` (6), `HouseholdStoreTests`, `EvidenceTests`, `ProfileDraftTests`, `AppModelTests` (unreadable data never overwritten, locked phone) | Mac, Sim |
| The preferences are rows of the database and every kind of value comes back as it went in, across a relaunch; they work in memory while the database cannot be opened and are written at the unlock; the old UserDefaults values are moved in, removed from UserDefaults only once stored, never while the database cannot be written, and a value already here wins | `PreferencesTests` (6), `PreferencesAppTests` | Mac, Sim |
| The database does not say which people or sites have a screenshot (opaque keys: no person id or site name anywhere in the file; other key, other row keys); a file of a newer layout is refused and left unchanged | `UserDatabaseTests.testTheRowKeysDoNotNameThePersonOrTheSite`, `testAFileOfANewerLayoutIsRefused` | Mac |
| The move from the old files (build 51 and earlier): the sealed bytes copied exactly and read back before a file is deleted; an old household that cannot be read is never saved over; the newer of a file and a row wins; nothing to move is just an empty database | `UserDatabaseTests` (the move tests) | Mac |
| The app does no file-system work while it runs: no file API outside a short allow-list, a non-persistent web view, the YAML reader not linked into the app | `tools/tests/test_runtime_file_io.py` | CI `checks` |
| The page scripts and the ZIP table are read from the catalog as the source files hold them; a catalog missing one fails the build's own check | `CatalogTests.testThePageScriptsAndTheZIPTableAreReadFromTheCatalogAsTheSourceFilesHoldThem`, `CatalogAppTests` | Mac, Sim |
| The app ships its data compiled into Catalog.sqlite and no YAML, script or table file; what it reads equals what the YAML loaders return for every real file; the file is one read-only file opened without writing beside it; another layout version is refused; reading it all takes about 0.02 s | `CatalogTests` (5), `CatalogAppTests.testTheAppShipsTheCompiledCatalogAndNoDataYAML`, `testTheModelLoadsFromTheCatalogWhatTheRepositorysYAMLHolds` | Mac, Sim |
| The Sites search finds sites by the start of a name, by what they hold in any of the app's languages (accents ignored), every word must match, best first, never an excluded site; a name match is listed first and the other filters still apply | `CatalogTests.testTheSearchFindsSitesByNameStartWhatTheyHoldInAnyLanguageBestFirst`, `SiteFilterTests.testEachFilterNarrowsAndTextMatchesAddressOrName`, `CatalogAppTests.testTheSitesSearchFindsSitesInTheBundledCatalog`, `DirectoryUITests` | Mac, Sim |
| One site is found by id, domain or family without scanning the list, with the same answer scanning gave, on every real site | `SiteIndexTests` (2) | Mac |
| After send is pressed, the page is not read until its answer has started, and a page still loading is never settled (a sent form was once read on its old page and counted as not sent) | `CoreTests.testAPageIsNotSettledWhileANavigationIsUnderWay`; end to end `FixtureJourneyUITests` and `AutoProtectionUITests.testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere` (the sent fixture site is counted as sent) | Mac, Sim |
| A portal whose form appears after its country and state menus is answered (United States, the person's state, "delete and opt out") and sent; a state menu without the person's state gets nothing and the site says its form is not for them | page scripts `menus-and-sending.test.js` ("a country menu takes the United States ..."), `navigation.test.js` ("choreograph.com's request links"); end to end `FixtureJourneyUITests.testAPortalWhoseFormAppearsAfterCountryAndStateMenusIsAnsweredAndSent` (fixtures `gatemenus`, `gatelaw`) | Mac + Sim |
| The background run waits for a Cloudflare check that passes by itself and sends; one that needs a person is never solved; a passed check (its token set) is not a check | page scripts `checks-and-prompts.test.js` ("a solved check ..."); end to end `FixtureJourneyUITests.testARunWaitsForACloudflareCheckThatPassesByItselfAndLeavesOneThatNeedsMe` (fixtures `turnstilepass`, `turnstile`) | Mac + Sim |
| The screen keeps answering while a run works (no main-thread stall of a second or more while the person scrolls) | `FixtureJourneyUITests.testTheScreenKeepsAnsweringWhileARunWorks` (the debug watchdog `MainThreadWatch`, `-uitest-watch-main`); a simulator is faster than a phone, so it catches only large regressions; a main-thread watchdog is UIKit's run loop, with no Mac test | Sim |
| A certification about the person themselves ("I certify that I am the person ... and that the information is true") is ticked on the account owner's own profile and sent; one sworn as an oath ("under penalty of perjury", "under oath", "sworn") never is, even on the owner's profile, and Solve and send says in plain words what it means; on a family member's profile any certification waits for that person; an agent-only box, terms and bot traps never are | `CoreTests.testTheOwnersProfileTicksACertificationAboutThemselvesButNotAnAgentsBox`, `OnlyForTests.testAConfirmationUnderPenaltyOfPerjuryGetsPlainWords`, page scripts `checks-and-prompts.test.js` (tick-identity-boxes); end to end `FixturePageTypeUITests.testACertificationUnderPenaltyOfPerjuryIsLeftForMeEvenOnMyOwnProfile`, `testACertificationBoxIsLeftForMeToTickAndTheFormIsSentWhenIHaveTickedIt` (family profile) | Mac + Sim |
| The fill gaps of the 2026-11-24 run: saymine's closed lists (hidden by visibility and opacity, keeping their size) are not taken for open, so State is pressed and the person's state chosen, never the closed Country list's option; a type-ahead's match is taken as soon as it shows and a list that closed is opened again; a type-ahead with a choice is not "a required choice"; "I am a" takes "Data subject making a request"; a website option is not a certification; a form with a visible check is the check | page scripts `menus-and-sending.test.js` (saymine as it really is, with `page(html, { webkitBoxes: true })`; type-ahead reopened; data subject), `fill-helpers.test.js` (chosen type-ahead), `checks-and-prompts.test.js` (website option); checked by hand on the simulator with `-semi-domains … -assisted-no-send` (azira.com, dnb.com, astoriacompany.com: "Ready, nothing sent"); the Swift steps (polling the type-ahead, the visible check first) run only in a real web view and have no test of their own | page scripts, Sim by hand |
| A site that holds data only on some people (`only_for`: agile-ed.com, people who work in US schools) counts as done, is never in the queue or the automatic run, and its line and page say who it is for; its page can still open it | `OnlyForTests.testASiteOnlyForSomePeopleIsDoneLeftOutOfTheRunAndSaysWhoItIsFor` | Mac |
| The pages reported on 2026-11-23, in the real web view: comscore's rebuilt State menu filled again and its labels floated; datatowin's "Myself", flag-only US phone entry and number after the dial code (kept on a later pass); klear's title-named boxes and its banner denied; the bot trap and cookie toggles never ticked; dnb's "Resident of" Illinois and the company's country left alone | page scripts in `fill-live.test.js`, `choose-request-options.test.js`, `discover-forms.test.js`, `checks-and-prompts.test.js`, `menus-and-sending.test.js`, `navigation.test.js`; `CoreTests` (phone country by flag, device ID, labels); end to end `FixtureJourneyUITests.testTheFormsReportedOnTheNovember23rdRunAreFilledAndSentCorrectly` | Mac + Sim |
| Run now tries again every site that did not go through this period that a fix could reach (no form found, no confirmation, sent once unconfirmed, a certification box ...), never a site sent this period, and leaves to the person only a human check, a code or a field no profile can fill (the north star in docs/PRINCIPLES.md) | `CoreTests.testARepeatPassTakesBackTheSitesGivenUpBeforeAnythingWasSent` (each reason, skipped or retried), `L10nTests.testAReasonStoredInAnotherLanguageIsStillSeenAsNeedingThePerson`; the whole cycle `ResumeAppTests.testRunNowRetriesWhatAFixCouldReachAndLeavesOnlyHumanChecksAndUnknownFieldsToThePerson` (a full pass with seven kinds of outcome, then Run now with a fixed build, then nothing left) | Mac |
| A request wizard: a step of only choices is answered and its Next pressed; a Next only moves on, never counts as sent; the details step is filled and Submit sends once | `LiveFormPickerTests.testAWizardStepOfOnlyChoicesIsAnsweredAndItsNextOnlyMovesOn`; end to end `FixtureJourneyUITests.testARequestWizardIsAnsweredStepByStepAndSent` (fixture `wizard`: deletion, myself, the details, one POST) | Mac + Sim |
| A form whose search finds no record ("No data was found") ends the site as not listed: pressed once, never counted as sent, done and out of the semi-automated queue for 30 days, then searched again; lines that only explain do not count; Solve and send records it too, also when the person ticked a human check and pressed the page's Submit themselves (the courtrecords.us sites) | `AssistedRunnerTests.testASearchThatFindsNoRecordIsReadAsNotListed`, `SemiAutomatedFlowTests.testASiteWhoseSearchFindsNoRecordIsRecordedAsNotListed`, `…testNoRecordFoundAfterThePersonTicksTheCheckAndPressesSubmitIsRecordedAsNotListed`, `…testNoRecordFoundAfterAFailedSendIsNoticedAndRecordedAsNotListed`, `SiteFilterTests.testASiteWhoseSearchFoundNoRecordIsDoneUntilItIsSearchedAgain`; end to end `FixtureJourneyUITests.testASiteWhoseSearchFindsNoRecordOfMeIsMarkedNotListedAndDone` (fixture `nodata`: one POST, the Not listed count, the site's page) and `…testASearchIRunMyselfBehindACheckThatFindsNoRecordOfMeIsMarkedNotListed` (fixture `nodatacheck`: Submit off until the check is ticked, my own press, the app's message, the site's page) | Mac + Sim |
| A run's hidden pages never bring up the keyboard, even when a page or a page script focuses a box; the page is still filled and sent | `FixtureJourneyUITests.testARunNeverBringsUpTheKeyboardWhenItsPagesFocusABox` (fixture `autofocus`, and `requestmenu`, whose menus the app opens by focusing them); first responder is UIKit's, with no Mac equivalent, so no unit test | Sim |
| A run's hidden pages are hidden from VoiceOver and accessibility queries | `AutoProtectionUITests.testANewPersonGetsTheAutomaticPassFirstAndTheSemiAutomatedQueueAfterIt` (no web view in the accessibility tree during the run); a UIKit property with no Mac equivalent, so no unit test | Sim |
| A page counts as still loading only when it says so in whole words ("downloading your data" is not "loading"); settled is unchanged for 1.5 s | `CoreTests.testAPageIsLoadingOnlyWhenItSaysSoInWholeWords` | Mac |
| iOS ending a run's background time stops it only when the app is not on screen | `AutomaticRunAppTests.testIOSEndingTheBackgroundTimeStopsTheRunOnlyWhenThePersonIsAway` | Sim |
| A repeat pass (and Run now after a full pass) takes back the sites given up before anything was sent, and once those sent and not confirmed; not those stopped by a check or refused | `CoreTests.testARepeatPassTakesBackTheSitesGivenUpBeforeAnythingWasSent`, `CoreTests.testASiteSentAndNotConfirmedGetsOneMoreTryNotMore` | Mac |
| After sending, a background run waits only as long as leaves time to read the page and take its picture; what the page said after a send is kept with the attempt, trimmed, and shown on the site's page (nothing for a site stopped before sending) | `CoreTests.testAfterSendingTheRunWaitsOnlyAsLongAsLeavesTimeToReadThePage`, `CoreTests.testWhatThePageSaidIsKeptWithTheAttemptTrimmed`, `FixtureJourneyUITests.testRunNowShowsWhatAPageSaidAndItsScreenshotWhenTheSiteDidNotConfirmInTime` | Mac, Sim |
| Run now leaves out the sites already sent this period; Re-test all tries them again | `CoreTests.testRunNowLeavesOutOnlyTheSitesAlreadySentThisPeriod`, `BackgroundPassesAppTests` (second run and re-test) | Mac, Sim |
| A new person gets the automatic pass first; the semi-automated queue waits for it and opens after; the report leads to it | `CoreTests.testTheSemiAutomatedQueueWaitsOnlyForTheVeryFirstAutomaticPass`, `BackgroundPassesAppTests` (`waitingForFirstPass`), `AutoProtectionUITests.testANewPersonGetsTheAutomaticPassFirstAndTheSemiAutomatedQueueAfterIt` | Mac, Sim |
| The automatic opt-out page sorts each site into need you, sent or not tried by this period's attempts; groups fold, counts open them, a site opens its page | `CoreTests.testTheActivityPageSortsEachSite...`, `AutoProtectionUITests.testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere`, `testRunNowShows...` (the counts move during a run) | Mac, Sim |
| The automatic opt-out page shows the current run only (`AutoSettings.runStarted`: set when a new pass starts; a stopped or cut-off run carried on is the same run); "Every site, all runs" combines every run (sent at least once / never went through / never tried, with how often), and each site opens its page with its screenshot | `CoreTests.testActivityWithASinceCountsOnlyThatRunsAttemptsAndAllRunsCountsEveryOne`, `AutoProtectionTests.testTheAutomaticPageShowsOnlyTheCurrentRunAndAllRunsCombinesThem`, `testANewRunStartsThePageAfreshAndACarriedOnRunDoesNot`, `FixtureJourneyUITests.testTheAutomaticPageShowsThisRunAndEverySiteAllRunsCombinesThem` | Mac, Sim |
| "Export this run" gives one zip: run.json with every site of the page in its order (group, line, opt-out page, last ten attempts with what the page said, latest search, screenshot name and when it was taken), the run log and why the run last paused, a README, and each kept screenshot byte for byte; the zip is one `unzip` reads back exactly (stored, CRC-32), with safe names. Built in memory, no file written. The share sheet itself was checked by hand on the simulator (saved to Files and unpacked) | `RunExportTests.testTheExportListsEverySiteWithItsAttemptsAndCarriesItsScreenshot`, `StoredZipTests` (`testUnzipReadsEveryFileBackExactly`, `testTheChecksumIsTheStandardOne`, `testNamesKeepOnlySafeCharacters`), `test_runtime_file_io.py` | Mac |
| Spokeo, FastPeopleSearch, PeopleConnect flows | `BrokerFlowUITests` | Sim |

## Workflow audit (2026-11-01)

Every workflow a person can do in the app, with the tests that pin it. **Mac** = `swift test` in `Packages/OptOutKitCore` or
`Packages/AssistedRunLogic`, no simulator. **Sim** = `xcodebuild test` on the iPhone 17 Pro simulator. A workflow is only "covered
without a simulator" when its rules live in the Mac packages; the SwiftUI wiring itself (what is drawn, which alert shows) can only be
checked in the simulator.

| # | Workflow | Mac tests | Simulator tests | Status |
|---|---|---|---|---|
| 1 | First run: walkthrough once, replay from Settings, language, place, both auto switches | Core: `FreshInstallGetsWalkthrough`, `UpdateWith...Message`, translation and country tests, `OptOutIsMonthlyNothingScansAndBothStartOffUntilThePersonDecides`, `DecliningTurnsEverythingOff...` | `OnboardingAndSitesUITests`, `AutoProtectionUITests`, `AppModelTests.WalkthroughOnFirstInstall...` | Covered |
| 2 | Profile: complete before anything runs, editor, relatives and switching, minor and public-figure flags, tagged email, encryption | Core: profile completeness, flags, Gmail tag, `RoundTrip`, `TamperingIsDetected`, `RemovingPersonDeletesTheirData` | `ProfileEditorUITests`, `SafetyFlagsUITests`, `ContactEmailAppTests`, `PlatformAppTests` (gate) | Covered |
| 3 | Queue and daily batch: 15 sites, kinds, rollover, goals | Core: `Daily`, batch and kind tests, queue order and bands | `AppModelTests.AFreshPick...`, `PlatformAppTests` queue tests, `BrokerListUITests` | Covered |
| 4 | Sites tab: search screen and its filters, Done / Skipped / Up next groups, status, scan, look-yourself and points | Core: scan, points, grouping tests, `SiteFilterTests` | `OnboardingAndSitesUITests` (Sites tab, scan, points) | Covered |
| 5 | Site page (title-header status, copy-link and done-circle buttons, region row with tracking icon, lasting section; Core: `RegionSummaryTests`, `BrokerCategorySymbolTests`): guide, email, heal a moved link, report a problem, skip, skip forever, bring back | Core: skip and return after a week, forever, report, healing, closed sites carry evidence | `LinkHealingTests`, `AppModelTests.ASkippedSite...`, `GuidedFlowUITests` | Covered; the lists of closed and locked sites are view-only (not tested) |
| 6 | Automatic protection (a full pass over every site that can be tried, a repeat every 3 months of the ones that went through, a full re-test every 6; a site that is lost goes to the semi-automated queue): scheduled run, run now, activity, run report, review list (each row opens the site page with its screenshot) | Core: run period (91 days), one send a period, dry run, evidence screenshots | `AutoProtectionTests`, `AutoProtectionUITests`, `PlatformAppTests` (`BackgroundPassesAppTests`, `AutomaticRunAppTests`), `CoreTests.AutoOptOutTests` (`testABackgroundRunTriesOnlySites...`, `testAFullPassTriesEverySiteAnd...`, `testTheFirstRunAndThenEverySixMonths...`, `testReTestingEverySiteNow...`), `RunPeriodTests` | Covered |
| 7 | Solve and send: check, terms, send, no confirmation, rate-limit pacing, skip, Mark as done, Previous site | AssistedRunLogic: `AssistedRunnerTests`, `EmailAndSkipFlowTests`, `EmailHandoffTests` | `SolveAndSendUITests` (skip, Previous site, Next site on the real screen), `AssistedAppTests` | Covered |
| 8 | Email an opt-out: batches, Bcc, mail apps, in-app composer, "Did you send it?" | Core: batch and mail-link tests; AssistedRunLogic: handoff | none for the Opt-out email screen's own alert | **Gap**: that screen's alert is wired in the view (same logic as the assisted run, which is tested) |
| 9 | Verify queue (forms that need only a human check ticked) | Core: `FormsThatOnlyNeedABotCheck...`; AssistedRunLogic | `SolveAndSendUITests` shares the screen | Covered |
| 10 | Email links tab: paste a link, safety check, fill, send, follow-ups, link shared from a mail app | Core: link check and follow-up tests (`LinkCheckTests`: a link on a provider's shared domain is never guessed between sites, a tenant's own address picks that site, sites waiting on an email are suggested first, a provider's general address is not one site's even when one site is recorded there, a hand-chosen site is trusted only with an address it is known by, the search over all sites) | `AppModelTests` (link taken from the share; `SharedLinkTests.testALinkSharedUnderASheetWaitsUntilTheSheetIsGone`: a link shared while a sheet covers the app waits until it is gone; follow-ups after 45 days), `WorkflowGapTests` (pasted address rules) | **Gap**: filling and sending on the loaded page needs a live https page; the "Which site is this for?" screen and the "already marked finished" question were checked by hand in the simulator (share link, search, choose, warning), with no automated screen test |
| 11 | Guided flow for sites needing a person | Core: guided plan tests | `GuidedRunnerTests`, `GuidedFlowUITests` | Covered |
| 12 | Live forms: picking the form, choices the person made, deletion over opt-out | Core: `FormFiller` tests (labels beat code names); page scripts | `FixturePageTypeUITests`, `FixtureJourneyUITests` | Covered |
| 13 | Settings: language, place, California link, Global Privacy Control, advertising ID, terms | Core: language and place tests, terms rules | `WorkflowGapTests` (California link, Global Privacy Control), `TermsGate` tests (core), page scripts `click-agree`, end to end `terms` / `termsok`, `PlatformAppTests` | Covered; the advertising ID read needs a device |
| 14 | Accepting site terms for you | Core: `TermsGate` tests, library has no risk-flagged approvals | `TermsGate` tests (core), page scripts `click-agree`, end to end `terms` / `termsok` | Covered |
| 15 | Background runs, reminders, notifications | Core: reminder schedule tests (08:01-08:15 next calendar day, stable on replanning, a 21:00 opt-out still gets next morning's) | none | **Gap**: iOS background scheduling and notification permission need a device |
| 16 | Share extension (send a link to Exnay) | Core: none | `AppModelTests.OnlyAWebAddress...` covers the app side | **Gap**: the extension itself needs a device |

### One set of rules for every flow

Solve and send, Email links, the monthly automated run and the guide all find forms, fill them, press send and read the result with the same code
(`Shared/AssistedRun`): `WebAssistedDriver.prepareLoaded` and `WebAssistedPage` for the page, `PageFlow.sendOnce` for what a press of send meant,
`PageFlow.watch` for what the person did, `PageFlow.reloadThenRefill`, the tap check (`AssistedPage.pressesSinceFill` + `SentQuestion`: a confirmation with no button, link or Enter pressed by the person since the fill is asked about, "Was this sent?", not assumed; `testAConfirmationTheyDidNotPressAnythingForIsAskedAboutNotAssumed`), the typing guard (`AssistedPage.userIsTyping`: while the person has the cursor in a box nothing is clicked, scrolled or filled; `testNothingIsFilledClickedOrScrolledWhileThePersonTypesInABox`), a verification-code sub-form (`FormRun.asksForCode`, `AssistedPage.awaitingCode`: "Verify Email" sends a code, the site is not finished until the person types it; `testAVerifyEmailSubFormIsAStepNotTheEndInEveryFlow`) for Refresh the page, `PageMenu.items` (which also carries "My data": each of the person's details listed in a submenu, tap to copy; `DetailChoices` tested on Mac, the menu by `testMyDataIsInTheMenuAndOffersEachDetailToCopy`) for the … menu's page actions (Copy link, Open in my browser, Refresh the page, fill; `ScreenHelperTests` (Mac): the question "Did you complete it?" is raised as the page opens, Yes finishes the site, No changes nothing, only web addresses open), `LiveFormPicker` for which form is the opt-out. What differs between flows is only the surroundings: the buttons,
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
(see `.github/workflows/pipeline.yml`; started by hand from the Actions tab for now). For each broker it loads every step page and,
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
