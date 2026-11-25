// Custom menus and type-aheads (a styled list instead of a <select>), and sending: the opt-out form's own send button, never a sign-up or "agree"
// button; the stored-plan filler (fill-fields) and its send (press-submit); and a direct POST (submit-form).
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, run, call, callJSON } = require('../harness');

const clicks = (w, ids) => { const seen = []; for (const id of ids) w.document.getElementById(id).addEventListener('click', () => seen.push(id)); return seen; };

// ---- custom-menus-open.js and custom-menus-pick.js

test('a menu about a company (dnb.com: "Country / Territory of Registration of Company 1") is never opened; the person\'s own is', () => {
  const w = page('<div><span id=c>Select in Country / Territory of Registration of Company 1</span><input role=combobox id=co aria-labelledby=c></div>' +
    '<div><span id=r>Select in Resident of</span><input role=combobox id=res aria-labelledby=r></div>');
  const seen = clicks(w, ['co', 'res']);
  assert.notEqual(call(w, 'custom-menus-open', ''), '');
  assert.deepEqual(seen, ['res']);
  assert.equal(call(w, 'custom-menus-open', ''), '', 'and the company menu is not opened after it');
});

test('an empty custom menu is opened once and marked; one that already shows a choice is not', () => {
  const w = page('<div><span>Relationship</span><div role=combobox id=m></div></div><div role=combobox id=set>Consumer</div>');
  const seen = clicks(w, ['m', 'set']);
  assert.notEqual(call(w, 'custom-menus-open', ''), '', 'something was opened (the app only checks that the answer is not empty)');
  assert.deepEqual(seen, ['m']);
  assert.equal(w.document.getElementById('m').getAttribute('data-ook-menu'), '1');
  assert.equal(call(w, 'custom-menus-open', ''), '', 'not opened a second time');
});

test('a menu showing only its prompt ("Select request type", trustsuperset.com\'s Radix menus) is opened; one showing a choice is not', () => {
  const w = page('<div><label>Request Type*</label><button type=button role=combobox id=rt data-placeholder=""><span>Select request type</span></button></div>' +
    '<div><label>Pronoun</label><button type=button role=combobox id=pr>She</button></div>');
  const seen = clicks(w, ['rt', 'pr']);
  assert.notEqual(call(w, 'custom-menus-open', ''), '');
  assert.deepEqual(seen, ['rt']);
  assert.equal(call(w, 'custom-menus-open', ''), '', 'the menu showing a choice is left alone');
  const unmarked = page('<div><label>Country</label><button type=button role=combobox id=c><span>Select country</span></button></div>');
  assert.notEqual(call(unmarked, 'custom-menus-open', ''), '', 'a prompt is known by its words too');
  const rights = page('<div role=listbox><div role=option>Right to Rectification</div><div role=option>Right to Opt-out of Sales</div><div role=option>Right to Erasure</div></div>');
  assert.equal(call(rights, 'custom-menus-pick', 'Illinois'), 'Right to Erasure', '"Erasure" is a deletion, chosen before an opt-out');
});

test('a menu still fading in is read as open: off screen the page is not drawn and the fade never ends (DataGrail\'s relationship menu); a closed list is not', () => {
  const w = page('<div class=paper id=paper style="opacity:0"><ul role=listbox><li role=option id=a>Employee</li><li role=option id=o>Other</li></ul></div>');
  w.document.getElementById('paper').getAnimations = () => [{ playState: 'running' }];
  const seen = clicks(w, ['a', 'o']);
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Other');
  assert.deepEqual(seen, ['o']);
  const closed = page('<div style="opacity:0"><ul role=listbox><li role=option id=o>Other</li></ul></div>');
  const none = clicks(closed, ['o']);
  assert.equal(call(closed, 'custom-menus-pick', 'Illinois'), '');
  assert.deepEqual(none, [], 'a list hidden with no fade under way is not open');
});

test('a script that focuses a box never lets the browser scroll to it (a person reading the page would be moved)', () => {
  const watch = (w) => { const calls = []; const f = w.HTMLElement.prototype.focus; w.HTMLElement.prototype.focus = function (o) { calls.push(o); return f.call(this, o); }; return calls; };
  const menu = page('<div><span>State</span><input role=combobox id=m></div>');
  const menuCalls = watch(menu);
  assert.notEqual(call(menu, 'custom-menus-open', ''), '');
  const rich = page('<form><div contenteditable="true" data-ook=m></div></form>');
  const richCalls = watch(rich);
  callJSON(rich, 'fill-live', JSON.stringify([{ name: 'm', candidates: ['Please delete my data.'], label: '' }]), 'false');
  for (const calls of [menuCalls, richCalls]) {
    assert.ok(calls.length > 0, 'the box was focused');
    for (const o of calls) assert.equal(o && o.preventScroll, true);
  }
  // And every focus in every page script says so, so a new one cannot forget.
  const fs = require('fs'); const path = require('path'); const dir = path.join(__dirname, '..', '..', '..', 'App', 'PageScripts');
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.js'))) {
    for (const m of fs.readFileSync(path.join(dir, f), 'utf8').matchAll(/\.focus\(([^)]*)\)/g)) assert.match(m[1], /preventScroll\s*:\s*true/, `${f}: ${m[0]}`);
  }
});

test('a country menu takes the United States; a state menu that does not list the person\'s state chooses nothing and says so (choreograph.com)', () => {
  const opts = (ids) => '<div role=listbox>' + ids.map((t, i) => `<div role=option id=o${i}>${t}</div>`).join('') + '</div>';
  const countries = page(opts(['anguilla', 'united states', 'canada']));
  const seen = clicks(countries, ['o0', 'o1', 'o2']);
  assert.equal(call(countries, 'custom-menus-pick', 'Illinois'), 'united states');
  assert.deepEqual(seen, ['o1']);
  const lawStates = page(opts(['california', 'colorado', 'connecticut', 'oregon', 'texas', 'virginia']));
  const none = clicks(lawStates, ['o0', 'o1', 'o2', 'o3', 'o4', 'o5']);
  assert.equal(call(lawStates, 'custom-menus-pick', 'Illinois'), 'not-offered:Illinois');
  assert.deepEqual(none, [], 'never another state (the last-option rule picked "virginia")');
  const withIL = page(opts(['california', 'illinois', 'texas']));
  const il = clicks(withIL, ['o0', 'o1', 'o2']);
  assert.equal(call(withIL, 'custom-menus-pick', 'Illinois'), 'illinois');
  assert.deepEqual(il, ['o1']);
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
  assert.notEqual(call(w, 'custom-menus-open', ''), '', 'the placeholder box was pressed');
  assert.equal(w.document.getElementById('p').style.display, 'block', 'the press reached the box (the innermost one, the placeholder, inside its label) and opened the list');
  assert.equal(w.document.querySelectorAll('[data-ook-menu]').length, 1, 'one box pressed and marked');
  const picked = clicks(w, ['il']);
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Illinois');
  assert.deepEqual(picked, ['il']);
  assert.equal(call(w, 'custom-menus-open', ''), '', 'not pressed again; "Choose a colour" has no list of options beside it');
  const chosen = page('<div><label>Illinois</label><ul style="display:none"><li>Alabama</li><li>Alaska</li><li>Illinois</li></ul></div>');
  assert.equal(call(chosen, 'custom-menus-open', ''), '', 'a box already showing a choice is left alone');
  const real = page('<select><option>Choose state</option><option>Alabama</option></select>');
  assert.equal(call(real, 'custom-menus-open', ''), '', 'a real menu is not one of these');
});

test('saymine as it really is (360mediadirect.com): closed lists keep their size, hidden by visibility and opacity; State is opened and Illinois taken, never the closed Country list\'s "United States"', () => {
  const dd = (id, shown, items) => `<div class=dropdown__wrapper id=${id}w><input type=checkbox class=dropdown__checkbox id=dropdown-${id}><label class=dropdown__label for=dropdown-${id} id=${id}l>` +
    `<span class=dropdown__symbol></span><span class=${shown ? 'dropdown__selected-value' : 'dropdown__placeholder'}>${shown || 'Choose state'}</span></label>` +
    `<ul class=dropdown__panel id=${id}p style="visibility:hidden;opacity:0">` + items.map((t) => `<li class=dropdown__option data-label="${t}" id="${id}-${t.replace(/ /g, '')}">${t}</li>`).join('') + '</ul></div>';
  const html = '<form><label>Country *</label>' + dd('country', 'United States', ['Anguilla', 'Canada', 'United States']) +
    '<label>State *</label>' + dd('state', '', ['Alabama', 'Alaska', 'Illinois', 'Oregon']) + '</form>';
  const w = page(html, { webkitBoxes: true });
  w.document.getElementById('statel').addEventListener('click', () => { const p = w.document.getElementById('statep'); p.style.visibility = 'visible'; p.style.opacity = '1'; });
  const seen = clicks(w, ['country-UnitedStates', 'state-Illinois']);
  assert.notEqual(call(w, 'custom-menus-open', ''), '', 'the State placeholder was pressed, though its closed options keep their size');
  assert.equal(w.document.getElementById('statep').style.visibility, 'visible', 'and its list opened');
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Illinois');
  assert.deepEqual(seen, ['state-Illinois'], 'the hidden Country list\'s "United States" was never clicked');
});

test('a Country or State menu the page set to another place is opened and set to the person\'s (360mediadirect.com and blackbaud.com showed "Mexico" on the phone)', () => {
  // saymine as on the phone: each menu in its own block with its title, a value already shown, the list closed (hidden by visibility and opacity).
  const dd = (id, title, shown, items) => `<div class=mine-dropdown id=${id}><label class=dropdown__header>${title} *</label><div class=dropdown__wrapper>` +
    `<input type=checkbox class=dropdown__checkbox id=dropdown-${id}><label class=dropdown__label for=dropdown-${id} id=${id}l><span class=dropdown__selected-value>${shown}</span></label>` +
    `<ul class=dropdown__panel id=${id}p style="visibility:hidden;opacity:0">` + items.map((t) => `<li class=dropdown__option data-label="${t}" id="${id}-${t.replace(/ /g, '')}">${t}</li>`).join('') + '</ul></div></div>';
  const html = '<form>' + dd('country', 'Country', 'Mexico', ['Canada', 'Mexico', 'United States']) + dd('state', 'State', 'Zacatecas', ['Jalisco', 'Zacatecas']) + '</form>';
  const w = page(html, { webkitBoxes: true });
  const openOn = (id) => w.document.getElementById(id + 'l').addEventListener('click', () => { const p = w.document.getElementById(id + 'p'); p.style.visibility = 'visible'; p.style.opacity = '1'; });
  openOn('country'); openOn('state');
  const seen = clicks(w, ['country-UnitedStates', 'country-Mexico']);
  assert.notEqual(call(w, 'custom-menus-open', 'Illinois'), '', 'the Country menu showing Mexico was opened');
  assert.equal(w.document.getElementById('countryp').style.visibility, 'visible');
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'United States');
  assert.deepEqual(seen, ['country-UnitedStates']);
  // Then the State menu, which also showed another place, is opened on the next call (only the menu opened is marked as done).
  assert.notEqual(call(w, 'custom-menus-open', 'Illinois'), '', 'the State menu showing Zacatecas was opened next');
  assert.equal(w.document.getElementById('statep').style.visibility, 'visible');
  assert.equal(call(w, 'custom-menus-open', 'Illinois'), '', 'each menu is opened once');
  // The page then shows the US: Country reads United States, State has the person's choices.
  const ok = page('<form>' + dd('country', 'Country', 'United States', ['Canada', 'United States']) + dd('state', 'State', 'Illinois', ['Alabama', 'Illinois']) + '</form>', { webkitBoxes: true });
  assert.equal(call(ok, 'custom-menus-open', 'Illinois'), '', 'a menu already showing the person\'s country and state is left alone');
  // Without the person's state nothing is known to be wrong: only empty menus are opened, as before.
  const none = page('<form>' + dd('country', 'Country', 'Mexico', ['Mexico', 'United States']) + '</form>', { webkitBoxes: true });
  assert.equal(call(none, 'custom-menus-open', ''), '');
  // A menu about a company keeps its place.
  const company = page('<form><div class=x><label>Company country</label><div role=combobox id=cc>Mexico</div></div></form>');
  assert.equal(call(company, 'custom-menus-open', 'Illinois'), '');
});

test('a type-to-search menu whose typing box is see-through until typed into is opened, also when it shows its prompt as a value (choreograph.com: react-select)', () => {
  const sel = (id, shown) => `<div class=rs-container><div class="rs__control" id=${id}c><div class="rs__value-container"><div class="rs__single-value">${shown}</div>` +
    `<input role=combobox id=${id} style="opacity:0" value=""></div></div></div>`;
  const w = page('<main>' + sel('lang', 'English') + '<p>Please select your country of residence to continue.</p>' + sel('country', 'select your country of residence') + '</main>');
  const seen = clicks(w, ['lang', 'country']);
  assert.notEqual(call(w, 'custom-menus-open', 'Illinois'), '', 'the country menu was opened');
  assert.deepEqual(seen, ['country'], 'not the language menu, which shows a real choice');
  assert.equal(call(w, 'custom-menus-open', 'Illinois'), '', 'and nothing else is left to open');
});

test('"I am a": "Data subject making a request" is taken, never the authorized agent (dnb.com, eyeota.com, netwisedata.com: TrustArc)', () => {
  const w = page('<div role=listbox><div role=option id=s>Data subject making a request</div><div role=option id=a>Authorized Agent making a request on behalf of a data subject</div></div>');
  const seen = clicks(w, ['s', 'a']);
  assert.equal(call(w, 'custom-menus-pick', 'Illinois'), 'Data subject making a request');
  assert.deepEqual(seen, ['s']);
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
  assert.notEqual(call(w, 'custom-menus-open', ''), '');
  assert.equal(call(w, 'custom-menus-pick', ''), '', 'no options showed');
  assert.notEqual(call(w, 'custom-menus-open', ''), '', 'pressed again');
  assert.equal(call(w, 'custom-menus-pick', ''), '');
  assert.equal(call(w, 'custom-menus-open', ''), '', 'not a third time');
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

test('a type-ahead named only by aria-labelledby is found; "Resident of" takes the state; a company\'s country box is left alone (dnb.com, TrustArc)', () => {
  const w = page('<span id=r>Select in Resident of</span><input id=res role=combobox aria-autocomplete=list aria-labelledby=r value=IL>' +
    '<span id=c>Select in Country / Territory of Registration of Company 1</span><input id=co role=combobox aria-autocomplete=list aria-labelledby=c>');
  assert.equal(call(w, 'type-ahead-open', 'country', 'United States'), false, 'the company\'s country is not the person\'s');
  assert.equal(w.document.getElementById('co').value, '');
  assert.equal(call(w, 'type-ahead-open', 'state', 'Illinois'), true);
  assert.equal(w.document.getElementById('res').value, 'Illinois', 'the full name replaces the "IL" the fill typed, so the list shows Illinois to choose');
});

test('a type-ahead whose list closed again (TrustArc on a phone: "Illinois" listed for under half a second) gets the down arrow in its box, which opens it again', () => {
  const w = page('<span id=r>Select in Resident of</span><input id=res role=combobox aria-autocomplete=list aria-labelledby=r>');
  const box = w.document.getElementById('res');
  call(w, 'type-ahead-open', 'state', 'Illinois');
  box.focus();
  const keys = []; box.addEventListener('keydown', (e) => keys.push(e.key));
  assert.equal(call(w, 'type-ahead-choose', 'Illinois'), false, 'no list showing: nothing chosen yet');
  assert.deepEqual(keys, ['ArrowDown'], 'the list is asked to open again');
  const shut = page('<input id=x aria-autocomplete=list>');
  const none = []; shut.document.getElementById('x').addEventListener('keydown', (e) => none.push(e.key));
  shut.document.getElementById('x').focus();
  call(shut, 'type-ahead-choose', 'Illinois');
  assert.deepEqual(none, [], 'a box with nothing typed in is left alone');
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

test('a form marked novalidate checks itself, so it is pressed even with the browser\'s check failing (arrests.org: "myself" and "agent" both required, one ticked)', () => {
  const html = '<form data-ook-form="f0" novalidate><label><input type=checkbox name=who required checked> I am submitting this request for myself.</label>' +
    '<label><input type=checkbox name=who required> I am an authorized agent</label><input name=first value=Pat required><button type=submit id=go>Submit</button></form>';
  const w = page(html);
  w.__ookUserAt = Date.now();
  const seen = clicks(w, ['go']);
  assert.equal(call(w, 'press-live-submit', 'f0'), true);
  assert.deepEqual(seen, ['go'], 'pressed');
  const stored = page('<form novalidate><input name=email value=a><input name=case required><button id=go>Send</button></form>');
  stored.__ookUserAt = Date.now();
  assert.equal(call(stored, 'press-submit', 'email'), true, 'the stored-plan press too');
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

test('several send buttons for different requests: Delete is pressed, never Export (privacy.sojern.com: Export, Delete, Opt Out)', () => {
  const w = page('<form data-ook-form="f0"><input type=email name=email_address value="pat@example.com">' +
    '<input type=submit name=op value="Export" id=ex><input type=submit name=op value="Delete" id=del><input type=submit name=op value="Opt Out" id=opt></form>');
  const seen = clicks(w, ['ex', 'del', 'opt']);
  assert.equal(call(w, 'press-live-submit', 'f0'), true);
  assert.deepEqual(seen, ['del']);
  const noDelete = page('<form data-ook-form="f0"><input type=submit value="Export" id=ex><input type=submit value="Opt Out" id=opt></form>');
  const seen2 = clicks(noDelete, ['ex', 'opt']);
  call(noDelete, 'press-live-submit', 'f0');
  assert.deepEqual(seen2, ['opt'], 'then opting out');
  const one = page('<form data-ook-form="f0"><input type=email value="a@b.c"><button type=submit id=go>Submit</button></form>');
  const seen3 = clicks(one, ['go']);
  call(one, 'press-live-submit', 'f0');
  assert.deepEqual(seen3, ['go'], 'one send button is pressed whatever it says');
});

