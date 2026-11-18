"""Build the confirmed OpenTodo API spec for the deployed server.

Sources, in order of trust:
  1. the v1.5.0 route table (internal/httpapi/*.go)   -> what the server code serves
  2. live OPTIONS probes against the instance          -> what this server actually exposes
Nothing is invented: a route only enters spec/routes.json with its live status.
"""
import json
import re
import sys
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BASE = "https://otd.003274.xyz"
TOKEN = "ot_P94sUirt1vambHVcnkGpQjRg8Qoty5U7ZXEQBMpzCe0"
SRC = Path(r"W:\repos\OTDA\_research\v1.5.0\internal\httpapi")
OUT = Path(r"W:\repos\OTDA\spec")

PROBE = {
    "id": "00000000-0000-4000-8000-000000000001",
    "userId": "00000000-0000-4000-8000-000000000002",
    "groupId": "00000000-0000-4000-8000-000000000003",
    "taskId": "00000000-0000-4000-8000-000000000001",
    "commentId": "00000000-0000-4000-8000-000000000004",
    "attachmentId": "00000000-0000-4000-8000-000000000005",
    "fieldId": "00000000-0000-4000-8000-000000000006",
    "entryId": "00000000-0000-4000-8000-000000000007",
    "reminderId": "00000000-0000-4000-8000-000000000008",
}

# Routes that belong to surfaces the app deliberately does not implement.
AI_MARKERS = ("/assistant", "/mcp", "/routines/", "/relay", "/skills", "agent-access")


def split_args(text: str):
    """Split the argument list of a call into top-level arguments."""
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


def call_body(src: str, start: int) -> str:
    """Return the text between the parens of the call whose '(' is at start."""
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
                return src[start + 1: i]
        i += 1
    return ""


def resolve(expr: str, constants: dict) -> str:
    """Evaluate a Go string-literal expression of literals and known constants."""
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"|([A-Za-z_][A-Za-z0-9_]*)', expr)
    out = ""
    for lit, ident in parts:
        if lit:
            out += lit.replace('\\"', '"')
        elif ident in constants:
            out += constants[ident]
        else:
            out += "{" + ident + "}"
    return out


def load_sources():
    files = sorted(SRC.glob("*.go"))
    texts = {f.name: f.read_text(encoding="utf-8", errors="replace") for f in files}
    # package-level string constants/var initialisers: name = "value" or name = "a" + "b"
    constants = {}
    for text in texts.values():
        for m in re.finditer(r'^\s*(?:const\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)\s*$', text, re.M):
            name, expr = m.group(1), m.group(2)
            val = "".join(re.findall(r'"((?:[^"\\]|\\.)*)"', expr))
            if val.startswith("/"):
                constants[name] = val
    return texts, constants


def routes():
    texts, constants = load_sources()
    found = []
    for fname, text in texts.items():
        for m in re.finditer(r"mux\.handle\(", text):
            body = call_body(text, m.end() - 1)
            args = split_args(body)
            if len(args) < 3:
                continue
            spec, policy, handler = args[0], args[1], args[2]
            resolved = resolve(spec, constants)
            if " " not in resolved:
                continue
            method, path = resolved.split(" ", 1)
            if not path.startswith("/"):
                continue
            policy_txt = re.sub(r"\s+", "", policy)
            found.append({
                "method": method,
                "path": path,
                "policy": policy_txt,
                "handler": handler,
                "file": fname,
            })
    # de-duplicate (same method+path registered once per file)
    seen, uniq = set(), []
    for r in found:
        key = (r["method"], r["path"])
        if key in seen:
            continue
        seen.add(key)
        uniq.append(r)
    return uniq


def concrete(path: str) -> str:
    def sub(m):
        name = m.group(1)
        return PROBE.get(name, "probe")
    return re.sub(r"\{([A-Za-z]+)\}", sub, path)


def probe(route):
    url = BASE + concrete(route["path"])
    req = urllib.request.Request(url, method="OPTIONS", headers={
        "User-Agent": "OTDA/0.1",
        "Authorization": "Bearer " + TOKEN,
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            status, allow = r.status, r.headers.get("Allow", "")
    except urllib.error.HTTPError as e:
        status, allow = e.code, e.headers.get("Allow", "") if e.headers else ""
    except Exception as e:  # noqa: BLE001 - a network error is a probe result, not a crash
        status, allow = -1, str(e)
    return status, allow


def main():
    rows = routes()
    print(f"source routes: {len(rows)}", file=sys.stderr)
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(probe, rows))
    for r, (status, allow) in zip(rows, results):
        r["probe_url"] = concrete(r["path"])
        r["status"] = status
        r["allow"] = allow
        r["exists"] = status != 404 and status != -1
        r["ai"] = any(m in r["path"] for m in AI_MARKERS)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "routes.json").write_text(
        json.dumps({"base": BASE, "server_version": "v1.5.0", "routes": rows}, indent=1),
        encoding="utf-8")
    present = [r for r in rows if r["exists"] and not r["ai"]]
    absent = [r for r in rows if not r["exists"]]
    print(f"confirmed present (non-AI): {len(present)}  absent: {len(absent)}", file=sys.stderr)
    for r in absent:
        print(f"  ABSENT {r['method']:6} {r['path']}", file=sys.stderr)


if __name__ == "__main__":
    main()
