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
editor and are written once, in one save, when the person taps Done or Continue, closes the editor, or leaves or closes the app (home, the app switcher; the scene is no longer active) (`AppModel.saveProfile`). The write is wrapped in a background task so iOS lets it finish as the app closes.

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

**Profile editor, after the tester feedback (2026-11-09).** What is typed is also kept as a sealed **draft** (`ProfileDraftStore`, its own small file) a second after typing stops, and comes
back when the editor reopens after a crash or a close; saving the profile removes it (nothing else is rewritten while typing, so there is no lag). The **first-run setup is remembered**: until the profile is
complete (or its setup screen is finished once) the profile screen reopens at every launch, after the walkthrough (`resumeSetupIfNeeded`; "Not now" skips it for that session only). Every other name,
previous address, phone and email has a visible red minus button, and one that was added and left empty is dropped when the profile is saved. A previous address asks only for city, state and ZIP code
(no street, no from/to years: the fields stay in the data, the screen no longer asks). The current address still needs a street, because most forms ask for it. The country list is built once per language.

**ZIP code fills the place.** Typing a five-digit US ZIP code in an address fills the city and state when they are empty, or are still what the previous ZIP filled in; it never overwrites what the person typed
(`ZipLookup`, a bundled table of 40,977 ZIP codes from GeoNames, CC BY 4.0, credited in Settings; nothing typed leaves the phone, so there is no street autocomplete, which would send it to Apple).

**The guided walkthrough's pages** each start with one bold line, the thing to take away ("A site is not finished until you tap the link in its email."), and the lines under it explain it: the … menu lists every
item in plain words (including Open in my browser and There is another email step), "human check" is explained as the "I am not a robot" box or puzzle, and the emails page says where to look, how to bring the
link into Exnay, and that some sites send more than one.

**Nothing is reported anywhere.** The app has no server and sends no reports, so no wording says or suggests otherwise. "Not working" in the … menu only marks the site on this phone and sets it aside to try again later
(the word is "marked", never "reported"; the walkthrough says "Nothing is sent anywhere"); "Look a site up yourself and mark what you see" is likewise kept on the phone.

**Roll the guide up.** A ^ beside the … button (Solve and send, the guided steps, Email links) folds the black guide to one row: the site's name (with its place in the list, such as 1/2) takes the place of
"Site 1 of 2" in the top bar, beside the buttons, and nothing else of the guide shows, so the site's page has the room; the progress bar, instruction, notes, "Send an email instead" and Auto-send come back when it is
unrolled. In Solve and send, rolled up, an envelope button before Mark as done does "Send an email instead" (it is in the … menu too), shown only for a site that has an address to write to. The guide's second buttons (Mark as done, the envelope, Back, Copy, Mark completed) are gold-outlined capsules (`GuideSecondaryStyle`) beside the solid gold primary one, and never cut short: the site's name shrinks first. The first time it is shown the ^ pulses with a small "Roll the guide up" bubble (once, then never again; `guide.collapseHintSeen`). A grabber bar at the bottom edge of the black guide does the same by swipe: up rolls it up, down opens it (the page behind is never touched by the swipe). One choice for every guide, kept between sites and after the app is closed. The "How a … works" sheets scroll, with "Got it" pinned below the text, so a long guide never hides the button. **My data** ends with **Applicable law**: the exact sentence
the app types into a box that asks which law gives the person this right (`FormFiller.legalBasis`), to paste where it could not reach. On forewarn.com that box is hidden until the person ticks the basis for
the request themselves (their claim, never ticked for them); it is then filled, and the box about a threat of harm never is (`testForewarnsLawBox...`).

The last tab is **Settings** (it was called About): the mail app, advertising ID, automatic protection, "Send forms for me by default", accepting site terms (with its Turn off), the walkthrough replays and the information about the app all live there.

## Two walkthroughs

- **First install** (`OnboardingView`): the promise, the email, the place and its rules, terms, the advertising ID (one button to share it with the app, which iOS
  asks once; afterwards only iOS Settings can change it), automatic protection, and a last page pointing to Settings. Its final button is plain "Start": the
  automatic-protection choice was made on the page before. There is no Skip: every page must be scrolled to its bottom before Next works (a short page counts at once), the next page does not exist to swipe to until the current one is read (a forward swipe just stops; going back is always allowed), and a hint says "Scroll to the bottom to continue." Start, on the last page, takes the person to the email or the place's rules if either is still missing.
- **Held pages and guided sites** (`GuidedIntro`; every page-only directory site and every hand-written walkthrough is semi-automatic now; there is no "Guided" method): shown once before the first Solve and send or manual site, so nothing runs behind it. It shows an example page, the "..."
  options, what a site needs, why the wording is scary, and the emails that follow. Skip leaves it; neither walkthrough blocks the other.
- The first walkthrough's **Start** button is never disabled. When the email or the reading of the place's rules is still missing, Start takes the person to that page; a replayed walkthrough counts the saved email and an already chosen place as done from the first page.
- **The prompt is only raised on screen.** Apple's tracking prompt shows only while the app is in the foreground; asked from a background run, iOS answers "denied" without showing it and never offers the switch again. `AdvertisingID.current()` therefore asks only when the app is active and otherwise returns nil, leaving the choice open for the next time the app is on screen (a form that asks for the ID, the walkthrough page, or About).
- **Advertising ID refused:** iOS asks once. After a refusal the walkthrough page and Settings show the same text and an Open Settings button: Settings, Privacy & Security, Tracking, switch Exnay on (first switch on Allow Apps to Request to Track if Exnay is not listed), or Allow Tracking in the app's own Settings page when it is shown. Without it, forms that ask for the ID go without it.
- Both are replayed from Settings ("Replay the walkthrough", "Replay the guided sites walkthrough"), which also holds the advertising ID button.

## Privacy promise (shown at first launch, and in Settings)

> **Your information never leaves this phone, except to the sites you opt out of.**
> There is no Opt-Out Kit server, no account, no analytics and no tracking. What you enter is stored encrypted on
> this device. The app only talks to the data-broker websites themselves, to remove you from them.
> The app is open source, so anyone can check this. Read the code at **[repo link, to be added when public]**.

Make it true in the build, not only in the copy: no analytics SDKs, no network calls except broker pages and the
optional registry fetch (off by default), a CI check that fails if a networking library or tracker is added, and a
reproducible-build note in the repo.

## The Sites tab

Short by default, with the whole list one tap away:

1. **A search field** at the top. It is a button that looks like one: tapping it opens the search screen with its field already focused (the filter button at the top right opens the same screen without the keyboard).
2. **Three groups**, ten sites each: **Done** (newest send first), **Skipped** (newest skip first, with "Skipped until" its return date or "Skipped for good") and **Up next** (in the order the home page takes them). A site is done while its send still holds (`DirectoryEntry.isCurrent`, as on the site page); once due again it is back in Up next marked "Due again". A site set aside is Skipped even if it was sent before (`SiteStatus.of`). A group with more than ten has **See all N**, which opens the search screen with that status already chosen.
3. Then the sites that unlock later, the ones that no longer respond, quick checks and the listing scan, as before.

**The search screen** lists every site, in sections by status, and searches the web address, the company's name and the name of the walkthrough or official service that handles it ("peopleconnect" finds TruthFinder and the other PeopleConnect sites). Under the field the filter chips, all in view at once (they wrap onto a second line rather than scroll sideways, `ChipFlow`), filter it: **Status** (Up next, Skipped, Done), **Region** (In your area or Not in your area, the same answer as the site page's region row), **Type** of company, what it **Tracks**, who it **Sells to**, and **Method** (Automatic, Semi-automatic, Email). A chosen chip turns blue and shows its value; an x before the chips clears them all (the search text stays). The footer says how many of all the sites are showing. The rules are `SiteFilter` in Core; the screen's choices are kept by the Sites tab, so they survive the screen being redrawn.

## The site page

Built to be read without tapping and, for most sites, without scrolling:

1. **Title header**: the site's name, and one line under it: its status (Done with its date, Not done yet, Due again, Skipped until a date). Top right: a link button that copies the opt-out page's address, and a circle that marks the site done by hand; it turns into a green check, and tapping that undoes a hand mark (a send the app made cannot be undone).
2. **The action on its own**: one button, "Opt out", or "Opt out again" when the opt-out is current, with no subtitle. Under it, the email link when the site takes one and a small note: "Did it yourself? Tap the circle at the top right to mark it done."
3. **Who they are**, shown in full (no category or priority line): one sentence about the company beside its kind's icon (one icon per kind, `BrokerCategory.symbol`), then on its own row between dividers whether the broker reaches this person and where it operates (`Regions.summary`): a tracking icon, red and broadcasting when it reaches them and grey and struck through when not, then in bold "In your state (CA)" when it is on the registry of a state they live or lived in, "In your area" when its region tags cover their country (or it works worldwide), else "Not in your area", followed by where it works and how we know ("In your area: Worldwide. How we know: registered as a data broker in California; on the UK ICO register…"). Then what it tracks (eye icon) and who it sells to (dollar icon), each on its own row with its icon in the same column. "More about them" folds the rest of the summary, the policy quote, what this kind of company does and the policy link.
4. **How long an opt-out lasts**: one line (lasts, or repeat every N months and why), and once done the done date and the repeat date on one line.
5. **More details**: everything else.

## Flow types

| Type | When | What the app automates | What the user does | Brokers it covers (from the probe) |
|---|---|---|---|---|
| **1. Family request** | One request covers many sites | Fills and tracks one request, then marks every site in `covers` done | One CAPTCHA, one email click | courtrecords.us family (51), PeopleConnect (4), BeenVerified family |
| **2. Form + challenge** | Short form, CAPTCHA or Cloudflare check | Step card with copy chips for each field; timed clipboard clear | Solves the challenge, submits, taps Done | FastPeopleSearch, SearchQuarry, SmartBackgroundChecks, Social Catfish, most "CAPTCHA widget" sites |
| **3. Find my listing** | Must locate a profile first | Opens the search, then asks "is this you?"; sends nothing until confirmed | Picks their listing, pastes its URL | Spokeo, Nuwber-style sites |
| **4. Email or letter** | No form; email or mail only | Drafts the message from the profile; opens the share sheet | Sends it | Covered-person and expungement requests, small brokers |
| **5. Hard steps** | Phone code, ID upload, account | Coaching card: what will happen, what to redact | Does the step | MyLife, WhitePages, PimEyes-style sites |
| **Blocked** | Cloudflare returns 403 to scripts | Nothing scripted; opens in real Safari View Controller | Passes the check like any visit | About 14% of probed sites, including BeenVerified, Intelius, WhitePages |

**After a guide is finished** (Finish on the last step) and the site page is back on screen, the app asks "Open <site> next?" with Open the next site / Not now. The site is the first one still in Up next that has a page of its own and has not been walked through from this site page already. Cancelling, Not working and Not now ask nothing and go back to the site page.

Every guide's … menu (Solve and send, the guided steps, Email links) has **Open in my browser**: the page goes to the phone's default browser, and "Did you complete it?" is already waiting when the person returns, as with another mail app. Yes finishes the site the way that flow finishes one (Mark as done, the guided Finish, Mark completed); No changes nothing.

**Is it completely done?** A site that looks sent may still email a link, sometimes several. So in every flow with a person on screen (Solve and send, the guided steps, Email links) a confirmation is believed on its own only when the page says the whole request is finished and mentions no email. Otherwise the person is asked: *Yes, completely done*; *An email is still to come*; *I am not sure* (kept on the waiting list); and *Not yet*, which leaves them on the page: nothing is recorded and nothing moves on (in Solve and send the guide waits for Next site, Skip or Mark as done and then asks again; in the guided steps it stops pressing anything and notices a confirmation later). The … menu of each of those flows also has **There is another email step**, and the Email links waiting list's Done button asks whether that was the last step or another is coming; steps finished so far are shown. The background run has nobody to ask, so it keeps the older rule: an email step only when the page says so.

Type 1 is the best ratio: it removes the most sites for the least effort, so it goes first in the queue and gets the
biggest reward ("51 sites cleared").

## Open questions

1. Does the courtrecords.us request remove records or only opt out of sale? Needs one real run.
2. Which of the 51 sites need a separate request anyway (the sites showing their own CAPTCHA at the search step)?
3. Can WKWebView ever fill forms on challenge-protected sites, or is Safari View Controller plus copy chips the ceiling?
   Decided by the simulator probe (milestone 2).


## A link shared in while a sheet is open

On the first open of a day the app can show the last run's report as a sheet (and the first launch shows its walkthrough, the profile gate and What's new the same way). A link shared to Exnay from a mail app at that moment is held, not dropped: the Email links tab opens it as soon as the sheet is closed (`AppModel.coveredByASheet`, `LinkFillerView.takeIncomingLink`). Before, the link was taken while the sheet covered the tab, so its page and questions could not show and the person had to close the sheet and share again.

## Which site is this link for?

Many sites send people to the same address: privacy-portal providers (OneTrust alone serves about 90 sites in the list), groups of sister sites. A link from an email therefore cannot always say which request it belongs to, so the app no longer guesses (`LinkCheck.check`, `OptOutKitCore`):

- **One site uses the address:** it is that site, as before.
- **A provider's tenant address** (`blackbaud-privacy.my.onetrust.com`: a name of its own before the provider) is that one site.
- **Anything else on a shared address** (`privacyportal.onetrust.com`, even if one site's page is recorded there) and **an address nobody uses** opens the **Which site is this for?** screen before the page loads: the sites that use the address (those waiting on an email first, the site recorded at that address next), the other sites waiting on an email, and a search box over every site in the list (names and web addresses, prefix matches first). "It is none of these: open the link anyway" loads the page with nothing filled in or marked.
- **A chosen site** gets the same fill-and-send as a matched link when the link's address is one that site is known by (its domain, an opt-out page's host, a subdomain). For a site picked by hand at an address it is not known by, the page is only loaded and the guide says so in orange ("You chose X, but this link's address is not one we know for that site"); nothing is filled or sent for the person.
- **A page already open with no site matched:** the guide line reads "We could not tell which site this link is for. Tap to choose it", and **Mark completed** opens the same screen, then finishes the site chosen.

**A site already marked finished:** the link no longer just says so. The app asks "*Site* is already marked finished. Does this link ask for more: a confirmation, another form or another step?" with **Yes, it needs more: open it** (the site goes back on the waiting list until that step is done, and the page opens as usual), **It is a different site** (the screen above) and **No, it is finished** (nothing opens).
