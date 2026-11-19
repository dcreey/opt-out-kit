// Runs the app's page scripts (App/PageScripts/*.js) the way the app does, in a headless DOM (jsdom), so what each one does to a page can be tested
// in milliseconds without a simulator. docs/TESTING.md, "Page scripts".
//
// jsdom has no layout, so the few things the scripts read from layout are stood in for here, from the page's own markup:
//   - getBoundingClientRect / offsetParent: zero size for an element (or an ancestor) that is display:none, visibility:hidden, [hidden], or has an
//     inline width or height of 0; an element placed off screen (an inline left or top below -1000, as bot traps are) gets that position.
//     Everything else is 200 x 30 at the top left.
//   - innerText: the text of what is shown (hidden elements, <script> and <style> left out), with blocks on their own lines.
//   - scrollIntoView, scrollTo, scrollBy: recorded, nothing moves.
//   - webkit.messageHandlers.<name>.postMessage: recorded.
//   - a form's submit() and requestSubmit(): recorded (requestSubmit also fires the submit event, as a browser does).
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const DIR = path.join(__dirname, '..', '..', 'App', 'PageScripts');

// The script's text, its includes resolved, exactly as PageScript.source gives it to the web view.
function source(name, depth = 0) {
  const text = fs.readFileSync(path.join(DIR, name + '.js'), 'utf8').trim();
  if (depth > 4 || !text.includes('//#include ')) return text;
  return text.split('\n').map((line) => {
    const t = line.trim();
    return t.startsWith('//#include ') ? source(t.slice('//#include '.length).trim(), depth + 1) : line;
  }).join('\n');
}

function names() {
  return fs.readdirSync(DIR).filter((f) => f.endsWith('.js')).map((f) => f.slice(0, -3)).sort();
}

const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DIV|DL|DT|DD|FIELDSET|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TR|UL|BR|LABEL|BUTTON|OPTION|SELECT|LEGEND|DETAILS|SUMMARY)$/;

function install(window) {
  const doc = window.document;
  const hidden = (el) => {
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      const cs = window.getComputedStyle(e);
      if (e.hidden || cs.display === 'none' || cs.visibility === 'hidden') return true;
      if (e.tagName === 'DETAILS' && !e.open && e !== el && !(el.closest('summary') && el.closest('details') === e)) return true;
      if (e.tagName === 'INPUT' && e.type === 'hidden') return true;
    }
    const st = el.style || {};
    return st.width === '0px' || st.height === '0px' || st.width === '0' || st.height === '0';
  };
  const offset = (el) => {
    for (let e = el; e && e.nodeType === 1; e = e.parentElement) {
      const st = e.style || {}; const l = parseFloat(st.left), t = parseFloat(st.top);
      if (l < -1000 || t < -1000) return { x: isNaN(l) ? 0 : l, y: isNaN(t) ? 0 : t };
    }
    return { x: 0, y: 0 };
  };
  window.Element.prototype.getBoundingClientRect = function () {
    if (hidden(this)) return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 };
    const o = offset(this);
    return { x: o.x, y: o.y, top: o.y, left: o.x, right: o.x + 200, bottom: o.y + 30, width: 200, height: 30 };
  };
  Object.defineProperty(window.HTMLElement.prototype, 'offsetParent', { configurable: true, get() { return hidden(this) ? null : (this.parentElement || doc.body); } });
  Object.defineProperty(window.HTMLElement.prototype, 'offsetWidth', { configurable: true, get() { return hidden(this) ? 0 : 200; } });
  Object.defineProperty(window.HTMLElement.prototype, 'offsetHeight', { configurable: true, get() { return hidden(this) ? 0 : 30; } });
  const text = (node) => {
    if (node.nodeType === 3) return node.nodeValue;
    if (node.nodeType !== 1) return '';
    if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(node.tagName) || hidden(node)) return '';
    if (node.tagName === 'BR') return '\n';
    let out = '';
    for (const c of node.childNodes) out += text(c);
    return BLOCK.test(node.tagName) ? '\n' + out + '\n' : out;
  };
  Object.defineProperty(window.HTMLElement.prototype, 'innerText', {
    configurable: true,
    get() { return text(this).replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{2,}/g, '\n').trim(); },
    set(v) { this.textContent = v; },
  });
  window.__scrolls = [];
  window.Element.prototype.scrollIntoView = function (o) { window.__scrolls.push({ el: this, opts: o }); };
  window.scrollTo = (x, y) => window.__scrolls.push({ to: [x, y] });
  window.scrollBy = (x, y) => window.__scrolls.push({ by: [x, y] });
  window.__posts = [];
  window.webkit = { messageHandlers: new Proxy({}, { get: (_, n) => ({ postMessage: (m) => window.__posts.push({ name: n, message: m }) }) }) };
  window.__submits = [];
  window.HTMLFormElement.prototype.submit = function () { window.__submits.push(this); };
  window.HTMLFormElement.prototype.requestSubmit = function () {
    const ev = new window.Event('submit', { bubbles: true, cancelable: true });
    if (this.dispatchEvent(ev)) window.__submits.push(this);
  };
  if (!window.CSS) window.CSS = { escape: (s) => String(s).replace(/["\\]/g, '\\$&') };
}

// A page to run scripts in. `url` sets location (some scripts read the page's address).
function page(html, { url = 'https://broker.example/privacy/opt-out', title } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  if (title !== undefined) dom.window.document.title = title;
  install(dom.window);
  return dom.window;
}

// Runs a plain script in the page and returns what it returned (what the app reads back from evaluateJavaScript).
function run(window, name) {
  return window.eval(source(name));
}

// Calls a script that takes values, with each value passed as JSON, as PageScript.call does.
function call(window, name, ...values) {
  return window.eval('(' + source(name) + ')(' + values.map((v) => JSON.stringify(v)).join(',') + ');');
}

// The same, with values already JSON text (PageScript.call(_:json:)).
function callJSON(window, name, ...json) {
  return window.eval('(' + source(name) + ')(' + json.join(',') + ');');
}

module.exports = { source, names, page, run, call, callJSON };
