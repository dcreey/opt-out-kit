#!/usr/bin/env python3
"""Which kinds of opt-out page the recorded sites have, and which of them an end-to-end test covers.

The recorded sites are the repository's dump of every site we have looked at (directory/*.yml: the page signals each was given, what blocked its form when it was
loaded for real, and the boxes of the form where one was read). Each kind of page is counted there and matched to the fixture broker that stands for it
(fixtures/pages, the same kinds as fixtures/sites) and the UI test that drives it. docs/PAGE-TYPES.md is this tool's output.

    page_type_coverage.py            print the table
    page_type_coverage.py --write    rewrite docs/PAGE-TYPES.md
    page_type_coverage.py --check    fail when docs/PAGE-TYPES.md is out of date, or a fixture or test the table names is missing

Needs ruamel.yaml (tools/requirements.txt), through tools/yamlio.py.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import yamlio  # noqa: E402

DOC = os.path.join(ROOT, 'docs', 'PAGE-TYPES.md')


def fields(d):
    return ((d.get('opt_out_form') or {}).get('fields')) or []


def label(f):
    return ((f.get('label') or '') + ' ' + (f.get('name') or '')).lower()


def has_signal(*names):
    return lambda d: any(n in (d.get('signals') or []) for n in names)


def has_blocker(prefix):
    return lambda d: any(b.startswith(prefix) for b in ((d.get('live_form') or {}).get('blockers') or []))


def field_match(kind, pattern):
    return lambda d: any(f.get('type') == kind and re.search(pattern, label(f)) for f in fields(d))


def label_count(pattern, at_least):
    return lambda d: sum(1 for f in fields(d) if re.search(pattern, label(f))) >= at_least


def listing(d):
    pat = r'your (listing|profile)|listing url|profile url|link to (your|the)|url of (your|my)|enter url'
    return has_signal('listing_url_input', 'search_first')(d) or any(re.search(pat, label(f)) for f in fields(d))


# (what the page is, detector over a recorded site, fixture kinds, tests (FixturePageTypeUITests / FixtureJourneyUITests ... method names), status)
# status: covered (the whole behaviour is driven), partial (the engine path is, a variant is not), none
KINDS = [
    ('A plain form: name and email', has_signal('email_input', 'name_input'), ['plain'], ['testRunNowFillsAndSendsTheFormOnEachBrokerPage'], 'covered'),
    ('Search first: find your own listing, then a form wants its link', listing, ['search'],
     ['testASearchFirstSiteIsSearchedForMeAndTheListingIPickGoesIntoItsForm', 'testNotBeingListedOnASearchFirstSiteSendsNothing'], 'covered'),
    ('Several addresses: boxes for previous addresses', label_count(r'(previous|other|additional|second|alternate|old).{0,20}(address|street|city|zip)|address ?[2-9]|street ?[2-9]', 1), ['multi'],
     ['testAPageWithBoxesForPreviousAddressesAndASecondEmailAndPhoneGetsEachOne'], 'covered'),
    ('Several emails: two or more email boxes', label_count(r'e-?mail', 2), ['multi', 'multiadd'],
     ['testAPageWithBoxesForPreviousAddressesAndASecondEmailAndPhoneGetsEachOne', 'testAddAnotherButtonsArePressedForTheFurtherEmailsAndPhones'], 'covered'),
    ('Several phones: two or more phone boxes', label_count(r'phone|mobile|cell|\btel\b', 2), ['multi', 'multiadd'],
     ['testAPageWithBoxesForPreviousAddressesAndASecondEmailAndPhoneGetsEachOne', 'testAddAnotherButtonsArePressedForTheFurtherEmailsAndPhones'], 'covered'),
    ('Choose exactly one request: radio buttons (know / correct / delete / opt out)', lambda d: any(f.get('type') == 'radio' for f in fields(d)), ['choose', 'chooseoptout'],
     ['testWhenOnlyOneOfKnowCorrectDeleteAndOptOutCanBeChosenItChoosesDelete', 'testWhenThereIsNoDeleteChoiceItChoosesOptOutOfTheSale'], 'covered'),
    ('Choose a request type from a menu', field_match('select', r'request|type|right|action|option|reason|regarding|nature'), ['chooseselect'], ['testARequestTypeMenuIsSetToARemovingChoice'], 'covered'),
    ('Tick the requests you want: checkboxes', field_match('checkbox', r'request|opt|delete|know|sell|right'), ['checkboxes'], ['testCheckboxesTickTheRemovingRequestsAndNotKnowOrCorrect'], 'covered'),
    ('A reCAPTCHA', has_signal('captcha_recaptcha'), ['recaptcha'], ['testAReCaptchaCheckboxWaitsForMeAndTheFormIsSentWhenITickIt'], 'covered'),
    ('A Cloudflare Turnstile', has_signal('captcha_turnstile'), ['turnstile'], ['testSolveAndSendFillsTheFormWaitsForMyCheckThenSendsAndMovesOn'], 'covered'),
    ('A bot check the page only shows when asked (an "I am not a robot" box)', has_blocker('check'), ['robot'], ['testSolveAndSendWaitsForTheNotARobotBoxAndSendsWhenITickIt'], 'covered'),
    ('An hCaptcha or DataDome check', has_signal('captcha_hcaptcha', 'captcha_datadome'), [], [], 'none'),
    ('A code to type (emailed or texted) before the first send', lambda d: has_signal('phone_verify')(d) or has_blocker('code')(d), ['code'],
     ['testSolveAndSendIsNotDoneUntilIHaveEnteredTheCodeFromTheEmail', 'testAWrongEmailedCodeIsNotCountedAsSent'], 'partial'),
    ('A certification box the person must tick', has_blocker('certify'), ['certify'], ['testACertificationBoxIsLeftForMeToTickAndTheFormIsSentWhenIHaveTickedIt'], 'covered'),
    ('A form built by script after the page loads', has_signal('script_rendered_page', 'script_rendered_form'), ['jsform'], ['testAFormBuiltByScriptAfterTheLoadIsFoundFilledAndSent'], 'covered'),
    ('A multi-step form (Next, then Submit)', has_blocker('step'), ['steps'], ['testATwoStepFormIsWalkedThroughAndSent'], 'covered'),
    ('No online form: a postal address or an email to write to', has_signal('mail_option', 'email_contact', 'email_only_wording'), ['noform'],
     ['testSolveAndSendSendsNothingToAPageWithNoFormAndLetsMeMarkItDone'], 'partial'),
    ('A confirmation that says an email follows', has_signal('email_link'), ['emaillink'], ['testSolveAndSendSeesThatASitePromisesAnEmailAndListsItForTheFollowUp'], 'covered'),
    ('A form that needs a login or an account', has_signal('account_hint', 'login_required'), ['login'], ['testASignInPageIsNeverFilledOrSent'], 'partial'),
    ('A form that needs ID or a file upload', has_signal('id_required', 'file_upload'), ['upload'], ['testAFormThatWantsAFileUploadIsNotSentWithoutIt'], 'covered'),
    ('A third-party privacy portal (Osano, OneTrust, TrustArc)', has_signal('portal_osano', 'portal_onetrust', 'portal_trustarc'), [], [], 'none'),
    ('A bot check on the site\'s home page, before its form', has_signal('bot_check_on_home'), [], [], 'none'),
    ('A terms prompt to accept before the form', has_blocker('terms'), [], [], 'none'),
    ('A form for an agent, a business or another person', lambda d: any(has_blocker(p)(d) for p in ('agent', 'business', 'other')), ['agent'], ['testAnAuthorizedAgentQuestionIsAnsweredNo'], 'partial'),
]

LABEL = {'covered': 'covered', 'partial': 'partly', 'none': 'not covered'}


def count():
    entries = [d for _, d in yamlio.entries('directory')]
    rows = []
    for name, detect, kinds, tests, status in KINDS:
        sites = sorted(d['domain'] for d in entries if detect(d))
        rows.append((name, sites, kinds, tests, status))
    return len(entries), rows


def render():
    total, rows = count()
    out = ['# Page types in the recorded sites, and what covers them end to end', '',
           f'Generated by `tools/page_type_coverage.py` from the {total} recorded sites in `directory/` (the dump of every site we looked at: each site\'s page signals, what blocked its',
           'form when it was loaded for real, and the boxes of its form where one was read). A site can be counted under several kinds. "Covered" means a fixture broker of that kind',
           '(`fixtures/pages`, `fixtures/sites`) is driven end to end by a UI test (`AppUITests`, run for a release; docs/TESTING.md, "End-to-end tests against fixture pages").', '',
           '| Kind of page | Recorded sites | Fixture | Test | |', '|---|---:|---|---|---|']
    for name, sites, kinds, tests, status in rows:
        fix = ', '.join(f'`{k}`' for k in kinds) or '(none yet)'
        tst = '<br>'.join(f'`{t}`' for t in tests) or ''
        out.append(f'| {name} | {len(sites)} | {fix} | {tst} | {LABEL[status]} |')
    covered = sum(len(s) for _, s, _, _, st in rows if st == 'covered')
    out += ['', 'The count of a kind that has no fixture is the work still to do. Sites counted per kind overlap, so the column does not add up to the number of sites.', '',
            '## Examples per kind', '']
    for name, sites, kinds, tests, status in rows:
        out.append(f'- **{name}** ({len(sites)}): {", ".join(sites[:6])}{" ..." if len(sites) > 6 else ""}')
    return '\n'.join(out) + '\n', covered


def check_files():
    problems = []
    pages = {os.path.basename(p)[:-5] for p in glob.glob(os.path.join(ROOT, 'fixtures', 'pages', '*.html'))}
    sites = {os.path.basename(p)[3:-4].rsplit('_', 1)[0] for p in glob.glob(os.path.join(ROOT, 'fixtures', 'sites', 'fx_*.yml'))}
    source = ''.join(open(p, encoding='utf-8').read() for p in glob.glob(os.path.join(ROOT, 'AppUITests', '*.swift')))
    for name, _, kinds, tests, _ in KINDS:
        for k in kinds:
            if k not in pages or k not in sites:
                problems.append(f'{name}: fixture kind {k} has no page or no site')
        for t in tests:
            if f'func {t}(' not in source:
                problems.append(f'{name}: test {t} does not exist')
    return problems


def main():
    text, _ = render()
    if '--write' in sys.argv:
        open(DOC, 'w', encoding='utf-8').write(text)
        print('wrote', DOC)
        return 0
    if '--check' in sys.argv:
        problems = check_files()
        if not os.path.exists(DOC) or open(DOC, encoding='utf-8').read() != text:
            problems.append('docs/PAGE-TYPES.md is out of date: run tools/page_type_coverage.py --write')
        for p in problems:
            print(p)
        return 1 if problems else 0
    print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
