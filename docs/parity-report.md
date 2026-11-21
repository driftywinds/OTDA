# OTDA vs the server: parity report

Measured against code, not documentation.

- **Server**: `internal/httpapi` in the v1.5.0 research copy, counting every
  `mux.handle("METHOD /api/v1/…")` in non-test files — **344 route registrations**
  across 40 areas.
- **App**: every `ApiClient` call in `lib/src`, plus the entities its op log can read
  and write (`lib/src/data/models.dart`, `repo.dart`).

The app is sync-first: most data travels as field operations through
`POST /api/v1/sync`, so a missing REST route is not automatically a missing feature.
The comparison below is by *feature*, then by the route area it belongs to.

---

## 1. What the app actually speaks

| Call | Used for |
|---|---|
| `GET /health`, `GET /healthz` | server version and capabilities |
| `POST /auth/login`, `/auth/mfa`, `/auth/reauth`, `/auth/logout` | sign-in, second factor, step-up, sign-out |
| `GET /me`, `GET /users/{id}/avatar` | profile and picture |
| `GET/POST /mfa`, `/mfa/totp/*`, `/mfa/recovery-codes/*`, `/mfa/trusted-devices/*` | read, enrol, confirm, disable, regenerate, forget browsers |
| `POST /sync`, `GET /sync/events` | the whole data model, live changes |
| `GET/PUT /encryption/keys` | end-to-end encryption key record |
| `GET /export?format=json\|zip` | account export |
| `GET /activity`, `/tasks/{id}/activity`, `/tasks/{id}/history` | activity feed and per-task history |
| `DELETE /tasks/{id}/purge`, `/projects/{id}/purge`, `POST /trash/purge` | Trash purge and empty |
| `GET /themes/instance` | instance theme as the default palette |
| `POST/PATCH /workspaces`, `POST /workspaces/{id}/leave`, `/transfer` | create, rename, leave and transfer a workspace |
| `GET/POST /projects/{id}/members`, `PATCH/DELETE …/members/{userId}` | list, add, re-role and remove project members |
| `GET /me/member-invitations`, `/accept`, `/decline`; cancel project/workspace invitations | invitations addressed to me, and revoking a pending one |
| `GET /workspaces/{id}`, `POST …/members` | workspace pending list and inviting a person |
| `GET/POST /projects/{id}/public-links`, `DELETE …/{linkId}`; `GET/POST/DELETE /tasks/{id}/page` | project public links and task pages |
| 13 admin paths (`/users`, `/invitations`, `/audit`, `/backups`, `/settings/storage`, …) | Settings → Server |

That is **59 route paths of 344**. Everything else the app stores goes through the op log.

### Entities the app can handle

| Entity | Read | Write |
|---|---|---|
| `task` | yes, full row | title, description, due (date+time), deadline, start/Someday, estimate, energy, priority, project, section, labels, parent, position, completion of a subtree, recurrence, deletion and restore |
| `project` | yes | name, colour, icon, delete and restore |
| `label` | yes | create-by-name, and assign/remove on a task |
| `section` | yes, per project | read only (the task's `section_id` is writable) |
| `workspace` | yes: role, owner, members, groups (for filtering) | create, rename, leave, transfer; projects move by `workspace_id` |
| `preferences` | yes | priority names and some device-facing prefs |

Everything else the server stores — comments, attachments, notes, time entries,
custom fields, saved views, objectives, routines, frames, slots, locations, review,
memory — is **synced into the replica as raw fields and never surfaced**. `lib/src/e2ee/fields.dart`
is the only file that names most of them, and only to encrypt them.

---

## 2. Fully implemented

| Area | Notes |
|---|---|
| Offline-first sync | op log, cursor, SSE stream, background timer, reseed after a restore, per-field LWW, one continuous first copy behind the startup gate |
| First-copy gate | the shell waits for a complete pull and an empty outbox; progress from the server head cursor; resume by stored cursor |
| Recurring tasks | series model ported from the web client: occurrence records, budgets, skips, three delete scopes, History view |
| Tasks (core) | create, edit, complete, undo, delete, snooze, priority, project, description, due date and time |
| Task metadata | deadline, start (date or Someday), estimate, energy, section, labels (create/assign), in the same LWW write path |
| Subtasks | create from the row/sheet, indent under the parent, position order, progress over direct children, fold per device, reparent/promote, subtree completion and deletion, project moves carry descendants |
| Trash | tasks and projects, newest first, subtree restore, project restore, task restored to Inbox when its project is still trashed, purge one, empty |
| Workspaces | list/switch/create/rename, members and groups read, move a project between workspaces, leave and transfer ownership |
| Project sharing | members with roles, add by email, change role, remove; shared projects marked, and an encrypted account explains the 409 refusal |
| Invitations | invite to project or workspace, accept/decline, pending list with revoke |
| Public links | project links (view/tick, list/board, expiry) and task pages (view/reply/tick), copied once and revocable |
| E2EE lifecycle | enable with a one-time recovery key, resumable content rewrite (personal scope only), encrypt-on-sight, history purge, disable with re-auth |
| Biometric unlock | fingerprint/face unlocks the account key from the platform keystore; the passphrase remains a fallback |
| Attachments | pick, encrypt personal files (OTAT1), record size/sha256 and upload; open verifies every chunk, images view in-app, other files share; remove tombstones |
| Built-in views | Inbox, Today (with Done today), Upcoming (with a trailing Anytime section), Anytime, Someday, History, Search, project lists |
| Statistics | completions per day/week, by project and label, this-week card, streaks for repeating tasks, all from the replica |
| Activity | shared-project feed with paging; per-task activity and change history, decrypted before display |
| Export | JSON and ZIP, streamed to a temp file with progress/cancel, shared through the system sheet |
| Calendar | **month grid only**, from recurrence projection |
| Reminders | local notifications with action buttons, exact alarms, boot re-arm, per-task time |
| Widget | Glance widget, project filter, complete and refresh from the widget, quick-add popup, Anytime section |
| Auth | password, TOTP second factor, API token, session cookie, re-auth for step-up, avatar; 2FA enrolment, recovery codes and trusted devices |
| Theming | system/light/dark, independent dark/AMOLED, accent swatches, density, row-detail choice, instance-default palette |
| Admin | users, roles, deactivate, invitations, audit log (first 100), backups, storage |

---

## 3. Partial

| Feature | Server | App |
|---|---|---|
| **End-to-end encryption** | full lifecycle (enable, migration, purge, disable, file encryption, fingerprint unlock, device relay) | enable/disable, recovery key, resumable rewrite, encrypt-on-sight, history purge, biometric unlock and file encryption/migration are done; the device relay is absent |
| **Auth** | OIDC, passkeys, app passwords, sign-out everywhere, trusted-device policy | password + TOTP, 2FA management; no passkeys, OIDC or app passwords |
| **Project fields** | notes, sharing, templates, timeline, flow, archived | name, colour, icon, trash |
| **Calendar** | month/week/day/year, feeds, Google/Microsoft sync, CalDAV | month grid from local recurrence only |
| **Admin** | 31 settings areas, webhooks, SMTP, branding, themes, storage, audit verify/export | users, invitations, audit (read), backups, storage figure |

---

## 4. Missing entirely

Grouped by the server area they belong to (route count in brackets).

### Content that cannot be created or read at all

| Feature | Server routes | State in the app |
|---|---|---|
| Attachments (files, images, links) | `attachments` [4] | files are added, encrypted, uploaded, verified/opened, migrated on enable/disable and removed; **link attachments and an in-app PDF renderer are missing** |
| Comments | `comments` [3] | nothing |
| Notes: standalone, pages, appends, rich text, links, graph | `notes` [10], `pages` [8], `task-pages` [1] | nothing |
| Time tracking | `time-entries` [6] | nothing |
| Custom fields | `fields` [3] | nothing |
| Sections and boards | inside `projects` [20] | sections are read only for the task editor; no board UI |
| Saved views and filters | `views` [3] | only the built-in views |
| Habits | `habits` [3] | nothing |
| Objectives / planner | inside `me` [35] | nothing |
| Routines and their emails | `routine-emails` [2], `rules` [13] | nothing |
| Frames and slots (calendar blocks) | `frames` [5], `slots` [5] | nothing |
| Task locations | `places` [1], `maps` [6] | nothing |

### Collaboration

| Feature | Server routes | State |
|---|---|---|
| Project group grants | `projects` [20], `workspaces` [21] | grants are listed read-only; no grant UI |
| Invite links | `project-invites` [2], `workspace-invites` [2], `/invitations/{token}` | nothing; these create an account through a public page |
| Note pages | `notes` [10], `notepages` [4] | no notes feature yet, so note public pages are unreachable |

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
| Import (incl. Todoist, preview, undo) | `import` [6] | nothing |
| Backup restore | `backups` [12] | run a backup and list archives; **no restore** |
| E2EE history purge | `encryption` [5] | nothing |
| Instance theme editing | `settings/themes/*` [3] | the app reads the instance default but cannot edit it |
| `/me/activity` | `me` [35] | not used: this is the security audit log, not task history |

### Platform niceties

Instance branding, demo mode, app sign-in (`app-passwords`, `tokens`, `me/apps`),
localization, command palette, keyboard shortcuts, bulk actions, multi-day tasks,
task dependencies, assignment, urgency score, day parts, focus mode, weekly review,
templates, project-flow views, list/row layout options.

---

## 5. The gaps that matter most for a phone app

Ranked by what a user would notice within a day of real use:

1. **Notes and comments** — long-form notes, comments and note public pages are not
   reachable; note pages are the one public-link shape left out.
2. **Device relay** — an encrypted account's assistant/CLI relay is absent; the app's
   own text, file and biometric lifecycle is complete.
3. **Calendar beyond a month grid** — no week/day view, no external calendars.
4. **Device relay** — text fields, biometric unlock and file migration are covered;
   the relay that lets an assistant decrypt through a device is not.
5. **Time tracking** — absent.
6. **Push notifications** — reminders only fire from the device that scheduled them.
7. **Saved views / custom fields** — the app shows only what the server's built-in
   views show.
8. **Import and backup restore** — export works, bringing data back does not.
9. **Project group grants** — groups are shown on a project, but granting a group is
   still a web-app action.
10. **Token invite pages** — project/workspace invite links and the public signup
    preview create an account, which stays a web flow.

## 6. Honest summary

- **Data plane**: strong. The op log, recurring-task model, batched apply and offline
  behaviour are the parts most likely to be correct, and they are the parts that took
  the most work. A 10,000-task first copy measured 6–9 s on a local server.
- **REST plane**: 59 of 344 route paths are used. Most of the remainder are features
  whose *data* the app already syncs but never displays — so the cost of adding them is
  UI and validation, not protocol.
- **Feature plane**: the personal task/project/label/reminder/widget surface is now
  complete, plus workspace management, project sharing, invitations, public links,
  statistics, activity, history, export, theming, the full E2EE client lifecycle,
  biometric unlock and encrypted attachments. Notes/comments and the device relay
  remain.
