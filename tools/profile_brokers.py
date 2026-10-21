#!/usr/bin/env python3
"""Profile broker sites from pipeline/census-sites.txt and write one directory entry per site.

For each site it fetches (politely: honest user agent, robots.txt honored, one request per second per site):
  home page -> finds the opt-out / privacy link -> opt-out page -> extracts structural signals only
(form fields, bot-check widgets, phone / ID / mail wording) -> assigns a PROVISIONAL tier and automation level.
It copies no prose from the sites. Re-run it any time: results are cached, so only new or stale sites are fetched.

  python3 tools/profile_brokers.py [--sites pipeline/census-sites.txt] [--out directory] [--cache .profile-cache]
                                   [--workers 6] [--refresh] [--only domain,domain]

Tier guide (docs/DESIGN.md): A form + email link, B adds a bot check, C phone / ID / account / app-only, D email or mail only.
A tier here is a guess from the page's shape. A person or the pipeline firms it up when a real flow is written.
"""
import argparse, concurrent.futures as cf, datetime, hashlib, json, os, re, sys, time, urllib.parse, urllib.request, urllib.robotparser
from html.parser import HTMLParser

UA = "OptOutKit-Profiler/1.0 (open source; polite, robots.txt honored)"
HARD_CHALLENGE = ["just a moment", "attention required", "verify you are human", "are you a human",
                  "checking your browser", "performing security verification", "security challenge", "managed challenge"]
LINK_SCORE = [(r"opt[\s_-]?out", 10), (r"do[\s_-]?not[\s_-]?sell", 8), (r"remov", 8), (r"suppress", 8),
              (r"delete[\s_-]?my|data[\s_-]?delet", 7), (r"your[\s_-]?privacy[\s_-]?choices|privacy[\s_-]?rights|privacy[\s_-]?request", 6),
              (r"privacy", 2)]
GUESS_PATHS = ["/optout", "/opt-out", "/optout/", "/opt-out/", "/privacy", "/remove", "/removal", "/privacy-rights"]
# Links to these are never a shared opt-out (share buttons, privacy policies of platforms, search engines).
NOT_A_FAMILY = ("globalprivacycontrol", "linkedin", "bing", "google", "facebook", "twitter", "x.com", "instagram", "youtube", "pinterest", "reddit",
                "tiktok", "zendesk", "freshdesk", "helpscout", "intercom", "dataprivacyframework", "apple.com", "microsoft", "amazon", "cloudflare", "wordpress", "w3.org", "gstatic", "doubleclick")
PORTALS = {"trustarc.com": "trustarc", "onetrust.com": "onetrust", "transcend.io": "transcend", "ketch.com": "ketch",
           "datagrail.io": "datagrail", "privacyportal": "onetrust", "osano.com": "osano", "securiti.ai": "securiti"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links, self.forms, self.inputs, self.iframes, self.scripts = [], [], [], [], []
        self.buttons, self.labels = [], {}
        self.text, self._skip, self._href, self._anchor = [], 0, None, []
        self.title, self._in_title = "", False
        self._form, self._label_for, self._button, self._select = -1, None, None, None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "style"):
            self._skip += 1
            if tag == "script" and a.get("src"): self.scripts.append(a["src"])
        elif tag == "a" and a.get("href"): self._href, self._anchor = a["href"], []
        elif tag == "form":
            self.forms.append({"action": a.get("action", ""), "method": (a.get("method") or "get").lower()})
            self._form = len(self.forms) - 1
        elif tag in ("input", "select", "textarea"):
            self.inputs.append({"type": (a.get("type") or tag).lower(), "name": (a.get("name") or a.get("id") or "").lower(),
                                "id": a.get("id") or "", "ph": (a.get("placeholder") or a.get("aria-label") or "").strip(),
                                "form": self._form, "value": a.get("value") or "", "opts": [], "raw_name": a.get("name") or a.get("id") or ""})
            self._select = self.inputs[-1] if tag == "select" else None
        elif tag == "option" and self._select is not None and a.get("value"): self._select["opts"].append(a["value"])
        elif tag == "button": self._button = [self._form, (a.get("type") or "submit").lower(), ""]
        elif tag == "label": self._label_for = [a.get("for"), ""]
        elif tag == "iframe" and a.get("src"): self.iframes.append(a["src"])
        elif tag == "title": self._in_title = True

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip: self._skip -= 1
        elif tag == "a" and self._href is not None:
            self.links.append((self._href, " ".join(self._anchor).strip())); self._href = None
        elif tag == "form": self._form = -1
        elif tag == "button" and self._button: self.buttons.append(tuple(self._button)); self._button = None
        elif tag == "label" and self._label_for:
            if self._label_for[0]: self.labels[self._label_for[0]] = self._label_for[1].strip()
            self._label_for = None
        elif tag == "title": self._in_title = False

    def handle_data(self, d):
        if self._in_title: self.title += d
        if self._skip: return
        self.text.append(d)
        if self._href is not None: self._anchor.append(d.strip())
        if self._button: self._button[2] += d
        if self._label_for: self._label_for[1] += d


def registrable(host):
    parts = host.lower().split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else host.lower()


class Fetcher:
    def __init__(self):
        self.robots = {}

    def allowed(self, url):
        host = urllib.parse.urlsplit(url).netloc
        rp = self.robots.get(host)
        if rp is None:
            rp = urllib.robotparser.RobotFileParser()
            try:
                req = urllib.request.Request(f"https://{host}/robots.txt", headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=15) as r:
                    rp.parse(r.read(400_000).decode("utf-8", "replace").splitlines())
            except Exception:
                rp.parse([])  # no readable robots.txt: nothing is disallowed
            self.robots[host] = rp
        return rp.can_fetch(UA, url)

    def get(self, url, method="GET", data=None):
        """Returns (status, final_url, text) or (None, url, '') on failure. Never raises. `data` is a form-encoded body for POST."""
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xhtml+xml",
                                                       **({"Content-Type": "application/x-www-form-urlencoded"} if data else {})},
                                         data=data.encode() if data else None, method=method)
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, r.geturl(), r.read(1_500_000).decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            try: body = e.read(400_000).decode("utf-8", "replace")
            except Exception: body = ""
            return e.code, url, body
        except Exception:
            return None, url, ""


def parse(html):
    p = Page()
    try: p.feed(html)
    except Exception: pass
    return p


NOT_FOUND = re.compile(r"page (can.?t|cannot|could not) be found|page not found|not found|doesn.?t exist|does not exist|error 404|404 error|\\b404\\b|oops", re.I)


def is_error_page(status, page, text):
    """An error page can still carry a search box, which is not an opt-out form. Skip it."""
    if status is not None and status >= 400: return True
    return bool(NOT_FOUND.search((page.title or "") + " " + text[:400]))


def is_blocked(status, html):
    low = html.lower()
    return status in (403, 429, 503) or any(m in low for m in HARD_CHALLENGE)


OPT_WORDS = re.compile(r"opt[\s_-]?out|remov|suppress|delete|do[\s_-]?not[\s_-]?sell|privacy (request|rights|choices)|control your", re.I)
SEARCHY = re.compile(r"search|find|lookup|people|name|query|\bq\b", re.I)


def link_score(href, text):
    hay = (href + " " + text).lower()
    return sum(w for pat, w in LINK_SCORE if re.search(pat, hay))


def form_fields(page, idx, base):
    """The visible inputs of one form: what a person would be asked to fill in."""
    out = []
    for i in page.inputs:
        if i["form"] != idx or i["type"] in ("hidden", "submit", "button", "image", "reset", "checkbox_hidden"): continue
        label = page.labels.get(i["id"]) or i["ph"] or i["name"]
        out.append({"type": i["type"], "name": i["name"], "label": re.sub(r"\s+", " ", label)[:60]})
    return out


def score_form(page, idx, base, page_text):
    """How likely this form is the real opt-out form (>= 3), as opposed to a search box, a newsletter box or a login.
    The page itself must be about opting out (its address, title or opening text), because every home page carries an
    opt-out link in its footer and a search form above it."""
    form = page.forms[idx]
    fields = form_fields(page, idx, base)
    if not fields: return -9
    path = urllib.parse.urlsplit(base).path
    context = (page.title or "") + " " + page_text[:400]       # the page's own heading, not a policy that merely mentions rights
    if path in ("", "/") or not OPT_WORDS.search(context): return -9
    kinds = " ".join(f["type"] + " " + f["name"] + " " + f["label"] for f in fields).lower()
    sc = 2
    if re.search(r"e-?mail", kinds): sc += 3
    if re.search(r"url|link|profile|listing", kinds): sc += 3
    if re.search(r"first|last|full.?name|\bname\b", kinds): sc += 1
    if any(i["form"] == idx and i["type"] == "submit" for i in page.inputs) or any(b[0] == idx for b in page.buttons): sc += 1
    if "password" in kinds: sc -= 3
    action = urllib.parse.urljoin(base, form["action"]).lower()
    action_is_removal = bool(OPT_WORDS.search(action))
    # A form that posts to another company's address is an affiliate or search box, unless that address is a removal portal.
    here = registrable(urllib.parse.urlsplit(base).netloc); there = registrable(urllib.parse.urlsplit(action).netloc)
    if there != here and not action_is_removal and not any(n in action for n in PORTALS): return -9
    if action_is_removal: sc += 3          # the form posts to a removal / opt-out address
    elif re.search(r"\bcity\b|\bstate\b|\bage\b|zip", kinds) and not re.search(r"e-?mail|url|link", kinds): sc -= 4
    if len(fields) <= 2 and (re.search(r"search|find|lookup|people", action) or re.search(r"\bq\b|query|search", kinds)) \
            and not re.search(r"e-?mail|url|link", kinds): sc -= 5
    return sc


def best_form(page, base, text):
    scored = [(score_form(page, i, base, text), i) for i in range(len(page.forms))]
    scored = [x for x in scored if x[0] >= 3]
    if not scored: return None
    sc, idx = max(scored)
    f = page.forms[idx]
    return {"score": sc, "method": f["method"], "action": urllib.parse.urljoin(base, f["action"]) if f["action"] else base,
            "fields": form_fields(page, idx, base)}


def crawl_for_form(start_url, fetcher, own_registrable, max_pages=6, max_depth=3):
    """Follow the most promising privacy / opt-out links, up to three hops, until a real form turns up.
    Returns (best_record, trail, blocked_seen). best_record is the page with the form, else the richest page seen."""
    import heapq
    queue = [(0, 0, start_url)]; trail_of = {start_url: [start_url]}
    best_pri = {start_url: 0}; fetched_urls = set()
    base = urllib.parse.urlsplit(start_url)
    for g in GUESS_PATHS:       # common opt-out addresses, tried after the links the site itself offers
        u = f"{base.scheme}://{base.netloc}{g}"
        if u not in best_pri: best_pri[u] = -1; trail_of[u] = [start_url, u]; queue.append((1, 1, u))
    import heapq; heapq.heapify(queue)
    fetched = 0; best = None; blocked_seen = False
    while queue and fetched < max_pages:
        _, depth, url = heapq.heappop(queue)
        if url in fetched_urls or not fetcher.allowed(url): continue
        fetched_urls.add(url)
        st, fin, body = fetcher.get(url); fetched += 1; time.sleep(1)
        if st is None or st >= 400 and not body: continue
        if is_blocked(st, body):
            blocked_seen = True
            if best is None: best = {"url": fin, "blocked": True, "sig": set(), "page": parse(""), "form": None, "trail": trail_of[url]}
            continue
        pg = parse(body)
        text = re.sub(r"\s+", " ", " ".join(pg.text))
        if is_error_page(st, pg, text): continue
        sig = signals_for(body, pg, fin)
        form = best_form(pg, fin, text)
        rec = {"url": fin, "blocked": False, "sig": sig, "page": pg, "form": form, "trail": trail_of[url], "status": st,
               "richness": len(pg.inputs) * 2 + len(pg.forms) + len(sig) + (10 if OPT_WORDS.search(pg.title or "") else 0)}
        if form: return rec, trail_of[url], blocked_seen
        if best is None or best["blocked"] or rec["richness"] > best.get("richness", 0): best = rec
        if depth >= max_depth: continue
        for href, t in pg.links:
            if href.startswith(("mailto:", "javascript:", "tel:", "#")): continue
            nxt = urllib.parse.urljoin(fin, href).split("#")[0]
            if not nxt.startswith("http") or nxt in fetched_urls: continue
            sc = link_score(href, t)
            host_reg = registrable(urllib.parse.urlsplit(nxt).netloc)
            if sc <= 0 or (host_reg != own_registrable and sc < 8): continue   # leave the site only for a strong opt-out link
            if any(n in nxt for n in NOT_A_FAMILY): continue
            # a real link to an address we only meant to guess upgrades the guess instead of being ignored as a duplicate
            if best_pri.get(nxt, -999) >= sc: continue
            best_pri[nxt] = sc; trail_of[nxt] = trail_of[url] + [nxt]
            heapq.heappush(queue, (-sc, depth + 1, nxt))
    return best, (best or {}).get("trail", [start_url]), blocked_seen


def signals_for(html, page, final_url):
    low = html.lower()
    s = set()
    for key, pats in {"turnstile": ["cf-turnstile", "turnstile"], "recaptcha": ["g-recaptcha", "recaptcha"],
                      "hcaptcha": ["hcaptcha", "h-captcha"], "perimeterx": ["px-captcha"], "datadome": ["datadome"]}.items():
        if any(p in low for p in pats): s.add(f"captcha_{key}")
    types = " ".join(i["type"] + " " + i["name"] + " " + i["ph"] for i in page.inputs)
    if re.search(r"email|e-mail", types): s.add("email_input")
    if re.search(r"first|last|fname|lname|full.?name|\bname\b", types): s.add("name_input")
    if re.search(r"url|link|profile|listing", " ".join(i["name"] + " " + i["ph"] for i in page.inputs)): s.add("listing_url_input")
    if re.search(r"\btel\b|phone", types): s.add("phone_input")
    if any(i["type"] == "file" for i in page.inputs): s.add("file_upload")
    if any(i["type"] == "password" for i in page.inputs): s.add("login_required")
    text = re.sub(r"\s+", " ", " ".join(page.text)).lower()
    if re.search(r"(phone call|call (you|us)|text message|sms|verification code|automated call)", text): s.add("phone_verify")
    if re.search(r"(driver'?s? licen[sc]e|government[- ]issued|photo id|passport|notari[sz]ed)", text): s.add("id_required")
    if re.search(r"(by mail|postal|mailing address|send (us )?a letter|certified mail)", text): s.add("mail_option")
    if re.search(r"(create an account|sign up to|log ?in to (opt|remove|manage))", text): s.add("account_hint")
    if re.search(r"(e-?mail (us|your request|a request|the request|our privacy)|send (us )?an? e-?mail|requests? (by|via|through) e-?mail|write to us at)", text): s.add("email_only_wording")
    if any("mailto:" in h for h, _ in page.links): s.add("email_contact")
    for f in page.forms:
        host = urllib.parse.urlsplit(urllib.parse.urljoin(final_url, f["action"])).netloc
        for needle, name in PORTALS.items():
            if needle in host: s.add(f"portal_{name}")
    for src in page.iframes + page.scripts:
        for needle, name in PORTALS.items():
            if needle in src: s.add(f"portal_{name}")
    if page.forms and not page.inputs: s.add("script_rendered_form")
    if any(re.search(r"first|last|name", i["name"]) for i in page.inputs) and any(re.search(r"city|state|zip", i["name"]) for i in page.inputs) \
            and re.search(r"remov|opt|suppress", " ".join(f["action"] for f in page.forms).lower()): s.add("search_first")
    if not page.forms and len(text) < 600: s.add("script_rendered_page")
    return s


def classify(blocked, robots_ok, found_page, sig):
    """-> (tier or None, automation, confidence). Order matters: the hardest requirement wins."""
    if not robots_ok: return None, "robots_disallowed", "n/a"
    if blocked: return None, "blocked", "n/a"
    if not found_page: return None, "unknown", "none"
    manual = {"phone_verify", "id_required", "file_upload", "login_required", "account_hint"}
    captcha = {x for x in sig if x.startswith("captcha_")}
    if "script_rendered_page" in sig or "script_rendered_form" in sig: return "C", "needs_browser", "low"
    if sig & manual: return "C", "guided", "medium"
    if captcha: return "B", "guided", "medium"
    # A bare name box is usually the site's search form, not an opt-out form, so it alone proves nothing.
    if "email_input" in sig or "listing_url_input" in sig:
        return "A", "scriptable", "medium" if {"email_input", "name_input"} <= sig else "low"
    if "email_only_wording" in sig or "mail_option" in sig: return "D", "guided", "low"
    return None, "unknown", "low"


def profile(domain, bucket, fetcher):
    rec = {"domain": domain, "bucket": bucket, "profiled": datetime.date.today().isoformat()}
    # Some sites answer robots.txt differently on the bare and www hosts (the bare host often just redirects),
    # so try both and use the first host whose robots.txt allows the home page.
    start = next((u for u in (f"https://{domain}/", f"https://www.{domain}/") if fetcher.allowed(u)), None)
    if start is None:
        start = f"https://{domain}/"
        rec.update(tier=None, automation="robots_disallowed", confidence="n/a", signals=[], opt_out_url=None)
        return rec
    status, final, html = fetcher.get(start)
    time.sleep(1)
    if status is None:
        rec.update(tier=None, automation="unreachable", confidence="n/a", signals=[], opt_out_url=None)
        return rec
    rec["home_status"] = status
    if is_blocked(status, html):
        rec.update(tier=None, automation="blocked", confidence="n/a", signals=["bot_check_on_home"], opt_out_url=None)
        return rec
    own = registrable(domain)
    best, trail, blocked_seen = crawl_for_form(final, fetcher, own)
    if best is None:
        rec.update(tier=None, automation="unknown", confidence="none", signals=[], opt_out_url=None)
        return rec
    sig = best["sig"]
    tier, auto, conf = classify(best["blocked"], True, True, sig)
    form = best.get("form")
    if form:
        # A real form was found: the tier now follows what the form asks for, not just the page's wording.
        sig = set(sig) | {"opt_out_form_found"}
        tier, auto, conf = classify(False, True, True, sig)
        conf = "high" if conf == "medium" else conf
        rec["opt_out_form"] = {"page": best["url"], "method": form["method"], "action": form["action"],
                               "fields": form["fields"], "hops": len(best["trail"]) - 1}
    rec.update(tier=tier, automation=auto, confidence=conf, signals=sorted(sig), opt_out_url=best["url"], form_found=bool(form), v=2)
    own_reg = own
    targets = [urllib.parse.urljoin(best["url"], f["action"]) for f in best["page"].forms if f["action"]]
    targets += [urllib.parse.urljoin(best["url"], h) for h, t in best["page"].links
                if re.search(r"opt|remov|do[-_ ]?not[-_ ]?sell|privacy|suppress", (h + " " + t).lower())]
    targets += list(best["trail"][1:])      # a hop that left the site is the strongest hint of a shared opt-out
    for t in targets:
        host = urllib.parse.urlsplit(t).netloc
        if host and registrable(host) != own_reg and not any(n in host for n in list(PORTALS) + list(NOT_A_FAMILY)):
            rec["family_target"] = registrable(host); break
    return rec


def to_yaml(rec):
    def q(v): return json.dumps(v) if isinstance(v, str) else ("null" if v is None else str(v).lower() if isinstance(v, bool) else str(v))
    lines = [f"# GENERATED by tools/profile_brokers.py on {rec['profiled']}. A provisional guess from the page's shape; edit or",
             "# replace with a hand-written flow in brokers/ once a real run confirms it."]
    order = ["id", "domain", "name", "bucket", "tier", "automation", "confidence", "opt_out_url", "opt_out_form", "family", "family_parent", "template", "signals", "profiled"]
    for k in order:
        if k not in rec or rec[k] in (None, "") and k not in ("tier", "opt_out_url"): continue
        v = rec[k]
        if k == "signals": lines.append("signals: [" + ", ".join(v) + "]")
        elif k == "opt_out_form": lines.append("opt_out_form: " + json.dumps(v))
        else: lines.append(f"{k}: {q(v)}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sites", default="pipeline/census-sites.txt"); ap.add_argument("--out", default="directory")
    ap.add_argument("--cache", default=".profile-cache"); ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--refresh", action="store_true"); ap.add_argument("--only", default="")
    a = ap.parse_args()
    sites = []
    for line in open(a.sites):
        if line.strip() and not line.startswith("#"):
            p = line.split(); sites.append((p[0], p[1] if len(p) > 1 else "direct"))
    if a.only: sites = [s for s in sites if s[0] in a.only.split(",")]
    os.makedirs(a.cache, exist_ok=True); os.makedirs(a.out, exist_ok=True)
    fetcher = Fetcher()

    def work(item):
        d, b = item
        cache = os.path.join(a.cache, d + ".json")
        if os.path.exists(cache) and not a.refresh and time.time() - os.path.getmtime(cache) < 30 * 86400 \
                and json.load(open(cache)).get("v") == 2:
            rec = json.load(open(cache))
            # The cache keeps the raw signals, so tier rules can change without fetching anything again.
            if rec.get("opt_out_url") and rec["automation"] not in ("blocked", "unreachable", "robots_disallowed"):
                rec["tier"], rec["automation"], rec["confidence"] = classify(False, True, True, set(rec["signals"]))
            return rec
        rec = profile(d, b, fetcher); rec.setdefault("v", 2)
        json.dump(rec, open(cache, "w"))
        return rec

    with cf.ThreadPoolExecutor(a.workers) as ex:
        recs = list(ex.map(work, sites))

    # families: sites whose opt-out leads to the same other domain
    groups = {}
    for r in recs:
        t = r.get("family_target")
        if t and not any(n in t for n in NOT_A_FAMILY): groups.setdefault(t, []).append(r)
    for target, members in groups.items():
        if len(members) >= 2:
            for r in members:
                r["family"] = re.sub(r"[^a-z0-9]+", "_", target); r["family_parent"] = target
    # Templates: different sites running the same opt-out form (same page path and same field names). Each site still needs
    # its own request, but they share one flow, so one UX and one set of steps covers the whole cluster.
    sigs = {}
    for r in recs:
        form = r.get("opt_out_form")
        if form:
            key = urllib.parse.urlsplit(form["page"]).path.rstrip("/") + "|" + ",".join(sorted(f["name"] for f in form["fields"]))
            sigs.setdefault(key, []).append(r)
    for key, members in sigs.items():
        if len(members) >= 3 and not (members[0].get("family")):
            for r in members: r["template"] = "t_" + hashlib.sha1(key.encode()).hexdigest()[:6]
    for r in recs:
        r["id"] = re.sub(r"[^a-z0-9]+", "_", r["domain"].lower()).strip("_"); r["name"] = r["domain"]
        target = os.path.join(a.out, r["id"] + ".yml")
        kept = ""
        if os.path.exists(target):
            old = open(target).read()
            i = old.find("\nsearch_check:\n")
            if i != -1: kept = old[i:]          # profile_search.py owns this block; never drop it
        open(target, "w").write(to_yaml(r).rstrip("\n") + ("\n" + kept.lstrip("\n") if kept else "\n"))

    # report
    from collections import Counter
    tiers = Counter(str(r["tier"]) for r in recs); autos = Counter(r["automation"] for r in recs)
    fams = Counter(r["family"] for r in recs if r.get("family"))
    forms = sum(1 for r in recs if r.get("opt_out_form"))
    temps = Counter(r["template"] for r in recs if r.get("template"))
    lines = [f"# Directory profile ({datetime.date.today()})", "", f"{len(recs)} sites profiled; real opt-out form found on {forms}.", "",
             "| Tier (provisional) | Sites |", "|---|---|"] + [f"| {t} | {n} |" for t, n in sorted(tiers.items())]
    lines += ["", "| Automation | Sites |", "|---|---|"] + [f"| {t} | {n} |" for t, n in sorted(autos.items())]
    lines += ["", "| Shared-opt-out family | Sites |", "|---|---|"] + [f"| {t} | {n} |" for t, n in fams.most_common()]
    lines += ["", "| Shared form template (separate request per site) | Sites |", "|---|---|"] + [f"| {t} | {n} |" for t, n in temps.most_common()]
    open(os.path.join(a.out, "REPORT.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
