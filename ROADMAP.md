# OTDA roadmap

OTDA is a **companion app** for OpenTodo: tasks, on a phone, well. It is not a full
client, so this roadmap contains only the gaps we decided are worth closing. Anything
not listed here is deliberately out of scope for now.

Companion to `docs/parity-report.md`, which records the full diff; this file is the
plan.

Status values: **todo** · **doing** · **done**. Nothing here is started yet.

---

## Milestone 1 — Make the task list trustworthy

The cheapest parity, and the things a user hits in the first week.

### 1.1 Trash

**Why** deleting is currently a one-way door: `Repo.trash()` writes a tombstone and
nothing in the app can list or restore it.

**Scope**
- A Trash view: deleted tasks and projects, newest first, with the day they went.
- Restore one item (`deleted_at = null`), restore a project with its tasks.
- Empty the trash, and purge one item for good.
- Reachable from Settings → Lists and from the sidebar footer.
- Server: `POST /api/v1/trash/purge`, `DELETE /api/v1/trash/task/{id}`, and the
  `deleted`/`include_deleted` query flags; the op log already carries `deleted_at`.

**Notes** restoring must re-emit the field ops so other devices see it, not just clear
the local row.

### 1.2 Task metadata in the editor

**Why** `deadline`, `start`, `estimate_minutes`, `energy`, `section_id` and labels are
already in the model and used by the views, but `lib/src/ui/task_sheet.dart` can only
set title, description, due, recurrence, priority and project.

**Scope**
- Deadline and start date (with the same day picker as due).
- Estimate (minutes) and energy.
- Labels: add, remove, create by name.
- Section picker for the task's project.
- Keep the sheet's "what changed" write path (`Repo.setField`) so partial edits do not
  clobber other fields.

**Notes** the recurring-task record copy (`occurrenceFields`) must carry the new
fields the same way it carries the current ones.

### 1.3 Proper subtasks

**Why** `parent_id` is read by `views.dart` (the Inbox rule) and copied into records,
but nothing can create a subtask, reorder one, or promote it.

**Scope**
- Create a subtask from a task, and from the list (indented row).
- Show children under their parent, with progress (done / total).
- Move a subtask to another parent, promote it to top level, delete it.
- Completing a parent does not complete children silently; the parent's completion
  should ask or leave them open (decide once, document in code).
- Recurrence: a subtask of a recurring task is copied with the record, as today.

**Notes** ordering already exists (`position`) and the server has `manual-ordering`;
reuse it rather than inventing a second order.

---

## Milestone 2 — Sharing and people

Turns the app from single-user to something you can hand to a partner or a team.

### 2.1 Workspaces

**Why** `Workspace` is read-only today: the app filters lists by the default workspace
and nothing else.

**Scope**
- List workspaces, switch the active one, create one, rename it.
- Move a project and a task between workspaces.
- Members and groups: see who is in a workspace (read).
- Leave a workspace, and transfer ownership when leaving as the owner.
- Server routes: `workspaces` (21), including `leave` and `transfer`.

### 2.2 Sharing and members

**Why** a project cannot be shared from the app at all.

**Scope**
- Project members: list, add by email, change role, remove.
- First share must handle the server's refusal for an encrypted account
  (`409 encryption_enabled`) with a sentence that explains why, not a raw error.
- Shared projects are never encrypted: the UI must show that state on the project.
- Server routes: `projects/{id}/members`, `projects/{id}/grants`.

### 2.3 Invitations

**Why** invitations exist in the app only for the admin tab (server invitations).

**Scope**
- Invite someone to a project, and to a workspace.
- Accept or decline an invitation addressed to me (`/me/member-invitations`).
- Pending invitation list with revoke.
- Server routes: `invitations`, `project-invites`, `workspace-invites`,
  `me/member-invitations`.

### 2.4 Public links

**Why** sharing a list with someone without an account is a server feature the app
cannot reach.

**Scope**
- Create, copy and revoke a public link for a task, a project or a note page.
- Show whether a link is active and what it exposes.
- Server routes: `public` and `public/{token}` (read the shape from the server code
  before designing the screen).

---

## Milestone 3 — Finish end-to-end encryption

Today the app can unlock and decrypt, but the account lifecycle lives in the web app.
This milestone closes that.

### 3.1 Enable and disable

**Scope**
- Enable: passphrase (12+ characters), recovery key shown once, key record stored,
  then the migration below. Confirmation copy that says the server will hold
  ciphertext and that the passphrase cannot be recovered by anyone.
- Disable: decrypt every encrypted file first and wait for it to be stored, then
  delete the key record, then re-write content as plaintext.
- Both need a fresh sign-in confirmation (`/auth/reauth`), as the server requires.

### 3.2 Plaintext migration

**Why** turning encryption on must re-write every content field, and any plaintext
written later (REST, email, import) must be rewritten as ciphertext when it arrives.

**Scope**
- A resumable job that walks every entity with content fields (`lib/src/e2ee/fields.dart`
  already lists them), seals them, and records progress so a kill or a crash resumes.
- Progress UI with counts, and "encrypt on sight" for plaintext that arrives during a
  normal sync (mark such values in the list until rewritten).
- `POST /api/v1/encryption/purge-history` as a follow-up action.
- The pre-0.21 gap: notes, time entries, routines, frames, slots, locations and the
  review line were never re-written by older clients; the job must cover them.

### 3.3 File encryption

**Why** attachments arrive through the op log but the app cannot decrypt or store the
bytes; `lib/src/e2ee/fields.dart` encrypts only the metadata.

**Scope**
- The 1 MiB chunked format from the spec (`OTAT1` header, nonce layout, last-chunk
  marker), verified against `web/src/lib/e2ee.vectors.json`.
- Download an attachment, verify and decrypt every chunk before showing anything.
- Upload a file, encrypt, and attach it with the right size and sha256.
- A locked device shows "Encrypted image" instead of a broken picture.

**Notes** this needs a way to *open* a file, which the app does not have yet; the
minimum is an in-app viewer for images and PDFs plus a share sheet for the rest.

### 3.4 Biometric unlock

**Why** the passphrase is the only way in, and 600,000 PBKDF2 rounds is a slow way.

**Scope**
- After a successful passphrase unlock, offer to keep the account key wrapped by the
  Android keystore under a fingerprint/face key (`flutter_secure_storage` with
  `setUserAuthenticationRequired`, or a Keystore-wrapped key).
- Unlock with fingerprint/face on the sheet while the passphrase still works.
- Delete the wrapped copy on sign-out, passphrase change or reset, encryption
  disable, and when the account key changes (the platform invalidates it when
  biometrics change).

---

## Milestone 4 — Read, export, theme

### 4.1 Export

**Scope**
- Export the account as zip and as PDF (`GET /api/v1/export?format=zip|pdf`), written
  to a file the user can share, with progress and a cancel.
- Works for an encrypted account by exporting ciphertext plus the wrapped key record,
  and say so in the UI.

### 4.2 Statistics

**Scope**
- Completed per day/week, by project and by label, from the local replica so it works
  offline.
- Streaks for recurring tasks.
- A compact "this week" card on Today, and a full screen from the sidebar.

### 4.3 Activity feed

**Why** there is an audit list in the admin tab, but nothing for the account's own
history.

**Scope**
- `GET /api/v1/activity` (and `/me/activity`) in a scrollable feed: what changed, by
  whom, when.
- Per-task history where the server exposes it (`/tasks/{id}/history`).
- Decrypt encrypted values on the device before showing them.

### 4.4 Local theming

**Why** the app has four theme choices and two fonts; the server has a theme editor and
instance themes the app ignores.

**Scope**
- Accent colour picker, and a dark/AMOLED pair that can be set independently.
- Row density (comfortable / compact) and a choice of what a row shows.
- Keep everything device-local via `shared_preferences`, as now; do not add a server
  round trip for appearance.
- Instance themes: read the server's theme and use it as the default palette when the
  user has not chosen one.

---

## Suggested order

1. Trash → task metadata → subtasks (all local, no new routes, immediate value).
2. Statistics and activity feed (read-only, also local-first).
3. Export, then local theming.
4. Workspaces → sharing and members → invitations → public links (each depends on the
   previous one's screens).
5. E2EE enable/disable and migration, then file encryption, then biometric unlock
   (the riskiest work, and the only part that can lose data if it is wrong).

## Assumptions to check before starting

- **Companion, not full client**: no attachments browser, no notes, no comments, no
  time tracking, no calendar sync, no automation rules. If those are wanted later they
  get their own milestone.
- **Server version**: features above assume the 1.5.0 route table; routes are read
  from `internal/httpapi` in the research copy.
- **Tests**: every milestone item lands with tests at the data layer (see
  `test/series_completion_test.dart` and `test/e2ee_replica_test.dart` for the shape),
  and anything that touches completion or encryption also gets a device run.
