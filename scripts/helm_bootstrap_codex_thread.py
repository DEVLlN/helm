#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bootstrap a discoverable empty Codex thread through the helm bridge.")
    parser.add_argument("--bridge-url", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--model", default="")
    return parser.parse_args()


def http_json(url: str, *, method: str = "GET", headers: dict[str, str] | None = None, payload: dict | None = None) -> dict:
    data = None
    request_headers = dict(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, method=method, headers=request_headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    args = parse_args()
    base_url = args.bridge_url.rstrip("/")

    try:
        pairing = http_json(f"{base_url}/api/pairing")
        token = ((pairing.get("pairing") or {}).get("token") or "").strip()
        if not token:
            raise RuntimeError("loopback pairing response did not include a token")

        body = {"cwd": args.cwd}
        if args.model:
            body["model"] = args.model

        result = http_json(
            f"{base_url}/api/codex/bootstrap-shell-thread",
            method="POST",
            headers={"Authorization": f"Bearer {token}"},
            payload=body,
        )
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace").strip()
        print(f"bootstrap request failed: HTTP {exc.code} {detail}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"bootstrap request failed: {exc}", file=sys.stderr)
        return 1

    thread_id = str(result.get("threadId") or "").strip()
    if not thread_id:
        print("bootstrap request failed: bridge response missing threadId", file=sys.stderr)
        return 1

    print(thread_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
