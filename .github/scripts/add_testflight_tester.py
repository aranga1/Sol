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


def _token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        PRIVATE_KEY,
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def _h():
    return {"Authorization": f"Bearer {_token()}", "Content-Type": "application/json"}


def api(method, path, **kwargs):
    r = getattr(requests, method)(f"{BASE}{path}", headers=_h(), **kwargs)
    if not r.ok:
        print(f"{method.upper()} {path} → {r.status_code}\n{r.text[:500]}", file=sys.stderr)
        r.raise_for_status()
    return r


# 1. Find app by bundle ID
apps = api("get", "/apps", params={"filter[bundleId]": BUNDLE_ID}).json()["data"]
if not apps:
    sys.exit(f"App {BUNDLE_ID} not found in App Store Connect")
app_id = apps[0]["id"]
print(f"App: {apps[0]['attributes']['name']} ({app_id})")

# 2. Find or create an external beta group
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

# 3. Create tester and link to group in one call (409 = tester already exists)
r = requests.post(
    f"{BASE}/betaTesters",
    headers=_h(),
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
elif r.status_code == 409:
    # Tester already exists; look them up and add to this group
    print(f"Tester {EMAIL} already exists — adding to group...")
    testers = api("get", "/betaTesters", params={"filter[email]": EMAIL}).json()["data"]
    if not testers:
        sys.exit(f"Could not find existing tester with email {EMAIL}")
    tester_id = testers[0]["id"]
    r2 = requests.post(
        f"{BASE}/betaGroups/{group_id}/relationships/betaTesters",
        headers=_h(),
        json={"data": [{"type": "betaTesters", "id": tester_id}]},
    )
    if r2.status_code == 409:
        print(f"✓ {EMAIL} is already in the group — nothing to do")
    else:
        r2.raise_for_status()
        print(f"✓ Added existing tester {EMAIL} to group")
else:
    print(r.status_code, r.text[:500], file=sys.stderr)
    r.raise_for_status()
