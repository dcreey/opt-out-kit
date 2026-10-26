# Form audit

`App/Sources/FormAudit.swift` (debug builds only) opens each site's page the way a real run does, fills the form from a complete made-up
profile and never sends it. It writes `results.json` and a picture of the filled form per site to the app's Documents/audit folder. Launch the app
on the simulator with `-audit-first-per-kind 3`, `-audit-all` or `-audit-domains a.com,b.com`; the run is parallel, resumes where it stopped, and
gives each site 75 seconds.

Each result records the page that opened, whether a form was found, every field with its label, whether it is required and whether it was filled,
anything that would stop a person (a bot check, a certification box, a typed code, a menu with no choice for them), and the dry-run outcome.

`docs/audits/` keeps the results of the runs we made. What the first full run showed (755 sites):

- 384 forms filled with nothing required left empty, 133 with a required field left empty, and 234 where no form was found on the page.
- Most "no form" pages hold the form in another site's frame (OneTrust, TrustSuperset, HubSpot, Google Forms). `tools/resolve_iframe_forms.py`
  finds those and records the frame's own address as the page to open.
- Several required fields were ones we could fill but did not (age, birth month, day and year, today's date, "Resident of", "First / Middle
  Name(s)", subject and message boxes). The form filler now fills them.
- A form asking for a company, job title or industry on a page that is not about privacy is a business form, not a personal opt-out. Those forms
  are dropped, and sites that are not data brokers at all are listed in `docs/EXCLUDED_SITES.md`.

## Real sends (2026-10-26)

`-real-send -real-send-domains a.com,b.com` (debug builds, simulator) really SENDS each site's form for the owner's profile on the device and records what
the site showed, with a picture of the page afterwards. Results: `docs/audits/real-send-2026-10-26/results.json`.

Of the 64 semi-automated sites that showed nothing blocking at load, 57 were sent through the live path (the other 7 have a stored form and go through the
background run). The classifier's label was checked against the pictures, and it was wrong both ways:

- 12 genuinely showed a confirmation (4 of them ask the person to tap a link in an email to finish) and now carry `run_check: confirmed`: semantiqhealth.com,
  stirista.com, draup.com, torusvotersystems.com, acronymix.com, everleads.com, inmar.com, networx.com, subgraph.tech, liveintent.com,
  advancedbackgroundchecks.com, getliminal.com.
- 5 were labelled confirmed but the picture showed a login page (monocl.com), a policy page (vistaview.ai), an empty form (healthlinkdimensions.com,
  rrd.com) or an unclear form (telephonelists.biz). They are not marked.
- Most failures were a Cloudflare "Verify you are human" box that appears after the form is filled (about a dozen sites), a multi-step portal that needs
  a request tile clicked first (bridg.com, lob.com, minerva.io, forian.com, definitivehc.com, cbinsights.com), a form that wants a work email
  (juicebox.ai, evertrue.com), or the wrong form on the page (agedleadstore.com picked a newsletter box).
