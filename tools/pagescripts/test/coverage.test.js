// Every page script has unit tests: a script added to App/PageScripts without one fails here (docs/TESTING.md, "Page scripts").
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { names, page, source } = require('../harness');

test('every page script is called by at least one test', () => {
  const tests = fs.readdirSync(__dirname).filter((f) => f.endsWith('.test.js')).map((f) => fs.readFileSync(path.join(__dirname, f), 'utf8')).join('\n');
  const untested = names().filter((n) => !tests.includes(`'${n}'`));
  assert.deepEqual(untested, [], 'scripts with no test');
});

// ownership.js is a fragment the choosers include (//#include ownership); its rules are tested through them, and here on their own.
test('ownership: the app\'s own events never mark a box as the person\'s, and a box the app chose stays marked as the app\'s', () => {
  const w = page('<input id=a><button id=b>Tile</button>');
  w.eval('(function(){' + source('ownership') + '; window.__t = {touched: touched, autoDone: autoDone, markAuto: markAuto};})()');
  const a = w.document.getElementById('a'), b = w.document.getElementById('b');
  a.dispatchEvent(new w.Event('input', { bubbles: true }));
  b.click();
  assert.equal(a.getAttribute('data-ook-user'), null, 'a scripted input is not the person');
  assert.equal(w.__t.touched(b), false, 'a scripted click is not the person');
  a.setAttribute('data-ook-user', '1');
  assert.equal(w.__t.touched(a), true, 'what the person changed is theirs');
  assert.equal(w.__t.autoDone(b), false);
  w.__t.markAuto(b);
  assert.equal(w.__t.autoDone(b), true);
});
