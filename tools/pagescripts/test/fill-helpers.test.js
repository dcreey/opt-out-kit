// The scripts that help the fill finish a form: "Add another" boxes, phone and date shapes a box rejects, a date shape shared by a page's date boxes,
// the first required box still empty, and the request-type tiles some pages use instead of radio boxes.
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, run, call } = require('../harness');

// ---- add-another-boxes.js: presses the form's "Add another email / phone" button when the profile has more values than the form has boxes

test('"Add another email" is pressed when the person has more emails than the form has email boxes', () => {
  const w = page('<form data-ook-form="f0"><label>Email <input type=email name=e1></label><button type=button id=add>+ Add another email</button></form>');
  let pressed = 0; w.document.getElementById('add').addEventListener('click', () => pressed++);
  assert.equal(call(w, 'add-another-boxes', 'f0', 2, 1), true);
  assert.equal(pressed, 1);
  assert.equal(w.document.getElementById('add').getAttribute('data-ook-added'), '1', 'counted, so it is not pressed forever');
});

test('no button is pressed when the form already has enough boxes, or the profile has only one value', () => {
  const w = page('<form data-ook-form="f0"><input type=email name=e1><input type=email name=e2><button type=button>Add another email</button></form>');
  assert.equal(call(w, 'add-another-boxes', 'f0', 2, 0), false);
  assert.equal(call(w, 'add-another-boxes', 'f0', 1, 0), false);
});

test('an add button that could send the form is never pressed: a plain <button> (it submits), a submit, or a link that goes somewhere', () => {
  for (const btn of ['<button id=add>Add another email</button>', '<input type=submit id=add value="Add another email">', '<a id=add href="/next">Add another email</a>']) {
    const w = page(`<form data-ook-form="f0"><input type=email name=e1>${btn}</form>`);
    let pressed = 0; w.document.getElementById('add').addEventListener('click', (e) => { pressed++; e.preventDefault(); });
    assert.equal(call(w, 'add-another-boxes', 'f0', 3, 0), false, btn);
    assert.equal(pressed, 0, btn);
  }
});

test('a "Remove" or "Opt out" button is never taken for an add button', () => {
  const w = page('<form data-ook-form="f0"><input type=email name=e1><button type=button>Remove email</button><button type=button>Opt out more</button></form>');
  assert.equal(call(w, 'add-another-boxes', 'f0', 2, 0), false);
});

test('a page that caps its boxes is not pressed again once a press added no box', () => {
  const w = page('<form data-ook-form="f0"><input type=email name=e1><button type=button id=add>Add another email</button></form>');
  assert.equal(call(w, 'add-another-boxes', 'f0', 3, 0), true, 'the first press');
  assert.equal(call(w, 'add-another-boxes', 'f0', 3, 0), false, 'no new box appeared: the page is at its cap');
});

test('a bare "+" counts only beside a box of its own kind', () => {
  const w = page('<form data-ook-form="f0"><div><input type=tel name=p1><button type=button id=plus>+</button></div><input type=email name=e1></form>');
  assert.equal(call(w, 'add-another-boxes', 'f0', 3, 0), false, 'no + beside the email box');
  assert.equal(call(w, 'add-another-boxes', 'f0', 1, 2), true, 'the + beside the phone box');
});

// ---- phone-format-step.js: a phone box that shows an error is tried in other shapes, one per step

function phonePage(extra = '') {
  return page(`<form><div class=row><input type=tel id=p data-ook-phone="5550100123" data-ook-last="5550100123" value="5550100123" ${extra}></div></form>`);
}

test('a phone box with no error is left as typed', () => {
  const w = phonePage();
  assert.deepEqual(JSON.parse(call(w, 'phone-format-step', 0)), { bad: 0, more: false });
  assert.equal(w.document.getElementById('p').value, '5550100123');
});

test('a phone box that is invalid is tried in the next shape at each step, then goes back to plain digits', () => {
  const w = phonePage('aria-invalid=true');
  const p = w.document.getElementById('p');
  assert.deepEqual(JSON.parse(call(w, 'phone-format-step', 3)), { bad: 1, more: true });
  assert.equal(p.value, '555-010-0123');
  assert.equal(p.getAttribute('data-ook-last'), '555-010-0123', 'so the next step still sees it as the app\'s own value');
  call(w, 'phone-format-step', 99);
  assert.equal(p.value, '5550100123', 'no shape worked: the plain number goes back');
});

test('an error message beside the box counts, and a box the person changed is never touched', () => {
  const msg = page('<form><div><input type=tel id=p data-ook-phone="5550100123" data-ook-last="5550100123" value="5550100123"><span class=error>Enter a valid phone number</span></div></form>');
  assert.equal(JSON.parse(call(msg, 'phone-format-step', 1)).bad, 1);
  const mine = phonePage('aria-invalid=true data-ook-user=1');
  assert.equal(JSON.parse(call(mine, 'phone-format-step', 3)).bad, 0);
  assert.equal(mine.document.getElementById('p').value, '5550100123');
});

// ---- date-format-step.js and align-date-formats.js: a date box that rejects a shape gets the next, and the page's other date boxes follow

test('a date box that shows an error gets the next shape, and remembers which step it is on', () => {
  const w = page('<form><input id=d data-ook-dob="1985-03-14" data-ook-last="03/14/1985" value="03/14/1985" aria-invalid=true></form>');
  const d = w.document.getElementById('d');
  assert.deepEqual(JSON.parse(call(w, 'date-format-step', 0)), { bad: 1, more: true });
  assert.equal(d.value, '14/03/1985');
  assert.equal(d.getAttribute('data-ook-step'), '1');
});

test('a date box with no error, or one the person changed, is left alone', () => {
  const ok = page('<form><input id=d data-ook-dob="1985-03-14" data-ook-last="03/14/1985" value="03/14/1985"></form>');
  assert.equal(JSON.parse(call(ok, 'date-format-step', 0)).bad, 0);
  const typed = page('<form><input id=d data-ook-dob="1985-03-14" data-ook-last="03/14/1985" value="14 March 1985" aria-invalid=true></form>');
  assert.equal(JSON.parse(call(typed, 'date-format-step', 0)).bad, 0, 'its value is no longer the app\'s');
});

test('the other date boxes take the shape a retried box settled on; one with its own placeholder keeps it', () => {
  const w = page(`<form><input id=a data-ook-dob="1985-03-14" data-ook-step=1 data-ook-last="14/03/1985" value="14/03/1985">
    <input id=b data-ook-dob="2026-11-05" data-ook-last="11/05/2026" value="11/05/2026">
    <input id=c data-ook-dob="2026-11-05" data-ook-last="11/05/2026" value="11/05/2026" placeholder="mm/dd/yyyy"></form>`);
  assert.equal(run(w, 'align-date-formats'), 1);
  assert.equal(w.document.getElementById('b').value, '05/11/2026');
  assert.equal(w.document.getElementById('c').value, '11/05/2026');
});

test('with no retried date box nothing is changed', () => {
  const w = page('<form><input id=b data-ook-dob="2026-11-05" data-ook-last="11/05/2026" value="11/05/2026"></form>');
  assert.equal(run(w, 'align-date-formats'), 0);
});

// ---- empty-required-choice.js: the first required box still empty, by its label (a check-code box is the person's)

test('the first required box still empty is named; filled ones, optional ones and check-code boxes are not', () => {
  const w = page(`<form data-ook-form="f0"><label>First name * <input value="Pat"></label><label>Nickname <input></label>
    <label>Verification code * <input></label><label>State * <select><option value="">Choose</option><option>IL</option></select></label></form>`);
  assert.equal(call(w, 'empty-required-choice', 'f0'), 'State', "the label's own words, without the menu's options")
  // A required menu inside a hidden bot trap has no shown label, so it is not something the person must fill (WebKit's LiveFormTests have the real trap).
  const trap = page('<form data-ook-form="f0"><div style="height:0;overflow:hidden;position:absolute;left:-8000px"><label>Send confirmation to *<select><option value="">Choose</option><option>Email</option></select></label></div></form>');
  assert.equal(call(trap, 'empty-required-choice', 'f0'), '');
  const done = page('<form data-ook-form="f0"><input required aria-label="Email" value="pat@example.com"></form>');
  assert.equal(call(done, 'empty-required-choice', 'f0'), '');
});

test('a type-ahead that has a choice (TrustArc on azira.com: the box empties, the choice shows beside it and sits in a hidden field) is not "a required choice"; one with none is', () => {
  const box = (chosen) => `<form data-ook-form="f0"><div class="ta-select"><div class="ta__control"><div class="ta__value-container">` +
    (chosen ? '<div class="ta__single-value">Illinois</div>' : '<div class="ta__placeholder">Select...</div>') +
    `<input id=res role=combobox aria-autocomplete=list aria-required=true value=""></div></div>` +
    `<input type=hidden name=res value="${chosen ? 'NA_US_IL' : ''}"></div></form>`;
  assert.equal(call(page(box(true)), 'empty-required-choice', 'f0'), '', 'the choice shows: answered');
  assert.equal(call(page(box(false)), 'empty-required-choice', 'f0'), 'a required choice', 'nothing chosen: still the person\'s');
  const heldOnly = page('<form data-ook-form="f0"><input id=x role=combobox aria-autocomplete=list aria-required=true><input type=hidden name=x value=NA_US_IL></form>');
  assert.equal(call(heldOnly, 'empty-required-choice', 'f0'), '', 'the hidden field named after the box holds the choice');
});

test('a state menu still empty after the fill says the person\'s state is not on its list (becausal.com lists only the 19 states with privacy laws)', () => {
  const w = page(`<form data-ook-form="f0"><label for=s>Please select the state in which you currently reside (required):</label>
    <select id=s name=Opt-Out-State><option value="">Select your state</option><option>California</option><option>Colorado</option><option>Connecticut</option><option>Delaware</option><option>Indiana</option><option>Iowa</option></select></form>`);
  assert.match(call(w, 'empty-required-choice', 'f0'), /your state is not on its list/);
});

// ---- choose-tile-buttons.js: "I am a(n)" and "Select request type" rows of buttons get the plain consumer answer and the removal request

test('request-type tiles take deletion, and "I am a" tiles take Other or Consumer; access and employee are never chosen', () => {
  const w = page(`<div><p>I am a</p><div><button type=button id=emp>Employee</button><button type=button id=con>Consumer</button></div></div>
    <div><p>Select request type</p><div><button type=button id=acc>Access</button><button type=button id=del>Delete my data</button><button type=button id=oo>Opt out</button></div></div>`);
  const clicked = []; for (const id of ['emp', 'con', 'acc', 'del', 'oo']) w.document.getElementById(id).addEventListener('click', () => clicked.push(id));
  assert.equal(run(w, 'choose-tile-buttons'), 2);
  assert.deepEqual(clicked.sort(), ['con', 'del'], 'each chosen tile tapped once, though its heading and the block around it both read "I am a"');
  assert.equal(w.document.getElementById('del').getAttribute('data-ook-auto'), '1');
});

test('tiles the person tapped, a tile already selected, or a group handled once are not tapped again', () => {
  const w = page('<div><p>Select request type</p><div><button type=button id=acc data-ook-user=1>Access</button><button type=button id=del>Delete</button></div></div>');
  assert.equal(run(w, 'choose-tile-buttons'), 0, 'the person chose in this group');
  const sel = page('<div><p>Select request type</p><div><button type=button aria-pressed=true>Opt out</button><button type=button>Delete</button></div></div>');
  assert.equal(run(sel, 'choose-tile-buttons'), 0, 'one is already selected');
  const once = page('<div><p>Select request type</p><div><button type=button>Access</button><button type=button id=del>Delete</button></div></div>');
  assert.equal(run(once, 'choose-tile-buttons'), 1);
  assert.equal(run(once, 'choose-tile-buttons'), 0, 'handled once per page, so a toggle is not switched back off');
});

test('OneTrust tiles: "Are you an authorized agent ...?" gets No and "Select a Requestor Type" gets Consumer (blackbaud.com)', () => {
  const w = page(`<div><p>* Are you an authorized agent submitting a request on the behalf of someone else?</p><div><button type=button id=no>No</button><button type=button id=yes>Yes</button></div></div>
    <div><p>* Select a Requestor Type</p><div><button type=button id=con>Consumer</button></div></div>
    <div><p>* Select a Request Type</p><div><button type=button id=oo>Data Subject Opt-out Request</button><button type=button id=del>Data Subject Deletion Request</button></div></div>`);
  const clicked = []; for (const id of ['no', 'yes', 'con', 'oo', 'del']) w.document.getElementById(id).addEventListener('click', () => clicked.push(id));
  assert.equal(run(w, 'choose-tile-buttons'), 3);
  assert.deepEqual(clicked.sort(), ['con', 'del', 'no'], 'a group of one tile (Consumer) is chosen too');
  const lone = page('<div><p>I am a</p><div><button type=button id=emp>Employee</button></div></div>');
  const hit = []; lone.document.getElementById('emp').addEventListener('click', () => hit.push(1));
  assert.equal(run(lone, 'choose-tile-buttons'), 0, 'a lone tile that is not the person\'s answer is not tapped');
});

test('a required bot trap is never "a required box still empty" (arrests.org: "Privacy Address", hidden from assistive tech, one pixel tall)', () => {
  const w = page(`<form data-ook-form="f0"><label>First * <input value="Pat" required></label>
    <div style="height:1px"><label>Privacy Address <input required tabindex="-1"></label></div>
    <div aria-hidden="true"><label>Privacy Authorization: <select required><option value="">Choose</option><option>Yes</option></select></label></div></form>`);
  assert.equal(call(w, 'empty-required-choice', 'f0'), '');
});

test('bot-trap: hidden from assistive tech, off the page, or out of the tab order inside a box one pixel tall; nothing else', () => {
  const w = page(`<div aria-hidden="true"><input id=a></div><div style="position:absolute;left:-9999px"><input id=b></div>
    <div style="height:1px"><input id=c tabindex="-1"></div><div style="height:1px"><input id=d></div><input id=e tabindex="-1"><input id=f>`);
  w.eval('(function(){' + require('../harness').source('bot-trap') + '; window.__trap = botTrap;})()');
  const t = (id) => w.__trap(w.document.getElementById(id));
  assert.deepEqual(['a', 'b', 'c', 'd', 'e', 'f'].map(t), [true, true, true, false, false, false]);
});
