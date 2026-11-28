# Test it

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

| Area | Tests |
| --- | --- |
| Parser | `test/quickadd/` — the shared vectors, a port of the web unit tests, the NLP grammar tests, and `relative_test.dart` (`in 4m`, `in 3d`, …, highlights, the highlighting controller) |
| Composer | `composer_state_test`, `compose_task_test`, `new_task_sheet_test` |
| Data and sync | `sync_exchange_test`, `live_update_test`, `sync_gate_test`, `apply_ops_test`, `series_completion_test`, `occurrences_test`, `recurrence_test`, the `inbox` / `views` vector tests |
| Tasks and Trash | `task_metadata_test`, `repo_metadata_test`, `subtasks_test`, `trash_test`, `trash_flow_test` |
| Workspaces | `workspace_test`, `workspace_flow_test` |
| Sharing | `sharing_test`, `sharing_flow_test`, `invitation_test`, `invitation_flow_test`, `public_links_test`, `public_links_flow_test` |
| Read and account | `stats_test`, `activity_flow_test`, `export_test`, `export_flow_test`, `mfa_flow_test`, `theme_palette_test`, `e2ee_lifecycle_test`, `biometric_test`, `file_crypto_test`, `attachments_test` |
| Reminders and widget | `reminder_planner_test`, `widget_snapshot_test`, `widget_settings_test` |
| UI | `settings_rows_test`, `theme_smoke_test`, `views_test`, `calendar_month_test` |

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

