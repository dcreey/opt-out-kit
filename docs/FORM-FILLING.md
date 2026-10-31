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
4. **Pre-filled pages keep their values.** A link from an email often pre-fills a name and email (`keepExisting`); those stay.

## What each rule is protected by

| Behavior | Test |
| --- | --- |
| Digits only, and no `+1` beside a country-code menu | `LiveFormTests.testAPhoneBoxBesideACountryCodeMenuTakesTheNumberAloneAndPersonEditsSurviveARefill` |
| A person's edit survives a refill | same test (first name) |
| Something the app did not type is not overwritten | same test (last name) |
| A value the app typed is replaced when the plan changes | `LiveFormTests.testAValueTheAppTypedIsReplacedWhenThePlanChanges` |
| An error on a phone box is retried in other shapes | `LiveFormTests.testAPhoneBoxThatRejectsPlainDigitsIsRetriedInOtherShapes` |
| Hand-off sites never get a send | `AssistedRunnerTests` (`handsOff`, `blockWidget`) |

## Auto-completing the run

The watcher (`AssistedRunner`) refills a page when it changes, presses send when nothing blocks it, and advances when the page shows a confirmation
(`FormRun.classify`, `classifyConfirmed`, `looksFinished`). Anything the person must do (a bot check, terms, a code, a menu with no choice for them)
pauses it; the person finishes, and "Mark as done" is always the fallback. Because a refill happens while the person is typing, rule 3 above is what makes
that safe.
