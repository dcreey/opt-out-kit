#!/usr/bin/env python3
"""Writes a plain-words description of every broker into the directory: who it is, what it tracks, who it sells to, and a priority score.

Input is the evidence tools/collect_about.py gathered (the site's own home page and privacy policy). Everything written is read from that
text: the category from what the site says it does, the data kinds from the categories its policy names, the buyers from the policy
sentences about selling or sharing, and one quoted sentence as proof. Where the text says nothing, the field says so rather than guessing.
Output: an `about:` and a `priority:` line in each directory/*.yml. Usage: describe_brokers.py [--about .about] [--dir directory] [--dry-run]
"""
import argparse, glob, json, os, re

import yamlio

OVERRIDES = json.load(open(os.path.join(os.path.dirname(__file__), "category_overrides.json")))      # categories fixed by reading the site, which win over the keywords

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
    ("lead_generation", "lead-generation company", r"lead generation|lead gen\b|connects? consumers|consumer acquisition|ready-to-buy|free quote|get a quote"),
    ("political", "political and nonprofit data provider", r"voter|democratic|republican|political (campaign|data)|fundrais|campaigns and (causes|organizations)|get out the vote"),
    ("recruiting", "recruiting and workforce data provider", r"recruit|talent|candidates|hiring|job (search|openings|seekers)|workforce"),
    ("automotive", "automotive data company", r"dealership|vehicle (history|registration|data)|automotive|\bvin\b|license plate|car (buyers|dealers)"),
    ("location_data", "device and location data company", r"geolocation|location data|mobility data|device location|ip location"),
    ("marketing_services", "marketing and direct-mail services company", r"direct mail|marketing agency|marketing services|influencer|media monitoring"),
]
# Fixed vocabularies: the ids are what the app filters on; the labels are the English words used in the written summary.
DATA_KINDS = {"name": "names and aliases", "address": "home addresses", "phone": "phone numbers", "email": "email addresses", "age": "age or birthdate",
              "relatives": "relatives and household members", "employment": "job title and employer", "education": "education", "income": "income or wealth",
              "property": "property and vehicles", "criminal": "criminal and court records", "purchases": "shopping and purchase behavior",
              "interests": "interests and demographics", "online": "devices and online activity", "location": "precise location", "health": "health information",
              "social": "social media profiles", "credit": "credit and financial accounts"}
BUYER_KINDS = {"advertisers": "advertisers and marketers", "brokers": "other data brokers and resellers", "employers": "employers and recruiters",
               "landlords": "landlords and property managers", "lenders": "banks, lenders and insurers", "government": "government and law enforcement",
               "businesses": "business customers and sales teams", "publishers": "publishers and ad platforms", "researchers": "researchers and nonprofits",
               "public": "the general public (people looking you up)"}
TRACKS = [
    ("name", r"\bname\b|aliases"), ("address", r"(home|mailing|street|residential|postal) address|address history|previous addresses"),
    ("phone", r"phone number|telephone number|mobile number|cell ?phone"), ("email", r"e-?mail address"),
    ("age", r"date of birth|birth ?date|\bage range\b|\bage\b"), ("relatives", r"relatives|household (members|composition)|family members|associates"),
    ("employment", r"job title|employer|employment (history|information)|work history|professional (information|background)"),
    ("education", r"education(al)? (history|information|background)|\bdegree\b|school"), ("income", r"household income|\bincome\b|net worth|wealth"),
    ("property", r"property (record|ownership|data)|home ?ownership|vehicle|mortgage|real estate"),
    ("criminal", r"criminal|arrest|court record|mugshot|conviction|sex offender"),
    ("purchases", r"purchase (history|behavior|data)|shopping|transaction data|retail"), ("interests", r"demographic|lifestyle|interests|marital status|ethnic|political"),
    ("online", r"cookie|device (id|identifier)|ip address|advertising (id|identifier)|browsing|clickstream|pixel|mobile advertising"),
    ("location", r"precise (geo)?location|geolocation|\bgps\b|location data"), ("health", r"health (information|data|condition)|medical|diagnos|prescription"),
    ("social", r"social media (profile|account)|linkedin|facebook"), ("credit", r"credit (score|history)|financial account|bank account|credit card"),
]
BUYERS = [
    ("advertisers", r"advertis|marketers|marketing (partners|companies|purposes)|brands"), ("brokers", r"data brokers?|resellers?|data partners|aggregators"),
    ("employers", r"employers|recruit|staffing|human resources"), ("landlords", r"landlords?|property managers?|tenant"),
    ("lenders", r"lenders|banks|financial institutions|insurers|insurance compan"), ("government", r"law enforcement|government (agenc|entit)|public safety"),
    ("businesses", r"business customers|b2b|sales teams|enterprise|corporate customers|our clients|our customers"), ("publishers", r"publishers|ad exchanges|ad platforms|demand[- ]side"),
    ("researchers", r"nonprofit|researchers|universities|political campaigns"),
]
NOT_SOLD = re.compile(r"(do|does|will) not sell|don.t sell|never sell|not sold", re.I)
SENSITIVE = {"criminal": 6, "health": 6, "location": 6, "income": 4, "relatives": 4, "address": 4, "phone": 3, "email": 2, "age": 2, "social": 2, "credit": 4}
BASE = {"lead_generation": 22, "political": 20, "recruiting": 16, "automotive": 18, "location_data": 24, "marketing_services": 10, "people_search": 34, "arrests": 30, "consumer_reporting": 28, "marketing_data": 26, "healthcare": 22, "financial": 22, "fraud_identity": 20, "real_estate": 20, "b2b": 18, "genealogy": 16, "adtech": 14, "other": 10}


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
    if ev["domain"] in OVERRIDES:
        cid = OVERRIDES[ev["domain"]]; label = next((l for c, l, _ in CATEGORIES if c == cid), label)
    tracks = [t for t, pat in TRACKS if re.search(pat, (ptext + " " + htext).lower())]
    if cid not in ("people_search", "arrests"): tracks = [t for t in tracks if t != "name"] or tracks
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
    if cid in ("people_search", "arrests", "genealogy") and re.search(r"subscription|membership|premium|pay[- ]per|unlimited (searches|reports)|get (the )?report", htext): sells.append("public")
    tagline = re.sub(r"\s+", " ", home.get("description") or "").strip()
    if tagline and len(tagline) > 190: tagline = tagline[:187].rsplit(" ", 1)[0] + "..."
    parts = [f"{name} is {'an' if label[0] in 'aeiou' else 'a'} {label}."]
    if tagline: parts.append(tagline if tagline.endswith((".", "!", "?", "...")) else tagline + ".")
    if tracks: parts.append("Its own pages mention " + ", ".join(DATA_KINDS[t] for t in tracks[:6]) + ".")
    parts.append(("Its policy names these buyers or recipients: " + "; ".join(BUYER_KINDS[b] for b in sells[:5]) + ".") if sells else "Its policy does not name who it sells to.")
    score = BASE[cid] + min(24, sum(SENSITIVE.get(t, 1) for t in tracks)) + min(15, 3 * len(sells)) + (10 if "public" in sells else 0) \
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
        doc = yamlio.load(f)
        d = doc["domain"]
        ev_path = os.path.join(a.about, d + ".json")
        if not os.path.exists(ev_path): continue
        ev = json.load(open(ev_path))
        if not ev.get("home") and not ev.get("policy"): continue
        about, score = describe(ev); dist[about["category"]] = dist.get(about["category"], 0) + 1; n += 1
        if a.dry_run: continue
        doc.pop("about", None); doc.pop("priority", None)
        doc["about"] = about; doc["priority"] = score
        yamlio.save(f, doc)
    print(n, "described;", dict(sorted(dist.items(), key=lambda x: -x[1])))


if __name__ == "__main__":
    main()
