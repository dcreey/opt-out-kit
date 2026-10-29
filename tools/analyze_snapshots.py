#!/usr/bin/env python3
"""Reads the pages saved by tools/snapshot_pages.py and reports, per site, which form the app's picker (LiveFormPicker.score) would choose, and
flags the risky ones: a pick that looks like a newsletter, sign-up or contact box, or one with a single email input.

  .tools-venv/bin/python tools/analyze_snapshots.py [--dir .rendered-html] [--all]
"""
import argparse, glob, os, re
from html.parser import HTMLParser

def rx(p): return re.compile(p, re.I)
MARKETING = rx(r"subscribe|free trial|get started|sign.?up|log.?in|sign.?in|search|book a|demo|contact us|get in touch|newsletter|join|download|add another")
OPTOUT = rx(r"opt.?(me.?)?out|do not sell|don.?t sell|do-not-sell|privacy|delete|deletion|remove|erase|request|rights|unsubscribe|suppress|removal")
SIGNUP = rx(r"subscribe|newsletter|sign.?up|register(?!ed)|create (an? )?account|\bjoin\b|waitlist|\bdemo\b|free trial|get started|contact sales|talk to|activation|log.?in|sign.?in|shortlist|get in touch|send message|contact us|request a (quote|call)|book a|get my [a-z ]*(guide|report)|show my report|free (guide|report)")
SIGNUP_CTX = rx(r"newsletter|(?<!un)subscrib(e|ing|ed)|receive (updates|news|emails?)|and receive|in your inbox|to your inbox|stay (updated|in the loop)|get (the )?(latest|updates)|join our|sign.?up for|free trial|updates (and|&) insights|delivered to")
STRONG = rx(r"opt.?(me.?)?out|do not sell|don.?t sell|privacy (request|choices|rights)|delete my|deletion request|erasure|data subject|remove (me|my)")
IDENT = rx(r"first|last|name|email|e-mail|address|zip|postal|phone|city")
SKIP_TYPES = {"hidden", "submit", "button", "image", "reset", "password", "checkbox", "radio"}
VOID = {"input", "br", "img", "meta", "link", "hr", "source", "area", "base", "col", "embed", "param", "track", "wbr"}

class Node:
    def __init__(s, tag, attrs, parent): s.tag, s.attrs, s.parent, s.kids, s.text = tag, dict(attrs), parent, [], []
    def inner(s): return " ".join(s.text + [k.inner() for k in s.kids])

class P(HTMLParser):
    def __init__(s): super().__init__(convert_charrefs=True); s.root = s.cur = Node("root", [], None); s.skip = 0; s.all = []
    def handle_starttag(s, tag, attrs):
        n = Node(tag, attrs, s.cur); s.cur.kids.append(n); s.all.append(n)
        if tag in ("script", "style", "noscript", "template"): s.skip += 1
        if tag not in VOID: s.cur = n
    def handle_endtag(s, tag):
        if tag in ("script", "style", "noscript", "template"): s.skip = max(0, s.skip - 1)
        n = s.cur
        while n and n.tag != tag: n = n.parent
        if n and n.parent: s.cur = n.parent
    def handle_data(s, d):
        if not s.skip and d.strip(): s.cur.text.append(re.sub(r"\s+", " ", d.strip()))

def hidden(n):
    while n:
        st = (n.attrs.get("style") or "").replace(" ", "").lower()
        if "display:none" in st or "visibility:hidden" in st or "hidden" in n.attrs and n.tag != "input" or n.attrs.get("aria-hidden") == "true" and n.tag == "form": return True
        n = n.parent
    return False

def under(n, tag):
    n = n.parent
    while n:
        if n.tag == tag: return n
        n = n.parent
    return None

def descend(n, pred, out=None):
    out = [] if out is None else out
    for k in n.kids:
        if pred(k): out.append(k)
        descend(k, pred, out)
    return out

def ctx_of(f):
    n = f
    for _ in range(8):
        if not n or n.tag in ("body", "html", "root"): break
        t = n.inner()
        if 25 <= len(t) <= 700: return t
        n = n.parent
    return (f.parent.inner() if f.parent else "")[:600]

def forms_of(root):
    out = []
    for f in descend(root, lambda k: k.tag == "form"):
        if hidden(f): continue
        fields = [i for i in descend(f, lambda k: k.tag in ("input", "select", "textarea")) if (i.attrs.get("type") or "text").lower() not in SKIP_TYPES and not hidden(i)]
        buttons = []
        for b in descend(f, lambda k: k.tag == "button" or (k.tag == "input" and (k.attrs.get("type") or "").lower() in ("submit", "button"))):
            t = (b.attrs.get("value") if b.tag == "input" else b.inner()) or ""
            if t.strip() and not hidden(b): buttons.append(t.strip()[:60])
        def lab(i):
            return " ".join(filter(None, [i.attrs.get("aria-label"), i.attrs.get("placeholder"), i.attrs.get("name"), i.attrs.get("id")]))
        out.append(dict(fields=[dict(type=(i.attrs.get("type") or i.tag).lower(), label=lab(i)) for i in fields], buttons=buttons, text=f.inner()[:240], ctx=ctx_of(f)[:600]))
    return out

def score(f, page_ctx=""):
    fields = f["fields"]
    if not fields: return -100
    buttons = " ".join(f["buttons"]); heading = f["text"]; ctx = f["ctx"]
    if SIGNUP.search(buttons + " " + heading[:200]) and not OPTOUT.search(buttons) and not STRONG.search(heading): return -100
    if len(fields) <= 3 and SIGNUP_CTX.search(ctx) and not STRONG.search(heading + " " + buttons): return -100
    if len(fields) <= 1 and not OPTOUT.search(buttons + " " + heading) and not STRONG.search(ctx): return -100
    s = 0
    if OPTOUT.search(buttons): s += 4
    if OPTOUT.search(heading): s += 2
    if MARKETING.search(buttons): s -= 6
    if MARKETING.search(heading) and not OPTOUT.search(buttons): s -= 3
    if OPTOUT.search(page_ctx): s += 3
    s += min(4, sum(1 for x in fields if IDENT.search(x["label"])))
    if any(x["type"] == "email" or re.search("e-?mail", x["label"], re.I) for x in fields): s += 2
    return s

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--dir", default=".rendered-html"); ap.add_argument("--all", action="store_true")
    a = ap.parse_args(); picked = risky = nopick = 0; rows = []
    for path in sorted(glob.glob(os.path.join(a.dir, "*.html"))):
        d = os.path.basename(path)[:-5]; html = open(path, errors="replace").read()
        m = re.match(r"<!-- URL (\S+) -->", html); url = m.group(1) if m else ""
        t = re.search(r"<title[^>]*>(.*?)</title>", html, re.S | re.I)
        page_ctx = (re.sub(r"https?://[^/]+", "", url) + " " + (t.group(1).strip() if t else ""))
        p = P(); p.feed(html); forms = forms_of(p.root)
        ranked = sorted(((score(f, page_ctx), f) for f in forms), key=lambda x: -x[0])
        if not ranked or ranked[0][0] < 3: nopick += 1; continue
        sc, f = ranked[0]; picked += 1
        flags = []
        if len(f["fields"]) <= 1: flags.append("one field")
        if SIGNUP.search(" ".join(f["buttons"])) : flags.append("signup button")
        if SIGNUP_CTX.search(f["ctx"]): flags.append("signup wording around it")
        if all(x["type"] == "email" or "mail" in x["label"].lower() for x in f["fields"]) and len(f["fields"]) <= 2 and not STRONG.search(f["ctx"] + " " + " ".join(f["buttons"]) + " " + f["text"]): flags.append("email-only, no opt-out wording")
        if flags: risky += 1
        if flags or a.all: rows.append((d, sc, "; ".join(flags), len(f["fields"]), f["buttons"][:2], f["ctx"][:110]))
    print(f"pages with a picked form: {picked}, no form picked: {nopick}, flagged: {risky}")
    for r in rows: print(r)

if __name__ == "__main__": main()
