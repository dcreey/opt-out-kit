# The advertising ID

Some data brokers keep an advertising profile of a phone, keyed by its advertising ID (their forms call it a "MAID" or "IDFA"), and remove that profile only when
given the ID. So Exnay can pass the ID to those forms. This page says exactly what happens, so a person can check it against the code.

## What the app does

- Only when a form (or an opt-out email) asks for the ID, and never before, Exnay asks iOS for permission. The person sees Apple's own "Allow tracking" prompt, with
  our reason in `NSUserTrackingUsageDescription`: the ID is used only to remove their phone from that broker's advertising profile.
- If the person agrees, the ID is read and put into that one form or email. If they refuse, or tracking is off in Settings, the form is filled without it.
- The person can also look at the ID and copy it themselves (About screen, "Advertising ID").
- Code: `App/Sources/AdvertisingID.swift` (the only place the ID is read), the form fill in `App/Sources/WebViewFetcher.swift`, the email path in
  `App/Sources/OptOutKitApp.swift`.

## What it does not do

- The ID is not stored, logged or written to the profile. It is read when needed and dropped.
- It is not sent to Exnay (there is no Exnay server), to an analytics service or to anyone but the broker whose form asked for it.
- It is not used to track the person, to show ads, or to link anything across apps or sites.
- The automatic background run may include it in a form that asks for it, but only if the person has already allowed it. iOS shows the prompt only while the app is on screen, so the run never asks from the background.

## What it means for privacy

- The ID is a device identifier. Giving it to a broker is the point of the opt-out, but it does leave the phone, so the app's privacy labels declare **Device ID**
  (purpose: app functionality) rather than "Data Not Collected". The wording everywhere else says "no server, no account, no tracking by us", not "nothing ever
  leaves your phone".
- Apple's definition of "tracking" includes sharing device data with data brokers. The purpose here is the reverse (removal), but the prompt is Apple's tracking
  prompt, and the app and its listing say so openly.
- Refusing costs little: those brokers' forms are filled without the ID and may not be able to remove the phone's profile. Everything else works.
- Apple's developer terms limit the ID to advertising purposes. Removing a phone from an advertising profile is such a purpose; the App Review notes explain it.

## Where else this is written

- [PRIVACY.md](../PRIVACY.md), "Advertising ID": the policy text.
- [PRINCIPLES.md](PRINCIPLES.md) §2: the commitment it must stay within.
- [FORM-FILLING.md](FORM-FILLING.md): how a form that asks for the ID is filled.
- `store/metadata.md`: the App Store description and review notes.
