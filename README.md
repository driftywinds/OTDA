<p align="center">
  <img src="assets/app-icon.png" alt="OTDA" width="120">
</p>

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

.flutter\flutter.bat test --exclude-tags integration   # what CI runs
.flutter\flutter.bat test --tags integration           # needs the server below
.flutter\flutter.bat analyze
.flutter\flutter.bat build apk --release --split-per-abi
```

The integration tests are tagged and expect a server at `http://127.0.0.1:18080`
with the account `dev@otda.local`. Start one from the release binary:

```powershell
$env:OPENTODO_ADDR='127.0.0.1:18080'; $env:OPENTODO_DATA_DIR="$PWD\.tmp\server\data"
.\.tmp\server\opentodo.exe
```

To check the real dataset on a live server (read-only):

```powershell
flutter test test/remote_pull_test.dart --dart-define=OT_SERVER=https://… --dart-define=OT_TOKEN=ot_…
```

## Releasing

Two workflows, adapted from the scrobbler project:

- `.github/workflows/ci.yml` — analyze, unit tests (integration tags excluded) and
  a release APK build on every pull request and push to `main`.
- `.github/workflows/release.yml` — on a `v*` tag or by hand. Tests, then builds
  the universal APK, one APK per ABI and the Play bundle, uploads them and
  publishes a GitHub release.

Add these repository secrets before the first signed release:

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the release keystore file, base64: `base64 -w0 release.keystore` |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore's store password |
| `ANDROID_KEY_ALIAS` | the key's alias |
| `ANDROID_KEY_PASSWORD` | the key's password |

Without `ANDROID_KEYSTORE_BASE64` the release job still runs and warns: the
artifacts are then signed with the debug key, which is fine for testing and
unusable for distribution. `key.properties` and `*.keystore` are gitignored, so
the keystore only ever exists on the runner.

## Regenerate the API spec

```powershell
python spec/build_routes_full.py   # parse every registration at tag v1.5.0, probe live
python spec/probe_openapi.py       # probe the repo's OpenAPI, capture response samples
python spec/make_spec.py           # write spec/API.md and spec/OTDA.openapi.json
```
