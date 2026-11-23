// Custom menus and type-aheads (a styled list instead of a <select>), and sending: the opt-out form's own send button, never a sign-up or "agree"
// button; the stored-plan filler (fill-fields) and its send (press-submit); and a direct POST (submit-form).
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, run, call, callJSON } = require('../harness');

const clicks = (w, ids) => { const seen = []; for (const id of ids) w.document.getElementById(id).addEventListener('click', () => seen.push(id)); return seen; };

// ---- custom-menus-open.js and custom-menus-pick.js

test('an empty custom menu is opened once and marked; one that already shows a choice is not', () => {
  const w = page('<div><span>Relationship</span><div role=combobox id=m></div></div><div role=combobox id=set>Consumer</div>');
  const seen = clicks(w, ['m', 'set']);
  assert.notEqual(run(w, 'custom-menus-open'), '', 'something was opened (the app only checks that the answer is not empty)');
  assert.deepEqual(seen, ['m']);
  assert.equal(w.document.getElementById('m').getAttribute('data-ook-menu'), '1');
  assert.equal(run(w, 'custom-menus-open'), '', 'not opened a second time');
});

test('an open menu takes the person\'s own state first, then consumer / none / other; never employee or partner', () => {
  const w = page('<ul role=listbox><li role=option id=a>Employee</li><li role=option id=b>Illinois</li><li role=option id=c>Consumer</li></ul>');
  const seen = clicks(w, ['a', 'b', 'c']);
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Illinois');
  assert.deepEqual(seen, ['b']);
  const noState = page('<ul role=listbox><li role=option id=a>Business partner</li><li role=option id=c>Consumer</li></ul>');
  assert.equal(call(noState, 'custom-menus-pick', ''), 'Consumer');
  const none = page('<ul role=listbox><li role=option>Vendor</li><li role=option>No relationship</li></ul>');
  assert.equal(call(none, 'custom-menus-pick', ''), 'No relationship');
});

test('a home-made menu showing only "Choose state" over a hidden list is opened, and its state option is taken (saymine)', () => {
  const html = '<div id=w><input type=checkbox id=t style="display:none"><label id=l for=t><span>Choose state</span></label>' +
    '<ul id=p style="display:none"><li class="dropdown__option" data-label=Alabama>Alabama</li><li class="dropdown__option" data-label=Alaska>Alaska</li>' +
    '<li class="dropdown__option" data-label=Illinois id=il>Illinois</li></ul></div><div><span>Choose a colour</span></div>';
  const w = page(html);
  w.document.getElementById('l').addEventListener('click', () => { w.document.getElementById('p').style.display = 'block'; });
  assert.notEqual(run(w, 'custom-menus-open'), '', 'the placeholder box was pressed');
  assert.equal(w.document.getElementById('p').style.display, 'block', 'the press reached the box (the innermost one, the placeholder, inside its label) and opened the list');
  assert.equal(w.document.querySelectorAll('[data-ook-menu]').length, 1, 'one box pressed and marked');
  const picked = clicks(w, ['il']);
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Illinois');
  assert.deepEqual(picked, ['il']);
  assert.equal(run(w, 'custom-menus-open'), '', 'not pressed again; "Choose a colour" has no list of options beside it');
  const chosen = page('<div><label>Illinois</label><ul style="display:none"><li>Alabama</li><li>Alaska</li><li>Illinois</li></ul></div>');
  assert.equal(run(chosen, 'custom-menus-open'), '', 'a box already showing a choice is left alone');
  const real = page('<select><option>Choose state</option><option>Alabama</option></select>');
  assert.equal(run(real, 'custom-menus-open'), '', 'a real menu is not one of these');
});

test('a request-type menu takes deletion, then opting out; never access, correct or update, even as the last option (azira.com\'s TrustArc form)', () => {
  const opts = ['Access My Information', 'Delete My Information', 'Opt-out or Unsubscribe', 'Do not Sell or Share My Personal Information', 'Withdraw My Consent', 'Correct or Update My Information'];
  const w = page('<ul role=listbox>' + opts.map((o, i) => `<li role=option id=o${i}>${o}</li>`).join('') + '</ul>');
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Delete My Information');
  const noDelete = page('<ul role=listbox><li role=option>Access My Information</li><li role=option>Opt-out or Unsubscribe</li><li role=option>Correct or Update My Information</li></ul>');
  assert.equal(call(noDelete, 'custom-menus-pick', ''), 'Opt-out or Unsubscribe');
  const onlyBad = page('<ul role=listbox><li role=option>Access My Information</li><li role=option>Correct or Update My Information</li></ul>');
  assert.equal(call(onlyBad, 'custom-menus-pick', ''), '', 'nothing suitable: left for the person, not the last option');
  const who = page('<div role=listbox><div role=option>Agent</div><div role=option>Individual</div></div>');
  assert.equal(call(who, 'custom-menus-pick', ''), 'Individual');
});

test('a menu that did not open on the first press is pressed once more, and only once', () => {
  const w = page('<div><span>Type of Request</span><input role=combobox id=m></div>');
  assert.notEqual(run(w, 'custom-menus-open'), '');
  assert.equal(call(w, 'custom-menus-pick', ''), '', 'no options showed');
  assert.notEqual(run(w, 'custom-menus-open'), '', 'pressed again');
  assert.equal(call(w, 'custom-menus-pick', ''), '');
  assert.equal(run(w, 'custom-menus-open'), '', 'not a third time');
});

test('a state with regex characters in its name is matched as written', () => {
  const w = page('<ul role=listbox><li role=option>Other</li><li role=option>St. (Saint) Kitts</li></ul>');
  assert.equal(call(w, 'custom-menus-pick', 'St. (Saint) Kitts'), 'St. (Saint) Kitts');
});

// ---- type-ahead-open.js and type-ahead-choose.js

test('a state type-ahead gets the state typed in (once), a country one the country; then the exact option is chosen', () => {
  const w = page('<label for=s>State of residence</label><input id=s aria-autocomplete=list><label for=c>Country</label><input id=c aria-autocomplete=list>');
  assert.equal(call(w, 'type-ahead-open', 'state', 'Illinois'), true);
  assert.equal(w.document.getElementById('s').value, 'Illinois');
  assert.equal(w.document.getElementById('c').value, '', 'the state is not typed into the country box');
  assert.equal(call(w, 'type-ahead-open', 'state', 'Illinois'), false, 'typed once');
  assert.equal(call(w, 'type-ahead-open', 'country', 'United States'), true);
  assert.equal(w.document.getElementById('c').value, 'United States');
  const list = page('<ul role=listbox><li role=option id=a>Illinois Valley</li><li role=option id=b>Illinois</li></ul>');
  const seen = clicks(list, ['a', 'b']);
  assert.equal(call(list, 'type-ahead-choose', 'Illinois'), true);
  assert.deepEqual(seen, ['b'], 'the exact name, not one that starts with it');
});

// ---- press-live-submit.js

test('the form\'s submit button is pressed; "agree", "cancel" and "add another" never are', () => {
  const w = page('<form data-ook-form="f0"><input name=e><button type=button id=ag>I agree</button><button type=button id=can>Cancel</button><button type=submit id=go>Submit request</button></form>');
  const seen = clicks(w, ['ag', 'can', 'go']);
  assert.equal(call(w, 'press-live-submit', 'f0'), true);
  assert.deepEqual(seen, ['go']);
});

test('a sign-up, newsletter or demo button is never pressed, whatever the form around it says; "Unsubscribe" is fine', () => {
  for (const label of ['Subscribe', 'Sign up', 'Request a demo', 'Create an account', 'Contact sales']) {
    const w = page(`<form data-ook-form="f0"><input name=e><button type=submit id=b>${label}</button></form>`);
    const seen = clicks(w, ['b']);
    assert.equal(call(w, 'press-live-submit', 'f0'), false, label);
    assert.deepEqual(seen, [], label);
    assert.equal(w.__submits.length, 0, `${label}: the form is not sent another way either`);
  }
  const unsub = page('<form data-ook-form="f0"><input name=e><button type=submit id=b>Unsubscribe me</button></form>');
  assert.equal(call(unsub, 'press-live-submit', 'f0'), true);
});

test('a form with no button is sent with requestSubmit', () => {
  const w = page('<form data-ook-form="f0"><input name=e></form>');
  assert.equal(call(w, 'press-live-submit', 'f0'), true);
  assert.equal(w.__submits.length, 1);
  assert.equal(call(page('<form></form>'), 'press-live-submit', 'missing'), false);
});

test('once the person has touched the page, a form with a required box still empty is not pressed (the browser would scroll to it); before, it is', () => {
  const html = '<form data-ook-form="f0"><input name=e value=a><input name=case required><button type=submit id=go>Submit</button></form>';
  const w = page(html);
  w.__ookUserAt = Date.now();
  const seen = clicks(w, ['go']);
  assert.equal(call(w, 'press-live-submit', 'f0'), 'invalid');
  assert.deepEqual(seen, [], 'not pressed');
  w.document.querySelector('[name=case]').value = '123';
  assert.equal(call(w, 'press-live-submit', 'f0'), true, 'filled: pressed');
  const untouched = page(html);
  assert.equal(call(untouched, 'press-live-submit', 'f0'), true, 'not touched: pressed as before');
  const stored = page('<form><input name=email value=a><input name=case required><button id=go>Send</button></form>');
  stored.__ookUserAt = Date.now();
  assert.equal(call(stored, 'press-submit', 'email'), 'invalid', 'the stored-plan press too');
});

// ---- fill-fields.js and press-submit.js (the stored-plan path)

test('fill-fields types by name or id, and sets a menu by value or text', () => {
  const w = page('<form><input name=first><input id=last><select name=st><option value="">-</option><option value=IL>Illinois</option></select></form>');
  const values = [{ name: 'first', candidates: ['Pat'] }, { name: 'last', candidates: ["O'Brien"] }, { name: 'st', candidates: ['illinois'] }, { name: 'none', candidates: ['x'] }];
  assert.equal(callJSON(w, 'fill-fields', JSON.stringify(values)), 3);
  assert.equal(w.document.querySelector('[name=first]').value, 'Pat');
  assert.equal(w.document.getElementById('last').value, "O'Brien");
  assert.equal(w.document.querySelector('[name=st]').value, 'IL');
});

test('a field name holding a quote or backslash is found, not a broken selector', () => {
  const w = page('<form><input name=\'a"b\'><input name="c\\d"><button id=go>Send</button></form>');
  assert.equal(callJSON(w, 'fill-fields', JSON.stringify([{ name: 'a"b', candidates: ['x'] }, { name: 'c\\d', candidates: ['y'] }])), 2);
  assert.equal(w.document.querySelector('form').elements[0].value, 'x');
  assert.equal(w.document.querySelector('form').elements[1].value, 'y');
  assert.equal(call(w, 'press-submit', 'a"b'), true);
});

test('press-submit presses the form\'s submit button, skipping an "I agree" one, and finds the form by a field\'s name', () => {
  const w = page('<form><input name=email><input type=submit id=ag value="I agree"><button id=go>Send</button></form>');
  const seen = clicks(w, ['ag', 'go']);
  assert.equal(call(w, 'press-submit', 'email'), true);
  assert.deepEqual(seen, ['go']);
  assert.equal(call(page('<input name=email>'), 'press-submit', 'email'), false, 'a box outside a form has nothing to send');
});

// ---- submit-form.js

test('submit-form posts the fields as hidden inputs to the action, values exactly as given', () => {
  const w = page('<p>page</p>');
  call(w, 'submit-form', 'https://broker.example/optout', [['name', "O'Brien \"Pat\""], ['email', 'pat@example.com']]);
  assert.equal(w.__submits.length, 1);
  const f = w.__submits[0];
  assert.equal(f.method, 'post');
  assert.equal(f.action, 'https://broker.example/optout');
  assert.deepEqual([...f.querySelectorAll('input')].map((i) => [i.type, i.name, i.value]), [['hidden', 'name', "O'Brien \"Pat\""], ['hidden', 'email', 'pat@example.com']]);
});
