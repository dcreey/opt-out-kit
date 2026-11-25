# Finding forms and filling them in

How the app finds an opt-out form on a live page, fills it, and keeps its hands off what the person has done. The code is in
`App/Sources/LiveForms.swift` (finding and filling), `AssistedOptOut.swift` (the semi-automatic run and its watcher), `WebViewFetcher.swift` (what the
page says afterwards) and `Packages/OptOutKitCore/.../FormFiller.swift` (which value goes in which field). Tests: the page scripts' unit tests (`tools/pagescripts`),
`AssistedRunnerTests.swift`, `FormFiller` tests in the core package, and the fixture journeys (`FixturePageTypeUITests`, `FixtureJourneyUITests`; docs/TESTING.md).

## Finding the form

- The page is loaded in a web view kept at phone size; cookie prompts are denied; forms are discovered in the page and in its frames
  (`discoverForms`, `discoverFormsDeep`). Each input gets a `data-ook` token so later passes find the same box again.
- `LiveFormPicker.score` ranks forms: an opt-out or privacy form beats a newsletter or free-trial box. A form is only filled if it scores high enough.
- A form that asks for a business or work email, an industry, a job title or a company size (a footer's "Stay Updated" box, a sales enquiry) is never filled unless its own button or words say opt out (`enformion.com`'s footer box was being filled instead of its request form).
- A box that already holds something stays as it is, with two exceptions: a State or Country the page ships with, and an email box holding something that is not an address (`peoplefinders.com`'s email box shipped with the word "opt-out" in it, so the person's address was never typed): the person's address replaces it. Text the person typed is never replaced.
- A form is also refused when it is about something else (`LiveFormPicker.notOptOut`: a quote, consultation, "what to report", "contact us", "thank you for contacting", a robot check) in its own words, its button or the heading just above it (`LiveForm.head`), unless its own words say opt out or delete; when it asks for an account password (a box whose label says password; a masked box for the last four digits of a social security number or a phone number is not one); when it is nothing but navigation toggles; and when it is menus only, with no button and nothing about privacy around it (a jump-to menu). Found by the Chrome load check, `docs/audits/chrome-load-2026-11-13.md`.
- A form whose email box the page has switched off (`disabled`) is never filled: it cannot take the person's address, so it is a later step. Peoplefinders' "Record Suppression Form" ships its email box disabled with the value "opt-out" (that word is the page's, not ours); the form that asks for the address opens from the intro's **Next** button. When only such a form shows, the run presses the page's one Next / Continue / Start button (only on a page about opting out, never inside a cookie or consent prompt) and reads the page again (`pressIntroNext`).
- A page that keeps its request forms hidden until a menu outside any form is set ("Select From Available Forms: Right to Opt-out / Right to Delete / Right to Know", `enformion.com`) has that menu set to the opt-out choice (else deletion) before the forms are read (`chooseRightsPicker`). A menu inside a form, one the person set, or one with only access or correction choices is left alone.
- A form the page builds a few seconds after it loads (blackbaud.com's OneTrust web form) is looked for again for up to 6 seconds before anything on the page is clicked (`discoverFormsDeep`), but only on a page that looks unfinished: a privacy portal's host (OneTrust, TrustArc, Securiti, saymine, ...) or a short page that says it is loading (`pageLooksUnbuilt`). Waiting on every page cost each form-less site 6 seconds and pushed a run's sites past their time limit. Before this the run said "no opt-out form was found on the page". Protected by `FixturePageTypeUITests.testAFormBuiltLateWithTileQuestionsIsFoundAnsweredAndSent`.
- A privacy page whose way on is a "Submit a Privacy Request" link that opens a new tab (`target=_blank`; 01advertising.com, to its Termly form) has it opened in the same page, since the app's page has no tabs, and the form on the new page is filled (`open-request-links`, then `discoverFormsDeep` waits for the new page). Termly and saymine count as privacy-request services when a link is followed off the site. Protected by `navigation.test.js` and `FixturePageTypeUITests.testARequestLinkThatOpensANewTabIsFollowedAndItsFormSent`.
- A choice on the page ("Who is this request for?", "Remove my information") can reveal a second form. The watcher notices a form it has not seen
  (`adoptNewForm`) and fills only its empty boxes.
- A code step that the page reveals only after a button that emails the code ("Email me a verification code"; the box is hidden, a person has not asked for the code yet) is a code to type: `empty-code-field` reports it until the box has a value, so the app never sends before the person has the code and types it in, and the site is not counted done until then.
- **Previous-address boxes of a live form are read by their label, not by the app's box tokens.** A live form's boxes are named `f0-9` and so on; those digits were read as "previous address 9" (so a box labelled "Previous street address" got no address) or "2" (so "Previous ZIP code" got the second previous address's). The tokens are now left out of what the rules read (`FormFiller.plan`; `testThePreviousAddressBoxesOfALiveFormAreNotMisreadFromTheirTokenNumbers`).
- **"Add another email" / "+ Add phone" is pressed on the first fill too** (Solve and send and the automatic run), not only for a form that appeared later: `WebAssistedPage.refill` presses it once per extra email or phone and fills the new boxes (`testAddAnotherButtonsArePressedForTheFurtherEmailsAndPhones`).
- **"Myself" is the person's answer, never "Another Individual".** "Individual" in "Another Individual" no longer reads as the person, and radios with no
  `name` that share a box are one question (HubSpot's newer forms): judged one by one, both were chosen and the last click, "Another Individual", won, which
  brought up an agent's certification box on datatowin.com (`choose-request-options.js`).
- **A long box label is shortened, never replaced by the box's token** ("f0-18"), in what the app tells the person (`FormField.display`).
- **A box is named by the words beside it before its placeholder.** A placeholder is often an example ("John", "john@doe.com"): it now comes after the label,
  never instead of it. With no label of its own, a box is named by the element just before it, or by a short title beside a wrapper that holds only this box
  (klear.com, Meltwater's opt-out: `<div>First Name</div><div><div><input placeholder="John"></div></div>`, read as "John", "Doe" and "john@doe.com", which
  match nothing in a profile: "We could not match any of this form's fields to your profile"). `discover-forms.js`.
- **A cookie banner in a shadow root is answered too** (Usercentrics, on the same page): `deny-cookies` searches open shadow roots and presses Deny, never Accept.
- **A request choice is never taken for "myself".** In a group of radios the answer "myself / me / individual / consumer" is the self-answer to "who is this for?", and used to match any option that said "me" ("Know what personal information you hold about **me**" was chosen ahead of the opt-out beside it). A label that is itself a request (opt out, delete, know, correct...) is no longer read that way (`choose-request-options.js`, `testWhenThereIsNoDeleteChoiceItChoosesOptOutOfTheSale`).
- A page that says the emailed code was wrong ("That code is not right", "invalid code", "the code expired") is a refusal (`FormRun.rejectsCode`, `.rejected("the site did not accept the code")`), never a send, even when the form has vanished and nothing else on the page looks like an error.
- A form the page shows only once a choice is made ("Who is this request for? Myself") is found by the automatic run too: when the form on screen has nothing to fill, the fill runs again (it answers the choice and adopts the form that appeared) before the form is judged.
- Sites that are not a form at all are handled by hand-off, and the app never presses send on them: block widgets (`usatrace.com`,
  `quickpeopletrace.com`: the person taps Block Profile) and per-record sites (`open-public-records.com`: each record has its own removal form).
  See `AssistedRunner.Item.handsOff`.

## Filling it in

`FormFiller.plan` chooses a value for each field from the person's profile; `fillLive` types them into the page. Rules that must keep holding:

1. **Phone numbers are plain digits.** No spaces, dashes, brackets or `+`: `7736331564`. A country-code menu beside the box ("United States (+1)") already
   supplies the code, so the box gets the 10 digits and nothing else. The only exception is a box whose `pattern` attribute rejects digits. The menu itself
   gets the United States: by name, by its flag (HubSpot's US entry is "🇺🇸 [placeholder for all other country codes]", with no name), or by a whole "+1"
   (never the "1" inside "+213" or "+1684": that pattern, unescaped, could pick another country; datatowin.com showed Mexico +52). A box that holds only the
   dial code its menu wrote there ("+1") is still empty of a number: it gets the number after the code (`+1 7736331564`), where before it was left as it was.
   A box already ending in the person's number is not typed again (a second pass typed bare digits over `+1 7736331564` and lost the code).
2. **An error is detected and resolved with other formats.** After filling, `tryPhoneFormats` looks at each phone box it typed into. A box is in error when
   its own validity check fails, it is marked `aria-invalid`, its class or its parent's class says invalid or error, or a visible error message sits next to it.
   It then tries other shapes one at a time (`1` + digits, `+1` + digits, `773-633-1564`, `(773) 633-1564`, dotted, spaced), waiting a moment for the page to
   react, and stops at the first that clears the error. If none does, the plain digits go back. Special characters only ever appear this way.
3. **Nothing the person put in is wiped.** A box or menu that already holds something is left alone unless it holds exactly what the app last typed there.
   Every value the app sets is recorded in `data-ook-last`; a later pass overwrites a box only when its value still equals that record. A menu counts as
   holding something once it is off its first option. Separately, a box the person edits themselves is marked `data-ook-user` from a real (trusted) input
   or change event, so the app's own events never count as the person's, and that box is never touched again.
4. **Dates are typed in the shape the box shows, and an error is retried.** A birthdate or "today's date" in a text box (not a native date picker, which takes
   `yyyy-mm-dd`) goes in as its placeholder shows (`dd/mm/yyyy`, `yyyy-mm-dd`, ...), else month/day/year. After filling, `tryDateFormats` checks each such box
   with the same error test as phones (validity, `aria-invalid`, an invalid or error class, a visible message). It then tries day first, year first, dashes,
   dots, no separators and spelled-out months, one at a time, until the error clears; if none does, the first shape goes back. The same user-edit and
   `data-ook-last` protection as rule 3 applies (the box carries `data-ook-dob` with the ISO date).
5. **A business's boxes stay empty.** A box labelled "business" with a street, address, email, phone, city, state, zip, contact or fax in it
   ("Business Relationship Information (if applicable)", catchlight.ai) is the business's, not the person's: `FormFiller` skips it and never counts it as required.
6. **Pre-filled pages keep their values.** A link from an email often pre-fills a name and email (`keepExisting`); those stay. The one exception is a **State or Country box the page ships with** (completemedicallists.com starts its State on "CA"): a page default is not the person's choice, so it is replaced by the profile's value unless it already agrees or the person typed it (`LiveForms.fillLive`, `pageDefault`).
   - **"Is this request for yourself?"** (a menu or radios) is answered Yes / "myself", never as an agent (`selfQ` in `chooseRequestOptions`). A box holding a list of phones is typed as the list, not squashed into one number.
7. **A box is never given another box's value.** `FormFiller.plan` decides by the words of the label, so the order and the exceptions matter:
   - *Identifiers only the person holds* (SSN, "last 4 digits", licence, passport, state or national ID, tax ID, account, order, reference, case, policy numbers) are
     left empty; when required they make the form "needs you". They used to match "last" (last name) or "state" (the state code).
   - *A LinkedIn box* (some recruiting and workforce sites need the person's profile to find a record): filled with the profile's optional **LinkedIn profile** address
     (`Person.linkedInURL`; "linkedin.com/in/…" gets `https://`, an address that is not on linkedin.com is not used), only in a text or URL box whose label or name says LinkedIn. With no address a
     required box makes the form `needsYou` ("This form asks for your LinkedIn profile…": add it to the profile or paste it on the page); an optional one is left empty. Facebook, X, Instagram
     and the other social boxes below are never filled.
   - *Someone else's or unknown details* (maiden name, mother, father, parent or guardian, spouse, emergency contact, alias, nickname, other or former names, a social
     profile or handle, gender, race, marital status, employer, occupation, income, birthplace) are left empty; when required, "needs you".
   - *A further email or phone* ("Alternate email", "Additional email", "Secondary phone", "Other phone", "Email 2") takes the next one in the profile, in order
     (the first such box gets the second email, the next the third, and so on); with none left it stays empty unless required. A **Confirm email** box is still the
     person's own first email (the check reads the visible label, not the field's code name: `wpforms[fields][5][secondary]` is a confirmation).
   - *A box added by "Add another"* repeats the label or the code name of an earlier box ("Email", "Email"; `emails`, `emails`), and a plural `emails` box after the main email box is the list of further ones, so it takes the next email or phone in the profile too; with none left it repeats the first, as a confirmation box would. A label that is only an example address ("you@email.com") is never a repeat by label; the code name (after " | " in a live label, since a live field's `name` is only its token) still is. Checked live on businessregistry.com, whose "Add email" button adds a box only once the last one has text: the button is pressed, the new box takes the next email, and what the page will not take (it stops at two extra boxes) goes in the message box.
   - *"Add another email" / "+ Add phone" buttons.* When the profile has more emails or phones than the form has boxes, `WebViewSession.addAnotherBoxes` presses the form's own add button (one press per box needed, at most five boxes of a kind), reads the form again and fills the new boxes. Pressing stops for a kind once a press adds no box (a page that caps its boxes), and the press goes to the innermost button, never a wrapper around it. It is shared by every flow: `scanAndFill` (guided, automated) and `adoptNewForm` (Solve and send). It never presses anything that could send the form: a `<button>` with no `type` (it submits), a submit button, a link that goes somewhere, a disabled one, or any text saying remove, delete, clear, send, submit, cancel or opt out. A bare "Add another" or "+" counts only when it sits beside that kind of box and no box of the other kind.
   - *Previous, former or prior* address, street, city, state or zip uses the person's second address, never the current one again; "Second previous address" or
     "Previous address 2" uses the next one, and the box stays empty when there is none.
   - *The person's own other names*: a "Maiden name" box gets the maiden name, "Nickname" the nickname, "Previous/former name" the previous legal name, and
     "Other names", "Also known as" or "Aliases" all the other names joined by commas. A relative's maiden name ("mother's maiden name") is never filled.
   - *A box for a whole list* ("Emails", "Phone Numbers", "Other email addresses (one per line)") gets them all, or only the others when it says other or additional;
     one to a line in a text area, comma-separated in a text box. An email-type box always gets one address. A hash or "64-character hex" box is never an email.
     An example address inside a label ("another@example.com") is a hint, not the word "another".
   - *What the form has no box for* is added to its message box: "I may also appear under other emails: ...; other phone numbers: ...; other names: ...; previous
     addresses: ... (years)." Only the leftovers are listed, so a form that already has boxes for them does not repeat them, and a form with no message box gets nothing extra.
   - *Phone boxes* include "cell", "cellular", "whatsapp" and "sms"; "(including country code)" and similar hints in brackets are not the country.
   - *A phone split over three boxes* (area code, prefix, line number: character limits 3, 3 and 4, as on roundsky.com) gets one part in each, `773`, `633`, `1564`, never the whole number in every box. It applies to exactly that 3-3-4 group of boxes, and these boxes are not retried in other formats.
   - *Names*: "first and last name" in one box is the full name; "Last Name or Business Name" is the last name; "Street name" is not a person's name.
   - *A street in two boxes*: "House number" gets the leading number of the street line ("12"), "Street name" the rest ("Main St"). "Street 2" is the second line (empty, "N/A" if required).
   - *Dates*: only "today's date", "date of request", "date signed", "Date" alone and similar get today. "Date you were contacted", "Effective date" and the rest are left
     empty (required: "needs you"). A **month** picker gets `yyyy-MM` (the birth month for a birthday), a **date and time** picker `yyyy-MM-ddTHH:mm`; time, week, range and
     colour boxes are never filled.
   - A box named only by a web address is an option from a list ("Websites used: ConsentCompliance.com", astoriacompany.com), never a certification, and
     "consent" counts only as a word (`pending-certification`): that option held Astoria's form as "a confirmation to tick yourself".
   - *Certification boxes* ("I certify under penalty of perjury", "I acknowledge", "I consent") are never ticked: the form waits for the person (`pending-certification`).
     The one exception (docs/PRINCIPLES.md, decided 2026-11-23): on the account owner's own profile, a certification about the owner themselves ("I certify
     that I am the individual ... whose information is the subject of this request ... and that all information I have submitted is true and accurate") is
     ticked with the "I am this person" boxes (`FormFiller.selfCertification`, `tick-identity-boxes`). "I certify that I am the subject of the request" is the same
     statement (fastbackgroundcheck.com's required box, which also lets the site email the person about the request; ticked on the owner's profile, decided
     2026-11-24). **Never one sworn as an oath** (`FormFiller.legalOath`:
     "under penalty of perjury", "under oath", "sworn", "swear"; decided 2026-11-24): missionwired.com's, 01advertising.com's and zoominfo.com's wait for the
     person, and Solve and send adds in plain words that the wording only means their details must be true, which their own details are, so ticking it puts
     them at no risk (`AssistedRunner.certificationNote`). An agent-only box ("written
     proof of authorization ... on behalf of the data subject"), terms and marketing never are; a family member's profile still waits for that person; and a
     box with no label of its own, or a bot trap, is never ticked.
     Only a box the person can see counts (a styled box hides the input and shows its label), and a request option is never one: "To withdraw consent" or "To opt out
     of the sale" is a request the app chooses or leaves. affinityanswers.com was held on "a certification box that you must tick yourself" by its "To withdraw
     consent" option in an EU section the page hides from US visitors. Only a box of a form the app is filling counts (`data-ook-form`), and a cookie toggle
     never does: focus-usa.com's opt-out page (the Complianz plugin) lists every cookie service below the form with an unticked "Consent to service
     google-adsense", and the run stopped there on "a certification box that you must tick yourself" with a form ready to send. A bot trap is never one either: a box
     moved off the page or hidden from assistive tech, with no visible label (cashmereai.com's honeypot "botcheck", 9,999 pixels to the left), and a box with no
     label of its own no longer borrows the words of a container that holds other fields (it read its whole form's wording as a certification). Protected by `checks-and-prompts.test.js` and
     `FixturePageTypeUITests.testCheckboxesTickTheRemovingRequestsAndNotKnowOrCorrect` (its page has both).
   - *"Authorized agent? No / Yes" as radios* is a question, not a certification: the page's No is chosen for a person asking for themselves, and the form is sent
     (astoriacompany.com was held on "No * | authorizedAgent"). A box that states "I am an authorized agent" is still a statement and waits for the person.
     Protected by `CoreTests.testARequiredAuthorizedAgentQuestionDoesNotHoldTheForm` and `FixturePageTypeUITests.testARequiredAuthorizedAgentRadioQuestionIsAnsweredNoAndTheFormSent`.
   - *A box that appears once another is filled* (adagio.io builds its State menu when Country is set): every fill reads the form again after filling and fills
     the new boxes (`WebAssistedPage.refill`). A box or menu that already shows the person's value is never set again (`fill-live`), because setting it again fires
     the page's change event and such a page rebuilds the box the app is about to fill. Protected by `fill-live.test.js` and
     `FixturePageTypeUITests.testAStateMenuThatAppearsOnceCountryIsSetGetsThePersonsState`.
   - *Request-type menus* (a type-to-search menu or a list: azira.com's TrustArc form) take deletion, then opting out; a request to see, correct, update or move the
     data is never chosen, not even as a list's last option (which was the fallback, and chose "Correct or Update My Information"). A type-to-search menu that did not
     open on the first press is pressed once more (focus and the down arrow). "I am" with Agent / Individual takes Individual. Protected by `menus-and-sending.test.js`
     and `FixturePageTypeUITests.testTypeToSearchMenusGetIndividualAndDeleteNotCorrect`.
   - *"I am a (an)" with only one answer that is not an agent* (Customer / Authorized Agent, blueaction.io) takes that answer. Protected by
     `choose-request-options.test.js` and `testAnIAmMenuOfCustomerOrAgentGetsCustomer`.
   - *Tile questions*: "Are you an authorized agent ...?" gets No, and "Select a Requestor Type" gets Consumer even when it is the only tile (blackbaud.com's OneTrust
     form). Protected by `fill-helpers.test.js` and `testAFormBuiltLateWithTileQuestionsIsFoundAnsweredAndSent`.
   - *A state list without the person's state* (becausal.com lists only the 19 states with privacy laws) is never answered with another state: the form waits, and the
     app says "your state is not on its list". Protected by `fill-helpers.test.js` and `testAStateListWithoutMyStateIsLeftForMeAndSaysSo`.
   - *Home-made menus* that show only a placeholder ("Choose state", "Select …") over a list of options hidden until pressed (saymine's portals, 360mediadirect.com) are pressed and the person's state (or consumer / none / other) is picked, like an ARIA combobox (`custom-menus-open`, `custom-menus-pick`). A closed list is hidden by `visibility` and `opacity`, not `display`, so its options keep their size: only an option that shows counts (2026-11-24: the opener took State's closed list for open and never pressed it, and the picker could click the closed Country list's hidden "United States"). Before this the State box stayed on "Choose state" and the page said "This field is mandatory". When a page still says that under a box after a send, the result names the box ("the site says a required box was left empty: State", `FormRun.requiredBoxLeftEmpty`, `testARequiredBoxLeftEmptyIsNamedNotReportedAsNoSuccessMessage`), not "no success message was shown". Protected by `menus-and-sending.test.js` and `FixturePageTypeUITests.testAHomeMadeStateMenuIsOpenedAndGetsThePersonsState`.
   - *A Country or State menu the page set to another place* (360mediadirect.com's saymine form and blackbaud.com's OneTrust form showed "Mexico" on the phone, from where the page placed it, and then said requests are not taken there) is opened and set to the person's country and state, as a plain `<select>` already is (`fill-live`); only a menu whose own block is titled Country, State or Province, and never a menu about a company. Protected by `menus-and-sending.test.js`.
   - *Type-to-search menus whose typing box is see-through until typed into* (react-select: choreograph.com's "select your country of residence", then "select your state") are judged by the box around them, and a value that reads as a prompt ("select your country of residence") is no choice: the country is set to the United States, then the state; choreograph.com lists only the 17 states with privacy laws, so for Illinois the app says the form does not take requests from the person's state (2026-11-24: it said "no opt-out form was found"). Protected by `menus-and-sending.test.js`.
   - *Bot traps* ("honeypots", `bot-trap`): a box hidden from assistive tech, off the page, or out of the tab order inside a box one pixel tall. The arrests.org portals add two or three with labels made of random words from the page ("Privacy Address", "Request: Authorization: of") that change on every load; the run took them for required choices ("the form needs a choice we cannot make for you (Privacy Address)"). A trap is not a visible box (`discover-forms`), is never filled, ticked or chosen (`choose-request-options`), and never "a required box still empty" (`empty-required-choice`). Protected by `discover-forms.test.js`, `fill-helpers.test.js` and `choose-request-options.test.js`.
   - *A request form of only choices* (blueprintaudiences.com: deletion, opt out, ..., "Submit Privacy Request", and no box: its data holds no names) is sent with its choices made, as a step of only choices is (`LiveFormPicker.isChoiceOnlyRequest`); so is *a choice of which identifier to give* with Email among them (privacy.sojern.com: Cookie, Mobile, Email, IP Address): Email is chosen, its box appears and is filled as a new form, and of several send buttons (Export, Delete, Opt Out) Delete is pressed, then Opt Out, never one that only shows or downloads the data (`press-live-submit`). Protected by `LiveFormPickerTests.testARequestFormOfOnlyChoicesWithARemovalIsSent`, `choose-request-options.test.js` and `menus-and-sending.test.js`; the Sojern sequence end to end is not in a fixture yet.
   - *"Authorized agent?" named only in code* (`authorizedAgent`, astoriacompany.com's No / Yes) is the agent question: No.
   - *Age range or group* menus get the age as a number, and the page's own bracket ("18-34", "35 - 49", "50+", "under 18") that holds it is picked; a text box asking for a range is left empty.
8. **A box's own limit is respected.** A box with `maxlength` gets the first candidate that fits: the message box takes the short request
   ("Please delete my personal information and stop selling or sharing it.") when the long one does not fit, and anything else is cut at a sentence end.
9. **Rich-text message boxes are boxes.** A `contenteditable` or `role=textbox` element is found like a textarea (inside a form, or loose beside real inputs; one alone, such as a comment box,
   is not a form), filled through the editor's own typing command so it fires the page's events, and counted by the "required box still empty" check.
9a. **A form that checks itself is sent.** Once the person has touched the page, a form the browser checks is not pressed with a required box still empty (the
   browser would scroll to it); a form marked `novalidate` checks itself, so it is pressed (the arrests.org portals mark both "for myself" and "authorized
   agent" required, one ticked is enough, and the browser's own check held every one back as "a required box is still empty"; `press-live-submit`,
   `press-submit`). A send button that then reads "Submitting…" or "Sending…" is sent, not confirmed (`FormRun.saysSending`; cashmereai.com), which counts as sent.
   A picture code to type beside its box (OneTrust's webforms, blackbaud.com) is a human check: "Blocked by a human check (a captcha code to type)"
   (`visible-challenge`).
10. **Known gaps.** Forms inside web components (shadow DOM) are not found; a multi-select menu gets one option; a format that only the site's server rejects, with
    nothing shown on the page, cannot be retried.

Every change to these rules is checked against all the forms the directory recorded (`opt_out_form` in `directory/*.yml`, about 2400 boxes): fill each with a test person
before and after and compare. The multi-value comparison (a person with three emails, two phones, three addresses and a maiden name and nickname) changed 10 boxes across the recorded forms, all of them improvements: alternate phone, nickname/maiden name, "Emails"/"Phone Numbers" lists, and one hash box that used to get an email now stays empty. The one before changed 17 boxes, all of them corrections (the two it first got wrong, "Confirm Email" and a textarea saying "handle your request", were fixed and have a test).

- **A page the person has touched is never scrolled by the app.** The touch tracker marks the page on the person's first touch (`window.__ookUserAt`); from then on
  no page script scrolls (the form, the check, a tile, a menu, an "Add another" button, a confirm button): each of their `scrollIntoView` calls checks it.
  Before this only the scroll helpers did, and a fill that pressed a tile or opened a menu could still move a long page the person was reading
  (`FixtureScrollUITests`; failed on GitHub's slower runner). A script that focuses a box (a rich-text box it types into, a search-style menu it opens) uses
  `focus({preventScroll: true})`, since a plain focus scrolls the box into view. And once the page is touched, send is not pressed on a form whose required box
  is still empty (`press-live-submit`, `press-submit` answer `invalid`): the browser would only scroll to that box under the person's finger and send nothing.
  The app says "a required box is still empty" and leaves the page to the person.

- **After pressing send**, the app waits for the page to start answering before reading it: the page changes or a load begins, at most six seconds. Then it
  lets the page settle, and a page is never settled while a load is under way (`PageSettle.quietLook`, `testAPageIsNotSettledWhileANavigationIsUnderWay`).
  Every press of send waits this way (`settleAfterPress`): the background run, Solve and send and the guided flow. Read too soon, a form that was sent looked like
  "nothing on the page changed after sending" on a slow machine (GitHub's runner). The background run's own press had no such wait at all, so the status
  page counted a sent site as not sent. A page that replaced the form with "Processing your
  request... Please wait... Do not close this page" has not confirmed anything: it is recorded as sent but not confirmed, which counts as sent (`FormRun.saysStillWorking`,
  `testAPageSayingItIsStillWorkingIsNotAConfirmation`), where before the result depended on how long the run happened to wait.

- **A type-to-search menu for where the person lives gets their state picked from its list.** The fill types the state into a box it reads as a state
  ("IL"), which in a type-to-search menu only filters the list; the type-ahead step then types the full name and chooses the option that is exactly it
  (`type-ahead-open`, `type-ahead-choose`). It finds a box by its label, `aria-label`, its group's label or the text its `aria-labelledby` points to (TrustArc names
  its menus only that way: dnb.com's required "Resident of", whose list has the US states and no "United States", was left on "IL" and the run stopped on "a
  required choice"). A box about a company ("Country / Territory of Registration of Company 1") is never the person's and is left alone.
  The match is taken as soon as it shows, looked for every 0.15 s for up to 5 s, and a list that closed is opened again with the down arrow in the box
  (2026-11-24: TrustArc's "Resident of" on azira.com listed "Illinois" for under half a second on a phone; the app looked once after 0.7 s and left the box
  holding the typed text, scrolled to "linois"). Once chosen, such a box empties its own text and shows the choice beside it (in a hidden field named after
  the box): `empty-required-choice` counts it as answered, where it read as "a required choice" and held the form. "I am a" takes "Data subject making a
  request", never the authorized agent (dnb.com, eyeota.com, netwisedata.com).

- **A portal whose form appears only after its menus is answered.** When a page has no form yet but has empty menus that open one ("select your country of
  residence", then "select your state", then request links: choreograph.com), the menus are answered (a menu of countries takes the United States, a menu
  of states the person's), the request is chosen ("delete and opt out" is pressed over "opt out" and "do not sell"), and the page is read again. A menu of US
  states that does not list the person's state (a portal for states with a privacy law only) gets nothing: never another state by the menu's
  last-option rule, which would have chosen "virginia" for a person in Illinois. The site then says its form "takes requests only from the states it lists"
  and offers the email (`custom-menus-pick` answers `not-offered:`; `WebViewSession.stateNotOffered`). A menu about a company ("Country / Territory of
  Registration of Company 1", dnb.com) is never opened (`custom-menus-open`).
- **An agent's box beside a "for myself" box is an option, not a certification.** "Submission Authorization *" as two boxes, "I am submitting this request for
  myself" and "I am an authorized agent ... on behalf of someone else" (coloradoarrests.org): "for myself" is ticked and the agent's box left unticked, where
  the agent's box used to hold the form as something to certify. A lone "I am an authorized agent" statement still waits for the person
  (`FormFiller.plan`, `testAnAgentBoxBesideAForMyselfBoxIsAnOptionNotACertification`).
- **A Cloudflare check that passes by itself is waited for.** A managed Turnstile shows "Verifying..." and, for most visitors, passes on its own in a few
  seconds; nothing is clicked or solved. Before judging the page, the background run waits for it (up to 12 seconds, within the site's time), and sends once
  its token is there. A check that asks for a person is still theirs (`LiveForms.liveSteps`; fixtures `turnstilepass` and `turnstile`). A check's own status line ("Success!",
  "Verified") is never a confirmation (`FormRun.isCheckStatus`): on GitHub's slower runner the check passed after the fill, its "Success!" was read as the site
  taking the request, and the site was recorded as sent with its form never pressed (`testAHumanCheckSayingSuccessIsNotAConfirmation`).
- **A typed box gets focus and blur events too**, as events only: nothing takes real focus, so no keyboard comes up and nothing scrolls. A page that floats a
  box's label out of the way on them (comscore.com's "First Name *") otherwise showed its label over what was typed.
- **A State menu is filled again after a Country is chosen.** A page may clear or rebuild its State menu from its own Country change handler, after the pass
  that chose the country (comscore.com was left on "Please make a selection"). The fill says when it chose a country, and one more pass fills what that left
  empty a moment later (`fill-live` returns `again`; `fillLive`). A menu already showing an option that holds the person's value ("United States of America"
  for "United States") is not set again, since setting it fires the handler once more.

- **A request wizard is answered step by step.** A step of only choices with Next ("What would you like to do?", "Who is submitting this request? Myself";
  the choices may be screen-reader-only radios behind cards) is not a form "we could not match to your profile": its choices are made and Next is pressed
  (`LiveFormPicker.isChoiceStep`). A press of a form whose only way forward is Next or Continue (`movesToNextStep`) is always the next step, never a send,
  even when the step it leaves vanishes (which otherwise reads as the site taking the request); the step that appears is adopted, filled and pressed in turn,
  up to its Submit. privacy.datarate.ai stopped on its second step with "We could not match any of this form's fields to your profile."

- **A search that finds nobody is an answer.** A form that searches before it removes can answer "No data was found" (or "No records found", "We could not
  find any records"): the site has nothing to opt out of. That answer, read in what appeared after pressing and before any error wording, ends the site as not
  listed (`FormRun.saysNoRecordFound`, `SubmitOutcome.notListed`); the form is not pressed again. A line that only explains ("If no records are found, ...") does
  not count. The answer counts the same when the person pressed the page's own Submit (after ticking a human check), read by `PageFlow.watch` while it
  watches the page. What it means for the site's status: docs/AUTOMATION.md.

- **A check asked for after sending is a human check.** A page that answers a send with "Please complete the verification challenge" (the Superset forms:
  gsdsi, fourleaf, gather analytics, graph8), "Please complete the security verification" (jmr-media.com), "Please complete the security check" (instantly.ai),
  "Verify you are human" or "Captcha is required" is a human check the person clears (`FormRun.asksForHumanCheck`, "a human check the page asked for after
  sending"), not an error or "no success message". A page whose form cannot be used until a visible check is passed (allwebleads.com's reCAPTCHA with Submit
  off) is that check, not "no opt-out form was found", and so is a form whose boxes the app could not fill when a check shows on the page (LiveRamp's device
  opt-out, which adprime.com uses: an ad-ID box and a reCAPTCHA; it said "We could not match any of this form's fields to your profile"). Such a site's line
  says "Blocked by a human check" (docs/UX.md).

- **A page working out of sight never takes the keyboard.** A background run's page is parked invisibly in the app's window, and many brokers' pages put the
  cursor in their first box (`autofocus`, or their own script), as do the app's own scripts that focus a box. Parked, the web view refuses to become first
  responder (`NoAccessoryWebView.parked`), so no keyboard comes up over the screen the person is using and a box they are typing in keeps it. The page's own
  focus still moves, so filling is unchanged. A page handed to the person (`presentable()`) takes the keyboard as usual
  (`FixtureJourneyUITests.testARunNeverBringsUpTheKeyboardWhenItsPagesFocusABox`, fixture `autofocus`).

## One form, one submission

A form is sent once, however many emails, phones, addresses or names the profile holds. The app never submits the same form again to cover another value: repeat
requests to one site can look like spam and get the person blocked. Extra values go into the form's own boxes (including boxes added with its "Add another" button)
and, for whatever has no box, into the message box as "I may also appear under other emails: …". A form with neither simply gets the first value of each kind.

## Opt-out emails carry the whole profile

The person used for forms (`AppModel.formPerson`) puts the household's own form address first and keeps every other email of the profile after it, so further email boxes and the "other emails" line still have them.

Every opt-out email (the batch message to several companies and the single-company message) is built from `EmailIdentity`, which lists the current name, email and
address, then the history: "Other names I have used", "Other email addresses I have used" and "Previous addresses" (with the years when known). A company that asks for a
phone number also gets "Other phone numbers"; a company matched by advertising ID (ad tech, location data) gets the names and emails but no postal history. The same body is used by the
Email screen, the assisted run and the automatic run (`emailBody(for:)`).

## Not sending while the person is typing

A bot-check or code box the person typed in blocks auto-send: `codeBoxInUse` is true while the box holds something they typed (`data-ook-user`) and it has the
cursor (up to 12 s without a key) or was typed in within the last 3 s. Before this, only an empty box blocked, so the first letter typed let the send go
(monitorbase.com). A box the app filled is never waited on. Tapping out of the box or pressing Return ends the wait at once.

## Addresses the directory gives us

Every `contact_email` is cut of sentence punctuation and checked when the directory loads (`ContactEmail.cleaned`: `legal@altrata.com.` becomes
`legal@altrata.com`; what is not an address, such as an image file name, is dropped). `testEveryDirectoryAddressIsValidAsWritten` also fails when a `directory/*.yml` carries a bad one.

A well-formed address can still be dead: `privacy@agedleadstore.com` bounced (`525 5.7.13 Disabled recipient address`), so the directory now uses the
`info@agedleadstore.com` its own opt-out page lists. A bounce reported by a person is fixed by editing that site's `contact_email` (and its `contact_email_source`) in `directory/`.
`privacy@tauxbe.com`, the only address Tauxbe's policy gives, also bounced (`550 5.7.1 Recipient address rejected: User email address is marked as invalid`) and no other address is published, so its `contact_email` is removed and the site is a manual one (the policy page lists phone 704-951-4333 and P.O. Box 349, Mount Holly NC 28120; its "Do Not Sell" page link does not exist).
`lexisnexis.com` uses the consumer portal's Opt-Out/Opt-In form (`consumer.risk.lexisnexis.com/optrequest`, posts to `/optSubmit`, a visible reCAPTCHA, asks for SSN or driver's licence as proof of identity) instead of the privacy-center form (`www.lexisnexis.com/global/privacy/privacy-center-us.page`), whose Submit hangs with no message: the reCAPTCHA works there, but the POST to `/systems/formsapi/api/international/pushdata2` never comes back and the page only logs the failure (checked 2026-11-09, in Chrome too). Deletion and access requests under state law are a separate portal form, `consumer.risk.lexisnexis.com/request`.
`transunion.com` was recorded with no opt-out page because the pipeline's fetch gets a 403 "wall" from it; its privacy portal (`www.transunion.com/consumer-privacy`: opt-out, delete, copy or correct, with a Submit Request into `service.transunion.com`) opens fine in a real browser, so the directory now points there (2026-11-09). 40 sites carry the same `wall` mark and 139 have no `opt_out_url`: each needs a look in a real browser, not a script.
2026-11-09: 25 sites that had no opt-out page got one from `tools/guess_optout_pages.py` (opens each site's home page and the usual privacy-page paths in a real browser and scores them; a person confirms) and were then loaded by `tools/live_forms.py`: 9 now read as semi-automatic (a form was found on the page), the rest are guided (page known, form not readable). The method is decided by `OptOutMethods.classify`, never by the old `automation:` field. `agedleadstore.com`, `archives.com`, `finthrive.com`, `pmg.com` and `spycloud.com` are on the survey's list of sites whose pages point at sign-up or search forms (`testSitesTheSurveyFoundPointingAtSignUpFormsAreNeverFilled`), so they stay guided even though a form was found; finthrive's OneTrust webform and spycloud's datasubject.com portal look like real request forms and could be taken off that list after a review. 60 more sites that refuse automated visits (including real Chrome) were not reachable and still need their pages found by a person.
`everyjoe.com` (the ThisNation engine) was a plain semi-automated site whose "form" was the name search in its page header, so Send pressed a search and no confirmation ever came (seen on a phone, 2026-11-10). Nothing in the app had been lost: it never had a flow for this site. Its real removal is: find your record by searching on the site (a JavaScript typeahead, so the app cannot search for you), copy the record's link, paste it into `/do-not-sell/`, enter an email on the next page, then tap the link in the confirmation email. It is now the hand-written walkthrough `brokers/thisnation.yml` (covering `everyjoe.com`), with the name-search form removed from the directory entry; `ThisNationFlowTests` pins it.
2026-11-11: `tools/live_forms.py` was run again on the 164 guided sites that have a page but no readable form; 115 finished (the other 49 are the slowest or blocked sites, left for the manual review in `tools/build_site_review.py`). It found a form on 36. 19 are now semi-automated (`datadelivers.com`, `familytreenow.com`, `graph8.com`, `greatlakeslists.com`, `hightouch.com`, `hireez.com`, `madhive.com`, `onaudience.com`, `paramountdirectmarketing.com`, `penlink.com`, `peoplefinders.com`, `plungedigital.com`, `privco.com`, `socialcatfish.com`, `spydialer.com`, `telesign.com`, `truepeoplesearch.com`, `windfall.com`, `you.com`). 15 found forms were left out after looking at the pages: contact, enquiry, sign-up and "scan your site" forms (`sharethrough.com`, `sharelocalmedia.com`, `plug-industries.com`, `dealmachine.com`, `lightboxre.com`, `revealmobile.com`, `datadecisionsgroup.com`), privacy policies with no request form (`sovrn.com`, `grayhairsoftware.com`, `graze.social`, `agrmarketingsolutions.com`, `tripwiredata.com`), and the sites on the sign-up survey's list that stay guided (`pmg.com`, `jungroup.com`, `agedleadstore.com`; `convergemarketing.com` and `swoop.com` too, by `testSitesTheSurveyFoundPointingAtSignUpFormsAreNeverFilled`).
2026-11-11, from a person's review: `crexi.com` goes to its BigID privacy center (`crexi.bigidprivacy.cloud/consumer/`), `cyberbackgroundchecks.com` to `/do-not-sell` (a Clym widget in a frame: the app cannot read it, so it stays a guide), `applovin.com` is email only (`dataprotection@applovin.com`, from its policy), and `affordablebackgroundchecks.com` has no request form and no email, only a contact form, so that form is its form: `LiveFormPicker.contactFormRoutes` lets the picker take a contact form (name, email, a message box) on that one site, the request goes in the message box, and a contact form is refused everywhere else (`testTheContactFormOfASiteThatTakesRequestsOnlyThereIsPickedAndNoOtherContactFormIs`).
`tools/policy_links.py` reads each site's own privacy policy and lists every link in it with its text and sentence, every email and every frame, scoring the ones that look like a request (portal hosts such as OneTrust, TrustArc, DataSubject, Securiti and SayMine; "submit a request"; opt-out words; industry-wide opt-outs like NAI and aboutads are marked down); 247 sites on 2026-11-11, 122 with a candidate. It found the real form for many guided sites (for example quotefinders.com's TrustArc form and illumin.com's request page).
The pages the policy scrape found were then loaded in the live scan (69 sites, 56 finished): 19 had a readable form and are semi-automated (`mobilityglobal.com`, `iqviadigital.com`, `finthrive.com`, `eab.com`, `affinity.solutions`, `zetaglobal.com`, `wiland.com` on OneTrust web forms, `cognism.com` on SayMine, `finsum.com` on a Smartsheet form, `attomdata.com`, `koddi.com`, `crunchbase.com`, `enformion.com`, `dealmachine.com`, `lightboxre.com`, `postpilot.com`, `mrginc.com`, `mailinglists.com`, `sovrn.com`); 25 sites that had no page now have the policy's own page (guided). `attomdata.com`, `finsum.com` and `finthrive.com` came off the sign-up survey's list in `testSitesTheSurveyFoundPointingAtSignUpFormsAreNeverFilled`, because their new pages are request forms, not the sign-up pages the survey flagged. Left out: `agedleadstore.com`, `sharelocalmedia.com`, `firstdirectmarketing.com`, `decide.co` (a contact form or a policy page, not a request form).
2026-11-15, three more bounces reported from a phone (`550 5.1.1 User does not exist`): `info@searchsystems.net` (`publicrecords.searchsystems.net`), `info@top4backgroundchecks.com` and `privacy@phantomdata.io`. Their domains take mail (MX records exist) but those mailboxes do not, and their privacy pages publish no other address, so each `contact_email` is removed: the first two are manual sites, and `phantomdata.io` keeps its found form (`app.phantomdata.io/do-not-sell`).
2026-11-15, a 404 seen on a phone: `fushiamedia.com`'s recorded page `/request-delete` is gone; its privacy page now links `/request/delete`, a script-driven form with no `action` (so the old recorded GET form was wrong). The recorded form is dropped and the page is set as the live form, which the app reads and fills like any other semi-automated site.
2026-11-15, TransUnion: `privacy@transunion.com` (found by a browser scan) answers every message with an automatic reply that says privacy requests must come through its self-service portal and that nothing else is acted on. Its `contact_email` is removed, so the site is the semi-automatic "we found the opt-out page" route to `www.transunion.com/consumer-privacy` (which a script cannot read, so the person fills it in and taps Mark as done), and the app no longer offers to write an email that is ignored. The same check is worth making for the other credit bureaus and any site whose policy says email requests are not accepted.
2026-11-15, `ididata.com` could not be submitted (seen on a phone): its recorded page `/opt-out-policy/` is IDI's non-disclosure form for people with a legal right or a risk of harm (it requires one of those two bases, asks for the law or threat, and its own text says residents of the listed privacy-law states should use the Do Not Sell page instead), so the app was filling a basis nobody can honestly claim. The directory now points at `/do-not-sell-my-personal-information/`, the CCPA form (name, address, six-month residence, phone, email, birth date). That page and the old one hide a bot trap (`.hpvalidcheck`: `height:0; overflow:hidden; left:-8000px`) whose menus and "I agree" box make the page's own submit silently do nothing if anything is put in them; a field is now never treated as visible when it is off-screen or inside a zero-height clipped parent (page scripts `discover-forms`, end to end `bottrap`, a guard: the fill was not seen touching the trap in the fixture).
2026-11-15: on the no-form screen of a site whose address was found on its own page (`socialcatfish.com`), Write the email did nothing, because the screen built the message from the directory entry (no address) instead of the offer's entry that carries the found one. It now uses `AssistedRunner.noFormEntry`.
2026-11-16, "We aren't autofilling" (Redi-Data, Definitive Healthcare: forms built by the page's script, empty on a phone with the cursor in the first box). Every fill (`WebAssistedPage.refill()`: the first fill, Fill again in the ••• menu, and the fill before each send) now reads the page again first (`adoptNewForm(force: true)`): boxes and forms that appeared after the first look are tagged and filled too, where before only the boxes tagged at first discovery were. That rescan ignores the "you are typing" pause, because the person asked for the fill, so an empty box they are in is filled as well. What they typed stays theirs (a box with real input carries their mark and is never overwritten). The page watcher's own rescans (`PageFlow.watch`, terms, scrolling) still wait while they type.
2026-11-17, `peoplewhiz.com` (seen from Email links): its removal page opens on a name, city and state "Search Now" form under "Remove Your Personal Information From Our Search Results", which `LiveFormPicker.score` rated 1 (the "search" button counts as marketing, -6) against the 3 it needs, so nothing was filled and Fill did nothing. A "Search" / "Search Now" button no longer counts as marketing when the form's heading, the page's address, title or opening words say to remove your information, opt out, do not sell or delete (hyphens count, so `/remove-my-info` does). The same search box under a plain page, such as the top of its privacy policy, is still refused.
A scan of every directory address's domain (2026-11-05) found two more: `fullcontact.com`'s was an image file name (`privacy-how-1@2x.png`, removed) and `usdatacorporation.com`'s policy
misspells its own domain (now `info@usdatacorporation.com`). `generitech.com` (shared by eight entries) has no MX record but its host accepts mail, so it stays.

## What each rule is protected by

| Behavior | Test |
| --- | --- |
| Digits only, and no `+1` beside a country-code menu | page scripts: `fill-live` ("a phone is typed as plain digits"); end to end: `FixturePageTypeUITests.testAPhoneBoxBesideACountryCodeMenuTakesTheNumberAlone` |
| A person's edit survives a refill | page scripts: `fill-live` ("what the person typed or changed is theirs"); end to end: `FixtureJourneyUITests.testAWordIChangeInTheFormIsNotUndoneWhenTheAppFillsAgainAndSends` |
| Something the app did not type is not overwritten | page scripts: `fill-live` ("a box that already holds something keeps it") |
| A value the app typed is replaced when the plan changes | page scripts: `fill-live` ("... unless it is what this fill typed before") |
| An error on a phone box is retried in other shapes | page scripts: `phone-format-step`; end to end: `FixturePageTypeUITests.testAPhoneBoxThatWantsParenthesesAndADashGetsThePhoneInThatShape` |
| A phone split over three boxes (3, 3, 4 characters) gets one part per box | page scripts: `fill-live` ("a phone split over three boxes") |
| A date box follows its placeholder and is retried in other shapes (day first) | page scripts: `date-format-step`, `fill-live` (birthdates); end to end: `FixturePageTypeUITests.testADateBoxThatWantsYearMonthDayGetsTheBirthDateInThatShape` |
| A LinkedIn box gets the profile's optional LinkedIn address only when one was entered; nothing is invented, and other social boxes stay empty | `CoreTests.testALinkedInBoxTakesTheProfilesLinkedInAddressOnlyWhenOneWasEntered` |
| An identifier, someone else's name or a social profile is never filled with the person's own details | `CoreTests.testIdentifiersAndSomeoneElsesNamesAreNeverFilledWithThePersonsOwnDetails` |
| A phone box that mentions a country code, or says "cell", is the phone | `CoreTests.testAPhoneBoxThatMentionsACountryCodeIsThePhoneAndACellBoxIsAPhoneToo` |
| "First and last name" is the full name; a previous address is the second one | `CoreTests.testFirstAndLastTogetherIsTheFullNameAndAPreviousAddressIsTheSecondOne` |
| A street split in two, and a second line | `CoreTests.testAStreetSplitInTwoAndASecondLineAreEachTheirOwnPart` |
| Only today's-date boxes get today; month and date-time pickers get their own shape | `CoreTests.testOnlyTodaysDateBoxesGetTodayAndEachPickerGetsItsOwnShape` |
| Age-range menus, second emails, short message fallback, last name beside a business name | `CoreTests.testAnAgeRangeMenuGetsTheAgeToMatch...`, `testALastNameBesideABusinessName...` |
| Several email, phone and previous-address boxes take the profile's values in order; other names fill their own boxes; leftovers go in the message | `CoreTests.testSeveralBoxesForTheSameKindTakeTheProfilesValuesInOrder`, `testPreviousAddressesAndOtherNamesFillTheirOwnBoxes`, `testWhatTheFormHasNoBoxForGoesInItsMessage` |
| A box for a whole list gets the list; a hash box stays empty | `CoreTests.testABoxForAWholeListGetsTheListAndAHashBoxStaysEmpty` |
| An opt-out email carries every name, email and past address (phones only for companies that ask) | `CoreTests.testAnEmailCarriesEveryNameEmailPhoneAndPastAddress` |
| Words inside another box's name or a sentence do not make it someone else's (Confirm Email, "handle your request") | `CoreTests.testWordsInsideAnotherBoxsNameOrSentenceDoNotMakeItSomeoneElses` |
| Month and date-time pickers, an age-bracket menu, a box with a small limit, a rich-text box, a cell number, a split street, an SSN box left empty, all on one page | page scripts: `fill-live` (menus, age brackets, limits, rich text); the plan for each box: the `CoreTests` above |
| A business's address, email and phone are left empty | `CoreTests.testTheBusinessRelationshipBoxesAreLeftEmptyAndTheirOwnAddressIsStillFilled` |
| A check the person is typing in holds the send | page scripts: `code-box-in-use`; the runner: `SemiAutomatedFlowTests` |
| A date box follows another that had to be retried | page scripts: `align-date-formats` |
| Directory addresses have no trailing punctuation | `CoreTests.testAnAddressFoundInASentenceLosesTheSentencePunctuation`, `testEveryDirectoryAddressIsValidAsWritten` |
| Hand-off sites never get a send | `AssistedRunnerTests` (`handsOff`, `blockWidget`) |
| Nothing on a page is judged (a terms prompt, a check, a certification) until the page is on screen: a page in no window is not laid out, its text reads empty, and a form was sent behind an unaccepted terms prompt (1 run in 3 of the `terms` fixture) | `AssistedRunnerTests.testNothingIsJudgedOrSentUntilThePageIsOnScreen`; end to end: `FixturePageTypeUITests.testATermsGateIsNeverAccepted...`, `testAnUnreviewedPromptIsLeftForMeEvenWhenIAllowedTermsInGeneral` |

## Auto-completing the run

The watcher (`AssistedRunner`) refills a page when it changes, presses send when nothing blocks it, and advances when the page shows a confirmation
(`FormRun.classify`, `classifyConfirmed`, `looksFinished`). Anything the person must do (a human check, terms, a code, a menu with no choice for them)
pauses it; the person finishes, and "Mark as done" is always the fallback. Because a refill happens while the person is typing, rule 3 above is what makes
that safe.

2026-11-13: a guide for a site with no recorded form (`GuidedPlanner.plan(for: DirectoryEntry)`) opens the page the live check found the form on (`live_form.page`) in preference to `opt_out_url`, which for `draup.com` and `acronymix.com` was a sales home page. Test: `testAGuideWithNoKnownFormOpensThePageTheLiveCheckFoundTheFormOn`.
