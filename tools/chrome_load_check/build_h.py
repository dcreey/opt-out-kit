#!/usr/bin/env python3
"""Rewrites the regex block at the top of h.js from Shared/AssistedRun/LiveFormPicker.swift, so the Chrome check uses the app's current words."""
import re, json
src = open('Shared/AssistedRun/LiveFormPicker.swift').read()
block = "var P={};\n"
for m in re.finditer(r'static let (\w+) = try! NSRegularExpression\(pattern: "((?:[^"\\]|\\.)*)"(?:, options: ([^)]*))?\)', src):
    name, pat, opt = m.group(1), m.group(2).replace('\\\\', '\\'), m.group(3) or ''
    block += "P.%s=new RegExp(%s,%s);\n" % (name, json.dumps(pat), json.dumps('i' if 'caseInsensitive' in opt else ''))
js = open('tools/chrome_load_check/h.js').read()
rest = js[js.index("var has=function"):]
open('tools/chrome_load_check/h.js', 'w').write(block + rest)
