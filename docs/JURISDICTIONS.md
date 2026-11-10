# Jurisdictions: what each place's law means, and what we do about it

Opt-Out Kit is organized around the **law where the person lives**. For every US state (and DC) we record, with a source and a review
date, whether the state makes data brokers register, whether it offers one request that reaches all of them, and what privacy law
its residents have. The walkthrough shows the person their state's version ("Your state requires brokers to register themselves; we
pull these registries", "Your state has an automatic opt-out for all of these registries; we integrate with it to simplify it", "We
also go beyond your state's registry..."), and Settings keeps it one tap away.

Countries will use the same shape (`kind: country`) in the same folder. They are not researched yet.

## Where the facts live

| File | What | Updated |
|---|---|---|
| `jurisdictions/us.yml` | One entry per state and DC: privacy law, broker registry, deletion platform, sources, `reviewed:` date | By a person, every ~6 months |
| `platforms/*.yml` | One-request services (California DROP) as guided walkthroughs | By a person |
| `registries/<state>.json` | Each state's registry, normalized: name, DBA, website, privacy-rights page | By the pipeline |
| `registries/all-brokers.json` | The joined list: every known broker once, with the states it is registered in | By the pipeline |
| `registries/summary.json` | Counts per state, shown in the app | By the pipeline |
| `registries/unresolved.json` | Registered names no website could be found for | By the pipeline |

## Sources and laws not yet in effect

- Every place has `sources:` (real pages: the regulator, the agency, the bill, a state tracker). The walkthrough lists them under "Where we found this", and `check_jurisdictions.py` fails if one is missing.
- A law's `effective:` date decides whether it is in effect, so a law that "takes effect 2027-01-01" turns into "in effect" by itself on that day.
- `pending:` lists laws not in effect: `stage: proposed` (introduced, in committee), `advancing` (passed a chamber, in conference) or `passed` (signed, takes effect later), with `as_of:`, `url:` and a short `note:`. The walkthrough shows each beside a "not law yet" label with a link. Once a `passed` law's date arrives it stops being shown as pending. Pending entries go stale faster than statutes, so the checker flags `as_of` older than 90 days.

## Registries we pull (2026-10-22)

| State | Source | Format | Brokers | Websites |
|---|---|---|---|---|
| California | [CalPrivacy registry](https://cppa.ca.gov/data_broker_registry/) | CSV download | 603 | all |
| Texas | [Secretary of State registry](https://texas-sos.appianportalsgov.com/data-broker-registry) | web app with "Export to Excel"; a headless browser clicks it | 456 | all, plus a consumer-rights link |
| Oregon | [DFR data broker file](https://dfr.oregon.gov/business/licensing/data-broker-registry/pages/index.aspx) | tab-delimited download (names and addresses only) | 392 | none: joined to the others by exact business name |
| Vermont | [Secretary of State portal](https://bizfilings.vermont.gov/online/DatabrokerInquire) | bulk download needs a free account | not pulled yet | drop the file in `registries/inbox/vt.csv` or `vt.xlsx` and it is imported |
| Connecticut, New Jersey | registries announced for 2027 | not open | 0 | add an importer when they open |

Together: **673 distinct broker sites**, 423 of them in more than one state's registry, and 19 Oregon names with no website
anywhere (listed in `unresolved.json`; add a hand-made match in a future `registries/overrides.yml`).

## How the joining works

1. Each registry's "website" cells are cleaned (brokers type things like `example.com; https://www.example.com` or `com; other.io`),
   reduced to registrable domains, and the first is the broker's **primary site**.
2. Brokers are grouped by primary site, so a business in three states is one entry that says `registered_in: [CA, OR, TX]`.
3. A registration with no website (Oregon) joins an entry when its business name or DBA equals one we know. Exact, not fuzzy.
4. Every primary site becomes a directory entry (`bucket: registry` for ones EasyOptOuts did not already list), crawled the same way
   as every other site, starting from the broker's own privacy-rights page.
5. California's DROP coverage is computed from the California registrations.

`tests`: every broker in `all-brokers.json` must have a directory entry, and every entry's `registered_in` must match the joined list.

## Keeping it current

State registries change often (brokers register each January); state laws change rarely. So:

- **Registries**: the "Refresh directory" workflow runs `tools/registries.py fetch` then `merge --add-sites`, re-crawls, and opens a
  pull request for a person to review. It never merges anything itself. (Workflows are switched to manual runs for now.)
- **Law facts**: every entry has `reviewed:`. `tools/check_jurisdictions.py` fails when one is older than 180 days, and the same
  workflow runs it, so a stale state shows up as a failing step to act on. To review a state: open its registry and privacy-law
  sources, correct `jurisdictions/us.yml`, bump `reviewed:`, run `swift test`.
- **New registry opens** (Connecticut and New Jersey in 2027, Vermont's 2027 changes): set `status: live` and `fetcher:` in
  `us.yml`, add the importer to `tools/registries.py`'s `FETCHERS`, and the walkthrough text updates itself.

## What the app tells a person

From `Jurisdiction.statements(summary:platforms:)`, in this order: the registry ("requires data brokers to register themselves; we pull
this registry (N brokers) and add every broker on it to our list", or "is setting up a registry", or "does not run one"), the
one-request service if there is one, "we also go beyond your state's registry" with the total, the privacy law and its effective date
(and that an enacted-but-not-yet-effective law does not bind brokers yet), and the universal opt-out signal (Global Privacy
Control) where reported. Choosing a state is optional; once the owner's profile has a current address, the address decides.

## What was researched, and how sure we are

Sources are mostly law-firm and compliance-vendor summaries plus the agencies' own pages. They disagree on some dates (New
Jersey's and Minnesota's universal opt-out dates, Vermont's 2027 amendments, Texas's chapter number), so `us.yml` records
"required" for the eight states every source agrees on (CA, CO, CT, DE, MN, MT, NH, OR) and "reported" for the ones only some
sources list (MD, NJ, TX, NE). Treat any date as a pointer to the statute, not the statute.

## Countries (researched 2026-10-22)

`jurisdictions/countries.yml` has **55 countries** and the **EU**: the 27 EU members and Iceland, Liechtenstein and Norway (the GDPR
applies directly; each lists its national act and its regulator), plus the United Kingdom, Switzerland, Canada, Mexico, Australia,
New Zealand, Brazil, Argentina, Chile, Colombia, Peru, Uruguay, Japan, South Korea, Singapore, India, South Africa, Israel,
Türkiye, Hong Kong, Indonesia, the Philippines, Nigeria, Kenya and Thailand. Other countries show "we do not have your country's rules yet".

### Is there a database to pull?

We looked first. What exists:

| Source | What it gives | Used |
|---|---|---|
| [UNCTAD Data Protection and Privacy Legislation Worldwide](https://unctad.org/page/data-protection-and-privacy-legislation-worldwide) | Whether each of 194 countries has, drafted or lacks a law (137 have one) | Reference only: no download link, no rights or regulator detail |
| Wikidata | Data protection authorities with websites for 47 countries; no usable per-country law table | Cross-check |
| Council of Europe Convention 108/108+ | Which countries are parties (34 ratifications of 108+) | Reference |
| EDPB members, regulators' own sites, EU-Lex | The EU/EEA regulators and the GDPR | Yes (source of the 30 EU/EEA entries) |
| [DLA Piper, Data Protection Laws of the World](https://www.dlapiperdataprotection.com) | Per-country law names, dates, regulator, rights, registration duties, 2025-26 changes, in a fixed structure | Yes: read for each non-EU country and cited in its entry |
| GitHub datasets | Korean enforcement tables, ISO country codes, privacy-policy corpora; no per-country rights dataset | No |

So there is no machine-readable source for rights and regulators. Each entry is hand-written from the sources above and carries the
date it was reviewed and its sources. The facts that mattered most are recorded exactly as found, and where a source says
"not stated" the entry says `unclear` or leaves the date out, rather than guessing. A few examples of what that surfaced:
Mexico replaced its 2010 law in March 2025 and moved the regulator out of INAI; Chile's new law takes effect 2026-12-01; India's
DPDP Act is phased in until 2027-05-13; Singapore's law gives no general right to deletion; Israel's Amendment 13 names data brokers
as a registration category.

### Registries outside the US

Only US states publish broker registries we can pull. Elsewhere, registries list organizations in general (Argentina, Colombia, Peru,
Uruguay, Türkiye, the Philippines, Nigeria, Kenya), or a narrow class (Quebec's "personal information agents", Israel's databases
whose main purpose is passing data to third parties). The app says which, and does not pull them. Israel's registry is the first
candidate to add an importer for.

### Facts that change

Same rule as the US: each entry has `reviewed:`, and `tools/check_jurisdictions.py` flags any that are more than 180 days old.
Dates to re-check first: Chile (2026-12-01), India (2026-11-13 and 2027-05-13), South Korea's March 2026 amendment (most
provisions 2026-09-11), Indonesia's planned agency, Mexico's commencement and regulations, the UK's Data (Use and Access) Act commencements,
and any country that opens a broker registry.
