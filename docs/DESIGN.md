# Opt-Out Kit: POC Design

2026-10-19 · Dylan Yurgionas

Opt-Out Kit is an open-source, local-first tool that submits opt-outs to the data brokers EasyOptOuts covers and guides you through the ones that can't be scripted. It is a mobile app that guides you through each broker in the phone's real browser; iOS ships first, Android later, and a desktop command-line tool is a stretch goal. It is gamified to push people to finish every opt-out, runs entirely on the device with no backend and no tracking, and is open source (a private GitHub repo at first). This POC proves the loop on three brokers: guide, confirm, re-check.

## Goals, non-goals and prior art

Pieces of this already exist, but none combines a scripted engine, a guided in-app browser and a shared broker-definition format under an open license. That combination is the POC's reason to exist.

**Goals**

- Guide the user through each priority broker in the phone's real browser, with the user doing the CAPTCHA, phone or ID steps.
- Keep all personal data on the device; give each broker only the fields it needs, and only after the user confirms a listing.
- Store each broker as data (a YAML file), so contributors fix breakage with a pull request.
- Prompt a re-check on a schedule, because brokers re-list people.
- Make finishing the list feel rewarding.

**Non-goals for the POC:** paid-tier brokers, Android and desktop builds, face-search sites, credit freezes, a hosted service, solving CAPTCHAs with third-party services.

**Does this already exist?** Partly:

| Project | What it does | Gap against this POC |
|---|---|---|
| [Blake104/OptOut](https://github.com/Blake104/OptOut) | Python CLI; YAML broker files; opens real Chrome via Playwright for each form | CLI only, no guided UI |
| [auto-identity-remove](https://github.com/stephenlthorn/auto-identity-remove) | Node runner; monthly schedule; state tracking; CAPTCHAs sent to a paid solving service | No human walkthrough; CAPTCHA data leaves the machine |
| [patrickomatic/opt-out](https://github.com/patrickomatic/opt-out) | Static web checklist with local notes | Submits nothing |
| [Infobreaker](https://discuss.privacyguides.net/t/infobreaker-data-broker-removal-for-macos-and-windows-that-runs-100-locally/39700.md) | Local app driving your Chrome; 57 brokers (26 scan, 3 end-to-end, 37 assisted) | Source license unclear; free for non-commercial use only |
| [Optery directory](https://www.optery.com/opterys-open-source-data-broker-directory-is-now-live-on-github/) | 640+ brokers with opt-out links and guides | Data only; license not stated on the page |

The closest match is Infobreaker, whose published license terms don't clearly allow reuse. The closest open code is Blake104/OptOut, so contributing there is a real alternative to starting fresh (see open questions).

## Target landscape: what EasyOptOuts covers

[EasyOptOuts](https://easyoptouts.com/sites) (US$19.99/year) targets 200+ high-visibility people-search sites and splits its list three ways, which is the split this POC should copy.

| Bucket | What it is | Examples from its list | POC treatment |
|---|---|---|---|
| Supported directly | Bots submit the opt-out | spokeo.com, whitepages.com, beenverified.com, fastpeoplesearch.com, truepeoplesearch.com, mylife.com, acxiom.com, lexisnexis.com | Seed the registry; script where the signals allow |
| Supported indirectly | Sites that mirror or redirect to a covered broker, so nothing is submitted | Dozens of state "arrests" and background-check mirror domains | Registry entries that point at their parent broker |
| Not supported | EasyOptOuts tells users to do it themselves | PeopleConnect brands (TruthFinder, Instant Checkmate, Intelius); secondary lead-generation brokers; social media | **Guided walkthrough:** the gap this tool fills |

Two details shape the design. For publicly searchable sites it searches first and submits only if your data is found, so it doesn't send your details to sites that never had them. And it re-scans every four months, so the scheduler is a core feature, not an extra.

The direct list also includes the Do Not Call registry and about fifty per-state court-records domains that share one pattern, so a single template covers them.

## More targets, and the signals that decide scripted vs guided

Four sources extend the seed list beyond EasyOptOuts:

- **California Data Broker Registry:** 581 registered brokers as of [June 2026](https://privacy.ca.gov/2026/06/privacy-momentum-builds-300000-californians-sign-up-for-drop-as-registered-data-brokers-hit-a-record-high/). Authoritative, but most entries run no public site.
- **[Big Ass Data Broker Opt-Out List](https://github.com/yaelwrites/Big-Ass-Data-Broker-Opt-Out-List)**** (BADBOOL):** roughly 55 sites, prioritized, with notes on each friction point. It is licensed CC BY-NC-SA, so use it as research and write our own step definitions rather than copying its text into the repo.
- **[Optery's directory](https://www.optery.com/opterys-open-source-data-broker-directory-is-now-live-on-github/)****:** 640+ brokers; check the repo's license before importing.
- **California DROP:** a single state-run request to all registered brokers, [live since January 2026](https://cppa.ca.gov/data_brokers), with processing required from August 1, 2026. It only helps California residents, so the tool should link to it and not replace it.

Each broker gets tagged with signals read off its opt-out flow. These are the ones that split the field:

| Signal | Effect on automation | Seen at (per BADBOOL and live pages) |
|---|---|---|
| Search first, then paste a profile URL | Scriptable; needs a name match step | Spokeo, Clustal, Nuwber, Radaris |
| Email confirmation link | Scriptable if the user's inbox is reachable; otherwise a human click | Spokeo, BeenVerified, SearchQuarry, Veripages |
| CAPTCHA | Human step in the embedded browser | FastPeopleSearch, TruePeopleSearch, UnMask, Rehold |
| Phone call or code | Human step | Whitepages (automated call, four-digit code), MyLife |
| ID upload | Human step; warn the user to redact | MyLife, PimEyes |
| Account or trial needed to see your listing | Guided; costs the user effort | Archives, Ancestry, Searchbug |
| One opt-out per email address | Needs alias emails | BeenVerified |
| Refuses third-party submissions | Must be user-driven | PeopleConnect |
| One request covers a family of sites | Collapse the family into one task | PeopleConnect (four brands); BeenVerified (PeopleLooker, PeopleSmart); FreePeopleDirectory via Spokeo |
| Single-page app with no readable HTML | Needs a real browser even to describe | PeopleConnect's Suppression Center (fetched as an empty shell) |

From these, every broker lands in one of four tiers: **A** (form plus email link: script it), **B** (adds a CAPTCHA: script it, pause for the user), **C** (phone, ID, account or app-only flow: walkthrough), **D** (email or letter only: generate the message). The POC treats the tier as data on each broker, not as code.

## Architecture

iOS ships first as a native SwiftUI app, Android follows, and a command-line tool for desktop is a stretch goal. The contract between platforms is data, not code: each broker is a YAML file checked against a JSON Schema, so Android and the CLI read the same registry.

| Component | Job | iOS choice |
|---|---|---|
| Broker registry | One YAML file per broker: URLs, tier, signals, fields, steps, last-verified date | Bundled in the app; validated in CI |
| Profile vault | Name, emails, addresses, phones; each broker gets only the fields its definition lists | Encrypted store with the key in the Keychain |
| Queue and state | Priority order, status per broker, next re-check date | SwiftData or SQLite on the device |
| Guide | Step cards: what to do, which values to copy, what to watch for | SwiftUI |
| Browser surface | Where the user does each step | Chosen by milestone 2 (below) |
| Reminders | Re-check prompts, streaks | Local notifications |

**Step vocabulary.** `open` (a URL), `copy` (a vault value, cleared from the clipboard after 60 seconds), `say` (an instruction), `search_match` (the user searches the site and confirms their listing; nothing is sent before this), `wait_for_email` (subject and time limit) and `confirm` (the user taps Done). Tier flags drive the queue order and the rewards.

**Browser surface: three candidates, one test.** Brokers probably block embedded webviews with human-verification challenges. That is an assumption I have not tested, so milestone 2 measures it on real devices.

| Surface | What it is | Upside | Downside |
|---|---|---|---|
| WKWebView | An in-app browser the app controls | The app can fill and highlight | Most likely to be blocked; carries none of the user's cookies |
| Safari View Controller | Real Safari engine and cookies in a modal | Passes checks like any visit | The app cannot see the page or draw over it, so the user loops between a step card and the browser, returning with its Done button |
| Safari Web Extension | An extension in the user's own Safari that highlights and fills fields on listed broker sites when the user taps | Real browser plus in-page guidance | The user must enable it and grant per-site access; the most work to build; unverified on these sites |

The baseline is Safari View Controller, because it is the cheapest thing that should pass verification. The extension is the upgrade if the step-card loop proves too clumsy. On Android, Chrome Custom Tabs have a partial-height mode that lets the guide sit above the real browser; confirm that when Android starts.

**What hand-guided gives up.** It scales to a short list, not 200 brokers. The app ships a prioritized queue of roughly 15 to 20 brokers (the high-priority tier from the lists above) and points California residents to DROP. The long tail waits for the command-line tool.

**Desktop (stretch goal).** A command-line tool reading the same YAML: tiers A and B in a visible Chrome through Playwright, tier C walked in the terminal. It is not in the POC and nothing in the app depends on it.

**Privacy rules in the code.** No analytics; no CAPTCHA-solving service (those send each challenge to a third party); nothing submitted until the user has confirmed a listing; alias emails supported for brokers that allow one opt-out per address.

## Gamification: finish the list

The aim is completion. Most people quit after the first few sites, and brokers re-list people, so the game rewards finishing and returning, never sharing or spending.

| Mechanic | How it works | Why |
|---|---|---|
| Exposure ring | A score from the share of queued brokers done and re-verified | One number to push to 100% |
| Family combos | PeopleConnect clears four brands in one run, so the app shows "4 sites cleared" | Rewards the high-leverage opt-outs first |
| Boss brokers | Tier C flows with a phone call or ID step get a bigger reward and extra coaching | Makes the dreaded steps the best ones |
| Quarterly streak | Keeps a streak alive by completing the re-check round | Targets the real failure, which is re-listing |
| Verified points | Points are paid when a re-check finds you gone, not when you tap "Done" | A skipped step can't be gamed, since "Done" is on trust |
| Next-best step | One button opens the next broker in priority order | Cuts the decision cost |

**Rules that protect the privacy goal**

- No accounts, leaderboards or friend lists; scores live on the device.
- No points for submitting to a broker that a scan showed doesn't hold you.
- No streak penalties that punish someone for a bad week; a missed quarter pauses the streak.
- Sharing is opt-in: the app renders a progress card image on the device, and the user sends it however they like.
- No dark patterns. The tool exists to fight them (see the risks above).

## No backend: everything on the device

There is no server we operate, so there is nothing to breach, subpoena or monetize, and no analytics SDK in the build.

| Need | On-device answer | Cost |
|---|---|---|
| Profile and progress | Encrypted local store; key in the iOS Keychain or Android Keystore | Lost phone means lost data unless the user exports |
| Backup and moving phones | User-initiated export of an encrypted file, passphrase-protected, saved wherever they choose | No automatic sync |
| Broker list updates | Registry bundled in each app release; optionally the app fetches a static, signed file from a GitHub release | The fetch exposes the user's IP to GitHub, so it is off by default |
| Re-check reminders | Local notifications | The OS may delay them |
| Broken-step reports | "Report" opens a prefilled GitHub issue in the browser containing only the broker ID and step number | The user chooses to send it; the maintainers learn nothing otherwise |
| Crash reporting | The OS's opt-in crash logs only | Slower bug discovery |

Two consequences. First, with no telemetry we cannot see which broker flows have broken, so the registry carries a `last_verified` date and the contributors' pull requests are the health signal. Second, the app still contacts the brokers themselves; the privacy claim is that only the brokers and the user's own browser see anything, and the docs should say that plainly.

## Open source plan

The repo starts private on GitHub and opens once the checks below pass.

- **Layout:** one monorepo with the iOS app, later the Android app and a command-line tool, and `brokers/*.yml` with the JSON Schema.
- **License:** MIT or Apache-2.0 for the code. GPL-family licenses are widely seen as awkward for App Store distribution, so avoid them unless a lawyer says otherwise. Broker definitions get their own license so list contributors can share them.
- **Source material:** [BADBOOL](https://github.com/yaelwrites/Big-Ass-Data-Broker-Opt-Out-List) is CC BY-NC-SA and Optery's directory has no stated license, so the repo contains only definitions written from the live opt-out pages, with a cited link and verified date.
- **Before going public:** an audit that no test fixture holds real personal data, a secrets scan of the history, a threat-model write-up, a `SECURITY.md`, and a contributor guide for adding a broker.
- **Reproducible builds:** a documented way to build the app from source and compare it with the store version, since no-tracking is a claim users need to verify.
- **Private phase:** invite a few testers who can open issues; use CI to validate every YAML file against the schema.

## Walkthrough: PeopleConnect suppression

PeopleConnect is the best test case because EasyOptOuts [explicitly doesn't support it](https://easyoptouts.com/sites), and [DeleteMe says](https://help.joindeleteme.com/hc/en-us/articles/25526064464019) PeopleConnect refuses third-party submissions. One request covers TruthFinder, Instant Checkmate, Intelius and US Search. The site is free; a recurring charge means you signed up for a paid product by mistake.

I did not submit anything. The live page is a script-rendered shell that a plain fetch returns empty, which is itself the signal that it needs a real browser. The steps below are cross-checked across three independent guides ([DeleteMe](https://help.joindeleteme.com/hc/en-us/articles/25526064464019), [Redact](https://redact.dev/data-brokers/peopleconnect-us/remove), [Whitebridge](https://whitebridge.ai/opt-out/truthfinder)), and the first real run should confirm them.

| # | What the user sees | Who acts | Signal |
|---|---|---|---|
| 1 | Open the Suppression Center; "Free - Start Here" asks for an email, a terms checkbox, Continue | User, with a copy chip for the email | App-only page |
| 2 | An email titled "Confirm your email address" arrives; its link must be clicked within 15 minutes | User taps the link; the app starts the clock | Email link, time-limited |
| 3 | A form asks for personal details, including a birthdate the page warns cannot be changed once set | User confirms the values | Irreversible field |
| 4 | The center searches its records and shows matches; it asks to verify email and phone | User | Phone or code check |
| 5 | The user picks the records to suppress and the "Suppression Setting" option, including future records | User | Judgement call |
| 6 | Confirmation; guides report processing in 48 to 72 hours | App sets a re-check | Re-listing risk |

Step card copy for step 3 would read like: "Step 3 of 6. Check the birthdate. The site says it can't be changed after you continue. [Copy birthdate] [Done]".

The same flow as a broker definition:

```yaml
id: peopleconnect
name: PeopleConnect (TruthFinder, Instant Checkmate, Intelius, US Search)
tier: C
covers: [truthfinder.com, instantcheckmate.com, intelius.com, ussearch.com]
signals: [app_only, email_link, time_limited_link, phone_verify, third_party_refused]
fields: [email, full_name, birthdate, phone]
steps:
  - open: https://suppression.peopleconnect.us/login
  - copy: email
  - say: "Enter your email, accept the terms and tap Continue."
  - wait_for_email:
      subject: "Confirm your email address"
      within_minutes: 15
  - say: "Check the birthdate. It can't be changed after you continue."
    confirm: true
  - say: "Select the records that are you, then choose the suppression setting."
    confirm: true
recheck_days: 30
verified: null   # set after the first real run
```

Two things this walkthrough exposes in the design: steps need a `time_limited` flag so the guide starts the clock when the email is requested, and a `covers` list so one run marks four brokers done.

## POC scope and milestones

The POC is done when one person on an iPhone can opt out of three brokers, one per tier, and the app reminds them to re-check.

| # | Delivers | Broker proven |
|---|---|---|
| 1 | Broker schema, three broker definitions, CI validation | none; schema tests only |
| 2 | Surface test on a real iPhone: each broker opened in a webview, in Safari View Controller, and with a Safari extension prototype; record any challenge or block | Spokeo, FastPeopleSearch, PeopleConnect |
| 3 | iOS app v0: queue, Keychain vault, step cards, tap-to-copy with timed clear, Done tracking | PeopleConnect (tier C), Spokeo (tier A, per its [live opt-out page](https://www.spokeo.com/optout)) |
| 4 | Re-check notifications, exposure ring, verified points | FastPeopleSearch (tier B; the user solves the CAPTCHA) |
| 5 | TestFlight build for a few private testers | All three |

**Success criteria:** each broker finishes in under ten minutes of the user's time; a broken step is fixed by editing one YAML file; nothing leaves the phone except what a broker's own form asks for.

**After the POC, in order:** the rest of the 15 to 20 broker queue, Android, then the command-line tool. Mail integration and California DROP automation are out of scope for now.

## Risks and open questions

- **Breakage.** Opt-out pages change often; [BADBOOL](https://github.com/yaelwrites/Big-Ass-Data-Broker-Opt-Out-List) warns the same. Mitigation: a last-verified date on every broker, a "report broken step" button, and easy pull requests.
- **Human checks.** Brokers may challenge or block webviews, and even the real browser. Mitigation: milestone 2 measures it before the app is built around a surface.
- **Disclosure to remove.** Opt-outs usually require handing over data. Mitigation: the user confirms a listing first, the app sends the minimum, and it shows exactly what each broker will receive.
- **Terms of service.** Some brokers refuse agents. The app automates nothing, the user submits their own data, and PeopleConnect stays fully user-driven. Needs a legal read before release.
- **Manipulative flows.** Brokers use dark patterns (EPIC has a [2026 report](https://epic.org/wp-content/uploads/2026/05/Good-Luck-Opting-Out-Manipulative-Design-Patterns-in-Opt-Out-Processes.pdf) listed in BADBOOL). The guide should name the trap, such as "don't buy a report".
- **List licensing.** BADBOOL is CC BY-NC-SA, and the Optery directory's license is unstated on its announcement page. We write our own definitions and cite them.
- **Wrong person.** A name match can be a namesake. The `search_match` step always asks the user to confirm.
- **Done on trust.** The app cannot see the page, so a skipped step goes unnoticed; the re-check is the real verification.
- **Clipboard exposure.** Copied values are briefly readable by other apps, hence the timed clear.

**Open questions**

1. Native SwiftUI for iOS, or a cross-platform framework to share more with Android later?
2. Which license: MIT or Apache for code, and a separate one for the broker data? See "Open source plan" for the constraints.
3. Safari View Controller or the Safari extension as the iOS surface? Decide after milestone 2.
4. Should the app link out to California DROP for residents, and detect residency?
5. For the later command-line tool, build new or contribute to [Blake104/OptOut](https://github.com/Blake104/OptOut), which already has YAML brokers and Playwright?

## Sources

Pages opened on 2026-10-19:

- [EasyOptOuts home](https://easyoptouts.com) and [Sites We Cover](https://easyoptouts.com/sites)
- [Big Ass Data Broker Opt-Out List](https://github.com/yaelwrites/Big-Ass-Data-Broker-Opt-Out-List)
- [Spokeo opt-out page](https://www.spokeo.com/optout)
- [CPPA data broker and DROP page](https://cppa.ca.gov/data_brokers) and [CalPrivacy DROP milestone release](https://privacy.ca.gov/2026/06/privacy-momentum-builds-300000-californians-sign-up-for-drop-as-registered-data-brokers-hit-a-record-high/)
- [DeleteMe: PeopleConnect steps](https://help.joindeleteme.com/hc/en-us/articles/25526064464019), [Redact](https://redact.dev/data-brokers/peopleconnect-us/remove), [Whitebridge](https://whitebridge.ai/opt-out/truthfinder)
- [Blake104/OptOut](https://github.com/Blake104/OptOut), [auto-identity-remove](https://github.com/stephenlthorn/auto-identity-remove), [patrickomatic/opt-out](https://github.com/patrickomatic/opt-out)
- [Infobreaker announcement](https://discuss.privacyguides.net/t/infobreaker-data-broker-removal-for-macos-and-windows-that-runs-100-locally/39700.md), [Optery directory announcement](https://www.optery.com/opterys-open-source-data-broker-directory-is-now-live-on-github/)

The PeopleConnect Suppression Center itself returned an empty page to a plain fetch, so its steps rest on the three guides above and are unverified until a first real run.
