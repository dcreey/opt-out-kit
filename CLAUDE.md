# Exnay (opt-out-kit)

## Principles

Read `docs/PRINCIPLES.md`. Never add a server, account, analytics, telemetry, paywall or anything that sends a person's data anywhere but the broker; if a task seems to need one, stop and ask.

## Keep the docs current

Every change to behavior updates the docs in the same piece of work, before it is committed:

- Check the docs that cover the area you touched and edit them: `README.md` and `docs/` (`FORM-FILLING.md` for finding and filling forms and sending,
  `UX.md` for screens and walkthroughs, `TESTING.md` for how each flow is tested, `REMINDERS.md`, `DIRECTORY.md`, `LOCALIZATION.md` and the rest as they apply).
- A new rule, flow or screen gets its text, and its test goes in the "protected by" table or the flow table in `docs/TESTING.md`.
- A fix that changes what an older line says is edited in place, so no doc contradicts the app.
- Before saying a task is done, list which docs you checked and which you changed. "None needed" is allowed only when you looked.

## Tests

- Every behavior gets a Mac test where it can (`swift test --package-path Packages/OptOutKitCore`, `Packages/AssistedRunLogic`); otherwise a simulator test.
- The semi-automated "Solve and send" flow is the most trusted: do not break it. Share logic and UI across flows instead of copying it.

## Translations

- Run `python3 tools/l10n.py build` and `check` after adding strings. Never `extract`.
