# OTDA vs the server: parity report

Measured against code, not documentation.

- **Server**: `internal/httpapi`, counting every `mux.handle("METHOD /api/v1/…")` in
  non-test files — **344 routes** across 40 areas.
- **App**: every `client.get/post/put/delete` in `lib/src`, plus the entities its op
  log can read and write (`lib/src/data/models.dart`, `repo.dart`).

The app is sync-first: almost everything travels as field operations through
`POST /api/v1/sync`, so a missing REST route is not automatically a missing feature.
The comparison below is by *feature*, then by the route area it belongs to.

---

## 1. What the app actually speaks

| Call | Used for |
|---|---|
| `GET /health` | server version and capabilities |
| `POST /auth/login`, `/auth/mfa`, `/auth/reauth`, `/auth/logout` | sign-in, second factor, step-up, sign-out |
| `GET /me`, `GET /me/avatar`, `GET /users/{id}/avatar` | profile and picture |
| `POST /sync`, `GET /sync/events` | the whole data model, live changes |
| `GET/PUT /encryption/keys` | end-to-end encryption key record |
| 13 admin paths (`/users`, `/invitations`, `/audit`, `/backups`, `/settings/storage`, …) | the Settings → Server tab |

That is **25 of 344 routes**. The rest of the app's data goes through the op log.

### Entities the app can handle

| Entity | Read | Write |
|---|---|---|
| `task` | yes, full row | title, description, due (date+time), recurrence, priority, project, completion, deletion, parent (read) |
| `project` | yes | name, colour, icon, archive flag (read), delete |
| `label` | yes | name (via `ensureLabel` only) |
| `workspace` | yes (filtering) | no |
| `preferences` | yes | priority names only |

Everything else the server stores — comments, attachments, notes, time entries,
custom fields, sections, saved views, objectives, routines, frames, slots, locations,
review, memory — is **invisible to the app**: it is synced into the replica as raw
fields and never surfaced, edited, or even validated. `lib/src/e2ee/fields.dart` is
the only file in the app that names most of them, and only to encrypt them.

---

## 2. Fully implemented

| Area | Notes |
|---|---|
| Offline-first sync | op log, cursor, SSE stream, background timer, reseed after a restore, conflict resolution by (timestamp, device) |
| Recurring tasks | series model ported from the web client: occurrence records, budgets, skips, three delete scopes, History view |
| Tasks (core) | create, edit, complete, undo, delete, snooze, priority, project, description, due date and time |
| Built-in views | Inbox, Today (with Done today), Upcoming, Anytime, Someday, History, Search, project lists |
| Calendar | **month grid only**, from recurrence projection |
| Reminders | local notifications with action buttons, exact alarms, boot re-arm, per-task time |
| Widget | Glance widget, project filter, complete from the widget, quick add popup |
| Auth | password, TOTP second factor, API token, session cookie, re-auth for step-up, avatar |
| Admin | users, roles, deactivate, invitations, audit log (first 100), backups, storage |
| End-to-end encryption | unlock (passphrase or recovery key), lock, local decrypt, seal/open on sync, key stored in the keystore |

---

## 3. Partial

| Feature | Server | App |
|---|---|---|
| **End-to-end encryption** | full lifecycle (enable, migration, purge, disable, file encryption, fingerprint unlock, device relay) | read side only: unlock, decrypt, encrypt new writes. **Cannot turn it on or off**, cannot re-encrypt old plaintext, cannot encrypt attachments, no biometric unlock, no relay |
| **Subtasks** | full tree, moves, ordering | `parent_id` is read for the Inbox rule and copied to records; no way to create a subtask |
| **Task fields** | deadline, start date, estimate, energy, sections, labels on tasks, assignees | `deadline`/`start`/`sector`/`energy`/`estimate`/`section_id` exist in the model and are used by views, but the editor cannot set them; labels are only auto-created by the parser |
| **Project fields** | notes, sharing, templates, timeline, flow, archived | name, colour, icon, trash |
| **Workspaces** | 21 routes: create, rename, members, groups, invites, leave, transfer | read-only: filter lists by the default workspace |
| **Calendar** | month/week/day/year, feeds, Google/Microsoft sync, CalDAV | month grid from local recurrence only; no external calendar can be shown |
| **Auth** | OIDC, passkeys, MFA enrolment, trusted devices, app passwords, sign-out everywhere | password + TOTP sign-in only; no enrolment, no passkeys, no OIDC, no trusted devices |
| **Admin** | 31 settings areas, webhooks, SMTP, branding, themes, storage, audit verify and export | users, invitations, audit (read), backups, storage figure |
| **Trash** | trash list, per-item restore, purge, `POST /trash/purge` | delete moves things to a tombstone; **no Trash screen**, no restore, no purge |

---

## 4. Missing entirely

Grouped by the server area they belong to (route count in brackets).

### Content that cannot be created or read at all

| Feature | Server routes | State in the app |
|---|---|---|
| Attachments (files, images, links) | `attachments` [4] | nothing; no picker, no download, no upload, and E2EE file encryption is unimplemented |
| Comments | `comments` [3] | nothing |
| Notes: standalone, pages, appends, rich text, links, graph | `notes` [10], `pages` [8], `task-pages` [1] | nothing |
| Time tracking | `time-entries` [6] | nothing |
| Custom fields | `fields` [3] | nothing; definitions are never fetched, values never shown |
| Sections and boards | inside `projects` [20] | nothing |
| Saved views and filters | `views` [3] | nothing; only the built-in views exist |
| Habits | `habits` [3] | nothing |
| Objectives / planner | inside `me` [35] | nothing |
| Routines and their emails | `routine-emails` [2], `rules` [13] | nothing |
| Frames and slots (calendar blocks) | `frames` [5], `slots` [5] | nothing |
| Task locations | `places` [1], `maps` [6] | nothing |

### Collaboration

| Feature | Server routes | State |
|---|---|---|
| Project sharing, members, groups, grants | `projects` [20], `members` [1] | nothing |
| Invitations (project, workspace, member) | `invitations` [4], `project-invites` [2], `workspace-invites` [2] | admin invitations only |
| Workspaces | `workspaces` [21] | read-only filter |
| Public links | `public` [2] | nothing |

### Automation and integration

| Feature | Server routes | State |
|---|---|---|
| Automation rules (conditions, actions, runs, proposals) | `rules` [13] | nothing |
| Webhooks and deliveries | `webhooks` [8] | nothing |
| Issue connections (GitHub/GitLab) | `issues` [6] | nothing |
| Push notifications (VAPID, subscriptions) | `push` [4] | nothing; reminders are local only |
| Notification channels | `notification-channels` [6] | nothing |
| Email capture inbox | `email-inbox` [3] | nothing |
| MCP / assistant / device relay / voice | `assistant` [2], `relay` [7], `voice` [1] | excluded by product decision |
| CalDAV | `settings/caldav` [1] | nothing |

### Data in and out

| Feature | Server routes | State |
|---|---|---|
| Export (zip, pdf) | `export` [2] | nothing |
| Import (incl. Todoist, preview, undo) | `import` [6] | nothing |
| Backup restore | `backups` [12] | run a backup and list archives; **no restore** |
| Trash purge | `trash` [1] | nothing |
| Activity feed | `activity` [1] | nothing |
| Statistics | inside `me` | nothing |

### Platform niceties

Themes and theme editor, instance branding, demo mode, app sign-in (`app-passwords`,
`tokens`, `me/apps`), localization, command palette, keyboard shortcuts, bulk actions,
multi-day tasks, task dependencies, assignment, urgency score, day parts, focus mode,
weekly review, templates, project-flow views, list/row layout options.

---

## 5. The gaps that matter most for a phone app

Ranked by what a user would notice within a day of real use:

1. **Attachments** — no way to add or open a file or a photo from a task.
2. **Trash** — deleting is a one-way door; nothing can be restored.
3. **Calendar beyond a month grid** — no week/day view, no external calendars.
4. **Comments and notes** — collaboration and long-form text are not reachable.
5. **Task metadata** — deadline, start date, estimate, energy, section, labels are
   editable on the server and in the web app, but not here.
6. **Time tracking** — absent.
7. **Push notifications** — reminders only fire from the device that scheduled them.
8. **Sharing** — a project cannot be shared, so the app is single-user in practice.
9. **E2EE lifecycle** — unlock works; enabling, disabling and files do not.
10. **Saved views / custom fields** — the app shows only what the server's built-in
    views show.

## 6. Honest summary

- **Data plane**: strong. The op log, recurring-task model and offline behaviour are
  the parts most likely to be correct, and they are the parts that took the most work.
- **REST plane**: 25 of 344 routes are used. Most of the remainder are features whose
  *data* the app already syncs but never displays — so the cost of adding them is UI
  and validation, not protocol.
- **Feature plane**: of roughly 130 shipped server specs, the app covers the core
  task/project/label/reminder/widget surface and none of the collaboration, content
  (files, notes, comments) or integration areas.
