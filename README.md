# Exnay: Opt Out Kit

Exnay is an iPhone app (SwiftUI, iOS 17+) that helps people get their personal data out of data brokers. It keeps a directory of about 830 brokers,
works out the best way to opt out of each one, does as much of it as it can on the phone, and walks the person through the rest.

It is local-first and open source. There is no Exnay server, no account and no analytics. What a person enters is stored encrypted on their phone and goes
only to the broker sites they opt out of.

> The repository and code are still named `opt-out-kit` (module `OptOutKitCore`, bundle id `dev.optoutkit.app`). Only the app's name changed.

## Principles

Always free. Never tracks: no backend, everything on the device. Teaches people their privacy rights, with the law that applies to them. Built by AI agents, validated by people on real phones. The person stays in control and the app is honest about what it knows. The full commitments are in [docs/PRINCIPLES.md](docs/PRINCIPLES.md).

## What the app does

- **A daily queue.** Each day the person picks one *kind* of broker to tackle (18 kinds, such as people search, ad tech, recruiting data, credit and
  consumer reporting), ranked by how bad the worst case is and how much opting out helps. A day is a batch of up to 15 sites of that kind. Every kind has a
  plain-language briefing with a best-case and worst-case example.
- **Three ways to opt out (plus manual)**, chosen per site from what was actually found:
  - *Automatic*: the app fills in and sends the form itself. Only sites whose form was seen working on a reviewed real send are in this group.
  - *Semi-automatic*: the app opens the live form and fills it in; the person clears a human check or a confirm step and presses the page's own button. The background run (below) also tries semi-automatic sites that have nothing only a person can do, and any that does not go through stays in the person's semi-automatic queue.
  - *Semi-automatic also covers pages with no readable form*: the app opens the page, clicks through a "Continue" button when the form hides behind one, fills what it can and never presses send; the person finishes and taps Mark as done. Sites that ask for business details or carry a caution show the page and put nothing of the person's in (`no_fill`). The five hand-written broker walkthroughs count as semi-automatic too. A site with both a page and an email address uses the page first, with the email as the fallback; email-only is for sites with no page. There is no separate "guided" method any more.
  - *Email*: one opt-out email to the privacy addresses of the day's sites, sent from the person's own mail app, with the person's other names, emails and previous addresses so a record held under any of them is found.
- **Email links tab.** Some opt-outs finish with a link in an email. The person pastes it; the app checks it against the directory and the sites already
  finished, loads it, and fills in the form. When several sites share the link's address (privacy-portal providers such as OneTrust), the app asks which site it is, with a search over every site, rather than guessing; a site already marked finished is asked about ("does this link ask for more?") before its page opens. A Share extension (`ShareExtension/`) lets the person share a link from a mail app straight to Exnay, which opens this tab through the `exnay://link?u=…` URL scheme; if the system blocks the hop, the link is copied for Paste. Requests that said an email would follow are tracked until the person finishes them.
- **Automatic protection.** The first run tries every site where the form is known and can be filled and sent without a person (about 500 of the ~830), and sends what it can. Every 3 months it sends again to the sites that went through. Every 6 months it re-tests every site from the start, and the person can start that full re-test by hand at any time. On any pass a site that does not go through is never marked done: it moves to the person's semi-automatic queue with the reason. The app explains this in plain words at first use and in Settings. For a new person the first pass comes first: the semi-automated queue opens when it finishes, with the sites that need a person for one step.
- **Official one-request services.** California's DROP is a platform task: one request that reaches every registered California broker.
- **Global Privacy Control.** Every page the app opens sends the signal, and a one-time task walks the person through turning it on in their own browser.
- **Re-ups.** The app records whether an opt-out is permanent or has to be repeated, and brings sites back after 6 to 12 months.
- **Languages.** The app is translated into French, Spanish and German. Where a broker offers its opt-out page in the person's language, that page is used.

## Where in the world

Every broker came from a US state registry (California, Oregon, Texas, Vermont), so the directory is a US one. Each site carries a `regions:` tag saying
whose data it collects (US, EU, UK, Canada, ..., or worldwide), with the evidence: vendor lists, privacy policies and terms, the UK ICO register, the broker's own
country sites, and the languages it is offered in. A person outside the US sees the sites that reach their country first, then can choose to do the rest.
Forms and request wording cite the law that applies to them (GDPR, UK GDPR, PIPEDA, LGPD, Ley 25.326, ...). Outside the US this is new and has had no real sends yet.
See [docs/REGIONS.md](docs/REGIONS.md) and [docs/FUTURE-WORK.md](docs/FUTURE-WORK.md) for the method, the counts, and the national lists not yet used.

## What it will not do

- It never solves a human check, accepts terms on someone's behalf without a reviewed list, or fills in a sign-up, newsletter, demo or contact form. Sites whose
  form turned out to be one are moved to guided, and a test fails if one is set to be filled automatically.
- It never sends a person's details anywhere but the broker being opted out of.
- It does not give legal advice. Broker pages change often; the directory records when each was last checked.

## Layout

| Path | What is in it |
|---|---|
| `App/` | The SwiftUI app: queue, sites, email links, Settings, the live-form engine (`LiveForms.swift`), the audit harness (`FormAudit.swift`, debug only) |
| `Packages/OptOutKitCore/` | The core Swift package: planning and ranking, method classification, form filling, regions, jurisdictions, persistence, tests |
| `directory/` | One YAML file per broker site: form, live-form findings, run checks, about, category, persistence, regions, languages, contact email |
| `brokers/`, `platforms/` | Hand-written walkthroughs, and one-request services such as California DROP |
| `jurisdictions/` | The privacy law of each US state and country, regulators, broker registries, and future work |
| `registries/`, `terms/`, `l10n/` | Registry snapshots, the reviewed terms library, and the French, Spanish and German strings |
| `tools/` | The crawlers and appliers that build the directory (see below) |
| `docs/` | Design, automation, verification, audits and region notes; `docs/audits/` holds the raw audit and real-send results |

## The tools

The directory is built by scripts, not by hand. The main ones, all in `tools/`:

- `registries.py`, `profile_brokers.py`: pull the state registries and profile each site's opt-out page.
- `live_forms.py`, `apply_live_forms.py`: open pages in a headless browser and record the forms and what a person would have to clear.
- `audit_forms.py`, `apply_audit*.py`, `apply_run_check.py`: audit forms and record which ones a reviewed real send confirmed.
- `survey_signup.py`: survey every opt-out page for forms that are really sign-ups.
- `tag_regions.py`, `regional_sites.py`, `site_languages.py`, `site_languages_browser.py`: find which regions and languages each site serves.
- `describe_brokers.py`, `describe_persistence.py`, `collect_about.py`: who each broker is, what it tracks, whether opting out lasts.
- `l10n.py`: extract, build and check translations.

Playwright runs from a local environment: `PLAYWRIGHT_BROWSERS_PATH=$PWD/.tools-browsers .tools-venv/bin/python tools/<script>.py`.

## Build and test

```bash
xcodegen generate
xcodebuild build-for-testing -scheme OptOutKit -destination 'generic/platform=iOS Simulator'
cd Packages/OptOutKitCore && swift test
```

The core package holds the logic and its unit tests (about 270). The app also has a debug-only harness (`-audit-semi`, `-audit-range`, `-real-send`) that dry-runs or
really sends opt-outs from the simulator and saves a screenshot of every result. Read each screenshot: the classifier mislabels results both ways. A site is only
marked confirmed (`run_check: confirmed`) after a person has seen its confirmation. See [docs/TESTING.md](docs/TESTING.md) and [docs/FORM-AUDIT.md](docs/FORM-AUDIT.md). How forms are found and filled, and the rules that keep a person's typing safe: [docs/FORM-FILLING.md](docs/FORM-FILLING.md). Come-back reminders: [docs/REMINDERS.md](docs/REMINDERS.md).

## Status

Working: the queue and daily flow, the live-form engine, about 27 sites confirmed by real sends, the email links tab, DROP, Global Privacy Control, regions and
languages, the translations. Still open: many semi-automatic forms have only been dry-run; OneTrust privacy-portal forms whose Submit button starts disabled;
walled people-search sites; non-US sends. Brokers re-list people, so check back on opted-out sites.

## Data credits

ZIP code places come from the GeoNames postal code data (geonames.org, Creative Commons Attribution 4.0), bundled as `Packages/OptOutKitCore/Sources/OptOutKitCore/Resources/zips-us.tsv`.

## More

[docs/DESIGN.md](docs/DESIGN.md) (design), [docs/AUTOMATION.md](docs/AUTOMATION.md) (what is automatic and why), [docs/DIRECTORY.md](docs/DIRECTORY.md) (directory format),
[docs/VERIFICATION.md](docs/VERIFICATION.md), [docs/EXCLUDED_SITES.md](docs/EXCLUDED_SITES.md), [CLOSED_SITES.md](CLOSED_SITES.md), [docs/PERSISTENCE.md](docs/PERSISTENCE.md),
[docs/LOCALIZATION.md](docs/LOCALIZATION.md).

## License

[MIT](LICENSE). The directory data (`directory/`, `brokers/`, `registries/`) is compiled from public pages and registries; each site's own name and marks belong to it.
