// Getting from a privacy page to the request form, and past cookie prompts: decline cookies (never accept), open the request behind a link or a
// choice, press a lone intro "Next", follow the clearest same-site opt-out link, the review step's final button, the name tab, the rights menu.
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, run, call } = require('../harness');

const clicks = (w, ids) => { const seen = []; for (const id of ids) w.document.getElementById(id).addEventListener('click', () => seen.push(id)); return seen; };

// ---- deny-cookies.js and decline-consent-banner.js: the most private choice, never "Accept"

test('a known consent manager\'s reject button is pressed', () => {
  const w = page('<div id=onetrust-banner-sdk><button id=onetrust-accept-btn-handler>Accept all</button><button id=onetrust-reject-all-handler>Reject all</button></div>');
  const seen = clicks(w, ['onetrust-accept-btn-handler', 'onetrust-reject-all-handler']);
  assert.equal(run(w, 'deny-cookies'), '#onetrust-reject-all-handler');
  assert.deepEqual(seen, ['onetrust-reject-all-handler']);
});

test('otherwise a button that says reject, decline or only necessary is pressed, in any of the app\'s languages; Accept never is', () => {
  for (const [label, html] of [['Reject all', ''], ['Only necessary cookies', ''], ['Tout refuser', ''], ['Alle ablehnen', ''], ['Decline', '']]) {
    const w = page(`<div><button id=acc>Accept all</button><button id=rej>${label}</button></div>${html}`);
    const seen = clicks(w, ['acc', 'rej']);
    assert.equal(run(w, 'deny-cookies'), label);
    assert.deepEqual(seen, ['rej'], label);
  }
  const only = page('<div><button id=acc>Accept all cookies</button></div>');
  const seen = clicks(only, ['acc']);
  assert.equal(run(only, 'deny-cookies'), null);
  assert.deepEqual(seen, [], 'nothing pressed when the only choice is to accept');
});

test('a hidden reject button is not pressed by deny-cookies', () => {
  const w = page('<div style="display:none"><button id=rej>Reject all</button></div>');
  assert.equal(run(w, 'deny-cookies'), null);
});

test('decline-consent-banner presses Reject / Decline / Ablehnen and never Accept', () => {
  const w = page('<button id=acc>Accept</button><button id=rej>Decline</button>');
  const seen = clicks(w, ['acc', 'rej']);
  assert.equal(run(w, 'decline-consent-banner'), true);
  assert.deepEqual(seen, ['rej']);
  assert.equal(run(page('<button>Accept</button>'), 'decline-consent-banner'), false);
});

test('decline-consent-banner never presses a hidden "Decline" (one in a closed menu)', () => {
  const w = page('<div style="display:none"><button id=hid>Decline</button></div><button id=acc>Accept</button>');
  const seen = clicks(w, ['hid', 'acc']);
  assert.equal(run(w, 'decline-consent-banner'), false);
  assert.deepEqual(seen, []);
});

// ---- hide-consent-overlays.js: a cookie overlay that would not go away stops covering the page (it consents to nothing)

test('a fixed cookie overlay is hidden, but not one holding a form, and the page can scroll again', () => {
  const w = page(`<div id=cc style="position:fixed">We use cookies and similar tracking technologies.</div>
    <div id=req style="position:fixed">Your privacy choices: we use cookies <form><input name=email></form></div><div id=body>Page</div>`);
  w.document.body.style.overflow = 'hidden';
  assert.equal(run(w, 'hide-consent-overlays'), 1);
  assert.equal(w.document.getElementById('cc').style.display, 'none');
  assert.notEqual(w.document.getElementById('req').style.display, 'none', 'an overlay with a form may be the request itself');
  assert.equal(w.document.body.style.overflow, 'auto');
});

// ---- press-intro-next.js: one Next / Continue on an opt-out page, outside forms and cookie prompts

test('the one Next button on an opt-out page is pressed', () => {
  const w = page('<p>Click the button below to start this process.</p><button id=n>Next</button>', { url: 'https://broker.example/do-not-sell' });
  const seen = clicks(w, ['n']);
  assert.equal(run(w, 'press-intro-next'), true);
  assert.deepEqual(seen, ['n']);
});

test('not on a page that is not about opting out, not when two such buttons show, not inside a cookie prompt', () => {
  assert.equal(run(page('<button>Next</button>', { url: 'https://broker.example/blog', title: 'Blog' }), 'press-intro-next'), false);
  assert.equal(run(page('<button>Next</button><button>Continue</button>', { url: 'https://broker.example/opt-out' }), 'press-intro-next'), false);
  assert.equal(run(page('<div id=cookie-banner><button>Continue</button></div>', { url: 'https://broker.example/opt-out' }), 'press-intro-next'), false);
});

// ---- advance-to-request-form.js: a privacy portal's choice of requests: deletion first, then opt-out; never access

test('"Start Deletion Request" is pressed over "Start Access Request"', () => {
  const w = page('<button id=acc>Start Access Request</button><button id=del>Start Deletion Request</button><button id=oo>Start Opt Out Request</button>');
  const seen = clicks(w, ['acc', 'del', 'oo']);
  assert.equal(call(w, 'advance-to-request-form', false), 'Start Deletion Request');
  assert.deepEqual(seen, ['del']);
});

test('a bare "Opt out" button counts only when loose; a portal with only access choices is left', () => {
  const html = '<button id=oo>Opt out</button>';
  assert.equal(call(page(html), 'advance-to-request-form', false), '');
  assert.equal(call(page(html), 'advance-to-request-form', true), 'Opt out');
  assert.equal(call(page('<button>Start Access Request</button><button>Start Correction Request</button>'), 'advance-to-request-form', true), '');
});

test('a bare Continue on an opt-out page with no box on screen is pressed; in a cookie prompt it is not', () => {
  assert.equal(call(page('<button>Continue</button>', { url: 'https://theorg.example/opt-out' }), 'advance-to-request-form', false), 'Continue');
  assert.equal(call(page('<div class=cookie-consent><button>Continue</button></div>', { url: 'https://theorg.example/opt-out' }), 'advance-to-request-form', false), '');
  assert.equal(call(page('<input name=email><button>Continue</button>', { url: 'https://theorg.example/opt-out' }), 'advance-to-request-form', false), '', 'a box is on screen: that is the form');
});

// ---- open-request-links.js and open-request-links-follow.js

test('a "Submit a privacy request" link that opens in the page is clicked, never a mail link', () => {
  const w = page('<a id=mail href="mailto:privacy@broker.example">Submit a privacy request</a><a id=page href="#">Submit a privacy request</a>');
  const seen = clicks(w, ['mail', 'page']);
  assert.equal(run(w, 'open-request-links'), 'Submit a privacy request');
  assert.deepEqual(seen, ['page']);
  assert.equal(run(page('<a href="mailto:x@y.example">Your privacy choices</a>'), 'open-request-links'), null);
});

test('a "Submit a Privacy Request" link that opens a new tab is opened in place, not clicked (the app\'s page has no tabs)', () => {
  const w = page('<a id=b href="https://app.termly.io/dsar/abc" target="_blank" rel="noopener">Submit a Privacy Request</a>', { url: 'https://www.broker.example/legal/dsar/' });
  const seen = clicks(w, ['b']);
  assert.equal(run(w, 'open-request-links'), 'Submit a Privacy Request');
  assert.deepEqual(seen, [], 'not clicked: a click would ask for a new tab, which the app\'s page ignores');
});

test('the clearest opt-out link is followed only when it stays on the site (or a known privacy-request service)', () => {
  const same = page('<a href="https://www.broker.example/optout-form">Opt out of the sale</a>', { url: 'https://broker.example/privacy' });
  assert.equal(run(same, 'open-request-links-follow'), 'https://www.broker.example/optout-form');
  const portal = page('<a href="https://privacyportal.onetrust.com/webform/abc">Do not sell my personal information</a>', { url: 'https://broker.example/privacy' });
  assert.equal(run(portal, 'open-request-links-follow'), 'https://privacyportal.onetrust.com/webform/abc');
  for (const svc of ['https://app.termly.io/dsar/abc', 'https://broker.privacy.saymine.io/Broker']) {
    const w = page(`<a href="${svc}">Submit a privacy request</a>`, { url: 'https://broker.example/privacy' });
    assert.equal(run(w, 'open-request-links-follow'), svc, 'Termly and saymine host request forms for many brokers');
  }
  const other = page('<a href="https://other-company.example/opt-out">Opt out</a>', { url: 'https://broker.example/privacy' });
  assert.equal(run(other, 'open-request-links-follow'), '', 'another company\'s page is not followed');
  const mail = page('<a href="mailto:privacy@broker.example">Opt out</a>', { url: 'https://broker.example/privacy' });
  assert.equal(run(mail, 'open-request-links-follow'), '');
});

// ---- press-confirm-step.js and confirm-button-label.js

test('the review step\'s final Submit is pressed only when the page says it is a review or confirmation step', () => {
  const w = page('<p>Please review your request before sending.</p><button id=back>Back</button><button id=go>Submit request</button>');
  const seen = clicks(w, ['back', 'go']);
  assert.equal(run(w, 'press-confirm-step'), true);
  assert.deepEqual(seen, ['go']);
  assert.equal(run(page('<p>Fill in the form.</p><button>Submit</button>'), 'press-confirm-step'), false, 'not a review step: never sent twice');
});

test('a confirm button\'s label is read (and scrolled to), not pressed', () => {
  const w = page('<p>Almost done.</p><button id=c>Confirm my request</button>');
  const seen = clicks(w, ['c']);
  assert.equal(run(w, 'confirm-button-label'), 'Confirm my request');
  assert.deepEqual(seen, []);
  assert.equal(run(page('<button>Submit</button>'), 'confirm-button-label'), '');
});

// ---- choose-name-tab.js and choose-rights-picker.js

test('of "Phone" and "Name" tabs, the name tab is opened; nothing happens without both, or when it is already open', () => {
  const w = page('<div role=tablist><button role=tab id=ph aria-selected=true>Phone</button><button role=tab id=nm>Name</button></div>');
  const seen = clicks(w, ['ph', 'nm']);
  assert.equal(run(w, 'choose-name-tab'), true);
  assert.deepEqual(seen, ['nm']);
  assert.equal(run(page('<button role=tab>Name</button>'), 'choose-name-tab'), false);
  assert.equal(run(page('<button role=tab>Phone</button><button role=tab aria-selected=true>Name</button>'), 'choose-name-tab'), false);
});

test('a rights menu outside any form takes opt-out (else deletion), never access; one the person set is left', () => {
  const w = page('<select id=r><option value="">Select From Available Forms</option><option value=k>Right to Know</option><option value=d>Right to Delete</option><option value=o>Right to Opt-out</option></select>');
  assert.equal(run(w, 'choose-rights-picker'), true);
  assert.equal(w.document.getElementById('r').value, 'o');
  const del = page('<select id=r><option value="">Select</option><option value=k>Access my data</option><option value=d>Delete my data</option></select>');
  run(del, 'choose-rights-picker'); assert.equal(del.document.getElementById('r').value, 'd');
  const mine = page('<select id=r data-ook-user=1><option value="">Select</option><option value=o>Opt out</option></select>');
  assert.equal(run(mine, 'choose-rights-picker'), false);
  assert.equal(run(page('<form><select><option>Opt out</option></select></form>'), 'choose-rights-picker'), false, 'a menu inside a form is the form\'s own');
});
