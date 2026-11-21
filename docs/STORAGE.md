# How the app keeps its data

The app does no file-system work while it runs. What it ships is read from one compiled SQLite file in the bundle; what it keeps for the person is rows in
one SQLite file in its own storage. Nothing is parsed, read or written as a loose file, and the web view keeps nothing on disk.

## What ships: `Catalog.sqlite` (read-only)

Compiled at build time from the repository by the core package's `CatalogPlugin` (`catalog-builder`); the app opens it read-only and immutable. It holds the
sites, the hand-written flows, the official removal services, the laws by place, the registry counts, the terms library, the 55 page scripts
(`App/PageScripts`, in the `scripts` table, read one at a time by `PageScript`), the 40,977 US ZIP codes (`data/zips-us.tsv`, the `zips` table, found by key,
none held in memory) and a full-text index for the Sites search. Details, layout and speed: [DIRECTORY.md](DIRECTORY.md), "The compiled catalog".

The app contains no YAML, no script file and no table file, and does not link the YAML reader (Yams): the loaders that read the repository's YAML live in
the `CatalogSource` module, used only by the build step, the pipeline tool and tests.

## What the person keeps: `exnay.sqlite` (read-write)

One file in the app's Application Support folder, opened through `UserDatabase`. One table, `sealed (kind, key, body, saved)`, with one row per thing:

| `kind` | `key` | Holds | Was, until build 51 |
|---|---|---|---|
| `household` | | Every profile, the progress, the settings | `household.sealed` |
| `evidence` | opaque, see below | The screenshot of what a site showed after an automatic send | `household.evidence/<person id>/<site id>.jpg.sealed` |
| `draft` | | What is typed in the profile editor and not yet saved | `profile-draft.sealed` |
| `setting` | the preference's name | The small preferences and "has seen this" flags: language, the tours, the day's batches, the guide's collapsed state (`StoredPreferences`, a binary property list per value; not sealed: they hold nothing personal, and the app reads them while the phone is locked, before the Keychain key is available) | the app's `UserDefaults` property list |

- **Encrypted: the values, not the container.** Each household, screenshot and draft `body` is AES-256-GCM (authenticated), with the key in the iOS Keychain
  (`SealedStore`, `KeychainKey`): the same bytes the separate files held. The SQLite file itself is an ordinary one: its table layout, the kind of each row,
  the saved times and the sizes of the blobs can be read by anything that can read the file, which is what the separate files showed too (their names and
  modification times). Two things limit that: iOS data protection keeps the file closed until the first unlock and encrypts it at rest, and **the row keys
  are opaque** (below), so the file does not say which people or which sites have a screenshot. A test reads the whole file and finds no name, email, site
  name, person id or picture bytes. Encrypting the container too (SQLCipher) would hide the layout, times and sizes as well; it is a third-party C library
  in place of the one in iOS, and is not used.
- **Opaque screenshot keys.** An `evidence` row's key is `<hash of the person>/<hash of the site>`, an HMAC-SHA256 with a key derived (HKDF) from the household's
  key, so it cannot be worked out from the ids without that key. One person's rows share a prefix, which is how they are removed together.
- **A layout version.** `PRAGMA user_version` is `UserDatabase.schemaVersion` (1). A file of a newer layout than the build knows is refused, not guessed at.
- **Atomic.** A write is one SQLite transaction: after a crash the old value or the new one is there, never half of one (the files were written atomically).
- **Data protection.** The file and its journal are readable after the first unlock since the phone started (`SQLITE_OPEN_FILEPROTECTION_...`), as the
  files were, so the automatic run keeps what it did while the phone is locked in a pocket or charging. Before that first unlock, opening fails and is
  reported as `StorageError.locked`: put off until the unlock, never shown as damage, never a reason to offer erasing.
- **Opening changes nothing.** Opening an existing file, reading from it and asking to delete what is not there write nothing to it, so data the app
  could not read (the wrong key, a locked phone) is never touched, even by the app starting up. A test compares the file's bytes before and after.
- **Erase means erase.** `secure_delete` overwrites what a delete frees and `auto_vacuum` gives the pages back: a removed screenshot is not left in the file.
- **No backup surprises.** The file is in the app's storage and backed up with the phone like the files were, with the key in the Keychain
  ([UX.md](UX.md), "Lost phone means lost data").

### The move from the old files and from UserDefaults (build 52)

Every place builds 1 to 51 ever kept data is moved in the first time it is read, and nothing is deleted before it is safely in the database. There were four, and
they have never been anything else: `household.sealed`, `household.evidence/`, `profile-draft.sealed` and the app's `UserDefaults` (the Keychain item holding the
key stays where it is: it is the system's secure store, not a file).

**The three files** (`UserDatabase.importLegacy`, the first time the household is read or saved):

1. Each old file's sealed bytes are stored **as they are**: nothing is decrypted or re-encoded, so the move cannot change what the file holds.
2. The row is **read back and compared** with the file's bytes; only when they are equal is the file deleted.
3. A file that cannot be read (the phone is still locked) stays where it is, loading and saving throw, and **nothing is saved over a household that was not
   read**. The move is tried again at the next unlock.
4. If a file and a row both exist (a move stopped half way, or an older build ran in between) the newer one, by the file's modification time and the row's
   saved time, is kept.

**The preferences** (`StoredPreferences.importLegacy`, when the model starts): every value in the app's `UserDefaults` domain (the system's own `Apple...`, `NS...` keys
are left alone) is stored as a row, read back and compared, and only then removed from `UserDefaults`; a value already in the database is kept; if the database cannot
be written yet (locked) nothing is removed, and the move is tried again at the next launch. The preferences work in memory meanwhile and are written at the unlock
(`reload()`).

Pinned by `UserDatabaseTests` and `PreferencesTests`: byte-for-byte, an unreadable old household is never saved over, the newer wins, a locked file is reported as locked,
a deleted screenshot is gone from the file, opening leaves the file as it was.

## What is left, and why

- **Translations.** iOS's own mechanism: Xcode compiles the string catalog into `<lang>.lproj` for the system, and SwiftUI reads text through it. (The raw
  catalog is read only when the package is built without Xcode, in tests: `L10n`.)
- **The database's own file**, its journal while a write is under way, and the catalog in the bundle: that is SQLite. `UserDefaults` and `@AppStorage` are no longer used
  (`Preferences`, `@Preference`); the one place that names `UserDefaults` is the one-time move out of it.
- **Debug builds only** (`#if DEBUG`, absent from a release build): the simulator audit tools write what they find to Documents for offline analysis
  (`FormAudit`, `SiteReviewView`, `-export-evidence`).
- **The web view** uses a non-persistent data store, and the network fetcher an ephemeral `URLSession` configuration: no cookies, cache or storage reach the disk.

## Keeping it that way

`tools/tests/test_runtime_file_io.py` (CI's `checks` job) fails on any file API (`FileManager`, `Data(contentsOf:)`, `Bundle.main.url`, `.write(to:)`, ...) in the
runtime sources outside a short allow-list with a reason for each entry, and checks that the web view stays non-persistent and that the YAML reader is not
linked into the app. A new bundled data set goes into the catalog; a new thing the person keeps is a new `kind` in `UserDatabase`.
