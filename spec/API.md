# OTDA — confirmed OpenTodo API spec

Server: `https://otd.003274.xyz` — **v1.5.0**. **354 `/api/v1` operations**, all present on the live server except the two listed below; **13 other routes**; **50 AI operations excluded by request**.

Regenerate all of it with:

```powershell
$py spec/build_routes_full.py    # parse every registration at tag v1.5.0 + probe live
$py spec/probe_openapi.py        # probe the repo's OpenAPI description, capture samples
$py spec/make_spec.py            # write API.md + OTDA.openapi.json
```

## How it was established (nothing assumed)

| Evidence | Role |
| --- | --- |
| `OpenTodo` @ tag `v1.5.0` — every `mux.handle` / `mux.Handle` registration, incl. the route packages (`maproutes`, `speech`, `davroutes`) and the generic `/api/v1/{collection}` patterns expanded over the 12 collection names | the complete route list |
| Live `OPTIONS` probe of every path (405 + `Allow` = exists, 404 = absent) | proves what this server serves |
| `OpenTodo/docs/openapi.json` (the file behind <https://open-todo.app/docs/api/>) | schemas, request/response bodies, examples, policy |
| `GET`s of the collections | real payload shapes in `spec/samples.json` |

Absent on this server — do not call: `POST /api/v1/demo/sandbox` (demo instances only), `GET /api/v1/export/archive` (host mode only).

> `GET /api/v1/openapi.json` does **not** exist before a later release — it answers 404 here. The spec in the repository is generated from `main`, so it lists operations this server does not have; that is why every route above was probed instead of trusted.

## Auth

- Bearer token on every call: `Authorization: Bearer ot_…`. Never follow a redirect with it attached.
- `full` tokens reach everything except *credential* routes (tokens, passkeys, 2FA, user admin, secret-bearing settings); those need `admin` or a session. The `Token?` column says which.
- Email + password without an existing token: `POST /api/v1/auth/login` (session cookie) → `POST /api/v1/tokens` → `POST /api/v1/auth/logout`; keep the returned `secret`. Send no `Origin` header and a JSON body on the token call.
- Do **not** use `/app/sign-in` + `POST /api/v1/app/token`: that flow exists for the official app (scope `app`, fixed `opentodo://signed-in` redirect).
- `read` tokens may only `GET`; `agent` tokens are the AI surface and are excluded here.

## Errors

`{"error":{"code","message"}}` on every failure. Branch on `code`. A known path with a wrong method answers 405 + `Allow`; an unknown path answers 404 `not_found`; `401` means re-authenticate, `403 insufficient_scope` means the token is too narrow.

## Sync is the data path

`POST /api/v1/sync` — one endpoint that carries the whole replicated state: push queued ops, pull everything after `cursor`. Field-level last-writer-wins on `(ts, device)`; 1000 ops / ~4 MB per page (`hasMore`); `generation` changes only when the server is restored from a backup; `rejected[]` answers per-op verdicts and carries the server's value for refused fields; `purged[]` names entities to delete locally. Live wake-up: `GET /api/v1/sync/events?device=…` (SSE, `event: ops` carries only a cursor). Full contract: `OpenTodo/docs/sync.md`.

## Endpoints

`Token?` = callable with a bearer token (`no` = session-only or credential route). `Confirmed` = answered the live probe.

### Tasks, projects and other synced data (124)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/activity` | Get activity | signed-in | yes | yes |
| DELETE | `/api/v1/comments/{id}` | Delete a comment | signed-in | yes | yes |
| PATCH | `/api/v1/comments/{id}` | Update a comment | signed-in | yes | yes |
| PUT | `/api/v1/comments/{id}/reactions` | Update comment reactions | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/export` | Get export | signed-in | yes | yes |
| GET | `/api/v1/fields` | List fields | signed-in | yes | yes |
| POST | `/api/v1/fields` | Create a field | signed-in | yes | yes |
| DELETE | `/api/v1/fields/{id}` | Delete a field | signed-in | yes | yes |
| GET | `/api/v1/fields/{id}` | Get a field | signed-in | yes | yes |
| PATCH | `/api/v1/fields/{id}` | Update a field | signed-in | yes | yes |
| GET | `/api/v1/habits` | List habits | signed-in | yes | yes |
| GET | `/api/v1/habits/{id}` | Get a habit | signed-in | yes | yes |
| POST | `/api/v1/habits/{id}/log` | Habit log | signed-in | yes | yes |
| POST | `/api/v1/import` | Import | signed-in | yes | yes |
| GET | `/api/v1/import/jobs` | List import jobs | signed-in | yes | yes |
| GET | `/api/v1/import/jobs/{id}` | Get a import job | signed-in | yes | yes |
| POST | `/api/v1/import/jobs/{id}/undo` | Import job undo | signed-in | yes | yes |
| POST | `/api/v1/import/preview` | Import preview | signed-in | yes | yes |
| POST | `/api/v1/import/todoist` | Import todoist | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/labels` | List labels | signed-in | yes | yes |
| POST | `/api/v1/labels` | Create a label | signed-in | yes | yes |
| DELETE | `/api/v1/labels/{id}` | Delete a label | signed-in | yes | yes |
| GET | `/api/v1/labels/{id}` | Get a label | signed-in | yes | yes |
| PATCH | `/api/v1/labels/{id}` | Update a label | signed-in | yes | yes |
| GET | `/api/v1/me/member-invitations` | List me member invitations | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/me/member-invitations/{id}/accept` | Me member invitation accept | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/me/member-invitations/{id}/decline` | Me member invitation decline | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/notes` | List notes | signed-in | yes | yes |
| POST | `/api/v1/notes` | Create a note | signed-in | yes | yes |
| DELETE | `/api/v1/notes/{id}` | Delete a note | signed-in | yes | yes |
| GET | `/api/v1/notes/{id}` | Get a note | signed-in | yes | yes |
| PATCH | `/api/v1/notes/{id}` | Update a note | signed-in | yes | yes |
| POST | `/api/v1/notes/{id}/append` | Note append | signed-in | yes | yes |
| GET | `/api/v1/notes/{id}/history` | Get note history | signed-in | yes | yes |
| DELETE | `/api/v1/notes/{id}/page` | Delete note page | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/notes/{id}/page` | Get note page | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/notes/{id}/page` | Note page | signed-in.full-tokens.recent | yes | yes |
| PUT | `/api/v1/notes/{id}/page/snapshot` | Update note page snapshot | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/notes/{id}/purge` | Delete note purge | signed-in | yes | yes |
| POST | `/api/v1/notes/{id}/to-task` | Note to task | signed-in | yes | yes |
| GET | `/api/v1/objectives` | List objectives | signed-in | yes | yes |
| POST | `/api/v1/objectives` | Create a objective | signed-in | yes | yes |
| DELETE | `/api/v1/objectives/{id}` | Delete a objective | signed-in | yes | yes |
| GET | `/api/v1/objectives/{id}` | Get a objective | signed-in | yes | yes |
| PATCH | `/api/v1/objectives/{id}` | Update a objective | signed-in | yes | yes |
| GET | `/api/v1/pages/{secret}` | Get a page | public | yes | yes |
| GET | `/api/v1/pages/{secret}/files/{fileId}` | Get a page file | public | yes | yes |
| GET | `/api/v1/pages/{secret}/maps/fonts/{fontstack}/{range}` | Get a page maps font | public | yes | yes |
| GET | `/api/v1/pages/{secret}/maps/sprites/{file}` | Get a page maps sprite | public | yes | yes |
| GET | `/api/v1/pages/{secret}/maps/tiles/{z}/{x}/{y}` | Get a page maps tile | public | yes | yes |
| POST | `/api/v1/pages/{secret}/replies` | Create a page reply | public | yes | yes |
| POST | `/api/v1/pages/{secret}/tick` | Page tick | public | yes | yes |
| GET | `/api/v1/places` | List places | signed-in | yes | yes |
| POST | `/api/v1/project-invites/{token}/accept` | Project invite accept | signed-in | yes | yes |
| GET | `/api/v1/projects` | List projects | signed-in | yes | yes |
| POST | `/api/v1/projects` | Create a project | signed-in | yes | yes |
| DELETE | `/api/v1/projects/{id}` | Delete a project | signed-in | yes | yes |
| GET | `/api/v1/projects/{id}` | Get a project | signed-in | yes | yes |
| PATCH | `/api/v1/projects/{id}` | Update a project | signed-in | yes | yes |
| GET | `/api/v1/projects/{id}/activity` | Get project activity | signed-in | yes | yes |
| GET | `/api/v1/projects/{id}/history` | Get project history | signed-in | yes | yes |
| GET | `/api/v1/projects/{id}/invites` | List project invites | signed-in | yes | yes |
| POST | `/api/v1/projects/{id}/invites` | Create a project invite | signed-in.recent | yes | yes |
| DELETE | `/api/v1/projects/{id}/invites/{inviteId}` | Delete a project invite | signed-in | yes | yes |
| DELETE | `/api/v1/projects/{id}/member-invitations/{invitationId}` | Delete a project member invitation | signed-in | yes | yes |
| GET | `/api/v1/projects/{id}/members` | List project members | signed-in | yes | yes |
| POST | `/api/v1/projects/{id}/members` | Create a project member | signed-in | yes | yes |
| DELETE | `/api/v1/projects/{id}/members/{userId}` | Delete a project member | signed-in | yes | yes |
| PATCH | `/api/v1/projects/{id}/members/{userId}` | Update a project member | signed-in | yes | yes |
| GET | `/api/v1/projects/{id}/public-links` | List project public links | signed-in | yes | yes |
| POST | `/api/v1/projects/{id}/public-links` | Create a project public link | signed-in.recent | yes | yes |
| DELETE | `/api/v1/projects/{id}/public-links/{linkId}` | Delete a project public link | signed-in | yes | yes |
| DELETE | `/api/v1/projects/{id}/purge` | Delete project purge | signed-in | yes | yes |
| POST | `/api/v1/projects/{id}/transfer` | Project transfer | signed-in | yes | yes |
| GET | `/api/v1/public/{token}` | Get a public | public | yes | yes |
| POST | `/api/v1/public/{token}/tick` | Public tick | public | yes | yes |
| POST | `/api/v1/quick-add/parse` | Quick add parse | signed-in | yes | yes |
| GET | `/api/v1/reminders` | List reminders | signed-in | yes | yes |
| POST | `/api/v1/reminders` | Create a reminder | signed-in | yes | yes |
| DELETE | `/api/v1/reminders/{id}` | Delete a reminder | signed-in | yes | yes |
| GET | `/api/v1/reminders/{id}` | Get a reminder | signed-in | yes | yes |
| PATCH | `/api/v1/reminders/{id}` | Update a reminder | signed-in | yes | yes |
| GET | `/api/v1/sections` | List sections | signed-in | yes | yes |
| POST | `/api/v1/sections` | Create a section | signed-in | yes | yes |
| GET | `/api/v1/sections/{id}` | Get a section | signed-in | yes | yes |
| PATCH | `/api/v1/sections/{id}` | Update a section | signed-in | yes | yes |
| POST | `/api/v1/sync` | Sync | signed-in | yes | yes |
| GET | `/api/v1/sync/events` | List sync events | signed-in | yes | yes |
| GET | `/api/v1/task-pages` | List task pages | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/tasks` | List tasks | signed-in | yes | yes |
| POST | `/api/v1/tasks` | Create a task | signed-in | yes | yes |
| DELETE | `/api/v1/tasks/{id}` | Delete a task | signed-in | yes | yes |
| GET | `/api/v1/tasks/{id}` | Get a task | signed-in | yes | yes |
| PATCH | `/api/v1/tasks/{id}` | Update a task | signed-in | yes | yes |
| GET | `/api/v1/tasks/{id}/activity` | Get task activity | signed-in | yes | yes |
| GET | `/api/v1/tasks/{id}/comments` | List task comments | signed-in | yes | yes |
| POST | `/api/v1/tasks/{id}/comments` | Create a task comment | signed-in | yes | yes |
| GET | `/api/v1/tasks/{id}/history` | Get task history | signed-in | yes | yes |
| POST | `/api/v1/tasks/{id}/note/append` | Task note append | signed-in | yes | yes |
| GET | `/api/v1/tasks/{id}/occurrences` | List task occurrences | signed-in | yes | yes |
| PATCH | `/api/v1/tasks/{id}/occurrences/{date}` | Update a task occurrence | signed-in | yes | yes |
| POST | `/api/v1/tasks/{id}/occurrences/{date}/complete` | Task occurrence complete | signed-in | yes | yes |
| POST | `/api/v1/tasks/{id}/occurrences/{date}/skip` | Task occurrence skip | signed-in | yes | yes |
| DELETE | `/api/v1/tasks/{id}/page` | Delete task page | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/tasks/{id}/page` | Get task page | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/tasks/{id}/page` | Task page | signed-in.full-tokens.recent | yes | yes |
| GET | `/api/v1/tasks/{id}/page/replies` | List task page replies | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/tasks/{id}/page/replies/{replyId}` | Delete a task page reply | signed-in.full-tokens | yes | yes |
| PUT | `/api/v1/tasks/{id}/page/snapshot` | Update task page snapshot | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/tasks/{id}/purge` | Delete task purge | signed-in | yes | yes |
| POST | `/api/v1/tasks/{id}/split` | Task split | signed-in | yes | yes |
| GET | `/api/v1/tasks/{id}/time-entries` | List task time entries | signed-in | yes | yes |
| GET | `/api/v1/time-entries` | List time entries | signed-in | yes | yes |
| POST | `/api/v1/time-entries` | Create a time entry | signed-in | yes | yes |
| GET | `/api/v1/time-entries/running` | Get time entries running | signed-in | yes | yes |
| POST | `/api/v1/time-entries/stop` | Time entries stop | signed-in | yes | yes |
| DELETE | `/api/v1/time-entries/{id}` | Delete a time entry | signed-in | yes | yes |
| PATCH | `/api/v1/time-entries/{id}` | Update a time entry | signed-in | yes | yes |
| POST | `/api/v1/trash/purge` | Trash purge | signed-in | yes | yes |
| GET | `/api/v1/views` | List views | signed-in | yes | yes |
| POST | `/api/v1/views` | Create a view | signed-in | yes | yes |
| DELETE | `/api/v1/views/{id}` | Delete a view | signed-in | yes | yes |
| GET | `/api/v1/views/{id}` | Get a view | signed-in | yes | yes |
| PATCH | `/api/v1/views/{id}` | Update a view | signed-in | yes | yes |

### Administration (owner and admins) (39)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/audit` | Get audit | owner-only | yes | yes |
| GET | `/api/v1/audit/export` | Get audit export | owner-only | yes | yes |
| GET | `/api/v1/audit/verify` | Get audit verify | owner-only | yes | yes |
| GET | `/api/v1/backups` | List backups | owner-only | yes | yes |
| GET | `/api/v1/backups/archives` | List backups archives | owner-only | yes | yes |
| GET | `/api/v1/backups/restore` | Get backups restore | owner-only | yes | yes |
| POST | `/api/v1/backups/restore` | Backups restore | owner-only.session-only.recent | no | yes |
| POST | `/api/v1/backups/restore/prepare` | Backups restore prepare | owner-only | yes | yes |
| DELETE | `/api/v1/backups/restore/safety-copies/{name}` | Delete a backups restore safety copy | owner-only.session-only.recent | no | yes |
| POST | `/api/v1/backups/restore/uploads` | Create a backups restore upload | owner-only | yes | yes |
| DELETE | `/api/v1/backups/restore/{id}` | Delete a backups restore | owner-only | yes | yes |
| POST | `/api/v1/backups/run` | Backups run | owner-only | yes | yes |
| GET | `/api/v1/backups/settings` | List backups settings | owner-only | yes | yes |
| PUT | `/api/v1/backups/settings` | Update backups settings | owner-only.credential | no | yes |
| POST | `/api/v1/backups/test` | Backups test | owner-only | yes | yes |
| GET | `/api/v1/invitations` | List invitations | admins-only | yes | yes |
| POST | `/api/v1/invitations` | Create a invitation | admins-only.credential.recent | no | yes |
| DELETE | `/api/v1/invitations/{id}` | Delete a invitation | admins-only.credential | no | yes |
| POST | `/api/v1/members/{id}/mfa/reset` | Member mfa reset | owner-only.credential.recent | no | yes |
| GET | `/api/v1/settings/audit` | Get settings audit | owner-only | yes | yes |
| PUT | `/api/v1/settings/audit` | Update settings audit | owner-only.credential | no | yes |
| GET | `/api/v1/settings/mfa` | Get settings mfa | owner-only | yes | yes |
| PUT | `/api/v1/settings/mfa` | Update settings mfa | owner-only.credential.recent | no | yes |
| GET | `/api/v1/settings/oidc` | Get settings oidc | owner-only | yes | yes |
| PUT | `/api/v1/settings/oidc` | Update settings oidc | owner-only.credential.recent | no | yes |
| POST | `/api/v1/settings/oidc/test` | Settings oidc test | owner-only | yes | yes |
| GET | `/api/v1/settings/smtp` | Get settings smtp | owner-only.credential | no | yes |
| PUT | `/api/v1/settings/smtp` | Update settings smtp | owner-only.credential.recent | no | yes |
| POST | `/api/v1/settings/smtp/test` | Settings smtp test | owner-only | yes | yes |
| GET | `/api/v1/settings/storage` | Get settings storage | owner-only | yes | yes |
| GET | `/api/v1/settings/webhooks` | List settings webhooks | owner-only | yes | yes |
| PUT | `/api/v1/settings/webhooks` | Update settings webhooks | owner-only.credential | no | yes |
| GET | `/api/v1/users` | List users | admins-only | yes | yes |
| DELETE | `/api/v1/users/{id}` | Delete a user | admins-only.credential.recent | no | yes |
| POST | `/api/v1/users/{id}/deactivate` | User deactivate | admins-only.credential.recent | no | yes |
| POST | `/api/v1/users/{id}/password-reset` | User password reset | admins-only.credential.recent | no | yes |
| POST | `/api/v1/users/{id}/reactivate` | User reactivate | admins-only.credential.recent | no | yes |
| PUT | `/api/v1/users/{id}/role` | Update user role | admins-only.credential.recent | no | yes |
| POST | `/api/v1/users/{id}/transfer-ownership` | User transfer ownership | admins-only.credential.recent | no | yes |

### Your account and credentials (34)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| DELETE | `/api/v1/encryption/keys` | Delete encryption keys | signed-in.credential.recent | no | yes |
| GET | `/api/v1/encryption/keys` | List encryption keys | signed-in | yes | yes |
| PUT | `/api/v1/encryption/keys` | Update encryption keys | signed-in.credential | no | yes |
| POST | `/api/v1/encryption/purge-history` | Encryption purge history | signed-in | yes | yes |
| GET | `/api/v1/me` | Get me | signed-in | yes | yes |
| GET | `/api/v1/me/activity` | Get me activity | signed-in | yes | yes |
| GET | `/api/v1/me/email-digest` | Get me email digest | signed-in.full-tokens | yes | yes |
| PUT | `/api/v1/me/email-digest` | Update me email digest | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/me/identities` | List me identities | signed-in | yes | yes |
| DELETE | `/api/v1/me/identities/{id}` | Delete a me identity | signed-in.credential | no | yes |
| POST | `/api/v1/me/password` | Me password | signed-in.credential.recent | no | yes |
| POST | `/api/v1/me/sign-out-everywhere` | Me sign out everywhere | signed-in.session-only.recent | no | yes |
| GET | `/api/v1/mfa` | Get mfa | signed-in | yes | yes |
| POST | `/api/v1/mfa/recovery-codes/regenerate` | Mfa recovery codes regenerate | signed-in.credential.recent | no | yes |
| DELETE | `/api/v1/mfa/totp` | Delete mfa totp | signed-in.credential.recent | no | yes |
| POST | `/api/v1/mfa/totp/confirm` | Mfa totp confirm | signed-in.credential.recent | no | yes |
| POST | `/api/v1/mfa/totp/enroll` | Mfa totp enroll | signed-in.credential.recent | no | yes |
| DELETE | `/api/v1/mfa/trusted-devices` | Delete mfa trusted devices | signed-in | yes | yes |
| GET | `/api/v1/mfa/trusted-devices` | List mfa trusted devices | signed-in | yes | yes |
| DELETE | `/api/v1/mfa/trusted-devices/{id}` | Delete a mfa trusted device | signed-in | yes | yes |
| GET | `/api/v1/notifications` | List notifications | signed-in | yes | yes |
| POST | `/api/v1/notifications/{id}/read` | Notification read | signed-in | yes | yes |
| GET | `/api/v1/passkeys` | List passkeys | signed-in | yes | yes |
| POST | `/api/v1/passkeys/register` | Passkeys register | signed-in.credential.recent | no | yes |
| POST | `/api/v1/passkeys/register/options` | Create a passkeys register option | signed-in.credential.recent | no | yes |
| DELETE | `/api/v1/passkeys/{id}` | Delete a passkey | signed-in.credential | no | yes |
| PATCH | `/api/v1/passkeys/{id}` | Update a passkey | signed-in.credential | no | yes |
| POST | `/api/v1/push/subscriptions` | Create a push subscription | signed-in | yes | yes |
| DELETE | `/api/v1/push/subscriptions/{id}` | Delete a push subscription | signed-in | yes | yes |
| POST | `/api/v1/push/test` | Push test | signed-in | yes | yes |
| GET | `/api/v1/push/vapid-key` | Get push vapid key | signed-in | yes | yes |
| GET | `/api/v1/tokens` | List tokens | signed-in | yes | yes |
| POST | `/api/v1/tokens` | Create a token | signed-in.credential.recent | no | yes |
| DELETE | `/api/v1/tokens/{id}` | Delete a token | signed-in | yes | yes |

### Workspaces (26)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| POST | `/api/v1/projects/{id}/grants` | Create a project grant | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/projects/{id}/grants/{groupId}` | Delete a project grant | signed-in.full-tokens | yes | yes |
| PATCH | `/api/v1/projects/{id}/grants/{groupId}` | Update a project grant | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/workspace-invites/{token}` | Get a workspace invite | public | yes | yes |
| POST | `/api/v1/workspace-invites/{token}/accept` | Workspace invite accept | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/workspaces` | List workspaces | signed-in | yes | yes |
| POST | `/api/v1/workspaces` | Create a workspace | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/workspaces/{id}` | Delete a workspace | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/workspaces/{id}` | Get a workspace | signed-in | yes | yes |
| PATCH | `/api/v1/workspaces/{id}` | Update a workspace | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/workspaces/{id}/groups` | List workspace groups | signed-in | yes | yes |
| POST | `/api/v1/workspaces/{id}/groups` | Create a workspace group | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/workspaces/{id}/groups/{groupId}` | Delete a workspace group | signed-in.full-tokens | yes | yes |
| PATCH | `/api/v1/workspaces/{id}/groups/{groupId}` | Update a workspace group | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/workspaces/{id}/groups/{groupId}/members/{userId}` | Delete a workspace group member | signed-in.full-tokens | yes | yes |
| PUT | `/api/v1/workspaces/{id}/groups/{groupId}/members/{userId}` | Replace a workspace group member | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/workspaces/{id}/invites` | List workspace invites | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/workspaces/{id}/invites` | Create a workspace invite | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/workspaces/{id}/invites/{inviteId}` | Delete a workspace invite | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/workspaces/{id}/leave` | Workspace leave | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/workspaces/{id}/member-invitations/{invitationId}` | Delete a workspace member invitation | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/workspaces/{id}/members` | List workspace members | signed-in | yes | yes |
| POST | `/api/v1/workspaces/{id}/members` | Create a workspace member | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/workspaces/{id}/members/{userId}` | Delete a workspace member | signed-in.full-tokens | yes | yes |
| PATCH | `/api/v1/workspaces/{id}/members/{userId}` | Update a workspace member | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/workspaces/{id}/transfer` | Workspace transfer | signed-in.full-tokens | yes | yes |

### Health and authentication (17)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| POST | `/api/v1/auth/login` | Auth login | public | yes | yes |
| POST | `/api/v1/auth/logout` | Auth logout | public | yes | yes |
| POST | `/api/v1/auth/mfa` | Auth mfa | public | yes | yes |
| GET | `/api/v1/auth/oidc/callback` | Get auth oidc callback | public | yes | yes |
| GET | `/api/v1/auth/oidc/start` | Get auth oidc start | public | yes | yes |
| POST | `/api/v1/auth/passkey` | Auth passkey | public | yes | yes |
| POST | `/api/v1/auth/passkey/options` | Create a auth passkey option | public | yes | yes |
| POST | `/api/v1/auth/password-reset` | Auth password reset | public | yes | yes |
| POST | `/api/v1/auth/reauth` | Auth reauth | signed-in | yes | yes |
| POST | `/api/v1/auth/register` | Auth register | public | yes | yes |
| GET | `/api/v1/auth/status` | List auth status | public | yes | yes |
| GET | `/api/v1/auth/verify/{token}` | Get a auth verify | public | yes | yes |
| POST | `/api/v1/auth/verify/{token}` | Auth verify | public | yes | yes |
| GET | `/api/v1/health` | Get health | public | yes | yes |
| GET | `/api/v1/password-resets/{token}` | Get a password reset | public | yes | yes |
| POST | `/api/v1/password-resets/{token}` | Password reset | public | yes | yes |
| GET | `/api/v1/project-invites/{token}` | Get a project invite | public | yes | yes |

### Integrations (15)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/app-passwords` | List app passwords | signed-in | yes | yes |
| POST | `/api/v1/app-passwords` | Create a app password | signed-in.credential.recent | no | yes |
| DELETE | `/api/v1/app-passwords/{id}` | Delete a app password | signed-in | yes | yes |
| PATCH | `/api/v1/app-passwords/{id}` | Update a app password | signed-in.credential.recent | no | yes |
| GET | `/api/v1/email-inbox` | Get email inbox | signed-in.full-tokens | yes | yes |
| PATCH | `/api/v1/email-inbox` | Update email inbox | signed-in.full-tokens | yes | yes |
| POST | `/api/v1/email-inbox/rotate` | Email inbox rotate | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/webhooks` | List webhooks | signed-in | yes | yes |
| POST | `/api/v1/webhooks` | Create a webhook | signed-in | yes | yes |
| DELETE | `/api/v1/webhooks/{id}` | Delete a webhook | signed-in | yes | yes |
| GET | `/api/v1/webhooks/{id}` | Get a webhook | signed-in | yes | yes |
| PATCH | `/api/v1/webhooks/{id}` | Update a webhook | signed-in | yes | yes |
| GET | `/api/v1/webhooks/{id}/deliveries` | List webhook deliveries | signed-in | yes | yes |
| POST | `/api/v1/webhooks/{id}/deliveries/{did}/redeliver` | Webhook delivery redeliver | signed-in | yes | yes |
| POST | `/api/v1/webhooks/{id}/test` | Webhook test | signed-in | yes | yes |

### Other routes (not in the OpenAPI description) (14)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/.well-known/oauth-authorization-server` |  | public("MCPclientsreadtheauthorizationserver'smetadatabeforetheyholdacredential") | no | yes |
| GET | `/.well-known/oauth-protected-resource` |  | public("MCPclientsdiscovertheauthorizationserverbeforetheyholdacredential") | no | yes |
| GET | `/.well-known/security.txt` |  | public("RFC9116:securityresearchersfindwheretoreportvulnerabilitiesinthesoftwarethisserverruns") | yes | yes |
| GET | `/api/v1/invitations/{token}` |  | public("theinviteepreviewstheinvitationbeforehavinganaccount") | yes | yes |
| GET | `/app/sign-in` |  | signedIn.SessionOnly().SignInFirst().DemoDenied() | yes | yes |
| GET | `/branding/{file}` |  | public("theinstancelogo,partofthepageliketheapp'sicons") | yes | yes |
| GET | `/feeds/{secret}/tasks.ics` |  | public("calendarappsauthenticatewiththesecretintheaddress").DemoDenied() | yes | yes |
| GET | `/healthz` |  | public("healthcheckforthecontainerandloadbalancers") | yes | yes |
| GET | `/n/` |  | public("anotepage;itsdatacomesfromthetaskpageAPI") | yes | yes |
| GET | `/public/` |  | public("apubliclistpage;itsdatacomesfromthepublic-linkAPI") | yes | yes |
| POST | `/share` |  | public("thesharesheetpostsherebeforetheserviceworkerruns;itonlyredirectsintotheapp") | yes | yes |
| GET | `/t/` |  | public("ataskpage;itsdatacomesfromthetaskpageAPI") | yes | yes |
| OPTIONS | `/{$}` |  | httpx.Public("CalDAVdiscoveryfromthehostroot;reportstheDAVcapabilities").DemoDenied() | yes | yes |
| PROPFIND | `/{$}` |  | httpx.Public("CalDAVdiscoveryfromthehostroot;redirectsto/dav/").DemoDenied() | yes | yes |

### Calendar sync (13)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/calendar-sync/connections` | List calendar sync connections | signed-in | yes | yes |
| POST | `/api/v1/calendar-sync/connections` | Create a calendar sync connection | signed-in.recent | yes | yes |
| DELETE | `/api/v1/calendar-sync/connections/{id}` | Delete a calendar sync connection | signed-in | yes | yes |
| PATCH | `/api/v1/calendar-sync/connections/{id}` | Update a calendar sync connection | signed-in | yes | yes |
| POST | `/api/v1/calendar-sync/connections/{id}/sync` | Calendar sync connection sync | signed-in | yes | yes |
| GET | `/api/v1/calendar-sync/google/callback` | Get calendar sync google callback | signed-in.session-only | no | yes |
| POST | `/api/v1/calendar-sync/google/start` | Calendar sync google start | signed-in.recent | yes | yes |
| GET | `/api/v1/calendar-sync/microsoft/callback` | Get calendar sync microsoft callback | signed-in.session-only | no | yes |
| POST | `/api/v1/calendar-sync/microsoft/start` | Calendar sync microsoft start | signed-in.recent | yes | yes |
| GET | `/api/v1/settings/calendar-sync/google` | Get settings calendar sync google | owner-only | yes | yes |
| PUT | `/api/v1/settings/calendar-sync/google` | Update settings calendar sync google | owner-only.credential | no | yes |
| GET | `/api/v1/settings/calendar-sync/microsoft` | Get settings calendar sync microsoft | owner-only | yes | yes |
| PUT | `/api/v1/settings/calendar-sync/microsoft` | Update settings calendar sync microsoft | owner-only.credential | no | yes |

### Attachments (10)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| DELETE | `/api/v1/attachments/{id}` | Delete a attachment | signed-in | yes | yes |
| PATCH | `/api/v1/attachments/{id}` | Update a attachment | signed-in | yes | yes |
| GET | `/api/v1/attachments/{id}/content` | Get attachment content | signed-in | yes | yes |
| PUT | `/api/v1/attachments/{id}/content` | Update attachment content | signed-in | yes | yes |
| GET | `/api/v1/notes/{id}/attachments` | List note attachments | signed-in | yes | yes |
| POST | `/api/v1/notes/{id}/attachments` | Create a note attachment | signed-in | yes | yes |
| GET | `/api/v1/settings/attachments` | List settings attachments | signed-in | yes | yes |
| PUT | `/api/v1/settings/attachments` | Update settings attachments | owner-only | yes | yes |
| GET | `/api/v1/tasks/{id}/attachments` | List task attachments | signed-in | yes | yes |
| POST | `/api/v1/tasks/{id}/attachments` | Create a task attachment | signed-in | yes | yes |

### Automation rules (9)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/me/rules` | List me rules | signed-in | yes | yes |
| PUT | `/api/v1/me/rules/paused` | Update me rules paused | signed-in | yes | yes |
| GET | `/api/v1/rules` | List rules | signed-in | yes | yes |
| POST | `/api/v1/rules` | Create a rule | signed-in | yes | yes |
| DELETE | `/api/v1/rules/{id}` | Delete a rule | signed-in | yes | yes |
| GET | `/api/v1/rules/{id}` | Get a rule | signed-in | yes | yes |
| PATCH | `/api/v1/rules/{id}` | Update a rule | signed-in | yes | yes |
| GET | `/api/v1/rules/{id}/runs` | List rule runs | signed-in | yes | yes |
| POST | `/api/v1/rules/{id}/test` | Rule test | signed-in | yes | yes |

### Calendar feeds (9)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/calendar-feeds/events` | List calendar feeds events | signed-in | yes | yes |
| DELETE | `/api/v1/calendar-feeds/feed` | Delete calendar feeds feed | signed-in | yes | yes |
| GET | `/api/v1/calendar-feeds/feed` | Get calendar feeds feed | signed-in | yes | yes |
| POST | `/api/v1/calendar-feeds/feed` | Calendar feeds feed | signed-in.recent | yes | yes |
| GET | `/api/v1/calendar-feeds/subscriptions` | List calendar feeds subscriptions | signed-in | yes | yes |
| POST | `/api/v1/calendar-feeds/subscriptions` | Create a calendar feeds subscription | signed-in | yes | yes |
| DELETE | `/api/v1/calendar-feeds/subscriptions/{id}` | Delete a calendar feeds subscription | signed-in | yes | yes |
| PATCH | `/api/v1/calendar-feeds/subscriptions/{id}` | Update a calendar feeds subscription | signed-in | yes | yes |
| POST | `/api/v1/calendar-feeds/subscriptions/{id}/refresh` | Calendar feeds subscription refresh | signed-in | yes | yes |

### Maps (9)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/maps/fonts/{fontstack}/{range}` | Get a maps font | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/maps/reverse` | Get maps reverse | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/maps/search` | Get maps search | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/maps/sprites/{file}` | Get a maps sprite | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/maps/style` | Get maps style | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/maps/tiles/{z}/{x}/{y}` | Get a maps tile | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/pages/{secret}/maps/style` | Get page maps style | public | yes | yes |
| GET | `/api/v1/settings/maps` | List settings maps | owner-only | yes | yes |
| PUT | `/api/v1/settings/maps` | Update settings maps | owner-only.credential | no | yes |

### Profile (8)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| DELETE | `/api/v1/me/avatar` | Delete me avatar | signed-in.full-tokens | yes | yes |
| PUT | `/api/v1/me/avatar` | Update me avatar | signed-in.full-tokens | yes | yes |
| DELETE | `/api/v1/me/email` | Delete me email | signed-in.session-only | no | yes |
| POST | `/api/v1/me/email` | Me email | signed-in.session-only.recent | no | yes |
| POST | `/api/v1/me/email/confirm` | Me email confirm | signed-in.session-only | no | yes |
| GET | `/api/v1/me/profile` | Get me profile | signed-in | yes | yes |
| PATCH | `/api/v1/me/profile` | Update me profile | signed-in.full-tokens | yes | yes |
| GET | `/api/v1/users/{id}/avatar` | Get user avatar | signed-in | yes | yes |

### Issue connections (6)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/issues/connections` | List issues connections | signed-in | yes | yes |
| POST | `/api/v1/issues/connections` | Create a issues connection | signed-in.recent | yes | yes |
| DELETE | `/api/v1/issues/connections/{id}` | Delete a issues connection | signed-in | yes | yes |
| PATCH | `/api/v1/issues/connections/{id}` | Update a issues connection | signed-in | yes | yes |
| POST | `/api/v1/issues/connections/{id}/sync` | Issues connection sync | signed-in | yes | yes |
| POST | `/api/v1/issues/connections/{id}/test` | Issues connection test | signed-in | yes | yes |

### Notification channels (6)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/notification-channels` | List notification channels | signed-in | yes | yes |
| POST | `/api/v1/notification-channels` | Create a notification channel | signed-in | yes | yes |
| DELETE | `/api/v1/notification-channels/{id}` | Delete a notification channel | signed-in | yes | yes |
| PATCH | `/api/v1/notification-channels/{id}` | Update a notification channel | signed-in | yes | yes |
| GET | `/api/v1/notification-channels/{id}/deliveries` | List notification channel deliveries | signed-in | yes | yes |
| POST | `/api/v1/notification-channels/{id}/test` | Notification channel test | signed-in | yes | yes |

### App sign-in (5)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| POST | `/api/v1/app/sign-out` | App sign out | signed-in | yes | yes |
| POST | `/api/v1/app/token` | App token | public | yes | yes |
| POST | `/api/v1/me/app-sign-in` | Me app sign in | signed-in.session-only | no | yes |
| GET | `/api/v1/me/apps` | List me apps | signed-in | yes | yes |
| DELETE | `/api/v1/me/apps/{id}` | Delete a me app | signed-in | yes | yes |

### Calendar frames (5)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/frames` | List frames | signed-in | yes | yes |
| POST | `/api/v1/frames` | Create a frame | signed-in | yes | yes |
| DELETE | `/api/v1/frames/{id}` | Delete a frame | signed-in | yes | yes |
| GET | `/api/v1/frames/{id}` | Get a frame | signed-in | yes | yes |
| PATCH | `/api/v1/frames/{id}` | Update a frame | signed-in | yes | yes |

### Calendar slots (5)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/slots` | List slots | signed-in | yes | yes |
| POST | `/api/v1/slots` | Create a slot | signed-in | yes | yes |
| DELETE | `/api/v1/slots/{id}` | Delete a slot | signed-in | yes | yes |
| GET | `/api/v1/slots/{id}` | Get a slot | signed-in | yes | yes |
| PATCH | `/api/v1/slots/{id}` | Update a slot | signed-in | yes | yes |

### Instance branding (4)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/settings/branding` | Get settings branding | owner-only | yes | yes |
| PUT | `/api/v1/settings/branding` | Update settings branding | owner-only | yes | yes |
| DELETE | `/api/v1/settings/branding/logo` | Delete settings branding logo | owner-only | yes | yes |
| PUT | `/api/v1/settings/branding/logo` | Update settings branding logo | owner-only | yes | yes |

### Server themes (4)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| PUT | `/api/v1/settings/themes/default` | Update settings themes default | owner-only | yes | yes |
| DELETE | `/api/v1/settings/themes/instance/{id}` | Delete a settings themes instance | owner-only | yes | yes |
| PUT | `/api/v1/settings/themes/instance/{id}` | Replace a settings themes instance | owner-only | yes | yes |
| GET | `/api/v1/themes/instance` | Get themes instance | signed-in | yes | yes |

### Speech to text (4)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| GET | `/api/v1/settings/stt` | Get settings stt | owner-only.credential | no | yes |
| PUT | `/api/v1/settings/stt` | Update settings stt | owner-only.credential | no | yes |
| POST | `/api/v1/settings/stt/test` | Settings stt test | owner-only.credential | no | yes |
| POST | `/api/v1/voice/transcribe` | Voice transcribe | signed-in.full-tokens | yes | yes |

### Sections (1)

| Method | Path | Summary | Policy | Token? | Confirmed |
| --- | --- | --- | --- | --- | --- |
| DELETE | `/api/v1/sections/{id}` | Delete a section | signed-in | yes | yes |

## Excluded: the AI surface

50 operations were removed on purpose:
- `/.well-known/oauth-protected-resource/mcp`
- `/api/v1/assistant/skills`
- `/api/v1/assistant/turn`
- `/api/v1/me/agent-access`
- `/api/v1/me/assistant`
- `/api/v1/me/assistant/disclosure-seen`
- `/api/v1/me/assistant/test`
- `/api/v1/me/assistant/usage`
- `/api/v1/me/mcp-consent`
- `/api/v1/me/rules/catalogue`
- `/api/v1/me/rules/proposals`
- `/api/v1/me/rules/proposals/{id}`
- `/api/v1/me/rules/proposals/{id}/apply`
- `/api/v1/me/rules/runs`
- `/api/v1/me/rules/runs/{run}/commit`
- `/api/v1/me/rules/runs/{run}/fail`
- `/api/v1/projects/{id}/agent-access`
- `/api/v1/relay/answers/{id}`
- `/api/v1/relay/devices`
- `/api/v1/relay/devices/{device}`
- `/api/v1/relay/devices/{device}/routines`
- `/api/v1/relay/events`
- `/api/v1/routine-emails/{token}`
- `/api/v1/routine-emails/{token}/stop`
- `/api/v1/rules/test`
- `/api/v1/rules/{id}/ai-usage`
- `/api/v1/rules/{id}/run`
- `/api/v1/rules/{id}/runs/{run}`
- `/api/v1/rules/{id}/runs/{run}/dismiss`
- `/api/v1/rules/{id}/runs/{run}/undo`
- `/api/v1/settings/assistant`
- `/api/v1/settings/assistant/test`
- `/api/v1/settings/mcp`
- `/api/v1/settings/mcp/clients`
- `/api/v1/settings/mcp/clients/{id}`
- `/oauth/authorize`
- `/oauth/register`
- `/oauth/revoke`
- `/oauth/token`
- `/routine-emails/`
