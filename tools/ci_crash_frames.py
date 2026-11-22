#!/usr/bin/env python3
"""Prints the crashed thread of a macOS crash report (.ips: a JSON header line, then JSON), one frame a line: image, symbol and offset. CI attaches it to a
Mac test job that crashed (.github/workflows/ci.yml), since its log cannot be read without a GitHub sign-in. Usage: ci_crash_frames.py <report.ips>"""
import json, sys


def frames(text, limit=25):
    head, _, body = text.partition("\n")
    report = json.loads(body or head)
    images = report.get("usedImages", [])
    out = [f"{report.get('exception', {}).get('type', '?')} {report.get('exception', {}).get('signal', '')}".strip()]
    for t in report.get("threads", []):
        if not t.get("triggered"):
            continue
        for f in t.get("frames", [])[:limit]:
            img = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
            out.append(f"{img}  {f.get('symbol', '?')} +{f.get('symbolLocation', 0)}")
    return out


if __name__ == "__main__":
    print("\n".join(frames(open(sys.argv[1], encoding="utf-8", errors="replace").read())))
