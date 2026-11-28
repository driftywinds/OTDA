# Releasing

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

