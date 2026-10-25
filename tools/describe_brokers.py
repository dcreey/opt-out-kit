#!/usr/bin/env python3
"""Writes a plain-words description of every broker into the directory: who it is, what it tracks, who it sells to, and a priority score.

Input is the evidence tools/collect_about.py gathered (the site's own home page and privacy policy). Everything written is read from that
text: the category from what the site says it does, the data kinds from the categories its policy names, the buyers from the policy
sentences about selling or sharing, and one quoted sentence as proof. Where the text says nothing, the field says so rather than guessing.
Output: an `about:` and a `priority:` line in each directory/*.yml. Usage: describe_brokers.py [--about .about] [--dir directory] [--dry-run]
"""
import argparse, glob, json, os, re

CATEGORIES = [   # (id, label, pattern); the best-scoring one wins, ties go to the earlier one
    ("arrests", "public arrest and court records site", r"arrest records?|mugshots?|inmate|booking|court records?|criminal records? search"),
    ("people_search", "people-search and public-records site", r"people search|find (people|anyone|someone|friends)|background (check|report)s?|public records? search|reverse (phone|address|email)|search (for )?(people|public records)|phone book|white ?pages|find relatives"),
    ("consumer_reporting", "background-screening and consumer-reporting company", r"consumer reporting agenc|\bfcra\b|tenant screening|employment screening|credit report|screening (services|solutions)"),
    ("healthcare", "healthcare data company", r"healthcare|health care|patient|physician|hospital|pharma|provider (data|directory)|clinical"),
    ("real_estate", "property and real-estate data company", r"real estate|property data|mortgage|home value|parcel|appraisal|title (insurance|company)|homeowner"),
    ("financial", "financial and credit data company", r"credit (score|bureau|data)|lending|loan|financial institution|wealth|investor|bank"),
    ("fraud_identity", "identity and fraud-prevention data provider", r"identity (verification|resolution|proofing)|fraud|risk (assessment|score)|kyc|anti-money"),
    ("adtech", "advertising technology company", r"advertising platform|programmatic|demand[- ]side|supply[- ]side|ad exchange|ad network|retarget|audience (segment|targeting)|identity graph|cross[- ]device|real[- ]time bidding|\bdsp\b|\bssp\b|ad tech|adtech|publishers and advertisers|connected tv|\bctv\b"),
    ("marketing_data", "marketing data provider", r"direct marketing|mailing list|consumer (data|database)|data append|marketing data|audience data|email append|data cooperative|list rental|consumer insights|household (data|level)"),
    ("b2b", "business-contact and sales-data provider", r"\bb2b\b|business contact|sales intelligence|prospect|lead gen|demand gen|account[- ]based|contact data|go-to-market|sales (and|&) marketing teams|business data|firmographic"),
    ("genealogy", "genealogy and family-records site", r"genealog|family tree|ancestry|ancestors"),
]
TRACKS = [
    ("your name and aliases", r"\bname\b|aliases"), ("home addresses and address history", r"(home|mailing|street|residential|postal) address|address history|previous addresses"),
    ("phone numbers", r"phone number|telephone number|mobile number|cell ?phone"), ("email addresses", r"e-?mail address"),
    ("age or birthdate", r"date of birth|birth ?date|\bage range\b|\bage\b"), ("relatives and household members", r"relatives|household (members|composition)|family members|associates"),
    ("job title and employer", r"job title|employer|employment (history|information)|work history|professional (information|background)"),
    ("education", r"education(al)? (history|information|background)|\bdegree\b|school"), ("income or wealth", r"household income|\bincome\b|net worth|wealth"),
    ("property and vehicles", r"property (record|ownership|data)|home ?ownership|vehicle|mortgage|real estate"),
    ("criminal and court records", r"criminal|arrest|court record|mugshot|conviction|sex offender"),
    ("shopping and purchase behavior", r"purchase (history|behavior|data)|shopping|transaction data|retail"), ("interests and demographics", r"demographic|lifestyle|interests|marital status|ethnic|political"),
    ("devices and online activity", r"cookie|device (id|identifier)|ip address|advertising (id|identifier)|browsing|clickstream|pixel|mobile advertising"),
    ("precise location", r"precise (geo)?location|geolocation|\bgps\b|location data"), ("health information", r"health (information|data|condition)|medical|diagnos|prescription"),
    ("social media profiles", r"social media (profile|account)|linkedin|facebook"), ("credit and financial accounts", r"credit (score|history)|financial account|bank account|credit card"),
]
BUYERS = [
    ("advertisers and marketers", r"advertis|marketers|marketing (partners|companies|purposes)|brands"), ("other data brokers and resellers", r"data brokers?|resellers?|data partners|aggregators"),
    ("employers and recruiters", r"employers|recruit|staffing|human resources"), ("landlords and property managers", r"landlords?|property managers?|tenant"),
    ("banks, lenders and insurers", r"lenders|banks|financial institutions|insurers|insurance compan"), ("government and law enforcement", r"law enforcement|government (agenc|entit)|public safety"),
    ("business customers and sales teams", r"business customers|\bb2b\b|sales teams|enterprise|corporate customers|our clients|our customers"), ("publishers and ad platforms", r"publishers|ad exchanges|ad platforms|demand[- ]side"),
    ("researchers and nonprofits", r"nonprofit|researchers|universities|political campaigns"),
]
NOT_SOLD = re.compile(r"(do|does|will) not sell|don.t sell|never sell|not sold", re.I)
SENSITIVE = {"criminal and court records": 6, "health information": 6, "precise location": 6, "income or wealth": 4, "relatives and household members": 4, "home addresses and address history": 4,
             "phone numbers": 3, "email addresses": 2, "age or birthdate": 2, "social media profiles": 2, "credit and financial accounts": 4}
BASE = {"people_search": 34, "arrests": 30, "consumer_reporting": 28, "marketing_data": 26, "healthcare": 22, "financial": 22, "fraud_identity": 20, "real_estate": 20, "b2b": 18, "genealogy": 16, "adtech": 14, "other": 10}


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if 25 < len(s.strip()) < 420]


def describe(ev):
    home, policy = ev.get("home") or {}, ev.get("policy") or {}
    htext = " ".join([home.get("title", ""), home.get("description", ""), " ".join(home.get("headings", [])), home.get("text", "")[:2500]]).lower()
    ptext = (policy.get("text") or "")
    name = (ev.get("names") or [ev["domain"]])[0]
    scores = []
    for i, (cid, label, pat) in enumerate(CATEGORIES):
        n = 3 * len(re.findall(pat, htext)) + len(re.findall(pat, ptext[:6000].lower()))
        scores.append((n, -i, cid, label))
    best = max(scores)
    cid, label = (best[2], best[3]) if best[0] >= 3 else ("other", "data company")
    tracks = [t for t, pat in TRACKS if re.search(pat, (ptext + " " + htext).lower())]
    if cid not in ("people_search", "arrests"): tracks = [t for t in tracks if t != "your name and aliases"] or tracks
    sells, note = [], ""
    for s in sentences(ptext):
        low = s.lower()
        if not re.search(r"\bsell|\bsold|disclos|share|provide[sd]? to|licen[sc]e", low): continue
        if re.search(r"(our|this) (web)?sites?\b|cookies|visitors|job applicants|employees", low): continue      # about visiting the site, not the data it sells
        hit = [b for b, pat in BUYERS if re.search(pat, low)]
        if hit and not NOT_SOLD.search(low):
            for b in hit:
                if b not in sells: sells.append(b)
            if not note and re.search(r"\bsell|\bsold|licen[sc]e|disclos", low): note = s[:240]
    if cid in ("people_search", "arrests", "genealogy") and re.search(r"subscription|membership|premium|pay[- ]per|unlimited (searches|reports)|get (the )?report", htext): sells.append("the general public (paid lookups)")
    says_no_sale = bool(NOT_SOLD.search(ptext)) and not sells
    tagline = re.sub(r"\s+", " ", home.get("description") or "").strip()
    if tagline and len(tagline) > 190: tagline = tagline[:187].rsplit(" ", 1)[0] + "..."
    parts = [f"{name} is {'an' if label[0] in 'aeiou' else 'a'} {label}."]
    if tagline: parts.append(tagline if tagline.endswith((".", "!", "?", "...")) else tagline + ".")
    if tracks: parts.append("Its own pages mention " + ", ".join(tracks[:6]) + ".")
    parts.append(("Its policy names these buyers or recipients: " + "; ".join(sells[:5]) + ".") if sells else "Its policy does not name who it sells to.")
    score = BASE[cid] + min(24, sum(SENSITIVE.get(t, 1) for t in tracks)) + min(15, 3 * len(sells)) + (10 if any(s.startswith("the general public") for s in sells) else 0) \
        + min(9, 3 * len(ev.get("registered_in") or []))
    about = {"category": cid, "summary": " ".join(parts), "tracks": tracks, "sells_to": sells}
    if note: about["sells_note"] = note
    src = policy.get("url") or home.get("url")
    if src: about["source"] = src
    return about, max(0, min(100, score))


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--about", default=".about"); ap.add_argument("--dir", default="directory"); ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(); n = 0; dist = {}
    for f in sorted(glob.glob(os.path.join(a.dir, "*.yml"))):
        s = open(f).read()
        d = re.search(r'^domain: "([^"]+)"', s, re.M).group(1)
        ev_path = os.path.join(a.about, d + ".json")
        if not os.path.exists(ev_path): continue
        ev = json.load(open(ev_path))
        if not ev.get("home") and not ev.get("policy"): continue
        about, score = describe(ev); dist[about["category"]] = dist.get(about["category"], 0) + 1; n += 1
        if a.dry_run: continue
        s = re.sub(r"\nabout: \{.*\}\n?", "\n", s); s = re.sub(r"\npriority: \d+\n?", "\n", s)
        open(f, "w").write(s.rstrip("\n") + f"\nabout: {json.dumps(about, ensure_ascii=False)}\npriority: {score}\n")
    print(n, "described;", dict(sorted(dist.items(), key=lambda x: -x[1])))


if __name__ == "__main__":
    main()
