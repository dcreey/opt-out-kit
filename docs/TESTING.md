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
| Skip this site | Moves on at once from the form page, while still loading, and from the last site (run ends) | `testSkipMovesOnWithoutSending`, `testSkippingWhileAPageIsStillLoading...`, `testSkippingTheLastSiteEndsTheRun` | Mac |
| Page will not load | Skipped after retries, shown as skipped, run continues | `testAPageThatWillNotLoad...` | Mac |
| Site has no form, only an email address | The no-form screen waits; "No" to the mail prompt keeps waiting; Skip moves on | `NoFormReasonTests`, `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| Send an email from a form page | Ends as Emailed (green check), never Skipped; next site runs | `EmailAndSkipFlowTests.testEmailingFromTheFormPage...` | Mac |
| Other mail app (Gmail, Outlook, ...) | "Did you send it?" appears as soon as the app opens and nothing covers it; Yes saves, No saves nothing | `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| In-app Mail composer | Send saves and finishes the site; Cancel saves nothing | `EmailHandoffTests`, `EmailAndSkipFlowTests` | Mac |
| Site failed or "Not working" | A site with an address offers email; Mark as done saves it as emailed; Skip moves on; no address means no offer | `EmailInsteadTests`, `EmailAndSkipFlowTests` | Mac |
| Stray or double email answers | Ignored; saved once | `EmailAndSkipFlowTests.testAnswersWithNothingOpen...` | Mac |
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
| Law pages for California, other states and countries; language switch | `OnboardingAndSitesUITests` | Sim |
| Both switches on by default; declining turns both off; skipping leaves a banner | `AutoProtectionUITests` | Sim |
| Birthdate required; legal name and address required to close the editor | `AutoProtectionUITests`, `ProfileEditorUITests` | Sim |
| Add a relative, switch accounts, profile survives relaunch | `ProfileEditorUITests` | Sim |
| Minor or public figure is never searched | `SafetyFlagsUITests` | Sim |
| Sites tab: search, grouping, status page, scan | `OnboardingAndSitesUITests`, `BrokerListUITests` | Sim |
| Guided flow: steps advance, Cancel, Not working, site view links | `GuidedFlowUITests`, `GuidedRunnerTests` | Sim |
| Run now shows what was sent and what needs you, with no network | `AutoProtectionUITests`, `DryRunUITests` | Sim |
| Spokeo, FastPeopleSearch, PeopleConnect flows | `BrokerFlowUITests` | Sim |

### Gaps

- Whether the real screen shows the alert or dialog (the logic is tested, the SwiftUI wiring is not).
- The hand-off to Gmail or Outlook on a device.
- The skip-to-return loop through the app model.

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
