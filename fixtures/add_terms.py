#!/usr/bin/env python3
"""Adds the fixture brokers' terms paragraphs to a copy of the terms library, as reviewed and ok (what a person's review would have made them), so the end-to-end
tests can show the app accepting a prompt for a person who allowed it. Stdlib only. Usage: add_terms.py <library.yml> (the copy the catalog is built from)."""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import terms_canon as T

HERE = os.path.dirname(os.path.abspath(__file__))
out = []
for name in sorted(os.listdir(os.path.join(HERE, 'terms'))):
    if not name.endswith('.txt'): continue
    domain = '127.0.0.1'          # the host the app judges the page by: the fixture server's address, not the site's name
    for p in open(os.path.join(HERE, 'terms', name)).read().strip().split('\n'):
        c = T.canonical(p, domain)
        out.append(f"  - hash: '{T.paragraph_hash(c)}'\n    sites: 1\n    kinds: ['prompt']\n    flags: []\n    prefix: '{re.sub(chr(39), '', c[:50])}'\n    reviewed: true\n    verdict: 'ok'\n    reviewer: 'fixture'\n")
with open(sys.argv[1], 'a') as f:
    if not open(sys.argv[1]).read().endswith('\n'): f.write('\n')
    f.write(''.join(out))
print(f"{len(out)} fixture paragraphs added to {sys.argv[1]}")
