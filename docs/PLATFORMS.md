# Platforms: one request for many brokers

Some governments run a service that sends a person's deletion request to every broker registered with them. California's
**DROP** (Delete Request and Opt-out Platform, [privacy.ca.gov/drop](https://privacy.ca.gov/drop/)) is the first. Opt-Out Kit
treats these as **platforms**: a walkthrough shaped like a hand-written broker flow, plus who may use it, which of our sites it
reaches, and how long to wait before trusting it. Adding another jurisdiction is a new file in `platforms/`, not new code.

## What the app does for California residents

1. The walkthrough asks which state you live in (stored for the account owner until their profile has an address; after that
   the **current address state** decides, and family members are checked by their own address). Choosing California explains the
   registry and DROP; see `docs/JURISDICTIONS.md`.
2. Eligible profiles get a "One request for many sites" row at the top of their queue. It opens a guided walkthrough
   (`platforms/ca-drop.yml`, steps drafted from the DROP site and not yet run end to end): open DROP, confirm California
   residency through the state's Identity Gateway (only the person can do this; the app never does), copy name, email and address
   into the form, submit, save the confirmation. A parent can do this for a child and a family member for an elderly relative, as
   DROP allows; they are just another profile.
3. Once every step is done, the sites DROP reaches are **left alone for 90 days** (brokers must check DROP every 45 days and can
   take up to 90 more days to report). Those rows say "Covered by California DROP until <date>", the weekly opt-out skips them with
   the same reason, and after the hold the app asks the sites directly again, so a broker that ignored DROP is still handled.
   Before the person submits, those sites show "Also covered by California DROP: one request reaches this site".

DROP is not automated. It needs state identity verification, and its page says nothing about third-party apps or automation, so
the app guides the person through it instead.

## The known list of brokers

California's registry is one of several we pull; see `docs/JURISDICTIONS.md` for all of them and how they are joined into
`registries/all-brokers.json`. DROP's reach is `platforms/ca-drop-coverage.json`: every site registered in California (603 brokers
on 2026-10-22), computed by `tools/registries.py merge`. The registry's per-broker privacy-rights pages are also the starting point
for finding each broker's opt-out form.

## Other places

| Where | What exists | Status here |
|---|---|---|
| California | DROP, 600+ brokers, mandatory processing since 2026-08-01 | Built: `platforms/ca-drop.yml` |
| Connecticut | Brokers register from 2026-10-01 and must honor a universal deletion mechanism | Not open yet |
| Vermont | Broker law amended 2026; per-broker deletion pages from January 2027 | Not open yet |
| Texas, Oregon | Broker registries, no single request | Per-broker only (our normal flows) |
| Everywhere | Per-broker forms | The 856-site directory |

Sources disagree on some of these dates (vendor blogs, not statutes), so check an agency page before treating one as live.

## Adding a platform

Create `platforms/<id>.yml` in the broker shape (`id`, `name`, `tier`, `steps`, ...) with a `platform:` block (`short_name`,
`jurisdiction`, `states`, `request_url`, `hold_days`, `live`, `summary`, `coverage_file`) and a coverage JSON like the California one.
`live: false` keeps a mechanism that is announced but not open out of the queue. Eligibility is by current-address state today; a
country-level platform would need a `countries:` rule next to `states:`.
