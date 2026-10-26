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
