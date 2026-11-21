#!/usr/bin/env python3
"""The fixture brokers for the end-to-end tests: a small local web server (Python's standard library, nothing to install) that serves the opt-out pages of
the sites in fixtures/sites, which the integration build's catalog carries (fixtures/build_catalog.sh). The app loads them exactly as it loads a real
broker's page, so a journey runs through the same engine, web view and page scripts. The tests ask it what it received.

    python3 fixtures/server.py [port]       default 8765 (the port written in fixtures/sites/*.yml)

A site's id says which page it shows: fx_<kind>_<n> serves fixtures/pages/<kind>.html (<kind>-frame.html for a form in a frame; /<site>/search?q= for kinds 'listed' and 'unlisted' (the exposure scan's name search) and 'search' (results, with /<site>/profile-... pages, then the removal form asking for the listing's link), received-<kind>.html
for its confirmation, 503 for kind 'down'; kind 'code' takes POST /<site>/code to "email" a code and accepts the request only with 750439). Every page is wrapped in a phone-sized shell.
    GET  /<site>/optout     the form        POST /<site>/send   what the form posts (recorded), answered with a confirmation
    GET  /__received        every request recorded so far, as JSON ([{site, path, fields}])
    POST /__scroll          a page's scroll report (y, time, whether a finger moved it); GET /__scrolls lists them (the long pages report them)
    POST /__reset           forget them
    GET  /__ready           200 when the server is up
docs/TESTING.md, "End-to-end tests against fixture pages".
"""
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
RECEIVED = []
SCROLLS = []
CODE = '750439'          # the verification code the 'code' pages say they emailed
LOCK = threading.Lock()
SHELL = ('<html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>{title}</title></head>'
         '<body style="font-family:-apple-system;padding:16px">{body}</body></html>')


def page(kind):
    path = os.path.join(HERE, 'pages', kind + '.html')
    if not re.fullmatch(r'[a-z0-9-]+', kind) or not os.path.exists(path):
        return None
    with open(path, encoding='utf-8') as f:
        return f.read()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, kind='text/html; charset=utf-8'):
        data = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def route(self, method):
        parts = [p for p in self.path.split('?')[0].split('/') if p]
        fields = {}
        if method == 'POST':
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8')
            fields = {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}
        if parts == ['__ready']:
            return self.send(200, 'ready', 'text/plain')
        if parts == ['__received']:
            with LOCK:
                return self.send(200, json.dumps(RECEIVED), 'application/json')
        if parts == ['__scroll'] and method == 'POST':
            with LOCK:
                SCROLLS.append({**fields, 'at': str(time.time())})
            return self.send(200, 'ok', 'text/plain')
        if parts == ['__scrolls']:
            with LOCK:
                return self.send(200, json.dumps(SCROLLS), 'application/json')
        if parts == ['__reset'] and method == 'POST':
            with LOCK:
                RECEIVED.clear()
                SCROLLS.clear()
            return self.send(200, 'ok', 'text/plain')
        # The reCAPTCHA checkbox's frame, at the path shape the page script looks for (kind 'recaptcha').
        if len(parts) == 4 and parts[0].startswith('fx_recaptcha_') and parts[1:] == ['recaptcha', 'api2', 'anchor']:
            return self.send(200, page('recaptcha-anchor') or '')
        if len(parts) != 2:
            return self.send(404, 'Not found')
        site, what = parts
        match = re.fullmatch(r'fx_([a-z0-9]+)_\d+', site)
        if not match:
            return self.send(404, 'Not found')
        kind = match.group(1)
        if kind == 'search' and (what == 'search' or what.startswith('profile')):
            # A people-search site: results for a name, each linking to a profile page that has the person's listing (the removal form asks for its link).
            if what == 'search':
                q = parse_qs(urlsplit(self.path).query).get('q', [''])[0]
                with LOCK:
                    RECEIVED.append({'site': site, 'path': 'search', 'fields': {'q': q}, 'at': time.time()})
                hit = 'pat' in q.lower()
                text = ('<h1>People search results</h1><ul>'
                        f'<li><a href="/{site}/profile-pat-example-il">Pat Example, 34, Springfield IL</a></li>'
                        f'<li><a href="/{site}/profile-pat-examplesson-or">Pat Examplesson, 61, Portland OR</a></li></ul>' if hit
                        else '<h1>People search results</h1><p>No records found for your search.</p>')
            else:
                text = (f'<h1>{what[8:].replace("-", " ").title()}</h1><p>Age 34. Lives in Springfield IL. Relatives: Sam Example.</p>'
                        f'<p><a href="/{site}/optout">Remove this record</a></p>')
            return self.send(200, SHELL.format(title=site, body=text))
        if kind == 'scriptlisted' and what == 'search':
            # Results built by script after a moment (a page that needs a real browser): "Loading" first, then Pat's listing.
            q = parse_qs(urlsplit(self.path).query).get('q', [''])[0].lower()
            result = 'Pat Example, 34, Springfield IL' if 'pat' in q else 'No records found for your search.'
            text = ('<h1>Search</h1><div id="r">Loading...</div><script>setTimeout(function(){document.getElementById("r").innerHTML="<h2>Search results</h2><p>' + result + '</p>";}, 1500);</script>')
            return self.send(200, SHELL.format(title=site, body=text))
        if what == 'search' and kind in ('listed', 'unlisted'):
            # A name search for the exposure scan: 'listed' finds anyone whose name has "pat" in it, 'unlisted' finds nobody.
            q = parse_qs(urlsplit(self.path).query).get('q', [''])[0].lower()
            hit = kind == 'listed' and 'pat' in q
            text = ('<h1>Search results</h1><p>Pat Example, 34, Springfield IL. Relatives: Sam Example.</p>' if hit
                    else '<h1>Search results</h1><p>No records found for your search.</p>')
            return self.send(200, SHELL.format(title=site, body=text))
        # A page that emails a code (kind 'code') accepts the request only with the code it "sent" (CODE); anything else is recorded as rejected.
        if kind == 'code' and what == 'send' and fields.get('code') != CODE:
            what = 'rejected'
        if method == 'POST':
            with LOCK:
                RECEIVED.append({'site': site, 'path': what, 'fields': fields, 'at': time.time()})
        if kind == 'down':
            return self.send(503, 'Service unavailable')
        if what == 'rejected':
            body = page('rejected-code')
        elif what == 'code':
            body = 'sent'
        elif what == 'send':
            body = page('received-' + kind) or page('received')
        elif what == 'optout':
            body = page(kind)
        elif what == 'frame':
            body = page(kind + '-frame')
        else:
            body = None
        if body is None:
            return self.send(404, 'Not found')
        self.send(200, SHELL.format(title=site, body=body.replace('{{site}}', site)))

    def do_GET(self):
        self.route('GET')

    def do_POST(self):
        self.route('POST')


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print(f'fixture brokers on http://127.0.0.1:{port}', flush=True)
    server.serve_forever()
