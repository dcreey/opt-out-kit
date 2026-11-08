# UX by opt-out type

Draft, 2026-10-20. Goal: the most automation per screen. We build one flow per *type* of opt-out, not per broker; a
broker YAML picks the type and supplies the data. Nothing here is built yet.

## Research finding that shapes this: shared opt-outs

All 51 `*courtrecords.us` state sites in the EasyOptOuts list (checked 2026-10-20) link to the same central page,
`courtrecords.us/do-not-sell-share-my-personal-information/`, and the same contact address. That page's form posts to
`members.courtrecords.us/removeMyData/`. SearchQuarry uses the same `/removeMyData/` path on its own domain, so this
looks like one vendor platform behind several brands.

- One submission plausibly covers about 51 sites, with one challenge to solve (the page carries Turnstile and
  reCAPTCHA markers). Not yet confirmed by a real run, and the request is a "do not sell or share" request, so check
  whether it removes the listing or only stops sale.
- The registry already has `covers:`; add `family:` so the app shows "51 sites cleared" for one run.
- A CAPTCHA solve cannot be reused across sites (tokens are single-use and site-bound), so the saving comes from
  one request covering many sites, not from reusing a solve.

## Intake: one-time profile setup

Ask once, store only on the phone. Collect what brokers match on, because a missed alias is a missed listing.

| Field | Why | Notes |
|---|---|---|
| Names | Matching; brokers list "Bob" and "Robert" separately | An unlimited list, each tagged legal, previous legal, maiden, nickname or other |
| Relationship | Links the person to the owner | Dropdown of family relationships (parent, child, sibling, spouse, cousin, other family and so on); no friends; not shown for the owner |
| Current and previous addresses | Matching; most brokers key on address | City, state and years lived; full street only if the user adds it. A US state is chosen from a menu of the fifty states and DC (two-letter code stored); another country keeps a free-text region |
| Emails | Confirmation links | The household email (owner's profile) plus an "Other email addresses" list on every profile ("Add email"): forms with more than one email box take them in order, the rest go in the message box. Offer alias addresses for brokers that allow one opt-out per email |
| Phones | Some matching, phone-code steps | Optional; shown as (773) 633-1564 while typed (`PhoneFormat.display`), forms still get plain digits |
| Birthdate | Some forms require it | Optional; sent only to brokers whose YAML lists it |

**When edits are saved.** Nothing is written while the profile is being edited, not even on leaving a field. The edits (including the household email) stay in the
editor and are written once, in one save, when the person taps Done or Continue or closes the editor (`AppModel.saveProfile`).

Relatives are not a field: add a relative as another person (with a relationship) and they get their own profile and
queue.

Rules: every field optional except a name; each broker receives only the fields its YAML lists; a "What this site
will receive" screen shows them before anything is sent.

## Family: many people, one app

The app runs opt-outs for a family, not only for the owner (family only for now; no friends). Each person has their own profile (above) and their own
progress, queue position, re-check dates and rewards. A person menu on the main screen switches between them.

- **Adding someone:** name first; the rest can be filled in with them later. The app says plainly: family members only, someone who asked you to or a child you are the parent or guardian of.
- **Minors and public figures:** each profile has an "Under 18" and a "Public figure" switch (both off by default; a birthdate under 18 also counts). Several sites' terms forbid searching for minors, public officials and celebrities, so the app never scans, re-checks or accepts terms for these profiles. Opt-out requests still work.
- **Their emails, not yours:** confirmation links and "one opt-out per email" brokers need the person's own address
  (or an alias). The profile warns when two people share one.
- **Run order:** "Next best step" works down one person's queue; a "Run for everyone" view lists the next step per
  person, so a family can sit down and clear one broker for all of them at once.
- **Family requests:** a broker that covers many sites is run once per person. Brokers that need the person
  themselves (phone codes, ID checks) are marked "needs them present".
- **Their data is theirs:** removing a person deletes their profile and progress together. Export and import (later)
  can move one person at a time, so they can take their own data with them.
- **Minors and others who cannot consent:** parent or guardian only; each broker's terms for requests made on
  someone's behalf need a legal read before release (already a risk in the design).

Built so far: the data model, a **Profile** button (edit the selected person), an **account switcher** (choose a
person or add one) and the profile editor, with encrypted on-device storage.

## Lost phone means lost data

Accepted trade-off: there is no server, so nothing can be recovered from us. The data lives in one encrypted file, and
its key is in the iOS Keychain. The key is not "this device only", so a normal encrypted iPhone backup carries both and
the profiles come back when the phone is restored. The editor says so: "If you lose your phone without a backup, this
data is gone. Back up your phone as usual and it comes with it."

Not yet verified on a real backup and restore. An explicit passphrase-protected export is a possible later addition.

## Two walkthroughs

- **First install** (`OnboardingView`): the promise, the email, the place and its rules, terms, the advertising ID (one button to share it with the app, which iOS
  asks once; afterwards only iOS Settings can change it), automatic protection, and a last page pointing to About. Its final button is plain "Start": the
  automatic-protection choice was made on the page before. Skip jumps to the first required step not done.
- **Guided sites** (`GuidedIntro`): shown once before the first Solve and send or manual site, so nothing runs behind it. It shows an example page, the "..."
  options, what a site needs, why the wording is scary, and the emails that follow. Skip leaves it; neither walkthrough blocks the other.
- The first walkthrough's **Start** button is never disabled. When the email or the reading of the place's rules is still missing, Start takes the person to that page; a replayed walkthrough counts the saved email and an already chosen place as done from the first page.
- **The prompt is only raised on screen.** Apple's tracking prompt shows only while the app is in the foreground; asked from a background run, iOS answers "denied" without showing it and never offers the switch again. `AdvertisingID.current()` therefore asks only when the app is active and otherwise returns nil, leaving the choice open for the next time the app is on screen (a form that asks for the ID, the walkthrough page, or About).
- **Advertising ID refused:** iOS asks once. After a refusal the walkthrough page and About show the same text and an Open Settings button: Settings, Privacy & Security, Tracking, switch Exnay on (first switch on Allow Apps to Request to Track if Exnay is not listed), or Allow Tracking in the app's own Settings page when it is shown. Without it, forms that ask for the ID go without it.
- Both are replayed from About ("Replay the walkthrough", "Replay the guided sites walkthrough"), which also holds the advertising ID button.

## Privacy promise (shown at first launch, and in Settings)

> **Your information never leaves this phone, except to the sites you opt out of.**
> There is no Opt-Out Kit server, no account, no analytics and no tracking. What you enter is stored encrypted on
> this device. The app only talks to the data-broker websites themselves, to remove you from them.
> The app is open source, so anyone can check this. Read the code at **[repo link, to be added when public]**.

Make it true in the build, not only in the copy: no analytics SDKs, no network calls except broker pages and the
optional registry fetch (off by default), a CI check that fails if a networking library or tracker is added, and a
reproducible-build note in the repo.

## Flow types

| Type | When | What the app automates | What the user does | Brokers it covers (from the probe) |
|---|---|---|---|---|
| **1. Family request** | One request covers many sites | Fills and tracks one request, then marks every site in `covers` done | One CAPTCHA, one email click | courtrecords.us family (51), PeopleConnect (4), BeenVerified family |
| **2. Form + challenge** | Short form, CAPTCHA or Cloudflare check | Step card with copy chips for each field; timed clipboard clear | Solves the challenge, submits, taps Done | FastPeopleSearch, SearchQuarry, SmartBackgroundChecks, Social Catfish, most "CAPTCHA widget" sites |
| **3. Find my listing** | Must locate a profile first | Opens the search, then asks "is this you?"; sends nothing until confirmed | Picks their listing, pastes its URL | Spokeo, Nuwber-style sites |
| **4. Email or letter** | No form; email or mail only | Drafts the message from the profile; opens the share sheet | Sends it | Covered-person and expungement requests, small brokers |
| **5. Hard steps** | Phone code, ID upload, account | Coaching card: what will happen, what to redact | Does the step | MyLife, WhitePages, PimEyes-style sites |
| **Blocked** | Cloudflare returns 403 to scripts | Nothing scripted; opens in real Safari View Controller | Passes the check like any visit | About 14% of probed sites, including BeenVerified, Intelius, WhitePages |

Type 1 is the best ratio: it removes the most sites for the least effort, so it goes first in the queue and gets the
biggest reward ("51 sites cleared").

## Open questions

1. Does the courtrecords.us request remove records or only opt out of sale? Needs one real run.
2. Which of the 51 sites need a separate request anyway (the sites showing their own CAPTCHA at the search step)?
3. Can WKWebView ever fill forms on challenge-protected sites, or is Safari View Controller plus copy chips the ceiling?
   Decided by the simulator probe (milestone 2).
