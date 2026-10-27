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

## Sample of the 31 "no readable form" and the 9 "unrecognised fields" (2026-10-27)

**The 31 with no readable form** (all 31 re-audited after teaching the app to press tiles such as "I am the person opting out" or "Delete your data", and to follow the page's own opt-out link):
2 now have a form and became semi-automatic: `blueaction.io` (its "Opt out of the sale and sharing of your data" tile opens a form) and `altairdata.com` (the "Individual: Opt-Out/Deletion Request Form"
link opens an Atlassian service-desk form). The other 29 were looked at by hand (screenshots of 12):
- the opt-out sits behind a click path the app does not follow yet: `greatlakeslists.com` ("who is submitting" tiles), `propertyreach.com` (an "Opt-Out Form" link to a separate portal), `familytreenow.com` (a menu that reveals the form, and its page now answers with an error page), `censia.com` (the policy links to a request form);
- the page is a people-search page with a footer link and no request on it: `peoplebyname.com`, `clustal.org`, `veripages.com`, `searchusapeople.com`, `truthed.com` (an ID is required first);
- the page is a privacy policy with no request form: `trelize.com`, `censia.com`.
So most of the 31 are correctly guided: the person follows the page's links. A few could become semi-automatic with a smarter click path.

**The 9 with unrecognised fields** all have a real opt-out form (screenshots checked): `liveramp.com` and `adprime.com` (a device opt-out with a reCAPTCHA, a device ID and AdID/IDFA buttons), `foursquare.com` (the same with an IDFA box),
`blueprintaudiences.com`, `clickagy.com`, `completemedicallists.com` (a long form with a reCAPTCHA), `unacast.com` (a HubSpot form), `maxmind.com` (it asks for the person's IP address) and `meltwater.com` (the Klear form asks for
social profile links). All nine were moved to semi-automatic: the stored crawl form (whose fields the app could not recognise) was dropped, the live page decides what is filled, and a person completes what the app does not hold
(an advertising ID, an IP address, a social profile) and clears the checks.

Counts now: 456 semi-automatic, 252 guided, 85 unlock later, 21 automatic.

## Email only is its own category (2026-10-27)

The 138 sites whose only route is an email (no form) are no longer "guided": `OptOutMethod.emailOnly` sits between semi-automatic and guided. In the queue the new band "Email only" comes after every
semi-automated band (`PlanRank.emailOnly`, between "Semi-automated, anywhere" and the manual bands), even for a broker registered where the person lives, so people finish the semi-automated sites first and then
send the emails. The plan still makes them one task ("Send opt-out emails": one message per address, naming every site it handles; the person reads each and taps Send).

Now: 456 semi-automatic, 138 email only, 114 guided, 85 unlock later, 21 automatic.
