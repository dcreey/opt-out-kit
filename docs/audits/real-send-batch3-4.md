# Real sends: batches 3 and 4 (2026-10-26)

Batch 3 was the next 50 sites in queue order, batch 4 the last 11 (`docs/audits/real-send-batch3/`, `docs/audits/real-send-batch4/`). With these, every semi-automatic site in the queue
(266, not counting 6 that use the "Report an Error" form) has had one real send attempt.

Batch 3 (50): 26 stopped at a check (16 reCAPTCHA checkbox, 4 Cloudflare, 3 reCAPTCHA puzzle, 2 certification boxes, 1 hCaptcha), 22 failed, 1 rejected by the site (`thinkdatagroup.com` showed an error after sending),
1 called "confirmed" by the classifier (`disconetwork.com`; its screenshot shows the filled Zendesk "Submit a request" form with "Data Opt Out/Deletion Request" chosen, not an answer, so not marked).
Batch 4 (11): 3 stopped at a reCAPTCHA checkbox, 8 failed. Nothing in either batch has a verified confirmation.

Failures worth fixing next:
- **A field called "link" read as the person's own listing** (`dnb.com`, `cashmereai.com`, `netwisedata.com`, `eyeota.com`): the form wants a disclaimer tick or a link of another kind, not a listing address.
- **State or relationship menus that do not offer the person's value** (`33mileradius.com`, `remodeling.com`, `health-union.com`): the person picks, or the app should match "Consumer" and similar plain answers more loosely.
- **"Customer" or business choices** (`ventiveiq.com`, `multimedialists.com`) and certify boxes, a math question (`anteriad.com`), the phone's advertising ID (`zerotoone.ai`, `vistarmedia.com`, `adswizz.com`): need the person or a device.
- **Fields named only by code** (`datarate.ai`, `nexxen.com`, `erepublic.com`): the filler cannot tell them apart.
- **Sent but no answer** (`bbdirect.com`, `demandscience.com`, `pebblepost.com`, `malvernmedia.com`, `teads.com`, `roq.ad`): the request may have gone through.
