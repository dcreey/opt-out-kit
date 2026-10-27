# Real sends of the shared forms (2026-10-27)

The 131 semi-automatic sites that are not individual tasks (50 `courtrecords.us` family members, 57 other family and template members, and 34 singles) fall into 49 groups.
One site per group was really sent: 44 sites. The 5 arrests templates (about 20 sites) all use the "Report an Error" form, so they were not sent. Results: `docs/audits/real-send-shared/results.json`.

| Result | Sites |
|---|---|
| Stopped at a check the person must clear (nothing sent): 22 reCAPTCHA checkbox, 3 Cloudflare, 1 other bot check | 26 |
| Failed | 14 |
| Site showed an error after sending | 3 (`donorbase.com`, `dspolitical.com`, `freewheel.com`) |
| Classifier said "confirmed" | 1 (`oan.pl`), not verified |
| **Total** | **44** |

What the shared forms showed:
- **`courtrecords.us` family (50 sites) and `arizonaarrests.org`'s template:** both sit behind a Cloudflare check, so for those groups a person does the check and the app does the rest.
- **The data-axle family** (`data-axle.com`, `donorbase.com`, `exactdata.com`, `usadata.com`): the form is filled correctly, but a consent box at the bottom ("By submitting, I understand that I may be required to verify...") stays unticked, so the Send does nothing.
  The app does not tick acknowledgements for the person.
- **`dspolitical.com`, `freewheel.com`** (a shared "Do Not Sell My Information" form): first name, last name and email are filled, and the page answers "one or more fields have an error". The cause is not visible; it may need a field the page hides.
- **`awl.com`, `allwebleads.com`:** an unsubscribe form with a reCAPTCHA whose email box stayed empty.
- **Listing forms** (`spokeo.com`, `freepeopledirectory.com`): the app asks the person to pick their listing first, as designed.

Fixed automatically after this round, each with a unit test:
- A field is the person's own listing only when it asks for it. A help sentence that says "link", a LinkedIn address and a cookie ID no longer count (this cleared `dnb.com`, `eyeota.com`, `netwisedata.com`, `cashmereai.com`, which were stopped for needing a listing).
- A "relationship to the company" menu now tries "Consumer, no business relationship", "Consumer", "No relationship", "None", "Individual", "Other" and "Not applicable" in that order (`health-union.com`).
