// What the app reads back from a page (its forms and links, a form's state and place, email addresses, the visible text, whether it changed) and what
// the person is doing (typing, using a code box); the scripts added to every page (Global Privacy Control, the frame reporter, the person's touches,
// the background run's activity signal); and the scroll helpers.
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, run, call } = require('../harness');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- describe-page.js, describe-form.js, form-state.js, form-top.js, page-emails.js, visible-fields.js

test('describe-page lists the links (absolute) and each form\'s boxes with labels, leaving buttons and hidden fields out', () => {
  const w = page('<a href="/privacy">Privacy</a><form action="/go"><label for=e>Email</label><input id=e name=email><input type=hidden name=t><button>Send</button></form>');
  const text = run(w, 'describe-page');
  assert.ok(text.includes('https://broker.example/privacy'), 'the link is made absolute');
  assert.ok(text.includes('"name":"email"') && !text.includes('"name":"t"'), 'the email box, not the hidden one');
});

test('describe-form gives the form\'s boxes, buttons and the text around it, for the record of what was filled', () => {
  const w = page('<div><p>Use this form to opt out of the sale of your data.</p><form data-ook-form="f0"><input name=email type=email><input type=checkbox name=ok><button>Opt out</button></form></div>');
  const out = JSON.parse(call(w, 'describe-form', 'f0'));
  assert.deepEqual(out.fields, ['email:email'], 'checkboxes and buttons are not boxes');
  assert.deepEqual(out.buttons, ['Opt out']);
  assert.match(out.ctx, /opt out of the sale/);
  assert.equal(call(w, 'describe-form', 'gone'), '');
});

test('form-state says whether the chosen form is still shown, and the page\'s address; form-top where it sits', () => {
  const w = page('<form data-ook-form="f0"><input></form><form data-ook-form="f1" style="display:none"><input></form>');
  assert.deepEqual(JSON.parse(call(w, 'form-state', 'f0')), { v: true, u: 'https://broker.example/privacy/opt-out' });
  assert.equal(JSON.parse(call(w, 'form-state', 'f1')).v, false);
  assert.equal(JSON.parse(call(w, 'form-state', 'gone')).v, false);
  assert.equal(call(w, 'form-top', 'f0'), 0);
  assert.equal(call(w, 'form-top', 'gone'), 0);
});

test('page-emails finds every address the page links to or shows', () => {
  const w = page('<a href="mailto:privacy@broker.example?subject=Opt%20out">Email us</a><p>Or write to dpo@broker.example.</p>');
  assert.deepEqual(JSON.parse(run(w, 'page-emails')), ['privacy@broker.example', 'dpo@broker.example']);
});

test('visible-fields lists the shown boxes with their values (the email-link filler checks what it filled)', () => {
  const w = page('<input id=a value=1><input type=hidden id=h><input id=g style="display:none"><select name=s><option>x</option></select>');
  assert.deepEqual(JSON.parse(run(w, 'visible-fields')).map((f) => f.id), ['a', 's']);
});

// ---- viewport-text.js and page-changed.js

test('viewport-text is the text shown on screen, not hidden text', () => {
  const w = page('<p>Your request was received.</p><p style="display:none">Hidden template: request received</p>');
  assert.equal(run(w, 'viewport-text'), 'Your request was received.');
});

test('page-changed says yes once the page changed and then sat still for a moment, then no until it changes again', async () => {
  const w = page('<div id=a>one</div>');
  assert.equal(run(w, 'page-changed'), false, 'just started watching');
  await sleep(650);
  assert.equal(run(w, 'page-changed'), true, 'the first look counts as a change');
  assert.equal(run(w, 'page-changed'), false, 'nothing since');
  w.document.getElementById('a').textContent = 'two';
  await sleep(20);
  assert.equal(run(w, 'page-changed'), false, 'still changing: wait for it to settle');
  await sleep(650);
  assert.equal(run(w, 'page-changed'), true);
  w.document.getElementById('a').setAttribute('data-ook', 'x');
  await sleep(650);
  assert.equal(run(w, 'page-changed'), false, 'the app\'s own markers are not a change');
});

// ---- user-is-typing.js, code-box-in-use.js, empty-code-field.js, empty-verification-code-box.js

test('the person is typing when a text box has focus and they touched the page in the last 45 seconds', () => {
  const w = page('<input id=t><input type=checkbox id=c>');
  w.document.getElementById('t').focus();
  assert.equal(run(w, 'user-is-typing'), false, 'no touch of theirs yet');
  w.__ookUserAt = Date.now();
  assert.equal(run(w, 'user-is-typing'), true);
  w.document.getElementById('c').focus();
  assert.equal(run(w, 'user-is-typing'), false, 'a checkbox is not typing');
  w.document.getElementById('t').focus(); w.__ookUserAt = Date.now() - 60000;
  assert.equal(run(w, 'user-is-typing'), false, 'too long ago');
});

test('a check-code box the person is typing in holds the send; one the app filled, or a ZIP code box, does not', () => {
  const w = page('<label for=c>Enter the code shown</label><input id=c value="AB12" data-ook-user=1><label for=z>ZIP code</label><input id=z value=62701 data-ook-user=1>');
  w.document.getElementById('c').focus(); w.__ookUserAt = Date.now();
  assert.equal(run(w, 'code-box-in-use'), true);
  w.document.getElementById('c').removeAttribute('data-ook-user');
  assert.equal(run(w, 'code-box-in-use'), false, 'not the person\'s');
  w.__ookUserAt = Date.now() - 20000;
  w.document.getElementById('c').setAttribute('data-ook-user', '1');
  assert.equal(run(w, 'code-box-in-use'), false, 'they stopped a while ago');
});

test('an empty captcha or verification code box is found; a filled one, a promo or ZIP box is not', () => {
  assert.equal(run(page('<input placeholder="Enter the characters">'), 'empty-code-field'), true);
  assert.equal(run(page('<input placeholder="Enter the characters" value="x7k">'), 'empty-code-field'), false);
  assert.equal(run(page('<input aria-label="Verification code">'), 'empty-verification-code-box'), true);
  assert.equal(run(page('<input aria-label="Promo code">'), 'empty-verification-code-box'), false);
  assert.equal(run(page('<input aria-label="ZIP code">'), 'empty-verification-code-box'), false);
});

// ---- the scripts added to every page

test('Global Privacy Control: every page reads navigator.globalPrivacyControl as true', () => {
  const w = page('<p>x</p>');
  run(w, 'global-privacy-control');
  assert.equal(w.navigator.globalPrivacyControl, true);
});

test('the frame reporter tells the app about a frame with boxes, and says nothing in the page itself', async () => {
  const w = page('<input name=a>');
  run(w, 'frame-reporter');
  await sleep(900);
  assert.deepEqual(w.__posts, [], 'the page itself is not a frame');
});

test('only the person\'s real touches count: the app\'s own scripted clicks and typing are not the person', () => {
  const w = page('<button id=b>Send</button><input id=i>');
  run(w, 'touch-tracker');
  w.document.getElementById('b').click();
  w.document.getElementById('i').dispatchEvent(new w.Event('input', { bubbles: true }));
  assert.equal(w.__ookPress, undefined);
  assert.equal(w.__ookUserAt, undefined);
});

test('a press reported by one of the page\'s own frames counts as the person\'s; one the page\'s own script posts does not', async () => {
  const w = page('<iframe id=f></iframe>');
  run(w, 'touch-tracker');
  w.postMessage('ookPress', '*');
  await sleep(10);
  assert.equal(w.__ookPress, undefined, 'the page itself cannot make a press look like the person\'s');
  w.dispatchEvent(new w.MessageEvent('message', { data: 'ookPress', source: w.document.getElementById('f').contentWindow }));
  assert.equal(w.__ookPress, 1, 'a frame of the page reports the person\'s press there');
});

test('the activity signal tells the app (at most once a second) when the page changes, and does not start twice', async () => {
  const w = page('<div id=a>one</div>');
  run(w, 'activity'); run(w, 'activity');
  w.document.getElementById('a').textContent = 'two';
  await sleep(5);
  w.document.getElementById('a').textContent = 'three';
  await sleep(5);
  assert.equal(w.__posts.filter((p) => p.name === 'ookActivity').length, 1, 'two changes within a second: one signal');
});

// ---- scroll helpers: they move the page so the person sees the form, the check, or the opt-out button; they never click

test('the scroll helpers bring the chosen form, the check or the opt-out control into view', () => {
  const w = page('<form data-ook-form="f0"><input></form><iframe src="https://www.google.com/recaptcha/api2/anchor"></iframe>');
  assert.equal(call(w, 'scroll-form-to-top', 'f0'), true);
  assert.equal(call(w, 'scroll-form-to-top', 'gone'), false);
  call(w, 'scroll-form-into-view', 'gone');
  assert.ok(w.__scrolls.some((s) => s.to && s.to[0] === 0 && s.to[1] === 0), 'an unknown form scrolls to the top');
  assert.equal(run(w, 'scroll-challenge-into-view'), true);
  call(w, 'scroll-frame-into-view', 'https://www.google.com/recaptcha/api2/anchor?k=1');
  assert.ok(w.__scrolls.some((s) => s.el && s.el.tagName === 'IFRAME'));
});

test('scroll-to-opt-out-control does nothing when the button is already on screen, and ignores menus in the header', () => {
  const on = page('<button>Opt out</button>');
  assert.equal(run(on, 'scroll-to-opt-out-control'), false, 'already on screen');
  const header = page('<header><a href="/x">Opt out</a></header>');
  assert.equal(run(header, 'scroll-to-opt-out-control'), false);
  const below = page('<div style="position:absolute;top:-5000px"><button>Remove my listing</button></div>');
  assert.equal(run(below, 'scroll-to-opt-out-control'), true, 'off screen: scrolled to it');
});

test('a code box that is hidden until a button emails the code still counts as a code to type, until it is filled', () => {
  const step = (value) => '<form><input name="email"><button type="button">Email me a verification code</button>' +
    '<div style="display:none"><label>Verification code <input name="code" autocomplete="one-time-code"' + (value ? ' value="750439"' : '') + '></label></div>' +
    '<button type="submit">Submit request</button></form>';
  assert.equal(run(page(step(false)), 'empty-code-field'), true, 'the code has not been asked for or typed');
  assert.equal(run(page(step(true)), 'empty-code-field'), false, 'typed');
  assert.equal(run(page('<form><input name="code"><button type="submit">Submit</button></form>'), 'empty-code-field'), false, 'a box named code, hidden, with no button that emails one: not a code step');
  assert.equal(run(page('<form><button type="button">Send message</button><div style="display:none"><input name="promo_code"></div></form>'), 'empty-code-field'), false, 'a promo code is not a verification code');
});
