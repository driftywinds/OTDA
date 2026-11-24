# OpenTodo 1.6 and 1.7: what changes for OTDA

Checked on 24 November 2026 against the upstream release notes for
[v1.6.0](https://github.com/OpenTodoApp/OpenTodo/releases/tag/v1.6.0) and
[v1.7.0](https://github.com/OpenTodoApp/OpenTodo/releases/tag/v1.7.0), and the
1.7.0 OpenAPI document that ships with the release.

## Short version

**OTDA does not need a server migration to keep working with 1.6.x or 1.7.x.**
The 1.x compatibility promise still holds: routes, fields and error codes are
added, not removed or changed. The app targets the v1.5.0 route table, and every
route it calls is still present in 1.7.0.

The differences are additive. They give us new things to show or offer; they do
not change the sync, auth or task shapes OTDA already uses.

## What is new upstream

### 1.6.0

- **Away periods** for repeating tasks, including skipped occurrences and a
  single Undo.
- **Calendar Quarter view**, workspace **Activity**, multi-step Undo/Redo.
- **Android Completed widget**.
- **OpenAPI description** at `/api/v1/openapi.json`, a client-building guide and
  optional `OPENTODO_CORS_ORIGINS` for browser clients.
- New synced values: Away periods, links to other apps, Today's manual order,
  daily-notes settings.
- Security: connected AI apps can be disconnected; `GET /api/v1/tokens` and
  `GET /api/v1/me/oauth-grants` now require a full or admin token (read and agent
  tokens get `403 insufficient_scope`).

### 1.7.0

- **System sign-in sheets** on Android/iPhone for providers such as Google; the
  apps check `/api/v1/health` first and fall back to the in-app form.
- **Assignment notifications** (`notify_assigned`, `notify_status`) and a
  **Completed or reopened** push event.
- **Show deadlines as dates** setting, a **`recurring` filter**, copy buttons for
  code blocks, native page transitions, more Undo coverage, haptics.
- iPhone gets a Completed widget and “Use my location”.
- No SQL migration; the server only adds two push-subscription columns.

## Effect on OTDA, by area

### Sync and the local replica

No effect. Sync still uses field-level operations. New task fields
(`flow_mode`, `habit`, `habit_period`, `span`, `sector`, `rotation`, `origin`,
`split_from`, `sample`, …) and new synced preferences are just fields OTDA does
not write or display; the operation log keeps them and sends them back
unchanged. The app does not rewrite whole rows, so connecting a 1.7 account does
not erase values set by a 1.7 client.

The 1.7 “Show deadlines as dates” preference, the 1.6 Away periods and the other
new synced values are ignored by this app. A 1.5 client is expected to ignore
them; it must not claim to support or clear them.

### Auth and admin

No effect on the normal sign-in flow. OTDA signs in with the server's own
email/password form (and its MFA flow); it does not use Google/OIDC, so the new
system sign-in sheet is an upstream mobile-app feature, not a route we call. The
health check at `/api/v1/health` is already the first thing OTDA asks a server,
which is also what 1.7 requires behind a reverse proxy.

The 1.6 token-scope change only affects clients that list tokens with a read or
agent token. OTDA's settings use the signed-in session. An admin screen that
needs `/api/v1/tokens` must still be opened by a session or full/admin token.

### Tasks, recurrence and reminders

OTDA's recurrence grammar already supports the 1.5 form
`every … [after completion] [until … | for N times]`; the new upstream views add
UI around the same data, not a new rule language. Away periods are server-side
exceptions: the app may show a skipped occurrence record as history, but it does
not create or edit Away periods yet.

The 1.7 assignment/status notifications are server push subscriptions. OTDA's
own local reminders are unaffected; it does not register for those push events.

### Widgets

The upstream Android Completed widget is part of the upstream Android app, not a
server feature. OTDA has its own Today widget and does not depend on it. Nothing
in the 1.7 API changes the snapshot fields OTDA writes.

### API surface we rely on

Every static route used by `lib/src` was checked against the 1.7.0 OpenAPI
document: all are present. The only apparent “missing” matches are routes built
with runtime segments (`/invitations/$id`, `/users/$userId/role`, …), not actual
removals. The server's own compatibility document states that within 1.x routes
and fields only grow.

## What we could adopt next

Not required for compatibility, but useful:

- Read and display `habit`/`habit_period` and the `recurring` filter.
- Show deadlines as dates when the synced preference is on.
- Respect Away periods in the Today/Upcoming projections.
- Register for assignment/status push notifications.
- Read `openapi.json` in a CI contract check instead of maintaining a hand-written
  route list.

None of these block using a 1.7 server today.
