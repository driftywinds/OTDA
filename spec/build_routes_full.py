"""Complete route inventory for the self-hosted server at tag v1.5.0.

Covers both registration styles the codebase uses (`mux.handle` in
internal/httpapi, `mux.Handle` in the route packages) and expands the generic
`/api/v1/{collection}` patterns over the 12 collection names in
`opsync.Plural`. Every path is then probed live.
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
SRC = Path(r"W:\repos\OTDA\_research\v1.5.0\internal\httpapi")
OUT = Path(r"W:\repos\OTDA\spec")
COLLECTIONS = ["projects", "tasks", "labels", "views", "reminders", "sections",
               "fields", "rules", "frames", "slots", "notes", "objectives"]
HOST_ONLY = ("/operator/",)  # only exists with OPENTODO_HOST_URL

PROBE = {
    "id": "00000000-0000-4000-8000-000000000001",
    "userId": "00000000-0000-4000-8000-000000000002",
    "groupId": "00000000-0000-4000-8000-000000000003",
    "commentId": "00000000-0000-4000-8000-000000000004",
    "entryId": "00000000-0000-4000-8000-000000000007",
    "name": "probe", "device": "probe", "file": "probe", "token": "probe",
    "secret": "probe", "fontstack": "x", "range": "0-255", "z": "0", "x": "0", "y": "0",
    "collection": "probe",
}


def split_args(text):
    args, depth, cur, quote, i = [], 0, "", None, 0
    while i < len(text):
        c = text[i]
        if quote:
            cur += c
            if c == "\\":
                cur += text[i + 1]
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'`":
            quote, cur = c, cur + c
        elif c in "([{":
            depth, cur = depth + 1, cur + c
        elif c in ")]}":
            depth, cur = depth - 1, cur + c
        elif c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        args.append(cur.strip())
    return args


def call_body(src, start):
    depth, i, quote = 0, start, None
    while i < len(src):
        c = src[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return src[start + 1:i]
        i += 1
    return ""


def resolve(expr, constants):
    out = ""
    for lit, ident in re.findall(r'"((?:[^"\\]|\\.)*)"|([A-Za-z_][A-Za-z0-9_]*)', expr):
        if lit:
            out += lit.replace('\\"', '"')
        elif ident in constants:
            out += constants[ident]
    return out


def main():
    files = [f for f in SRC.rglob("*.go") if not f.name.endswith("_test.go")]
    texts = {f: f.read_text(encoding="utf-8", errors="replace") for f in files}
    constants = {}
    for text in texts.values():
        for m in re.finditer(r'^\s*(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)\s*$', text, re.M):
            val = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2)))
            if val.startswith("/"):
                constants[m.group(1)] = val

    found = []
    for f, text in texts.items():
        for m in re.finditer(r"\.(?:handle|Handle)\(", text):
            body = call_body(text, m.end() - 1)
            args = split_args(body)
            if len(args) < 2:
                continue
            spec = resolve(args[0], constants)
            if " " not in spec or not spec.split(" ", 1)[1].startswith("/"):
                continue  # host-mode catch-alls and dynamic paths
            method, path = spec.split(" ", 1)
            found.append({
                "method": method, "path": path,
                "policy": re.sub(r"\s+", "", args[1]),
                "handler": args[2] if len(args) > 2 else "",
                "file": str(f.relative_to(SRC)),
                "host_only": any(h in path for h in HOST_ONLY),
            })

    # expand the generic collection patterns
    expanded = []
    for r in found:
        if "{collection}" in r["path"]:
            for c in COLLECTIONS:
                e = dict(r)
                e["path"] = r["path"].replace("{collection}", c)
                e["collection_of"] = r["path"]
                expanded.append(e)
        else:
            expanded.append(r)

    seen, uniq = set(), []
    for r in expanded:
        key = (r["method"], r["path"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(r)
    print(f"registrations parsed: {len(found)}  after expansion+dedupe: {len(uniq)}", file=sys.stderr)
    print(f"  of which host-mode only: {sum(1 for r in uniq if r['host_only'])}", file=sys.stderr)
    generic = [r for r in uniq if r["path"] == "/api/v1/{collection}"]
    print(f"  unresolved placeholders left: {len(generic)}", file=sys.stderr)

    def concrete(path):
        return re.sub(r"\{([A-Za-z_]+)\}", lambda m: PROBE.get(m.group(1), "probe"), path)

    def probe(r):
        req = urllib.request.Request(BASE + concrete(r["path"]), method="OPTIONS", headers={
            "User-Agent": "OTDA/0.1", "Accept": "application/json",
            "Authorization": "Bearer " + TOKEN})
        try:
            with urllib.request.urlopen(req, timeout=25) as resp:
                return resp.status, resp.headers.get("Allow", "")
        except urllib.error.HTTPError as e:
            return e.code, (e.headers.get("Allow", "") if e.headers else "")
        except Exception:  # noqa: BLE001
            return -1, ""

    with ThreadPoolExecutor(max_workers=8) as pool:
        probes = list(pool.map(probe, uniq))
    for r, (status, allow) in zip(uniq, probes):
        r["probe_url"] = concrete(r["path"])
        r["status"] = status
        r["allow"] = allow
        r["exists"] = status not in (404, -1)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "routes_full.json").write_text(json.dumps({
        "base": BASE, "version": "v1.5.0",
        "collections": COLLECTIONS, "routes": uniq}, indent=1), encoding="utf-8")

    api = [r for r in uniq if r["path"].startswith("/api/v1/") and not r["host_only"]]
    present = [r for r in api if r["exists"]]
    absent = [r for r in api if not r["exists"]]
    print(f"\n/api/v1 routes: {len(api)}  present: {len(present)}  absent: {len(absent)}", file=sys.stderr)
    for r in sorted(absent, key=lambda r: r["path"]):
        print(f"  ABSENT {r['method']:6} {r['path']}  ({r['file']})", file=sys.stderr)
    non_api = sorted({r["path"] for r in uniq if not r["path"].startswith("/api/v1/") and not r["host_only"]})
    print(f"\nnon-/api routes ({len(non_api)}): {', '.join(non_api)}", file=sys.stderr)


if __name__ == "__main__":
    main()
