// The scripts that find what only a person may do: a human check (visible-challenge), a legal certification box (pending-certification), the plain
// "I am the person" box the owner allowed the app to tick (tick-identity-boxes), and an "I agree to the terms" prompt (find-terms-gate, click-agree).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { page, run, call } = require('../harness');

// The terms-prompt pattern exactly as the app passes it (WebViewSession.gatePattern).
const swift = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'App', 'Sources', 'WebViewFetcher.swift'), 'utf8');
const GATE = /static let gatePattern = #"(.*)"#/.exec(swift)[1];

// ---- visible-challenge.js

test('a page that asks the person to prove they are human is a check, named for what it is', () => {
  assert.equal(run(page('<p>Please confirm you are human before continuing.</p>'), 'visible-challenge') !== null, true);
  assert.equal(run(page('<div class="cf-turnstile"></div>'), 'visible-challenge'), 'a Cloudflare check');
  assert.equal(run(page('<iframe src="https://www.google.com/recaptcha/api2/bframe?k=x"></iframe>'), 'visible-challenge'), 'a reCAPTCHA puzzle');
  assert.equal(run(page('<iframe src="https://www.google.com/recaptcha/api2/anchor?k=x"></iframe>'), 'visible-challenge'), 'a reCAPTCHA checkbox');
  assert.equal(run(page('<iframe src="https://newassets.hcaptcha.com/captcha/v1/x"></iframe>'), 'visible-challenge'), 'an hCaptcha');
});

test('a reCAPTCHA that refused the send is reported, so only the person\'s own press can get past it', () => {
  assert.equal(run(page('<p>The reCAPTCHA could not be verified. Please try again.</p>'), 'visible-challenge'), 'a reCAPTCHA that rejected the automatic send');
});

test('a solved check, the reCAPTCHA badge in the corner, a tiny frame and a plain page are not checks', () => {
  assert.equal(run(page('<iframe src="https://www.google.com/recaptcha/api2/anchor?k=x"></iframe><textarea name="g-recaptcha-response">token</textarea>'), 'visible-challenge'), null, 'solved');
  assert.equal(run(page('<div class="cf-turnstile">Success!</div><input type=hidden name="cf-turnstile-response" value="token">'), 'visible-challenge'), null, 'a Cloudflare check that passed by itself');
  assert.equal(run(page('<div class="grecaptcha-badge"><iframe src="https://www.google.com/recaptcha/api2/anchor?k=x"></iframe></div>'), 'visible-challenge'), null, 'the badge');
  assert.equal(run(page('<p>Thank you, your request was received.</p>'), 'visible-challenge'), null, 'a plain page');
  assert.equal(run(page('<p>Please wait for the anti-spam check.</p><input name="cf-turnstile-response" value="done">'), 'visible-challenge'), null,
    'the left-over line of a check already passed');
});

// ---- pending-certification.js

test('an unticked certification or consent box is returned with its wording, in any of the app\'s languages', () => {
  assert.match(run(page('<label><input type=checkbox> I certify under penalty of perjury that this is true</label>'), 'pending-certification'), /certify under penalty/);
  assert.match(run(page('<label><input type=checkbox> Je certifie que ces informations sont exactes</label>'), 'pending-certification'), /Je certifie/);
  assert.match(run(page('<label><input type=checkbox> Ich bestätige die Richtigkeit</label>'), 'pending-certification'), /Ich bestätige/);
});

test('a bot trap (honeypot) is not a certification: off the page or hidden from assistive tech, with no label, and its form\'s words are not its own (cashmereai.com)', () => {
  const trap = '<form data-ook-form="f0"><input type=checkbox name=botcheck tabindex=-1 aria-hidden=true class=dns-hp style="position:absolute;left:-9999px">' +
    '<fieldset>By submitting you certify and consent that this is your information.<label><input type=radio name=t checked> Opt out</label></fieldset><input name=n></form>';
  assert.equal(run(page(trap), 'pending-certification'), null);
  assert.match(run(page('<form data-ook-form="f0"><label><input type=checkbox> I certify under penalty of perjury</label><input name=n></form>'), 'pending-certification'), /certify/,
    'a real certification box still stops the run');
});

test('a box outside the forms the app is filling, and a cookie toggle, are not certifications (focus-usa.com: the cookie policy below the form)', () => {
  const cookies = '<details><summary><h3>Google Adsense</h3><label for=ga><span>Consent to service google-adsense</span></label><input type=checkbox id=ga class="cmplz-accept-service"></summary></details>';
  const form = '<form data-ook-form="f0"><input name=name><label><input type=checkbox checked> Global opt-out from selling and sharing</label><label><input type=checkbox> Request for access</label><button>Send</button></form>';
  assert.equal(run(page(form + cookies), 'pending-certification'), null, 'the opt-out form has nothing to certify');
  assert.equal(run(page(cookies), 'pending-certification'), null, 'a cookie toggle is never one, even with no form marked');
  assert.equal(run(page('<form data-ook-form="f0"><input name=n></form><div><label><input type=checkbox> I certify under penalty of perjury</label></div>'), 'pending-certification'), null,
    'a box outside the marked form is not part of the request');
  assert.match(run(page('<form data-ook-form="f0"><input name=n><label><input type=checkbox> I certify under penalty of perjury</label></form>'), 'pending-certification'), /certify/,
    'inside the form it still stops the run');
});

test('a ticked box, an agent option and an ordinary box are not pending certifications', () => {
  assert.equal(run(page('<label><input type=checkbox checked> I certify this is true</label>'), 'pending-certification'), null);
  assert.equal(run(page('<label><input type=checkbox> I am an authorized agent submitting on behalf of someone</label>'), 'pending-certification'), null);
  assert.equal(run(page('<label><input type=checkbox> Send me a copy</label>'), 'pending-certification'), null);
});

test('a request option ("To withdraw consent", "To opt out of the sale") and a box in a hidden section are not certifications (affinityanswers.com)', () => {
  assert.equal(run(page('<label><input type=checkbox> To withdraw consent. You can withdraw consent for our use of cookies at any time.</label>'), 'pending-certification'), null);
  assert.equal(run(page('<label><input type=checkbox> I want to opt out of the sale of my personal data, and I consent to being contacted</label>'), 'pending-certification'), null);
  assert.equal(run(page('<div style="display:none"><label><input type=checkbox> I certify under penalty of perjury that this is true</label></div>'), 'pending-certification'), null, 'hidden: not asked of the person');
  // A styled box: the input itself is hidden, its label is what shows.
  assert.match(run(page('<input type=checkbox id=c style="display:none"><label for=c>I certify under penalty of perjury that this is true</label>'), 'pending-certification'), /certify/);
});

// ---- tick-identity-boxes.js

// The script runs only for the account owner's own profile (Person.mayConfirmOwnIdentity): what it ticks is true of them.
test('"I confirm I am the person whose email this is" and a certification about the person themselves are ticked; terms and agent boxes are not', () => {
  const w = page(`<label><input type=checkbox id=me> I confirm that I am the person associated with this email address</label>
    <label><input type=checkbox id=perj> I declare under penalty of perjury that I am the person whose information is the subject of this request</label>
    <label><input type=checkbox id=terms> I confirm I am the account owner and accept the terms</label>
    <label><input type=checkbox id=agent> I am an authorized agent acting on behalf of the person</label>`);
  assert.equal(run(w, 'tick-identity-boxes'), 2);
  assert.deepEqual(['me', 'perj', 'terms', 'agent'].map((i) => w.document.getElementById(i).checked), [true, true, false, false]);
});

test('missionwired.com: the perjury certification ("I am the individual, or authorized agent of the individual ... true and accurate") is ticked; the agent\'s written-proof box and a bot trap are not', () => {
  const w = page(`<form><label><input type=checkbox id=proof> Check this box to confirm that you can provide written proof of authorization to request information on behalf of the data subject.</label>
    <label><input type=checkbox id=cert> I certify under penalty of perjury that, I am the individual, or authorized agent of the individual, whose information is the subject of this request; that I am a resident of the state identified above, and that all information I have submitted is true and accurate.*</label>
    <input type=checkbox id=trap aria-hidden=true style="position:absolute;left:-9999px"> <input name=n></form>`);
  assert.equal(run(w, 'tick-identity-boxes'), 1);
  assert.deepEqual(['proof', 'cert', 'trap'].map((i) => w.document.getElementById(i).checked), [false, true, false]);
});

test('"I understand I may be required to verify my identity and authorize them to contact me" is ticked, unless it is about selling or marketing', () => {
  const w = page(`<label><input type=checkbox id=a> I understand I may be required to verify my identity and I authorize Example to contact me about this request</label>
    <label><input type=checkbox id=b> I understand I may be required to verify my identity and I authorize Example to contact me with marketing offers</label>`);
  assert.equal(run(w, 'tick-identity-boxes'), 1);
  assert.equal(w.document.getElementById('a').checked, true);
  assert.equal(w.document.getElementById('b').checked, false);
});

// ---- find-terms-gate.js and click-agree.js

test('an "I agree to the terms" prompt is found with its wording and the same site\'s terms pages; footer text with nothing to press is not a prompt', () => {
  const w = page(`<div id=gate><p>By clicking I agree, you accept the Terms of Service and Privacy Policy.</p><button>I agree</button></div>
    <a href="https://broker.example/terms">Terms</a><a href="https://other.example/privacy">Privacy elsewhere</a>`);
  const out = JSON.parse(call(w, 'find-terms-gate', GATE));
  assert.match(out.prompt, /By clicking I agree/);
  assert.deepEqual(out.links, ['https://broker.example/terms'], 'only the site\'s own pages');
  assert.equal(call(page('<footer>Use of this site is subject to our acceptable use policy.</footer>'), 'find-terms-gate', GATE), null, 'no button to accept');
});

test('click-agree presses the prompt\'s own agree button and nothing else', () => {
  const w = page('<div><p>You must agree to the terms of use to continue.</p><button id=no>Cancel</button><button id=yes>I agree</button></div>');
  const pressed = []; for (const id of ['no', 'yes']) w.document.getElementById(id).addEventListener('click', () => pressed.push(id));
  assert.equal(call(w, 'click-agree', GATE), true);
  assert.deepEqual(pressed, ['yes']);
  assert.equal(call(page('<p>Nothing to agree to</p><button>OK</button>'), 'click-agree', GATE), false);
});
