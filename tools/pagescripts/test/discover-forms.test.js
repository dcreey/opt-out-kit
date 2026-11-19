// discover-forms.js: every form on the page, with its boxes (token, name, type, label, required, visible, disabled), its visible buttons and the text
// around it. The app picks the opt-out form and plans what to type from this (LiveFormPicker, FormFiller), so what it reads is what gets filled.
const test = require('node:test');
const assert = require('node:assert/strict');
const { page, run } = require('../harness');

const forms = (html, opts) => { const w = page(html, opts); return { w, out: JSON.parse(run(w, 'discover-forms')) }; };
const field = (f, name) => f.fields.find((x) => x.name === name);

test('each form and box gets a token, set on the page so later steps find the same element', () => {
  const { w, out } = forms('<form><input name=a></form><form><input name=b><input name=c></form>');
  assert.deepEqual(out.map((f) => f.token), ['f0', 'f1']);
  assert.deepEqual(out[1].fields.map((x) => x.token), ['f1-0', 'f1-1']);
  assert.equal(w.document.querySelector('[name=c]').getAttribute('data-ook'), 'f1-1');
  assert.equal(w.document.querySelectorAll('form')[1].getAttribute('data-ook-form'), 'f1');
});

test('a label is read from label[for], a wrapping label, aria-labelledby, aria-label, placeholder, title, then the text before or around it', () => {
  const { out } = forms(`<form>
    <label for=i1>First name</label><input id=i1 name=l1>
    <label>Last name <input name=l2></label>
    <h3 id=q1>Your</h3><h3 id=q2>email</h3><input name=l3 aria-labelledby="q1 q2">
    <input name=l4 aria-label="Phone number">
    <input name=l5 placeholder="City">
    <input name=l6 title="ZIP code">
    <div><span>Street address</span><input name=l7></div>
    <div>State of residence <input name=l8></div></form>`);
  const f = out[0];
  assert.equal(field(f, 'l1').label, 'First name');
  assert.equal(field(f, 'l2').label, 'Last name');
  assert.equal(field(f, 'l3').label, 'Your email', 'every id it points at, joined');
  assert.equal(field(f, 'l4').label, 'Phone number');
  assert.equal(field(f, 'l5').label, 'City');
  assert.equal(field(f, 'l6').label, 'ZIP code');
  assert.equal(field(f, 'l7').label, 'Street address', 'the element just before it');
  assert.equal(field(f, 'l8').label, 'State of residence', "its parent's text");
});

test('a box with no label of its own does not borrow the label of the box before it', () => {
  const { out } = forms('<form><label>Email *<input name=email></label><input name=nick><span>Street</span><input name=street></form>');
  const f = out[0];
  assert.notEqual(field(f, 'nick').label, 'Email *', 'the label before it belongs to the email box');
  assert.equal(field(f, 'nick').required, false, "so it is not taken as required either");
  assert.equal(field(f, 'street').label, 'Street', 'a plain caption before a box is still its label');
  const forOther = forms('<form><div><label for=a>First name</label><input id=a name=a></div><div><label for=a>First name</label><input id=b name=b><input name=c></div></form>').out[0];
  assert.notEqual(field(forOther, 'b').label, 'First name', 'a label for another box on the page is not this box\'s');
  const missing = forms('<form><label for=nope>Last name</label><input id=b name=b></form>').out[0];
  assert.equal(field(missing, 'b').label, 'Last name', 'a label for an id that does not exist is taken as this box\'s (the page\'s own mistake)');
});

test('buttons and hidden inputs are not boxes; a box is required when marked so or its label has a star', () => {
  const { out } = forms(`<form><input type=hidden name=h><input type=submit name=s value=Go><input type=button name=b><input type=image name=im>
    <input type=reset name=r><input name=req required><label>Email *<input name=star></label><input name=opt aria-label="Nickname"><input name=off disabled aria-label="Code"></form>`);
  const f = out[0];
  assert.deepEqual(f.fields.map((x) => x.name), ['req', 'star', 'opt', 'off']);
  assert.equal(field(f, 'req').required, true);
  assert.equal(field(f, 'star').required, true, 'a star in the label');
  assert.equal(field(f, 'opt').required, false);
  assert.equal(field(f, 'off').disabled, true);
});

test('a box that is not shown is marked not visible: hidden, off screen (a bot trap), or inside a box of no height', () => {
  const { out } = forms(`<form><input name=shown><input name=none style="display:none"><input name=invisible style="visibility:hidden">
    <div style="position:absolute;left:-9999px"><input name=trap></div>
    <div style="overflow:hidden;height:0"><input name=folded></div></form>`);
  const f = out[0];
  assert.equal(field(f, 'shown').visible, true);
  for (const n of ['none', 'invisible', 'trap', 'folded']) assert.equal(field(f, n).visible, false, n);
});

test('a select is "select", a textarea and a rich-text box are "textarea", a nested rich-text box is not counted twice', () => {
  const { out } = forms(`<form><select name=st><option>IL</option></select><textarea name=msg></textarea>
    <div contenteditable="true" id=rich><p contenteditable="true" id=inner>x</p></div><input type=email name=em><input name=plain></form>`);
  const f = out[0];
  assert.equal(field(f, 'st').type, 'select');
  assert.equal(field(f, 'msg').type, 'textarea');
  assert.equal(field(f, 'rich').type, 'textarea');
  assert.equal(field(f, 'inner'), undefined, 'the inner editable is part of the outer one');
  assert.equal(field(f, 'em').type, 'email');
  assert.equal(field(f, 'plain').type, 'text');
});

test('the visible buttons are listed with their text; the form keeps its action and method', () => {
  const { out } = forms(`<form action="/optout" method="post"><input name=a><button>Submit request</button><input type=submit value="Send">
    <button style="display:none">Hidden</button><div role=button>Next</div></form>`);
  assert.deepEqual(out[0].buttons, ['Submit request', 'Send', 'Next']);
  assert.equal(out[0].action, '/optout');
  assert.equal(out[0].method, 'post');
});

test('boxes outside any form become one form "fx" on the body; search boxes and hidden ones are left out', () => {
  const { w, out } = forms(`<div><h2>Do not sell my information</h2><p>Fill this in to opt out of the sale of your data.</p>
    <input name=email placeholder=Email><input type=search name=q><input name=gone style="display:none"><button>Opt out</button></div>`);
  const fx = out.find((f) => f.token === 'fx');
  assert.ok(fx, 'a form made of the loose boxes');
  assert.deepEqual(fx.fields.map((x) => x.name), ['email']);
  assert.equal(w.document.body.getAttribute('data-ook-form'), 'fx');
  assert.deepEqual(fx.buttons, ['Opt out'], "the buttons beside them");
  assert.equal(fx.head, '', 'no heading before the block itself');
});

test('a lone rich-text box with no other box is not a form (a comment box)', () => {
  const { out } = forms('<div><div contenteditable="true">Leave a comment</div><button>Post</button></div>');
  assert.equal(out.length, 0);
});

test('the heading before a form and the text around it are kept, so the picker can tell an opt-out form from a newsletter box', () => {
  const { out } = forms(`<section><h2>Request to delete my data</h2><div><form><input name=email><button>Send</button></form></div></section>
    <footer><h4>Newsletter</h4><form><input name=news><button>Subscribe</button></form></footer>`);
  assert.equal(out[0].head, 'Request to delete my data');
  assert.equal(out[1].head, 'Newsletter');
  assert.match(out[0].text, /Send/);
});
