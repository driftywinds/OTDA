# OTDA

A Flutter client for [OpenTodo](https://github.com/OpenTodoApp/OpenTodo) servers —
offline-first, with the same data model as the server so every device converges.

- Package / bundle id: `com.dw.otda`
- Target server: OpenTodo **v1.5.0** and later (`/api/v1`)
- Platforms: Android, iOS

## What is here

| Path | What it is |
| --- | --- |
| `spec/API.md` | The confirmed API surface: **400 `/api/v1` operations**, every one probed against a live v1.5.0 server, AI surface excluded. |
| `spec/OTDA.openapi.json` | The same surface as OpenAPI 3.1, filtered to what this app uses. |
| `spec/*.py` | The scripts that produced it (route table of tag `v1.5.0` + live probes + the repo's OpenAPI). |
| `lib/src/api/` | HTTP client: bearer token or session cookie, error envelope, no redirects. |
| `lib/src/auth/` | Health check, password sign-in, second factor, step-up (`reauth`), token sign-in. |
| `lib/src/data/` | The local replica: per-field last-writer-wins, op outbox, hybrid logical clock, sync engine, view rules. |
| `lib/src/quickadd/` | The quick-add parser, ported from the web app with its shared vectors. |
| `test/` | Unit tests, parity fixtures (`inbox`, `views`, `quickadd` vectors), and integration tests against a real server. |

## Sign-in

Session cookie first (email + password, second factor, step-up for the
credential routes), API token second. The token is for scripts and for servers
where single sign-on has closed password sign-in.

## The data model

The server is a field-level last-writer-wins op log. This app keeps the same
shape locally: `fields(entity, entity_id, field, value, ts, device)`, plus an
`outbox`. Every edit is `(ts, device)`-stamped, applied locally at once, and
pushed by the next exchange. Pulling applies the same comparison, so a device
that was offline for a week ends up identical to one that never left.

`POST /api/v1/sync` carries it: `cursor` in, `ops`/`cursor`/`hasMore` out, plus
`rejected` (per-op verdicts), `purged` (delete these locally) and `generation`
(server restored from a backup → re-seed).

## Test it

```powershell
$env:APPDATA="$PWD\.tmp\appdata"; $env:LOCALAPPDATA="$PWD\.tmp\localappdata"
$env:PUB_CACHE="$PWD\.tmp\pub-cache"; $env:HOME="$PWD\.tmp\home"
$env:TEMP="$PWD\.tmp\temp"; $env:TMP=$env:TEMP
$env:ANDROID_HOME='W:\repos\librarium-android\.tooling\android-sdk'
$env:GRADLE_USER_HOME="$PWD\.tmp\gradle"; $env:ANDROID_USER_HOME="$PWD\.tmp\android-user"

.flutter\flutter.bat test            # unit + parity + integration (needs the local server)
.flutter\flutter.bat analyze
```

The integration tests expect a server at `http://127.0.0.1:18080` with the
account `dev@otda.local`. Start one from the release binary:

```powershell
$env:OPENTODO_ADDR='127.0.0.1:18080'; $env:OPENTODO_DATA_DIR="$PWD\.tmp\server\data"
.\.tmp\server\opentodo.exe
```

To check the real dataset on a live server (read-only):

```powershell
flutter test test/remote_pull_test.dart --dart-define=OT_SERVER=https://… --dart-define=OT_TOKEN=ot_…
```

## Regenerate the API spec

```powershell
python spec/build_routes_full.py   # parse every registration at tag v1.5.0, probe live
python spec/probe_openapi.py       # probe the repo's OpenAPI, capture response samples
python spec/make_spec.py           # write spec/API.md and spec/OTDA.openapi.json
```
