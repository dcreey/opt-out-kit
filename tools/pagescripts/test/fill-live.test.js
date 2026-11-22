// fill-live.js: types the planned values into the boxes the app chose (by token), the way a page notices (input and change events), and never undoes
// what the person typed. Called as PageScript.call("fill-live", json: [values, keepExisting]). Returns {filled, unmatched}.
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, callJSON } = require('../harness');

// values: [{name: token, candidates: [...], label}]
function fill(html, values, keepExisting = false) {
  const w = page(html);
  const out = JSON.parse(callJSON(w, 'fill-live', JSON.stringify(values), keepExisting ? 'true' : 'false'));
  return { w, out, $: (sel) => w.document.querySelector(sel) };
}
const v = (name, ...candidates) => ({ name, candidates, label: '' });

test('a text box gets the first value, with input and change events so the page notices', () => {
  const w = page('<form><input data-ook=a></form>');
  const seen = []; for (const t of ['input', 'change']) w.document.querySelector('[data-ook=a]').addEventListener(t, () => seen.push(t));
  const out = JSON.parse(callJSON(w, 'fill-live', JSON.stringify([v('a', 'Pat', 'Patricia')]), 'false'));
  assert.equal(w.document.querySelector('[data-ook=a]').value, 'Pat');
  assert.deepEqual(seen, ['input', 'change']);
  assert.deepEqual(out, { filled: 1, unmatched: [] });
});

test('a value with quotes, an apostrophe or accents is typed exactly as given', () => {
  const { $ } = fill('<form><input data-ook=a><input data-ook=b></form>', [v('a', "O'Brien \"Pat\""), v('b', 'José Ñúñez')]);
  assert.equal($('[data-ook=a]').value, "O'Brien \"Pat\"");
  assert.equal($('[data-ook=b]').value, 'José Ñúñez');
});

test('what the person typed or changed is theirs: a box they touched is left alone and counted as filled', () => {
  const { $, out } = fill('<form><input data-ook=a data-ook-user=1 value="Mine"></form>', [v('a', 'Pat')]);
  assert.equal($('[data-ook=a]').value, 'Mine');
  assert.equal(out.filled, 1);
});

test('a box that already holds something keeps it, unless it is what this fill typed before (then a new plan replaces it)', () => {
  const kept = fill('<form><input data-ook=a value="Already here"></form>', [v('a', 'Pat')]);
  assert.equal(kept.$('[data-ook=a]').value, 'Already here');
  const ours = fill('<form><input data-ook=a value="Old plan" data-ook-last="Old plan"></form>', [v('a', 'New plan')]);
  assert.equal(ours.$('[data-ook=a]').value, 'New plan', 'what the app typed itself gives way to the new value');
});

test('with keepExisting, a box that holds something keeps it even when the app typed it', () => {
  const { $, out } = fill('<form><input data-ook=a value="From the email link" data-ook-last="From the email link"></form>', [v('a', 'Pat')], true);
  assert.equal($('[data-ook=a]').value, 'From the email link');
  assert.equal(out.filled, 1);
});

test('a State or Country the page ships with gives way to the person\'s own; other prefilled boxes stay', () => {
  const { $ } = fill(`<form><select data-ook=st name=state><option value="">Choose</option><option value=CA selected>California</option><option value=IL>Illinois</option></select>
    <input data-ook=co name=company value="Acme"></form>`,
    [{ name: 'st', candidates: ['IL', 'Illinois'], label: 'State' }, { name: 'co', candidates: ['Other'], label: 'Company' }]);
  assert.equal($('[data-ook=st]').value, 'IL', 'the page default is not the person\'s choice');
  assert.equal($('[data-ook=co]').value, 'Acme');
});

test('an email box that ships holding words, not an address, takes the person\'s address', () => {
  const { $ } = fill('<form><input type=email data-ook=e value="your email"></form>', [v('e', 'pat@example.com')]);
  assert.equal($('[data-ook=e]').value, 'pat@example.com');
});

test('a box with a character limit gets the first value that fits, else the first cut at a sentence end', () => {
  const alt = fill('<form><textarea data-ook=m maxlength=40></textarea></form>', [v('m', 'A very long request that does not fit in forty characters at all.', 'Please delete my data.')]);
  assert.equal(alt.$('[data-ook=m]').value, 'Please delete my data.');
  const cut = fill('<form><textarea data-ook=m maxlength=60></textarea></form>', [v('m', 'Please delete all my personal data. I do not consent to its sale or sharing in any way.')]);
  assert.equal(cut.$('[data-ook=m]').value, 'Please delete all my personal data.');
});

test('a menu is set by option value or text, or by the state inside an option ("IL - Illinois"), never to an "Other" option by a partial match', () => {
  const byValue = fill('<form><select data-ook=s><option value="">-</option><option value=IL>Illinois</option></select></form>', [v('s', 'IL')]);
  assert.equal(byValue.$('[data-ook=s]').value, 'IL');
  const byText = fill('<form><select data-ook=s><option value="">-</option><option value=17>Illinois</option></select></form>', [v('s', 'illinois')]);
  assert.equal(byText.$('[data-ook=s]').value, '17');
  const inside = fill('<form><select data-ook=s><option value="">-</option><option value=x>Other state</option><option value=il>IL - Illinois</option></select></form>', [v('s', 'IL')]);
  assert.equal(inside.$('[data-ook=s]').value, 'il', 'the code as a whole word, not inside "Other"');
});

test('an age against a menu of brackets takes the bracket it falls in', () => {
  const html = '<form><select data-ook=a><option value="">-</option><option value=1>Under 18</option><option value=2>18-24</option><option value=3>25 to 34</option><option value=4>65+</option></select></form>';
  assert.equal(fill(html, [v('a', '30')]).$('[data-ook=a]').value, '3');
  assert.equal(fill(html, [v('a', '70')]).$('[data-ook=a]').value, '4');
  assert.equal(fill(html, [v('a', '16')]).$('[data-ook=a]').value, '1');
});

test('a state menu without the person\'s state takes "Other"; a required menu with no match is reported as unmatched', () => {
  const other = fill('<form><select data-ook=s name=state><option value="">-</option><option value=CA>California</option><option value=OT>Other U.S. state</option></select></form>', [v('s', 'IL', 'Illinois')]);
  assert.equal(other.$('[data-ook=s]').value, 'OT');
  const none = fill('<form><select data-ook=s name=pick required><option value="">-</option><option value=a>Apple</option></select></form>', [v('s', 'Pear')]);
  assert.deepEqual(none.out.unmatched, ['Pear']);
  assert.equal(none.out.filled, 0);
});

test('a phone is typed as plain digits (a leading 1 dropped), or in the shape the box\'s pattern asks for', () => {
  const plain = fill('<form><input type=tel data-ook=p></form>', [v('p', '+1 (555) 010-0123')]);
  assert.equal(plain.$('[data-ook=p]').value, '5550100123');
  assert.equal(plain.$('[data-ook=p]').getAttribute('data-ook-phone'), '15550100123', 'kept so the format retry knows the number');
  const shaped = fill('<form><input type=tel data-ook=p pattern="\\d{3}-\\d{3}-\\d{4}"></form>', [v('p', '555-010-0123')]);
  assert.equal(shaped.$('[data-ook=p]').value, '555-010-0123');
});

test('a phone split over three boxes (3, 3 and 4 digits) gets one part in each', () => {
  const { $ } = fill('<form><div><input data-ook=p1 name=phone1 maxlength=3><input data-ook=p2 name=phone2 maxlength=3><input data-ook=p3 name=phone3 maxlength=4></div></form>',
    [v('p1', '5550100123'), v('p2', '5550100123'), v('p3', '5550100123')]);
  assert.deepEqual([$('[data-ook=p1]').value, $('[data-ook=p2]').value, $('[data-ook=p3]').value], ['555', '010', '0123']);
});

test('a phone list ("a, b") is not squashed into one number', () => {
  const { $ } = fill('<form><input type=tel data-ook=p></form>', [v('p', '555-0100, 555-0199')]);
  assert.equal($('[data-ook=p]').value, '555-0100, 555-0199');
});

test('a birthdate in a text box takes the shape its placeholder or the text near it shows, else month/day/year', () => {
  const md = fill('<form><input data-ook=d name=dob></form>', [v('d', '1985-03-14')]);
  assert.equal(md.$('[data-ook=d]').value, '03/14/1985');
  assert.equal(md.$('[data-ook=d]').getAttribute('data-ook-dob'), '1985-03-14');
  assert.equal(fill('<form><input data-ook=d name=dob placeholder="DD/MM/YYYY"></form>', [v('d', '1985-03-14')]).$('[data-ook=d]').value, '14/03/1985');
  assert.equal(fill('<form><input data-ook=d name=dob placeholder="yyyy-mm-dd"></form>', [v('d', '1985-03-14')]).$('[data-ook=d]').value, '1985-03-14');
  assert.equal(fill('<form><label>Date of birth (dd.mm.yyyy)<input data-ook=d name=dob></label></form>', [v('d', '1985-03-14')]).$('[data-ook=d]').value, '14.03.1985');
  assert.equal(fill('<form><input type=date data-ook=d name=dob></form>', [v('d', '1985-03-14')]).$('[data-ook=d]').value, '1985-03-14', 'a real date box takes the ISO date');
});

test('a rich-text box (contenteditable) is filled as text', () => {
  const { $ } = fill('<form><div contenteditable="true" data-ook=m></div></form>', [v('m', 'Please delete my data.')]);
  assert.equal($('[data-ook=m]').textContent, 'Please delete my data.');
});

test('a value with no candidates or a token not on the page is skipped without error', () => {
  const { out } = fill('<form><input data-ook=a></form>', [{ name: 'a', candidates: [null], label: '' }, v('missing', 'x')]);
  assert.deepEqual(out, { filled: 0, unmatched: [] });
});

test('a box or menu already showing the person\'s value is not set again, so a page that rebuilds its boxes on change keeps the ones the app fills next (adagio.io)', () => {
  const w = page('<form><select id=c data-ook=c><option value="">--</option><option value=US>United States</option></select><input id=n data-ook=n value="Pat Example"></form>');
  w.document.getElementById('c').value = 'US';
  let changes = 0; w.document.getElementById('c').addEventListener('change', () => changes++);
  let inputs = 0; w.document.getElementById('n').addEventListener('input', () => inputs++);
  const r = JSON.parse(callJSON(w, 'fill-live', JSON.stringify([{ name: 'c', candidates: ['US', 'United States'], label: 'Country', type: 'select' }, { name: 'n', candidates: ['Pat Example'], label: 'Full name', type: 'text' }]), 'true'));
  assert.equal(r.filled, 2, 'both count as filled');
  assert.equal(changes, 0, 'no change event for a menu already on the person\'s country');
  assert.equal(inputs, 0, 'nor an input event for a box already holding their name');
});
