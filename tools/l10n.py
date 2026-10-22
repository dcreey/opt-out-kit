#!/usr/bin/env python3
"""Translations for the app and the core package.

  l10n.py extract            list every English string that needs a translation (writes l10n/keys.json)
  l10n.py build              write the two string catalogs from l10n/<lang>.json (App/Resources and the core package)
  l10n.py check              report missing translations and placeholder mismatches per language

English is the key. SwiftUI literals (Text("Next")) are found by Xcode's own extraction (`xcodebuild -exportLocalizations`);
words built in code are `Loc.t("...")` / `Loc.f("...", args)` in the app and `L10n.t` / `L10n.f` in the core package, found by
scanning the source. A translation file is {"English text": "Translated text"}; placeholders (%@, %lld, %1$@) must be kept.
The master terms list is NOT translated: it stays in each site's own language (see tools/terms_census.py --lang).
"""
import argparse, glob, json, os, re, subprocess, sys, tempfile

LANGS = ["fr", "es", "de"]
APP_CATALOG = "App/Resources/Localizable.xcstrings"
CORE_CATALOG = "Packages/OptOutKitCore/Sources/OptOutKitCore/Resources/Localizable.xcstrings"
CALL = re.compile(r'\b(?:Loc|L10n)\.(?:t|f|noun)\(\s*"')


def string_at(s, i):
    """s[i] == '"'. Returns (end, key) where \\( ... ) interpolation is not expected in keys (they use %@)."""
    j = i + 1; buf = []
    while j < len(s):
        c = s[j]
        if c == '\\' and j + 1 < len(s):
            nxt = s[j + 1]
            buf.append({'"': '"', 'n': '\n', 't': '\t', '\\': '\\'}.get(nxt, nxt)); j += 2; continue
        if c == '"': return j + 1, ''.join(buf)
        buf.append(c); j += 1
    raise ValueError("unterminated string")


def scan_calls(paths):
    keys = {}
    for p in paths:
        s = open(p).read()
        for m in CALL.finditer(s):
            try: _, key = string_at(s, m.end() - 1)
            except ValueError: continue
            keys.setdefault(key, set()).add(os.path.basename(p))
    return keys


def swiftui_keys():
    """Keys Xcode extracts from SwiftUI literals, via the official localization export."""
    out = tempfile.mkdtemp()
    subprocess.run(["xcodebuild", "-exportLocalizations", "-localizationPath", out, "-project", "OptOutKit.xcodeproj", "-exportLanguage", "en"],
                   check=True, capture_output=True)
    f = glob.glob(os.path.join(out, "en.xcloc", "Localized Contents", "*.xliff"))[0]
    text = open(f).read()
    keys = {}
    for tid, src in re.findall(r'<trans-unit id="([^"]*)"[^>]*>\s*<source>(.*?)</source>', text, re.S):
        if tid.startswith("CFBundle") or tid in ("%@", "%lld"): continue
        key = (tid.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'"))
        keys[key] = {"SwiftUI"}
    return keys


def state_names():
    """US state names and the EU's name, which the app translates itself. Country names come from the system's region names."""
    names = set(re.findall(r"^    name: (.+)$", open("jurisdictions/us.yml").read(), re.M)) | {"European Union", "General Data Protection Regulation (EU) 2016/679"}
    return {n: {"jurisdictions"} for n in names}


def cmd_extract(a):
    app = scan_calls(glob.glob("App/Sources/*.swift")); app.update({k: v | app.get(k, set()) for k, v in swiftui_keys().items()})
    core = scan_calls(glob.glob("Packages/OptOutKitCore/Sources/OptOutKitCore/*.swift")); core.update(state_names())
    json.dump({"app": sorted(app), "core": sorted(core)}, open("l10n/keys.json", "w"), indent=1, ensure_ascii=False)
    print(f"{len(app)} app strings, {len(core)} core strings, {len(set(app) | set(core))} distinct")


PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|d|ld|f)")


def placeholders(s): return sorted(re.sub(r"\d+\$", "", p) for p in PLACEHOLDER.findall(s))


def load_translations():
    out = {}
    for lang in LANGS:
        path = f"l10n/{lang}.json"
        out[lang] = json.load(open(path)) if os.path.exists(path) else {}
    return out


def catalog(keys, tr):
    strings = {}
    for k in keys:
        loc = {}
        for lang in LANGS:
            v = tr[lang].get(k)
            if v: loc[lang] = {"stringUnit": {"state": "translated", "value": v}}
        entry = {"extractionState": "manual", "localizations": loc} if loc else {"extractionState": "manual"}
        strings[k] = entry
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def cmd_build(a):
    keys = json.load(open("l10n/keys.json")); tr = load_translations()
    json.dump(catalog(keys["app"], tr), open(APP_CATALOG, "w"), indent=1, ensure_ascii=False)
    json.dump(catalog(keys["core"], tr), open(CORE_CATALOG, "w"), indent=1, ensure_ascii=False)
    print("wrote", APP_CATALOG, "and", CORE_CATALOG)


def cmd_check(a):
    keys = json.load(open("l10n/keys.json")); tr = load_translations()
    allkeys = sorted(set(keys["app"]) | set(keys["core"]))
    bad = 0
    for lang in LANGS:
        missing = [k for k in allkeys if k not in tr[lang]]
        mismatch = [k for k in allkeys if k in tr[lang] and placeholders(k) != placeholders(tr[lang][k])]
        extra = [k for k in tr[lang] if k not in allkeys]
        print(f"{lang}: {len(allkeys) - len(missing)}/{len(allkeys)} translated, {len(mismatch)} placeholder mismatches, {len(extra)} unused")
        for k in mismatch[:5]: print("   MISMATCH", k[:70], "->", tr[lang][k][:70])
        bad += len(mismatch) + (len(missing) if a.strict else 0)
        if a.missing:
            for k in missing[: a.missing]: print("   MISSING", k[:110])
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("extract"); sub.add_parser("build")
    c = sub.add_parser("check"); c.add_argument("--strict", action="store_true"); c.add_argument("--missing", type=int, default=0)
    a = ap.parse_args()
    sys.exit({"extract": cmd_extract, "build": cmd_build, "check": cmd_check}[a.cmd](a) or 0)


if __name__ == "__main__":
    main()
