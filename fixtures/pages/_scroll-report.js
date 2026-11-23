// The long fixture pages' reporter (served at /__scroll-report.js; fixtures/server.py, /__scroll). It reports:
// - where the page is scrolled to, and whether a finger or wheel was moving it ('scroll', 'touchstart', 'touchend', 'load');
// - every call that can move the page from a script ('call:scrollIntoView', 'call:focus', 'call:scrollTo', ..., 'call:invalid' for a form the browser
//   refused to send, which it scrolls to the empty box). The app never moves a web view from Swift, so these calls are all the ways it can move the page:
//   a test counts them after the person's first touch instead of guessing from how far a scroll went (a fast flick on a slow machine jumps far too).
(function () {
  var site = (document.currentScript && document.currentScript.getAttribute('data-site')) || '';
  var t0 = Date.now(), touching = false, lastTouch = 0, lastY = -1;
  function user() { return touching || Date.now() - lastTouch < 2500 ? 1 : 0; }
  function send(kind) {
    var y = Math.round(window.scrollY);
    navigator.sendBeacon('/__scroll', new URLSearchParams({site: site, y: y, t: Date.now() - t0, user: user(), kind: kind, max: Math.round(document.documentElement.scrollHeight - window.innerHeight)}));
  }
  window.addEventListener('touchstart', function () { touching = true; lastTouch = Date.now(); send('touchstart'); }, {passive: true});
  window.addEventListener('touchend', function () { touching = false; lastTouch = Date.now(); send('touchend'); }, {passive: true});
  window.addEventListener('wheel', function () { lastTouch = Date.now(); }, {passive: true});
  window.addEventListener('scroll', function () { if (Math.round(window.scrollY) !== lastY) { lastY = Math.round(window.scrollY); send('scroll'); } }, {passive: true});
  window.addEventListener('load', function () { send('load'); });
  // Calls that move the page. Each still does its work; it is only reported first.
  function wrap(owner, name, moves) {
    var orig = owner[name]; if (typeof orig !== 'function') return;
    owner[name] = function () { if (!moves || moves.apply(this, arguments)) send('call:' + name); return orig.apply(this, arguments); };
  }
  wrap(Element.prototype, 'scrollIntoView');
  wrap(Element.prototype, 'scrollIntoViewIfNeeded');
  wrap(Element.prototype, 'scrollTo'); wrap(Element.prototype, 'scrollBy'); wrap(Element.prototype, 'scroll');
  wrap(window, 'scrollTo'); wrap(window, 'scrollBy'); wrap(window, 'scroll');
  // focus() scrolls the box into view unless told not to.
  wrap(HTMLElement.prototype, 'focus', function (o) { return !(o && o.preventScroll); });
  // Setting scrollTop on the page itself.
  var d = Object.getOwnPropertyDescriptor(Element.prototype, 'scrollTop');
  if (d && d.set) Object.defineProperty(Element.prototype, 'scrollTop', {get: d.get, set: function (v) { if (this === document.scrollingElement) send('call:scrollTop'); d.set.call(this, v); }, configurable: true});
  // A form the browser refused to send for an empty required box: it scrolls to that box.
  document.addEventListener('invalid', function () { send('call:invalid'); }, true);
})();
