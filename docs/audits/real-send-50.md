# Real sends: the next 50 sites with none (2026-10-26)

The first 50 semi-automatic sites in queue order that had never been really sent, starting with the kinds that had no confirmed send (arrests, location data, real estate, financial, fraud and
identity, other: 26 sites) and then the rest of the queue in order. The 33 arrests sites whose form is a "Report an Error" form were left out. Raw results: `docs/audits/real-send-50/results.json`.

| Result | Sites |
|---|---|
| Stopped at a check the person must clear (nothing was sent): certification box 17, Cloudflare 8, reCAPTCHA 10, hCaptcha 1 | 36 |
| Failed: nothing on the page changed after sending | 4 (`complementics.com`, `babelstreet.com`, `veraset.com`, `occulytics.com`) |
| Failed: the form wants something the app does not hold or may not tick | 7 (advertising ID: `quadrant.io`, `fogdatascience.com`; certify box: `connectedinvestors.com`, `monitorbase.com`, `completemailinglists.com`; a menu or math question: `ididata.com`, `pipl.com`) |
| Failed: a menu rejected the value (a phone number sent to a country-code menu) | 1 (`growinglibraries.com`) |
| Failed: no opt-out form found | 1 (`buildertrend.com`) |
| Classifier said "confirmed" | 1 (`yobi.ai`), not confirmed: its screenshot shows the filled form, not a confirmation |
| **Total** | **50** |

No site in this batch has a verified confirmation, so none was marked `run_check: confirmed`. As designed, the app stops at every bot check and certification box and never ticks or solves them; the 36
sites that stopped there need a person to finish (those are the semi-automatic sites doing their job).

Bugs the real data showed, both fixed with a test:
- `occulytics.com` has a postal-code box whose code name is "Region-State-Province-2"; the app put the state code in it. The visible label now wins over the field's code name.
- `growinglibraries.com` has a menu beside the phone box (its country-code list); the app tried to pick the phone number in it. A menu beside a phone box is now its country code.

The `yobi.ai` request, and the four "nothing changed" sites, may or may not have gone through; their screenshots show the filled form and no answer.

## Why the 13 failed, and what was fixed afterwards

- **`growinglibraries.com`** (phone number sent to a country-code menu) and **`occulytics.com`** (state code in the postal box): fixed earlier the same day.
- **`occulytics.com`, second cause:** its "Street Address Line 2" is a required box the app left empty, so the form could not send. A required second address line now gets "N/A"; an optional one stays empty.
  The form's required marks (the page's `required` attribute, not only an asterisk in the label) are now passed to the filler, so a required box with nothing to fill stops the run instead of failing silently.
- **`babelstreet.com`:** the form needs two choices made by pressing buttons ("I am a(n)" and "Select request type"), which the app did not press. It now picks "Other" or the plain consumer answer, and the opt-out or deletion request, never access, update or transfer.
- **Not fixable by the app:** a bot check or certify box (`connectedinvestors.com`, `monitorbase.com`, `completemailinglists.com`, `pipl.com`'s math question) and the phone's advertising ID (`quadrant.io`, `fogdatascience.com`, `veraset.com`, `complementics.com`). A person clears them, and the advertising ID is read only on a phone that allows it.
- **Still open:** `ididata.com` asks "have you lived here for more than 6 months?", a fact only the person knows; `buildertrend.com` shows no form since the newsletter rules went in.

Re-audit after these changes (266 sites, dry run): no site lost its form, none got more unfilled required boxes, and five got fewer (`occulytics.com`, `datapartners.com`, `thinkdatagroup.com`, `disconetwork.com`, `maarrests.org`). Results in `docs/audits/after-fixes-2026-10-26/`.
