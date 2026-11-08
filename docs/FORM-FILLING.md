# Finding forms and filling them in

How the app finds an opt-out form on a live page, fills it, and keeps its hands off what the person has done. The code is in
`App/Sources/LiveForms.swift` (finding and filling), `AssistedOptOut.swift` (the semi-automatic run and its watcher), `WebViewFetcher.swift` (what the
page says afterwards) and `Packages/OptOutKitCore/.../FormFiller.swift` (which value goes in which field). Tests: `AppTests/LiveFormTests.swift`,
`AssistedRunnerTests.swift`, `FormFiller` tests in the core package.

## Finding the form

- The page is loaded in a web view kept at phone size; cookie prompts are denied; forms are discovered in the page and in its frames
  (`discoverForms`, `discoverFormsDeep`). Each input gets a `data-ook` token so later passes find the same box again.
- `LiveFormPicker.score` ranks forms: an opt-out or privacy form beats a newsletter or free-trial box. A form is only filled if it scores high enough.
- A choice on the page ("Who is this request for?", "Remove my information") can reveal a second form. The watcher notices a form it has not seen
  (`adoptNewForm`) and fills only its empty boxes.
- Sites that are not a form at all are handled by hand-off, and the app never presses send on them: block widgets (`usatrace.com`,
  `quickpeopletrace.com`: the person taps Block Profile) and per-record sites (`open-public-records.com`: each record has its own removal form).
  See `AssistedRunner.Item.handsOff`.

## Filling it in

`FormFiller.plan` chooses a value for each field from the person's profile; `fillLive` types them into the page. Rules that must keep holding:

1. **Phone numbers are plain digits.** No spaces, dashes, brackets or `+`: `7736331564`. A country-code menu beside the box ("United States (+1)") already
   supplies the code, so the box gets the 10 digits and nothing else. The only exception is a box whose `pattern` attribute rejects digits.
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
   - *Age range or group* menus get the age as a number, and the page's own bracket ("18-34", "35 - 49", "50+", "under 18") that holds it is picked; a text box asking for a range is left empty.
8. **A box's own limit is respected.** A box with `maxlength` gets the first candidate that fits: the message box takes the short request
   ("Please delete my personal information and stop selling or sharing it.") when the long one does not fit, and anything else is cut at a sentence end.
9. **Rich-text message boxes are boxes.** A `contenteditable` or `role=textbox` element is found like a textarea (inside a form, or loose beside real inputs; one alone, such as a comment box,
   is not a form), filled through the editor's own typing command so it fires the page's events, and counted by the "required box still empty" check.
10. **Known gaps.** Forms inside web components (shadow DOM) are not found; a multi-select menu gets one option; a format that only the site's server rejects, with
    nothing shown on the page, cannot be retried.

Every change to these rules is checked against all the forms the directory recorded (`opt_out_form` in `directory/*.yml`, about 2400 boxes): fill each with a test person
before and after and compare. The multi-value comparison (a person with three emails, two phones, three addresses and a maiden name and nickname) changed 10 boxes across the recorded forms, all of them improvements: alternate phone, nickname/maiden name, "Emails"/"Phone Numbers" lists, and one hash box that used to get an email now stays empty. The one before changed 17 boxes, all of them corrections (the two it first got wrong, "Confirm Email" and a textarea saying "handle your request", were fixed and have a test).

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
A scan of every directory address's domain (2026-11-05) found two more: `fullcontact.com`'s was an image file name (`privacy-how-1@2x.png`, removed) and `usdatacorporation.com`'s policy
misspells its own domain (now `info@usdatacorporation.com`). `generitech.com` (shared by eight entries) has no MX record but its host accepts mail, so it stays.

## What each rule is protected by

| Behavior | Test |
| --- | --- |
| Digits only, and no `+1` beside a country-code menu | `LiveFormTests.testAPhoneBoxBesideACountryCodeMenuTakesTheNumberAloneAndPersonEditsSurviveARefill` |
| A person's edit survives a refill | same test (first name) |
| Something the app did not type is not overwritten | same test (last name) |
| A value the app typed is replaced when the plan changes | `LiveFormTests.testAValueTheAppTypedIsReplacedWhenThePlanChanges` |
| An error on a phone box is retried in other shapes | `LiveFormTests.testAPhoneBoxThatRejectsPlainDigitsIsRetriedInOtherShapes` |
| A phone split over three boxes (3, 3, 4 characters) gets one part per box | `LiveFormTests.testAPhoneSplitOverThreeBoxesGetsOnePartInEach` |
| A date box follows its placeholder and is retried in other shapes (day first) | `LiveFormTests.testADateBoxThatRejectsTheFirstShapeIsRetriedInOtherShapes` |
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
| Month and date-time pickers, an age-bracket menu, a box with a small limit, a rich-text box, a cell number, a split street, an SSN box left empty, all on one page | `LiveFormTests.testEveryKindOfBoxIsFilledInItsOwnShapeAndTheOnesThatAreNotTheirsStayEmpty` |
| A business's address, email and phone are left empty | `CoreTests.testTheBusinessRelationshipBoxesAreLeftEmptyAndTheirOwnAddressIsStillFilled` |
| A check the person is typing in holds the send | `LiveFormTests.testABotCheckBoxTheyAreTypingInHoldsTheSendUntilTheyStop` |
| A date box follows another that had to be retried | `LiveFormTests.testAnotherDateBoxFollowsTheShapeARetriedDateBoxSettledOn` |
| Directory addresses have no trailing punctuation | `CoreTests.testAnAddressFoundInASentenceLosesTheSentencePunctuation`, `testEveryDirectoryAddressIsValidAsWritten` |
| Hand-off sites never get a send | `AssistedRunnerTests` (`handsOff`, `blockWidget`) |

## Auto-completing the run

The watcher (`AssistedRunner`) refills a page when it changes, presses send when nothing blocks it, and advances when the page shows a confirmation
(`FormRun.classify`, `classifyConfirmed`, `looksFinished`). Anything the person must do (a bot check, terms, a code, a menu with no choice for them)
pauses it; the person finishes, and "Mark as done" is always the fallback. Because a refill happens while the person is typing, rule 3 above is what makes
that safe.
