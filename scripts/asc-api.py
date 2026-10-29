#!/usr/bin/env python3
"""App Store Connect REST API ヘルパ。

使い方:
    asc-api.py create-app --bundle-id com.fournoha.audiorouter.ios \\
                          --name "AudioRouter Companion" \\
                          --sku audiorouter-ios

    asc-api.py mark-build-compliance --bundle-id com.fournoha.audiorouter.ios \\
                                      [--build-number N]   # 省略時=最新

    asc-api.py add-internal-tester --bundle-id com.fournoha.audiorouter.ios \\
                                    --email you@example.com \\
                                    --first-name "Name"

すべて以下の env を要求:
    APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID,
    APP_STORE_CONNECT_KEY_PATH (.p8 ファイル)
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

try:
    import jwt
    import urllib.request
    import urllib.error
except ImportError as e:
    print(f"missing dep: {e}. 'pip3 install --break-system-packages PyJWT cryptography' でインストール",
          file=sys.stderr)
    sys.exit(2)


API_BASE = "https://api.appstoreconnect.apple.com/v1"


def make_token() -> str:
    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key_path = os.environ["APP_STORE_CONNECT_KEY_PATH"]
    with open(key_path) as f:
        pkey = f.read()
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, pkey, algorithm="ES256",
                       headers={"kid": key_id, "typ": "JWT"})


def request(method: str, path: str, body=None, query=None):
    url = API_BASE + path
    if query:
        from urllib.parse import urlencode
        url += "?" + urlencode(query, doseq=True)
    data = None
    headers = {
        "Authorization": "Bearer " + make_token(),
        "Content-Type": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            if not raw:
                return None
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode("utf-8", errors="replace")
        print(f"HTTP {e.code} {method} {url}\n{body_txt}", file=sys.stderr)
        raise


def find_app_by_bundle_id(bundle_id: str):
    res = request("GET", "/apps",
                  query={"filter[bundleId]": bundle_id, "limit": 1})
    items = (res or {}).get("data") or []
    return items[0] if items else None


def cmd_create_app(args):
    existing = find_app_by_bundle_id(args.bundle_id)
    if existing:
        print(f"app already exists: id={existing['id']} bundleId={args.bundle_id}")
        return
    # App Store Connect の App 作成は通常 Web UI 経由が必要。API 経由作成は
    # 限定的 (条件次第で 409)。まず試して、ダメなら Web UI に誘導する。
    body = {
        "data": {
            "type": "apps",
            "attributes": {
                "bundleId": args.bundle_id,
                "name": args.name,
                "primaryLocale": "ja",
                "sku": args.sku,
            }
        }
    }
    try:
        res = request("POST", "/apps", body=body)
        print(f"created: {res['data']['id']}")
    except urllib.error.HTTPError as e:
        print("\nApp 作成 API はアカウント設定により利用不可な場合あり。\n"
              "Web UI で作成してください: https://appstoreconnect.apple.com/apps\n"
              "   Bundle ID: " + args.bundle_id + "\n"
              "   名前: " + args.name, file=sys.stderr)
        sys.exit(3)


def cmd_mark_build_compliance(args):
    app = find_app_by_bundle_id(args.bundle_id)
    if not app:
        print("app not found, register via Web UI first", file=sys.stderr); sys.exit(3)
    # 最新ビルドを取得。/apps/{id}/builds は sort パラメータ不可なので
    # トップレベル /builds を filter[app] で絞る。
    res = request("GET", "/builds",
                  query={"filter[app]": app['id'],
                         "sort": "-uploadedDate",
                         "limit": 5})
    builds = (res or {}).get("data") or []
    target = None
    if args.build_number:
        for b in builds:
            if b["attributes"].get("version") == str(args.build_number):
                target = b; break
    else:
        target = builds[0] if builds else None
    if not target:
        print("no build found", file=sys.stderr); sys.exit(3)
    bid = target["id"]
    body = {
        "data": {
            "type": "builds",
            "id": bid,
            "attributes": {"usesNonExemptEncryption": False}
        }
    }
    request("PATCH", f"/builds/{bid}", body=body)
    print(f"marked compliance on build {target['attributes'].get('version')} ({bid})")


def cmd_add_internal_tester(args):
    app = find_app_by_bundle_id(args.bundle_id)
    if not app:
        print("app not found", file=sys.stderr); sys.exit(3)
    # 既存テスター検索
    res = request("GET", "/betaTesters",
                  query={"filter[email]": args.email, "limit": 1})
    items = (res or {}).get("data") or []
    if items:
        print(f"tester already exists: {items[0]['id']}")
        return
    body = {
        "data": {
            "type": "betaTesters",
            "attributes": {
                "email": args.email,
                "firstName": args.first_name or "",
                "lastName": args.last_name or "",
            },
            "relationships": {
                "apps": {
                    "data": [{"type": "apps", "id": app["id"]}]
                }
            }
        }
    }
    res = request("POST", "/betaTesters", body=body)
    print(f"added tester: {res['data']['id']} -> {args.email}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("create-app")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--sku", required=True)
    p.set_defaults(func=cmd_create_app)

    p = sub.add_parser("mark-build-compliance")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--build-number", default=None)
    p.set_defaults(func=cmd_mark_build_compliance)

    p = sub.add_parser("add-internal-tester")
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--email", required=True)
    p.add_argument("--first-name", default=None)
    p.add_argument("--last-name", default=None)
    p.set_defaults(func=cmd_add_internal_tester)

    for n in ("APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID",
              "APP_STORE_CONNECT_KEY_PATH"):
        if not os.environ.get(n):
            print(f"required env {n} missing", file=sys.stderr); sys.exit(2)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
