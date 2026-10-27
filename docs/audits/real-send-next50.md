# Real sends: the three fixed sites and the next 50 (2026-10-26)

Results: `docs/audits/real-send-next50/results.json` (53 sites).

| Result | Sites |
|---|---|
| Stopped at a check the person must clear (nothing was sent): 14 reCAPTCHA checkbox or puzzle, 3 hCaptcha-style or Cloudflare... see list in the file; 12 certification boxes | 33 |
| Failed | 19 |
| Classifier said "confirmed" | 1 (`occulytics.com`): its screenshot shows only the top of the page, so it is not marked confirmed |
| **Total** | **53** |

The three re-sends: `occulytics.com` (now complete, with "N/A" for its required second address line and the right postal code; the classifier calls it confirmed, but the screenshot does not show an answer),
`growinglibraries.com` (now stops at a reCAPTCHA puzzle, so a person finishes it), and `babelstreet.com` (still "nothing changed": its "I am a(n)" and "Select request type" tiles
stay unselected, because the page does not react to the app's click; a person presses them).

The 19 failures, by cause:
- Needs the person: certify boxes (`usphonebook.com`, `comscore.com`, `melissa.com`), a question only they can answer (`forewarn.com`: how long they lived at the address), a listing link (`clay.com`), a LinkedIn profile (`seekout.com`), a social platform (`captiv8.io`), the phone's advertising ID (`infillion.com`).
- A menu the app could not answer: `i-360.com` and `usdatacorporation.com` (a state menu without Illinois), `lexisnexis.com` (a message menu got the request sentence), `01advertising.com` (a subject menu).
  The two menu cases are fixed: a subject or topic menu now picks "privacy request" or "opt out", and a message-style menu is left alone.
- Fields the app could not match: `usatrace.com`, `indexexchange.com`, `realsourcedata.com` (fields named by code only).
- No form found: `redidata.com`, `thedatagroup.com`.
- Nothing changed after sending: `datapartners.com`, `babelstreet.com`.

Across all 103 real sends in this session's two batches, none has a verified confirmation. The pattern: most of the remaining semi-automatic sites in queue order sit behind a bot check or a certification box, so a real
send tells us the app got that far, not that the request landed. Sites that can only be finished by a person are working as designed.
