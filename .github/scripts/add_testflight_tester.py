#!/usr/bin/env python3
"""Add a beta tester to Sol's TestFlight external group via App Store Connect API."""
import os
import sys
import time

import jwt
import requests

KEY_ID      = os.environ["ASC_API_KEY_ID"]
ISSUER_ID   = os.environ["ASC_ISSUER_ID"]
PRIVATE_KEY = os.environ["ASC_PRIVATE_KEY"]
EMAIL       = os.environ["TESTER_EMAIL"].strip()
FIRST_NAME  = os.environ.get("TESTER_FIRST", "").strip()
BUNDLE_ID   = "com.aakashranga.Sol"
BASE        = "https://api.appstoreconnect.apple.com/v1"

# Generate once — subtract 30s from iat to tolerate runner clock skew.
_now = int(time.time())
_raw_token = jwt.encode(
    {"iss": ISSUER_ID, "iat": _now - 30, "exp": _now + 1200, "aud": "appstoreconnect-v1"},
    PRIVATE_KEY,
    algorithm="ES256",
    headers={"kid": KEY_ID},
)
# PyJWT <2.0 returns bytes; >=2.0 returns str.
_JWT = _raw_token if isinstance(_raw_token, str) else _raw_token.decode()


def _h():
    return {"Authorization": f"Bearer {_JWT}", "Content-Type": "application/json"}


def api(method, path, allow=(200, 201, 204), retries=3, **kwargs):
    """Call the ASC REST API with automatic retry on 401 (transient auth errors)."""
    for attempt in range(retries):
        r = getattr(requests, method)(f"{BASE}{path}", headers=_h(), **kwargs)
        if r.status_code in allow:
            return r
        if r.status_code == 401 and attempt < retries - 1:
            wait = 2 ** attempt
            print(f"  401 on attempt {attempt + 1}, retrying in {wait}s…", file=sys.stderr)
            time.sleep(wait)
            continue
        # Any other non-OK response is fatal.
        print(f"{method.upper()} {path} → {r.status_code}\n{r.text[:500]}", file=sys.stderr)
        r.raise_for_status()
    return r


# 1. Find app by bundle ID.
apps = api("get", "/apps", params={"filter[bundleId]": BUNDLE_ID}).json()["data"]
if not apps:
    sys.exit(f"App {BUNDLE_ID} not found in App Store Connect")
app_id = apps[0]["id"]
print(f"App: {apps[0]['attributes']['name']} ({app_id})")

# 2. Find or create an external beta group.
all_groups = api("get", f"/apps/{app_id}/betaGroups").json()["data"]
groups = [g for g in all_groups if not g["attributes"].get("isInternalGroup", True)]

if groups:
    group_id = groups[0]["id"]
    print(f"Group: {groups[0]['attributes']['name']} ({group_id})")
else:
    r = api("post", "/betaGroups", json={
        "data": {
            "type": "betaGroups",
            "attributes": {"name": "External Testers", "publicLinkEnabled": False},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    })
    group_id = r.json()["data"]["id"]
    print(f"Created group: External Testers ({group_id})")

# 3. Create tester + link to group (409 = tester already exists in ASC).
r = api(
    "post", "/betaTesters",
    allow=(201, 409),
    json={
        "data": {
            "type": "betaTesters",
            "attributes": {"email": EMAIL, "firstName": FIRST_NAME},
            "relationships": {
                "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}
            },
        }
    },
)

if r.status_code == 201:
    print(f"✓ Added {EMAIL} to TestFlight")
else:
    # Tester exists in ASC already — find them and ensure they're in this group.
    print(f"Tester {EMAIL} already exists — ensuring group membership…")
    testers = api("get", "/betaTesters", params={"filter[email]": EMAIL}).json()["data"]
    if not testers:
        sys.exit(f"Could not find existing tester with email {EMAIL}")
    tester_id = testers[0]["id"]
    r2 = api(
        "post", f"/betaGroups/{group_id}/relationships/betaTesters",
        allow=(204, 409),
        json={"data": [{"type": "betaTesters", "id": tester_id}]},
    )
    if r2.status_code == 409:
        print(f"✓ {EMAIL} is already in the group — nothing to do")
    else:
        print(f"✓ Added existing tester {EMAIL} to group")
