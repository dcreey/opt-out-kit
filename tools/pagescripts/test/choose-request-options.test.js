// choose-request-options.js: inside the chosen form, picks the choices an opt-out needs (radio groups, checkboxes, request-type menus): removal or
// deletion first, then opt-out of sale; never access, correction or marketing; "No" to "are you an agent?", "Yes" to "is this for yourself?"; a plain
// self-declaration only when the owner allowed it. What the person set, or what the app already chose, is never redone.
// Called as PageScript.call("choose-request-options", token, ownerMayConfirm). Returns {chosen, unresolved}.
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, call } = require('../harness');

function choose(inner, ownerMayConfirm = false) {
  const w = page(`<form data-ook-form="f0">${inner}</form>`);
  const out = JSON.parse(call(w, 'choose-request-options', 'f0', ownerMayConfirm));
  return { w, out, $: (s) => w.document.querySelector(s) };
}
const radio = (name, id, text, extra = '') => `<label><input type=radio name=${name} id=${id} ${extra}> ${text}</label>`;
const box = (id, text, extra = '') => `<label><input type=checkbox id=${id} ${extra}> ${text}</label>`;

test('removing the listing beats a gentler choice, and deleting beats opting out of sale', () => {
  const r = choose(radio('t', 'a', 'Your privacy choices') + radio('t', 'b', 'Remove my information') + radio('t', 'c', 'Do not sell'));
  assert.equal(r.$('#b').checked, true);
  assert.equal(r.out.chosen, 1);
  const d = choose(radio('t', 'a', 'Opt out of sale') + radio('t', 'b', 'Delete my data') + radio('t', 'c', 'Access my data'));
  assert.equal(d.$('#b').checked, true);
});

test('a group of only access, correction or marketing choices is left alone; a required one is reported unresolved', () => {
  const r = choose(radio('t', 'a', 'Right to know', 'required') + radio('t', 'b', 'Correct my data') + radio('t', 'c', 'Subscribe to the newsletter'));
  assert.deepEqual([r.$('#a').checked, r.$('#b').checked, r.$('#c').checked], [false, false, false]);
  assert.deepEqual(r.out.unresolved, ['Right to know']);
});

test('"Are you an authorized agent?" gets No; "Is this request for yourself?" gets Yes', () => {
  const agent = choose('<fieldset><legend>Are you an authorized agent acting on behalf of someone?</legend>' + radio('ag', 'y', 'Yes') + radio('ag', 'n', 'No') + '</fieldset>');
  assert.equal(agent.$('#n').checked, true);
  const self = choose('<fieldset><legend>Are you submitting this request for yourself?</legend>' + radio('me', 'y', 'Yes') + radio('me', 'n', 'No, on behalf of someone') + '</fieldset>');
  assert.equal(self.$('#y').checked, true);
});

test('"Myself" is chosen over "Authorized agent" or "Deceased person"', () => {
  const r = choose(radio('who', 'a', 'Authorized agent') + radio('who', 'b', 'Myself') + radio('who', 'c', 'A deceased person'));
  assert.equal(r.$('#b').checked, true);
});

test('a choice of device ID types takes IDFA (this is an iPhone)', () => {
  const r = choose(radio('dev', 'g', 'GAID (Android)') + radio('dev', 'i', 'IDFA (Apple)'));
  assert.equal(r.$('#i').checked, true);
});

test('checkboxes: "for myself" and opt-out choices are ticked; opt-in, newsletter and access are not', () => {
  const r = choose(box('me', 'I am submitting this request for myself') + box('oo', 'Opt out of the sale of my data') + box('del', 'Delete my personal information')
    + box('oi', 'Opt in to marketing emails') + box('nl', 'Subscribe to our newsletter') + box('acc', 'Send me a copy of my data'));
  assert.deepEqual(['me', 'oo', 'del', 'oi', 'nl', 'acc'].map((i) => r.$('#' + i).checked), [true, true, true, false, false, false]);
  assert.equal(r.out.chosen, 3);
});

test('a plain "I confirm I am the person" box is ticked only when the owner allowed it, and never one about perjury or terms', () => {
  const html = box('decl', 'I confirm that I am the person whose email address is entered above') + box('perj', 'I declare under penalty of perjury that I am the person named')
    + box('terms', 'I confirm I am the person and accept the terms');
  const no = choose(html, false);
  assert.equal(no.$('#decl').checked, false, 'not without the owner\'s permission');
  const yes = choose(html, true);
  assert.equal(yes.$('#decl').checked, true);
  assert.equal(yes.$('#perj').checked, false, 'a legal certification stays the person\'s');
  assert.equal(yes.$('#terms').checked, false);
});

test('a request-type menu takes deletion over opt-out, never access; a state or country menu is not touched', () => {
  const r = choose(`<div>Request type <select id=rt name=request><option value="">Select</option><option>Right to know</option><option>Opt out of sale</option><option>Delete my data</option></select></div>
    <div>State <select id=st name=state><option value="">Select</option><option>Delete</option></select></div>`);
  assert.equal(r.$('#rt').value, 'Delete my data');
  assert.equal(r.$('#st').selectedIndex, 0, 'a menu named state is filled by value elsewhere, never here');
});

test('a "relationship with us" menu takes consumer, not customer, employee or partner', () => {
  const r = choose('<div>What is your relationship with us? <select id=rel name=rel><option value="">Select</option><option>Customer</option><option>Employee</option><option>Consumer</option><option>Business partner</option></select></div>');
  assert.equal(r.$('#rel').value, 'Consumer');
});

test('a required menu with nothing suitable is reported unresolved', () => {
  const r = choose('<div>Department <select id=d name=dept required><option value="">Select</option><option>Sales</option><option>Support</option></select></div>');
  assert.equal(r.$('#d').selectedIndex, 0);
  assert.equal(r.out.unresolved.length, 1);
});

test('what the person set, what the app chose before, and a group already answered are left as they are', () => {
  const touched = choose(radio('t', 'a', 'Opt out of sale', 'data-ook-user=1') + radio('t', 'b', 'Delete my data'));
  assert.equal(touched.$('#b').checked, false, 'the person touched this group');
  const ours = choose(radio('t', 'a', 'Opt out of sale', 'data-ook-auto=1') + radio('t', 'b', 'Delete my data'));
  assert.equal(ours.$('#b').checked, false, 'the app answered this group once already');
  const answered = choose(radio('t', 'a', 'Opt out of sale', 'checked') + radio('t', 'b', 'Access my data'));
  assert.equal(answered.out.chosen, 0);
  const box1 = choose(box('oo', 'Opt out of the sale of my data', 'data-ook-user=1'));
  assert.equal(box1.$('#oo').checked, false, 'a box the person unticked stays unticked');
});

test('a token that is not on the page chooses nothing', () => {
  const w = page('<form><input type=checkbox id=a></form>');
  assert.deepEqual(JSON.parse(call(w, 'choose-request-options', 'nope', false)), { chosen: 0, unresolved: [] });
});

test('a "know" choice that says "me" is not read as the person answering "myself": the opt-out beside it is chosen', () => {
  const r = choose(radio('t', 'a', 'Know what personal information you hold about me') + radio('t', 'b', 'Opt out of the sale or sharing of my personal information') +
                   radio('t', 'c', 'Limit the use of my sensitive personal information'));
  assert.deepEqual([r.$('#a').checked, r.$('#b').checked, r.$('#c').checked], [false, true, false]);
  const delivered = choose(radio('t', 'a', 'Send me a copy of my data') + radio('t', 'b', 'Do not sell my information'));
  assert.deepEqual([delivered.$('#a').checked, delivered.$('#b').checked], [false, true]);
  const who = choose(radio('w', 'a', 'Myself') + radio('w', 'b', 'Authorized agent'));
  assert.equal(who.$('#a').checked, true, 'the real self-answer still wins');
});

test('"I am a (an)": Customer / Authorized Agent takes the one answer that is not someone acting for another (blueaction.io)', () => {
  const r = choose('<label for=t>I am a (an) *</label><select id=t name=typeCode required><option hidden value=""></option><option value=customer>Customer</option><option value=authorized_agent>Authorized Agent</option></select>');
  assert.equal(r.$('#t').value, 'customer');
  const two = choose('<label for=t>I am a</label><select id=t><option value=""></option><option value=c>Customer</option><option value=e>Employee</option><option value=a>Agent</option></select>');
  assert.equal(two.$('#t').value, '', 'two answers of the person\'s own kind: not guessed');
});
