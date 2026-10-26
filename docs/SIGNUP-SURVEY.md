# Sign-up survey (2026-10-26)

`tools/survey_signup.py` opens the recorded opt-out page of every site that has one (724 of the 829 shown sites) in a headless browser and lists its visible forms.
A site is flagged when the page redirects to a sign-up or login address, or when every form on it carries sign-up wording (subscribe, newsletter, free trial, demo,
get started, join, contact sales, send message) or a password field and none looks like a privacy request. Nothing is filled or sent. Raw results:
`pipeline/signup-survey.json`.

Result: 79 flagged. 34 were clear: the page's only forms were a newsletter, a trial, a site search, a contact form, an AI chat box or a sign-in. Those sites
(listed in `testSitesTheSurveyFoundPointingAtSignUpFormsAreNeverFilled`) lost their recorded page and form and are "unlock later" unless they have a privacy email,
and a unit test keeps them from ever becoming automatic or semi-automatic.

Left alone because the form on the page is probably the real one: identity-verification flows (a "magic link" or "verification link" before the request, as on
draup.com and contactout.com), "Get started" headings over a real request form (advancedbackgroundchecks.com, equifax.com), non-disclosure/opt-out forms
(forewarn.com, ididata.com), and forms behind a frame the survey cannot read (windfall.com). About 20 flagged sites with only an "I am human" box or an unclear
single field (allantgroup.com, versium.com, visitiq.io, magnite.com, ispot.tv, vector.co, demandbase.com, thedatagroup.com, videoamp.com, ogury.com) still need a person to
look. One site redirected to a sign-in page; 2 pages would not open.

## Hand check of the 34 demoted sites

I opened every demoted page and looked at it. 15 of the 34 had been demoted wrongly: the survey read a newsletter or search box in the page footer, while the page itself is a real
privacy-choices page, or its page links to one. They are back as guides (the app opens the page, the person completes it; nothing is filled for them):
`intentiq.com`, `jungroup.com` (a HyprMX privacy center), `mediawallah.com`, `outwardmedia.com`, `skydeo.com`, `swoop.com`, `firmable.com` (profile removal request),
`amplemarket.com` (opt out by email to privacy@amplemarket.com, now recorded), `coasttechnology.com`, and re-pointed to the real page: `seamless.ai`, `convergemarketing.com`
(its DataSubject portal), `fideo.ai`, `finsum.com`, `idatabasesolutions.com`, `whitepages.com`.

The other 19 stay unlock-later, and the check agrees with the survey: the page is a home page, product page, blog post, search box, trial or sign-up (`applovin.com`, `archives.com`,
`bluedatalead.com`, `citydata.ai`, `enrichlayer.com`, `ocean.io`, `pitchbook.com`, `spycloud.com`, `verisk.com`, `agedleadstore.com`), a plain privacy policy with no
request form on it (`attomdata.com`, `cotality.com`, `evertrue.com`, `finthrive.com`, `dresdendirect.com`), a sign-in (`lead-enhance.com`), another company's page
(`internetbrands.com` is Adobe's analytics opt-out, `pmg.com` is the Texas attorney general's), or a third party's opt-out (`jwx.com` links to Connatix).

Lesson: the survey flags forms it can see, and many privacy forms sit behind a modal or a frame, so a flag means look, not demote.

## Frames and modals (2026-10-26)

The app now reads forms inside frames and behind modal triggers. Every frame with inputs tells the page's web view, so a form embedded from another site (a Google Form, a privacy
portal) can be read, filled and sent, and the steps after it run in that frame. When no opt-out form shows, the app also opens a request that hides behind a link or button
("Submit a privacy request", "Your Privacy Choices", "Do Not Share or Sell My Personal Information") and looks again; it never clicks a mail link.

Doing this exposed a worse problem: with single inputs counted as forms, the app had been picking newsletter boxes (jungroup.com, swoop.com, skydeo.com and firmable.com all
have one) and would have filled and sent the person's email. A form is now refused when the words around its inputs say newsletter or "delivered to your inbox" (only for forms of
three or fewer inputs), and a lone email box needs privacy wording near it. Re-audited: the newsletter boxes are gone and the real forms were found (jungroup's HyprMX form in a frame,
firmable's removal request, skydeo's opt-out, mediawallah's form, outwardmedia's request modal). Across the 266 semi-automatic sites re-audited, 9 stopped showing a form; 4 came back
after fixing the word "unsubscribe" and "Contact Us Form" headings being read as sign-up wording. Still lost: open-public-records.com (not an opt-out), groundtruth.com,
videoamp.com (a lone box), buildertrend.com and thedatagroup.com (cause not found). Still not found: windfall.com, intentiq.com, coasttechnology.com. Results in `docs/audits/frames-and-modals/`.
