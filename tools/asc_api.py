#!/usr/bin/env python3
"""Minimal App Store Connect API client (standard library plus the system `openssl`, which signs the token with the API key; the key is never read by this script).

  from asc_api import api
  api("GET", "/v1/apps")            # -> parsed JSON
Needs ASC_KEY_ID and ASC_ISSUER_ID in the environment and the key at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8.
"""
import base64, json, os, subprocess, time, urllib.request, urllib.error

BASE = "https://api.appstoreconnect.apple.com"


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_to_raw(der):
    # ECDSA DER -> r||s, 32 bytes each
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    assert der[i] == 0x02
    rl = der[i + 1]; r = der[i + 2:i + 2 + rl]; i = i + 2 + rl
    assert der[i] == 0x02
    sl = der[i + 1]; s = der[i + 2:i + 2 + sl]
    return r.lstrip(b"\0").rjust(32, b"\0") + s.lstrip(b"\0").rjust(32, b"\0")


def token():
    kid, iss = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    head = _b64(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    body = _b64(json.dumps({"iss": iss, "iat": int(time.time()), "exp": int(time.time()) + 1100, "aud": "appstoreconnect-v1"}).encode())
    key = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{kid}.p8")
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=f"{head}.{body}".encode(), capture_output=True, check=True).stdout
    return f"{head}.{body}.{_b64(_der_to_raw(sig))}"


def api(method, path, body=None, raw=None, headers=None, url=None):
    req = urllib.request.Request(url or BASE + path, method=method, data=raw if raw is not None else (json.dumps(body).encode() if body is not None else None))
    req.add_header("Authorization", "Bearer " + token())
    if body is not None: req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items(): req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
            return json.loads(data) if data and r.headers.get("Content-Type", "").startswith("application/json") else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read().decode()[:1500]}")
