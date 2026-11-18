# Exnay privacy policy

Last updated 2026-11-17.

**Exnay does not collect your information. There is no Exnay server, no account, no analytics and no tracking.**

## What the app holds

What you type into a profile (names, addresses, emails, phone numbers, birthdate, an optional LinkedIn address) is stored encrypted on your phone, in the
app's own storage. It is not sent to us, because we have nowhere to receive it. If you delete a profile or the app, it is gone; we cannot recover it.

## Where your information goes

Only to the data-broker website you are opting out of, and only the details that site's own form or email asks for. The app fills the broker's page on your phone and, depending on the site, either
sends it itself in the background run you turn on, or leaves the final button to you; emails are sent from your own mail app. Exnay itself never sees these requests and keeps no copy outside your phone.
Each broker's own privacy policy governs what it does with a request.

## Advertising ID

Some brokers opt a phone out by its advertising ID. If a form asks for it, Exnay asks iOS for your permission (the system "Allow tracking" prompt) and, if you
agree, gives the ID to that broker's form so it can remove your phone. Exnay does not store it, never sends it to us, and does not use it to track you. If you
refuse, those forms are filled without it. Because the ID does leave your phone for that broker, the App Store privacy details list it as a Device ID used for
app functionality. Full details, with the code that handles it: [docs/ADVERTISING-ID.md](docs/ADVERTISING-ID.md).

## What the app does not do

- No analytics, crash reporting, advertising, or third-party SDKs that contact anyone.
- No accounts, sign-in or cloud sync.
- No selling or sharing of data: there is none to sell.
- No solving of human checks by a third-party service.

## Network use

The app connects only to the websites of the brokers you open, to pages and email links you ask it to open, and to Apple for installing and updating the app.
Pages the app opens are sent a Global Privacy Control signal that tells the site not to sell or share your data.

## Notifications

Reminders to repeat an opt-out are local notifications scheduled on your phone. No push server is involved.

## Children

Exnay can hold a profile for a child, entered by a parent or guardian. It is stored the same way, on the phone only. The app is not directed at children.

## Open source

The code is public at <https://github.com/dcreey/opt-out-kit> (MIT license), so anyone can check these statements. The commitments behind them are in
[docs/PRINCIPLES.md](docs/PRINCIPLES.md).

## Changes and contact

If this policy changes, the new version is published here with a new date and the change is in the repository history. Questions or concerns: open an issue at
<https://github.com/dcreey/opt-out-kit/issues>.
