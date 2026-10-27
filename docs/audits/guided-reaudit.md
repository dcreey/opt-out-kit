# Why sites are guided and not semi-automatic (2026-10-27)

Of 814 shown sites the app now classifies 445 as semi-automatic, 263 as guided, 85 as unlock-later and 21 as automatic. Before this pass it was 423, 285, 85 and 21.

The 282 guided sites had these reasons: 155 email only, 36 page found with no readable form, 25 business details, 14 questions the app cannot read, 13 ID upload or signature, 10 may
verify by phone, 9 unrecognised fields, 6 earlier real run failed, 5 asks for something the app does not hold, 3 authorized-agent form, 3 advertising ID, 2 needs an account, 1 certify box,
plus the rest of the email cases.

The biggest group, email only (155), is not a failure: those sites take the request by email, and 131 of them also have a page the live crawl never found a form on. The crawl predates the
app's reading of frames and modals, so the 195 guided sites that have a page (not business, agent, file, advertising-ID, account or earlier-failed) were re-audited with the new reading
(`docs/audits/guided-reaudit/results.json`): **44 had a form after all, and 38 were promoted to semi-automatic** (`tools/apply_audit_live.py`, then `tools/apply_audit_blockers.py` for business, agent,
file and "questions the app cannot read" blockers). Left out: login forms (`l2-data.com` asks for a user name and password) and one form with a broken placeholder (`allantgroup.com`).

Now guided, 263 sites, by reason: 138 email only (114 also have a page with no form found), 31 page found but no form the app can read, 27 asks for business details (a company or job title: the
person fills these), 15 questions the app cannot read (Google Forms where every field is "Your answer"), 13 ID upload or signature, 10 may verify by phone, 9 fields the app cannot recognise,
6 an earlier real run failed (a bot check appears after sending: Deep Sync and others), 6 asks for something the app does not hold, 3 authorized-agent forms, 3 the phone's advertising ID,
2 need an account.

Which of these a person-or-code change could still move to semi-automatic: the 31 with no readable form (a custom widget, a page that needs a click path, or a wall), the 9 with unrecognised fields
(fields named only by code), and the 10 phone-verification ones (the app can fill the form and the person confirms by phone). Business details, ID uploads, agent forms, accounts and advertising IDs
stay with the person or the device.
