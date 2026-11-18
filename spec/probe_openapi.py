"""Probe every operation in the repo's OpenAPI description against the live server.

answers: which of those operations this v1.5.0 instance actually serves (404 = not served),
which are part of the AI surface the app skips, and real response samples for the
collections the app models.
"""
import json
import re
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BASE = "https://otd.003274.xyz"
TOKEN = "ot_P94sUirt1vambHVcnkGpQjRg8Qoty5U7ZXEQBMpzCe0"
DOC = Path(r"W:\repos\OTDA\_research\OpenTodo\docs\openapi.json")
OUT = Path(r"W:\repos\OTDA\spec")

PROBE = {
    "id": "00000000-0000-4000-8000-000000000001",
    "userId": "00000000-0000-4000-8000-000000000002",
    "groupId": "00000000-0000-4000-8000-000000000003",
    "taskId": "00000000-0000-4000-8000-000000000001",
    "commentId": "00000000-0000-4000-8000-000000000004",
    "entryId": "00000000-0000-4000-8000-000000000007",
    "fontstack": "x",
    "range": "0-255",
    "z": "0", "x": "0", "y": "0",
    "secret": "probe", "token": "probe", "file": "probe", "collection": "probe",
}
AI_TAGS = {"In-app assistant", "AI assistants (MCP)", "Routines"}
SAMPLES = ["me", "tasks", "projects", "labels", "sections", "views", "notes",
           "reminders", "workspaces", "places", "objectives", "fields",
           "time-entries", "notifications", "settings", "people"]


def concrete(path: str) -> str:
    return re.sub(r"\{([A-Za-z_]+)\}", lambda m: PROBE.get(m.group(1), "probe"), path)


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=body, headers={
        "User-Agent": "OTDA/0.1", "Accept": "application/json",
        "Authorization": "Bearer " + TOKEN,
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()
    except Exception as e:  # noqa: BLE001
        return -1, {}, str(e).encode()


def probe(op):
    method, path = op
    status, headers, _ = call("OPTIONS", concrete(path))
    return {"method": method, "path": path, "probe_path": concrete(path),
            "status": status, "allow": headers.get("Allow", ""), "exists": status not in (404, -1)}


def main():
    doc = json.loads(DOC.read_text(encoding="utf-8"))
    ops, ai = [], set()
    for path, item in doc["paths"].items():
        for method, op in item.items():
            if method.upper() not in ("GET", "POST", "PUT", "PATCH", "DELETE"):
                continue
            ops.append((method.upper(), path))
            if AI_TAGS & set(op.get("tags") or []):
                ai.add((method.upper(), path))
    print(f"openapi operations: {len(ops)} (ai: {len(ai)})", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=8) as pool:
        rows = list(pool.map(probe, ops))
    for r in rows:
        r["ai"] = (r["method"], r["path"]) in ai
    present = [r for r in rows if r["exists"]]
    absent = [r for r in rows if not r["exists"]]
    print(f"present: {len(present)}  absent: {len(absent)}", file=sys.stderr)
    for r in sorted(absent, key=lambda r: r["path"]):
        print(f"  ABSENT {r['method']:6} {r['path']}", file=sys.stderr)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "openapi_probed.json").write_text(json.dumps({
        "base": BASE, "served_version": "v1.5.0",
        "description_version": doc["info"].get("version"),
        "operations": rows,
    }, indent=1), encoding="utf-8")

    # real payloads: one GET per collection, trimmed so the file stays readable
    samples = {}
    for name in SAMPLES:
        status, _, body = call("GET", f"/api/v1/{name}")
        entry = {"status": status, "bytes": len(body)}
        if status == 200:
            try:
                payload = json.loads(body)
                entry["keys"] = sorted(payload) if isinstance(payload, dict) else ["<array>"]
                if isinstance(payload, dict):
                    for k, v in payload.items():
                        if isinstance(v, list) and v and isinstance(v[0], dict):
                            entry["item_keys"] = sorted(v[0])
                            entry["item"] = v[0]
                            break
            except ValueError:
                entry["error"] = "not json"
        samples[name] = entry
    (OUT / "samples.json").write_text(json.dumps(samples, indent=1), encoding="utf-8")
    for name, e in samples.items():
        print(f"sample {name}: {e['status']} {e.get('bytes')}B keys={e.get('keys')}", file=sys.stderr)


if __name__ == "__main__":
    main()
