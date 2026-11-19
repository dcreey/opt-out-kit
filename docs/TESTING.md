# Testing

Layers, cheapest first:

| Layer | Kind | Where | Runs |
|---|---|---|---|
| Broker and directory YAML vs `schema/*.schema.json`, the Python tools, translations | check | CI `checks` job | every push |
| Core logic (decode, queue, plan, rules) | **unit** | `Packages/OptOutKitCore/Tests` | `swift test` in that folder (Mac, no simulator); every push |
| Assisted run logic (runner, email handoff, page-text reading) | **unit** | `Packages/AssistedRunLogic/Tests`, on the app's own sources in `Shared/AssistedRun` | `swift test --package-path Packages/AssistedRunLogic`; every push |
| App unit tests (the app model, web views on local pages, storage) | **unit** | `AppTests` (target `OptOutKitTests`) | `xcodebuild test` on a simulator; every push |
| Page scripts (the JavaScript the app runs in web pages) | **unit** | `tools/pagescripts` (headless DOM) | `npm test` in that folder; every push |
| UI tests (the real app driven on a simulator) | **integration** | `AppUITests` (target `OptOutKitUITests`) | for a release (`.github/workflows/integration.yml`) |
| The automatic run over every site, sending faked | **integration** | `AutoProtectionUITests` with `OPTOUT_ALL_SITES=1` | for a release, and weekly |
| Live sites (read-only) | live | `AppTests/Live*` with `OPTOUT_LIVE=1`; `pipeline.yml` | by hand only |

## Page scripts

The JavaScript the app runs inside web pages (finding forms and their boxes, filling them, choosing request options, spotting checks, terms prompts and
confirmations, declining cookie prompts, telling the app what the person touched) lives in `App/PageScripts/`, one file per script, loaded by
`App/Sources/PageScript.swift`. A plain script is one expression, run as it is; a script that takes values is a function expression called with its values
as JSON (`PageScript.call`), so an apostrophe or quote in a name arrives as typed and nothing is left on the page. `//#include name` shares a fragment
(`ownership.js`). Moved there from Swift strings on 2026-11-19: the plain scripts were checked byte for byte against what Swift produced, and every
web-view test passed before and after. `PageScriptTests` checks that each one loads, is valid JavaScript and receives its values intact.

**Unit tests** (`tools/pagescripts`, `npm test`, in CI's `checks` job on every push; about 1 second): each script runs against small test pages in a
headless DOM (jsdom), loaded and called exactly as the app does it (`harness.js`). jsdom has no layout, so the harness stands in for what the scripts read
from it, from the page's own markup: an element that is hidden (or inside a hidden one, a closed `<details>`, a zero-height box) has no size, one placed
far off screen (a bot trap) is off screen, a frame is 300 x 150, anything else is 200 x 30; `innerText` is the shown text. What a real browser does with
layout, input masks and real taps stays covered by the WebKit tests (`LiveFormTests` and the others), which run in the integration workflow.
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

**Unit tests run on every push; integration tests run for a release.** Unit tests are everything in the two Swift packages and the app's
`OptOutKitTests`: they check a rule (what is sent, what is skipped, what is saved, what a screen is given to show) without driving the app's screens, and
they run in `.github/workflows/ci.yml` on every push and pull request. Integration tests are the UI tests in `OptOutKitUITests`: they drive the real app
on a simulator, tap through its screens and check what a person sees. They take far longer (a UI test walks every screen in its way), so they run in
`.github/workflows/integration.yml` when a GitHub release is published, and by hand from the Actions tab (Integration, Run workflow). The run over every
site runs there too, and weekly.

**Every rule an integration test checks has a unit test.** A UI test is the end-to-end proof that the screens are wired to the rules; the rule itself is
proved by a unit test, so a push that breaks a rule fails at once, not at the next release. A test that only checks layout (where something sits on the
screen, that a sheet stays open, that a keyboard has a Done button) has no rule behind it and is integration only. When a UI test is added, the unit test
for its rule is added with it, and both go in the table below.

**Releasing (the gate):** a build goes to TestFlight or the App Store only from a commit whose unit tests and integration tests passed.
`tools/release_testflight.sh` runs `tools/release_gate.py` first and stops unless the working copy is clean, the commit is on GitHub's `main`, and both the
CI workflow and the Integration workflow succeeded for exactly that commit (read from GitHub's public API; `tools/tests/test_release_gate.py`). To release:
push the commit; publish a GitHub release for it (Releases, Draft a new release, a tag such as `v1.0-49`), which starts Integration on it, or start
Integration by hand (Actions, Integration, Run workflow, on `main`); when both pass, run `tools/release_testflight.sh`. A failing integration test is fixed
(or the release is held) before the build goes to review. Integration takes the UI tests about 15 minutes and the run over every site up to two hours.

| Integration test (`OptOutKitUITests`) | The rules it checks, and their unit tests |
|---|---|
| `OnboardingAndSitesUITests.testTheFirstRunFromWalkthroughToQueue` | Walkthrough shown once: `CoreTests.testFreshInstallGetsWalkthrough`, `testUpdateWithNoNewMessageShowsNothing`. The answer saved: `AutoProtectionTests.testSayingYesTurnsOnBothAndNoTurnsBothOff`. The profile asked for: `CoreTests.testAProfileNeedsALegalFirstAndLastNameAndACurrentAddress`. First pass first: `CoreTests.testTheSemiAutomatedQueueWaitsOnlyForTheVeryFirstAutomaticPass`, `BackgroundPassesAppTests`. Page order, scroll-to-unlock: layout |
| `…testChoosingCaliforniaExplainsItsLawsAndOffersDropInTheQueue`, `testChoosingAnotherCountryShowsItsLawsAndRegulatorAndNeedsReadingToo`, `testAStateWithNoLawPointsToStrongerStatesWithExamples`, `testNotLivingInCaliforniaHidesIt` | Each place's rules and examples: `CoreTests.testEachCountryIsToldItsOwnRulesAndStrongPlacesAreOfferedAsExamples`, `testTheCountriesLoadWithTheEUAndEveryMemberAndAreUniqueByID`. DROP only in California, sites it covers not separate work: `AutomaticRunAppTests.testDROPComesFirstInCaliforniaAndIsLeftOutEverywhereElse`, `PlatformAppTests.testASiteDropHandlesIsListedOnceAndIsNotSeparateWork` |
| `…testTheDeviceLanguageIsUsedAndTheWalkthroughCanSwitchLanguage` | `PlatformAppTests.testTheAppSpeaksTheChosenLanguageEverywhereItBuildsWords`, `testAnUnsupportedLanguageIsIgnoredAndTheChoiceIsRemembered`, `L10nTests` |
| `…testFirstVisitsShowAShortGuideOnceInsteadOfWalkthroughPages` | `PlatformAppTests.testAGuideIsShownOnceAndOnlyForTasksAPersonTakesPartIn` |
| `…testTheSitesTabShowsTenPerGroupAndSeeAllOpensTheSearchWithThatStatus`, `testSitesTabSearchAndStatus`, `DirectoryUITests.*` | `SiteFilterTests`, `CoreTests.testEachFilterNarrowsAndTextMatchesAddressOrName`; the site page's shared opt-out: `DirectoryTests.testTheCourtRecordsSitesShareOneOptOutThatSubmitsToTheMembersHost` |
| `…testAboutTabReplaysWalkthrough`, `testThePageDotsSitBelowTheContentNotOnTopOfIt`, `testEveryKeyboardHasADoneButtonThatPutsItAway`, `SiteViewLayoutUITests.*`, `GuidedFlowUITests.testTheGuideSitsOnTopInAColouredFrameAndShowsTheWholeStep`, `AutoProtectionUITests.testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere` | Layout and navigation only |
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

## Continuous integration

Two workflows, on GitHub's hosted runners (free for a public repository). Neither contacts a real broker site: the live tests skip unless `OPTOUT_LIVE=1`,
and the UI tests use the app's fake sites.

**`.github/workflows/ci.yml`: the unit tests, on every push to `main` and every pull request.**

| Job | Machine | What it runs |
|---|---|---|
| `checks` | Linux | Broker and directory files against their schemas; `tools/tests` (the Python tools); `tools/l10n.py check`; the page-script unit tests (`tools/pagescripts`); the shard split |
| `packages` | macOS | `swift test` in `Packages/OptOutKitCore` and `Packages/AssistedRunLogic` |
| `test` (4 at once) | macOS, one each | The app's unit tests (`OptOutKitTests`). Shards 1 to 3 start booting their simulator before anything else; shard 0 builds first and boots after (a booting simulator starves the machine, and its checkout then took minutes), so it gets less of the tests. Shard 0 builds the app and both test targets once (`build-for-testing`, from the cached build folder) and hands the build to the others as an artifact; shards 1 to 3 compile nothing: they boot, wait for that build (`actions: read`, polling this run's artifacts) and download it. Every shard then runs its share (`test-without-building`). A notice says when the simulator was ready and when the tests started |

**`.github/workflows/integration.yml`: the integration tests, for a release.** On a published GitHub release and by hand: the UI tests (`OptOutKitUITests`)
in 5 shards, built and handed over the same way. On a release, by hand and weekly (Mondays): the automatic run over every site (see below).

`tools/ci_shards.py` shares the tests out (`--suite` picks the unit or the UI tests) so the shards end at about the same time: unit tests a class at a time (a class measured over 45 seconds, such as the
web-view classes, one test at a time), UI tests one test at a time (one UI class can take ten minutes). Each is weighed by the seconds it took in the last measured run (`tools/ci_timings.json`); one never measured is estimated
from its number of tests, and shard 0 is given less to make room for the package tests (`--reserve`). Every shard prints its timings as a notice, and
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
list), and XcodeGen itself (downloaded from its release rather than installed with Homebrew, which is slow there). The checkout fetches the last 100
commits, which is enough for the file times. The packages' `Package.resolved` files are committed: they pin Yams, and the CI build copies the core package's into the
generated project and builds with `-disableAutomaticPackageResolution` (no package resolution over the network), `-skipPackagePluginValidation` and
`-skipMacroValidation`; `swift test` runs with `--disable-automatic-resolution`. The CI test build leaves out the app icon
(`ASSETCATALOG_COMPILER_APPICON_NAME=`): rendering its appearance variants took over three minutes on those machines, and no test looks at it. The build
cache's key comes from git's tree hashes of the source folders (hashing every file with `hashFiles` took over two minutes and timed out). Code signing stays on (ad hoc): the app's encryption key lives in the
Keychain, which needs a signed app on the simulator. Xcode and SwiftPM decide what to rebuild by file times, and a fresh checkout
gives every file the time of the checkout, so before building `tools/ci_restore_mtimes.py` gives each file the time of its last commit; then only what
changed since the cached build is compiled. Each shard's build posts a notice with the Swift files it compiled, the cache it started from, the build
folder's size and its slowest kinds of step (`-showBuildTimingSummary`, read by `ci_shards.py --build-summary`). The caches are keyed by the Xcode version and the sources, so a new
Xcode starts clean; one shard saves each cache. Raising `CACHE_VERSION` in the workflow throws every cached build away. Timings that a test checks have
room for slower CI machines.

**UI tests are quick on purpose.** The app turns animations off when launched with a `-uitest` flag (debug builds only). A UI test of a whole automatic
run uses `-uitest-sites 25` (`XCUIApplication.fewSites`): the first 25 sites with a known form, so the run finishes in seconds and the test checks the
finished run and its report. Long lists build their rows only as they scroll into view, so a test scrolls to what it needs (`scrollUntilExists`); the
profile editor's own Done is `editor-done` (the keyboard has a Done too); the profile gate after the walkthrough is `completeProfileGate`; a toggle is set with `setSwitch` (where its switch sits depends on the phone). Under a
`-uitest` flag a run never asks iOS for the advertising ID: on a fresh simulator (as in CI) the tracking prompt came up at an unpredictable moment and the
run waited for it for ever. The walkthrough's advertising-ID page has its own test (`testWalkthroughOffersTheAdvertisingIDAndLetsYouPassIt`). `-uitest-reset` also marks the first-visit guide cards and the once-only explainers (email links, follow-ups) as seen unless a test asks for them
(`-uitest-coach`, `-uitest-explainers`), so a fresh simulator, as in CI, behaves like a used one: on CI the email-links explainer covered the run report.
A UI test that only needs a complete profile starts with `-uitest-seed-profile` instead of typing one (typing is tested in `ProfileEditorUITests`).
A test that relaunches the app to check what was kept opens it again with `-uitest-relaunch` (it keeps the data): a launch with no `-uitest` flag behaves like
a real one, so it resumed the first-run setup over the half-typed profile and started the automatic run, and on CI the profile editor never showed.

**The run over every site** (`integration.yml`, job `all-sites`: on a release, Mondays and by hand): the same automatic-run UI tests over every site
(`TEST_RUNNER_OPTOUT_ALL_SITES=1` lifts the 25-site limit), waiting for the whole run to finish. Sending is faked; no broker site is contacted.

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
| Choices the person makes on the page (request-type tiles, boxes, radios, menus) | The app chooses once, before the person acts, and never again on a refill. A tile, box or menu the person tapped is theirs: adding a second tile, unselecting ours or picking another is never undone, and a toggling tile is never tapped twice | `LiveFormTests.testTilesTheAppChoseOnce...`, `testAPersonAddingAnotherTile...`, `testAPersonUnselecting...`, `testATileTheAppHasNotYetChosen...`, `testBoxesAndMenusTheAppSet...`, `testABoxTheAppTicked...` | Sim |
| Only one request can be chosen (tiles, radios, a request-type menu) | Deletion is picked over opt-out, whichever comes first; a page that starts on opt-out is moved to deletion unless the person chose it. Where several can be ticked (checkboxes) both are ticked | `LiveFormTests.testASingleChoiceOf...`, `testAPageThatStartsOnOptOut...` | Sim |
| Filling a form whose code names mislead (usmarketinggrp.com: the box labelled Phone is named `email`; a "Full Address" box) | The visible label wins over the code name: Phone gets the phone, Full Address gets the whole address, never the name | `CoreTests.testTheVisibleLabelBeatsTheCodeName...`, `testAnEmailBoxNamedPhone...` | Mac |
| Accepting site terms for you | Off until the person taps Allow. When on, a prompt whose every paragraph is on the reviewed list is accepted once per page and logged; anything else, a risk-flagged paragraph, or the setting off leaves it to the person. The shipped list reviews nothing risk-flagged | `CoreTests.testTheGeneratedLibrary...`, `TermsAcceptanceTests` (render, Solve-and-send page), `TermsSettingsTests` | Mac / Sim |
| Settings: California DROP link | Shown only when California is the chosen state | none yet (view only) | n/a |
| Opening the right form is not "done" | Instructions on a form page ("your request is submitted only after you enter the code") are never a confirmation; real confirmations ("Thank you. Your request has been received.") still count, even below the instructions | `AssistedRunnerTests.PrematureDoneTests` (Melissa's consumer privacy page) | Mac |
| Never the deceased-person form | No directory opt-out page is a deceased list; Melissa uses its consumer privacy form; the live form picker scores a deceased form down | `CoreTests.testNoOptOutPageIsAListForDeceased...`, `LiveFormPickerTests.testAFormForADeceasedPersonIsScoredBelow...` | Mac |
| Send it for me (guides) | On by default; the box in a guide changes it for the session; Settings changes the default. Off: the form is filled, nothing is pressed, the person presses the page's button, and a confirmation is noticed or they tap Mark as done or Next (not recorded as sent or failed) | `EmailAndSkipFlowTests` (three tests), `WorkflowGapTests`, `SolveAndSendUITests` | Mac / Sim |
| A form whose email box is switched off (peoplefinders.com's record form) | Never filled; the intro's Next button is pressed and the form that asks for the email is filled instead | `LiveFormPickerTests.testAFormWhoseEmailBoxIsSwitchedOffIsNotFilled` (the Next press is page script: checked by hand in Chrome on the live page) | Mac |
| Contact, report, quote, consultation, newsletter, sign-in, navigation and jump-to-menu forms on a privacy page | Never picked; a masked social-security box and a request-type menu under a privacy heading still are | `LiveFormPickerTests.testContactQuoteNewsletterLoginAndNavigationFormsAreNotOptOutForms` | Mac |
| A business footer form (business email, industry) on a do-not-sell page | Never filled; the page's real request form is picked instead | `LiveFormPickerTests.testABusinessFooterFormIsNotFilledOnADoNotSellPage` | Mac |
| A page with several opt-out forms (nordicdataresources.com: email, cookie button, device ID) | The person is told "This page has 3 opt-out forms… form 2 of 3". Every form whose own words say opt-out or delete is filled and sent in turn, a sign-up, newsletter or contact form never is, the device-ID form gets this phone's IDFA (not the Android GAID), a later form that fails does not undo the earlier ones, the site is recorded once | `EmailAndSkipFlowTests` (three multi-form tests), `LiveFormTests.testOnlyFormsThatAreSpecificallyOptOuts...`, `AssistedAppTests.testEveryOptOutFormOnAPageIsFilledAndSentIncludingTheDeviceIDOne` | Mac / Sim |
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
| Profile editor rows (other names, previous addresses, phones, other emails) deleted while on screen | A row removed under its own binding gives the default and ignores a late store instead of trapping with "Index out of range" | `RowFieldTests` | Simulator unit test (SwiftUI bindings) |
| Closing the app while editing a profile | What is typed is saved when the app goes to the background (home), and is there after the app is killed and reopened | `ProfileEditorUITests.testProfileSurvivesRelaunch` | Simulator UI test |
| Applicable law on a page that hides it (forewarn.com) | The basis checkbox is never ticked by the app; once the person ticks it the law box is filled with the plain applicable-law sentence; the threat-of-harm box stays empty; "My data" offers the same sentence | `LiveFormTests.testForewarnsLawBox...`, `DetailChoicesTests` | Simulator unit test, Mac |
| ZIP code fills city and state | A five-digit (or ZIP+4) US ZIP gives its city and state; anything else gives nothing; every state code is one the state menu knows | `ZipLookupTests` (Core) | Mac |
| Email sent instead while the site's form had not gone through (send failed, waiting on the person): "Yes, I sent it" | The site is recorded as emailed, not failed, and no second "This site did not go through" offer | `SemiAutomatedFlowTests.testEmailingASiteWhoseFormDidNotGoThroughRecordsItAsEmailedAndOffersNothing` | Mac |
| Fields in an off-screen, zero-height bot-trap block (ididata.com) are left empty | A field off-screen or inside a clipped zero-height parent is not visible, so never filled | `LiveFormTests.testBoxesInAnOffScreenBotTrapAreNeverFilled` | Simulator |
| A fill (Fill again, first fill, before a send) finds boxes that appeared after the first look and fills them, even with the person's cursor in a box; what they typed stays | `refill()` rescans with `adoptNewForm(force: true)`; the typing pause still holds for the page watcher's own rescans | `LiveFormTests.testFillAgainRescansThePageAndFillsNewBoxesEvenWhileThePersonIsInABox` | Simulator |
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
| Every kind of form box (text, email, tel, number, date, month, date-time, select, age brackets, textarea, contenteditable) | Each is filled in its own shape and limit; identifiers (SSN), someone else's names and other dates stay empty; a before/after comparison over every recorded directory form guards the rules | `CoreTests` (the "field-by-field robustness" group), `LiveFormTests.testEveryKindOfBoxIsFilledInItsOwnShape...` | Mac / Sim |
| A page that ships a State/Country default ("CA"); "Is this for yourself?"; a phone list | The page default gives way to the profile's state, a matching country and a pre-filled name stay, a State the person typed survives; the self question is answered Yes; the phone list keeps both numbers | `LiveFormTests.testAStateOrCountryThePageShipsWith...`, `testForYourselfIsAnsweredYes...` | Sim |
| Forms with an "Add another email" / "+ Add phone" button | The buttons are pressed until each email and phone has a box, the new boxes get the next values, nothing is sent, a Remove button is never pressed, a type-less button that would submit the form is left alone | `LiveFormTests.testAddAnotherEmailAndPhoneButtonsArePressed...`, `testAnAddButtonThatWouldSubmitTheFormIsNotPressed`, `testAPageThatCapsItsExtraBoxes...` (a capped page, a wrapper around the button, boxes named `emails`), `CoreTests.testABoxClonedByAddAnotherTakesTheNextValue` | Sim / Mac |
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
| Sites tab shows ten per group (Done, Skipped, Up next); See all opens the search screen with that status chosen; the chips narrow the list; the tab's search field opens it focused | `SiteFilterTests` (status rules, every filter, clearing keeps the text); `OnboardingAndSitesUITests.testTheSitesTabShowsTenPerGroupAndSeeAllOpensTheSearchWithThatStatus`, `testEveryKeyboardHasADoneButtonThatPutsItAway` | Mac + Sim |
| Hand-written walkthrough flow (semi-automatic since the guided method was removed): steps advance, Cancel, Not working, site view links | `GuidedFlowUITests`, `GuidedRunnerTests` | Sim |
| Run now shows what was sent and what needs you, with no network | `AutoProtectionUITests`, `DryRunUITests` | Sim |
| A site the run's rules leave alone (DROP hold) is not counted as tried, never sent, kept on the page with its reason, and counted in the report; Re-test all really re-sends to sites sent this period | `AutomaticRunAppTests.testSitesTheRunLeavesAloneAreNotCountedAsTriedAndKeepTheirReason`, `BackgroundPassesAppTests` (re-test checks the pages sent) | Sim |
| A page with no sign of life for 15 s is moved to semi-automatic; a busy one is waited for | `CoreTests.testASiteWhosePageGoesQuietIsMovedToSemiAutomaticAndABusyOneIsWaitedFor` | Mac |
| A run cut off and brought back to the front stays pending; a site never tried is in every run, even a repeat | `AutomaticRunAppTests.testARunCutOffAndThenBroughtBackToTheFrontIsNotTakenAsFinished`, `testEverySiteNeverTriedIsInEveryRunEvenARepeat` | Sim |
| In California DROP is step 1 and the first pass waits for it; elsewhere DROP is not in the plan and holds nothing | `AutomaticRunAppTests.testDROPComesFirstInCaliforniaAndIsLeftOutEverywhereElse` | Sim |
| The engine can work on several sites at once (the app uses one): never more than asked, results in the order given, a shared page sent once, Stop starts no more sites | `CoreTests.testTheRunWorksOnThreeSitesAtOnceInOrderAndSendsASharedPageOnce`, `InterruptedRunTests` (one at a time) | Mac |
| A site the run gives up on has its work cancelled and its hidden pages ended; pages outside a background run are never touched | `CoreTests.testASiteTheRunGivesUpOnHasItsWorkCancelled`, `GivenUpPageTests` | Mac, Sim |
| A locked phone: a save waits for the unlock instead of stopping all saves; profiles opened while locked open at the unlock, and erasing is offered only for data that really cannot be opened | `CoreTests.testAFailureFromALockedPhoneIsToldApartFromDamagedData`, `PeopleTests.testASaveWhileThePhoneIsLockedIsWrittenAtTheUnlock`, `testProfilesThatCouldNotBeOpenedWhileLockedOpenAtTheUnlockAndAreNeverOfferedForErasing`, `testUnreadableDataIsNeverOverwritten` | Mac, Sim |
| A run rebuilds the plan once when it ends, not after every site; rebuilding it takes under 0.2 s | `ResumeAppTests.testARunRebuildsThePlanOnceWhenItEndsNotAfterEverySite`, `ActivityPageSpeedTests` | Sim |
| A stopped run carries on with only the sites left, never sending one twice; a stopped Re-test all carries on as a re-test | `ResumeAppTests` | Sim |
| Stop means stop: a stopped run is not carried on or started on schedule until the person starts one; Run now then counts only the sites left | `CoreTests.testARunThePersonStoppedDoesNotStartByItself`, `AutomaticRunAppTests.testStopEndsTheRunPartWayAndLeavesTheRestForLater` | Mac, Sim |
| The automatic opt-out page is worked out off the main thread, each form's fill once, with the same counts as the run's own rules | `ActivityPageSpeedTests.testTheActivityPageIsWorkedOutQuickly` (equal rows and Run now count, under 0.3 s after the first time) | Sim |
| A site that never answers is given up as too slow and the run goes on; a run settles a site at least every 30 s; Stop ends a run part-way and keeps the rest for later | `CoreTests.testASiteThatNeverAnswersIsGivenUpAndTheRunGoesOnToTheNext`, `AutomaticRunAppTests.testStopEndsTheRunPartWayAndLeavesTheRestForLater` | Mac, Sim |
| A site given up after its form was sent is recorded as sent and not confirmed and never sent again in the pass; one that ran out of time before sending is tried once more at the end, and the progress count never stands still or goes back | `CoreTests.testASiteGivenUpAfterItsFormWasSentIsRecordedAsSentUnconfirmedAndNotSentAgain`, `CoreTests.testASiteThatRanOutOfTimeBeforeSendingIsTriedOnceMoreAtTheEndAndProgressKeepsMoving`, `LiveFormTests.testAPageGivenUpAfterItsSendWasPressedIsKnownToHaveBeenSent` (a real page: pressing send reaches the watchdog) | Mac, Sim |
| A page counts as still loading only when it says so in whole words ("downloading your data" is not "loading"); settled is unchanged for 1.5 s | `CoreTests.testAPageIsLoadingOnlyWhenItSaysSoInWholeWords` | Mac |
| iOS ending a run's background time stops it only when the app is not on screen | `AutomaticRunAppTests.testIOSEndingTheBackgroundTimeStopsTheRunOnlyWhenThePersonIsAway` | Sim |
| Run now leaves out the sites already sent this period; Re-test all tries them again | `CoreTests.testRunNowLeavesOutOnlyTheSitesAlreadySentThisPeriod`, `BackgroundPassesAppTests` (second run and re-test) | Mac, Sim |
| A new person gets the automatic pass first; the semi-automated queue waits for it and opens after; the report leads to it | `CoreTests.testTheSemiAutomatedQueueWaitsOnlyForTheVeryFirstAutomaticPass`, `BackgroundPassesAppTests` (`waitingForFirstPass`), `AutoProtectionUITests.testANewPersonGetsTheAutomaticPassFirstAndTheSemiAutomatedQueueAfterIt` | Mac, Sim |
| The automatic opt-out page sorts each site into need you, sent or not tried by this period's attempts; groups fold, counts open them, a site opens its page | `CoreTests.testTheActivityPageSortsEachSite...`, `AutoProtectionUITests.testASiteOnTheAutomaticStatusPageOpensItsPageAndStaysThere`, `testRunNowShows...` (the counts move during a run) | Mac, Sim |
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
| 12 | Live forms: picking the form, choices the person made, deletion over opt-out | Core: `FormFiller` tests (labels beat code names) | `LiveFormTests`, `WebFormSubmitterTests` | Covered |
| 13 | Settings: language, place, California link, Global Privacy Control, advertising ID, terms | Core: language and place tests, terms rules | `WorkflowGapTests` (California link, Global Privacy Control), `TermsAcceptanceTests`, `PlatformAppTests` | Covered; the advertising ID read needs a device |
| 14 | Accepting site terms for you | Core: `TermsGate` tests, library has no risk-flagged approvals | `TermsAcceptanceTests` | Covered |
| 15 | Background runs, reminders, notifications | Core: reminder schedule tests (08:01-08:15 next calendar day, stable on replanning, a 21:00 opt-out still gets next morning's) | none | **Gap**: iOS background scheduling and notification permission need a device |
| 16 | Share extension (send a link to Exnay) | Core: none | `AppModelTests.OnlyAWebAddress...` covers the app side | **Gap**: the extension itself needs a device |

### One set of rules for every flow

Solve and send, Email links, the monthly automated run and the guide all find forms, fill them, press send and read the result with the same code
(`Shared/AssistedRun`): `WebAssistedDriver.prepareLoaded` and `WebAssistedPage` for the page, `PageFlow.sendOnce` for what a press of send meant,
`PageFlow.watch` for what the person did, `PageFlow.reloadThenRefill`, the tap check (`AssistedPage.pressesSinceFill` + `SentQuestion`: a confirmation with no button, link or Enter pressed by the person since the fill is asked about, "Was this sent?", not assumed; `testAConfirmationTheyDidNotPressAnythingForIsAskedAboutNotAssumed`), the typing guard (`AssistedPage.userIsTyping`: while the person has the cursor in a box nothing is clicked, scrolled or filled; `testNothingIsFilledClickedOrScrolledWhileThePersonTypesInABox`), a verification-code sub-form (`FormRun.asksForCode`, `AssistedPage.awaitingCode`: "Verify Email" sends a code, the site is not finished until the person types it; `testAVerifyEmailSubFormIsAStepNotTheEndInEveryFlow`) for Refresh the page, `PageMenu.items` (which also carries "My data": each of the person's details listed in a submenu, tap to copy; `DetailChoices` tested on Mac, the menu by `testMyDataIsInTheMenuAndOffersEachDetailToCopy`) for the … menu's page actions (Copy link, Open in my browser, Refresh the page, fill; `BrowserHandoffTests`: the question "Did you complete it?" is raised as the page opens, Yes finishes the site, No changes nothing, only web addresses open), `LiveFormPicker` for which form is the opt-out. What differs between flows is only the surroundings: the buttons,
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
