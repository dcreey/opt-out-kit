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
- Unit tests (the Swift packages and `AppTests`) run on every push (`ci.yml`); integration tests (the UI tests in `AppUITests`) run for a GitHub release
  (`integration.yml`). Every rule a UI test checks also has a unit test, listed in `docs/TESTING.md` ("Unit and integration tests"); add both together.
- A GitHub release (and Integration) is for releasing the app on the App Store, not for TestFlight. A TestFlight upload needs only CI to pass for its
  commit (`tools/release_gate.py --for testflight`, run by `tools/release_testflight.sh`); App Store review needs CI and Integration (`release_gate.py`).
- CI lints Swift, the workflows, YAML, JSON, Python and shell scripts (`lint-*` jobs in `ci.yml`; commands in `docs/TESTING.md`, "Lint"). Run them before pushing a change to those files.
- The app does no file-system work while it runs (docs/STORAGE.md): what it ships is compiled into `Catalog.sqlite` at build time (`Catalog`, `CatalogPlugin`)
  and read through SQLite; what the person keeps is rows of `UserDatabase`. New bundled data goes into the catalog, new user data into a `kind` of the database.
  `tools/tests/test_runtime_file_io.py` fails on any other file API in the runtime sources.
- All YAML follows `.yamllint.yml`: single-quoted string values, block mappings. Tools read and write YAML only through `tools/yamlio.py` (never as text
  with patterns); `pip install -r tools/requirements.txt` first.
- JavaScript the app runs in web pages lives in `App/PageScripts/*.js` (never a Swift string; compiled into the catalog). Every script and every rule in it has a unit test in
  `tools/pagescripts` (`npm test`); `coverage.test.js` fails for a script without one.

## Translations

- Run `python3 tools/l10n.py build` and `check` after adding strings. Never `extract`.
