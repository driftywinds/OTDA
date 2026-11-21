# OTDA roadmap

OTDA is a **companion app** for OpenTodo: tasks, on a phone, well. It is not a full
client, so this roadmap contains only the gaps we decided are worth closing. Anything
not listed here is deliberately out of scope for now.

Companion to `docs/parity-report.md`, which records the full diff; this file is the
plan.

Status values: **todo** · **doing** · **done**.

**Current state:** Milestone 1 (Trash, task metadata, subtasks), Milestone 2
(workspaces, project sharing, invitations, public links) and Milestone 4 (export,
statistics, activity, theming) are done, except that note pages await the notes
feature. Milestone 3 is in progress: enable/disable and the resumable rewrite are
done; file encryption and biometric unlock remain.

---

## Milestone 1 — Make the task list trustworthy

The cheapest parity, and the things a user hits in the first week.

### 1.1 Trash

**Status: done.**

**Why** deleting is currently a one-way door: `Repo.trash()` writes a tombstone and
nothing in the app can list or restore it.

**Scope**
- A Trash view: deleted tasks and projects, newest first, with the day they went.
- Restore one item (`deleted_at = null`), restore a project with its tasks.
- Empty the trash, and purge one item for good.
- Reachable from Settings → Lists and from the sidebar footer.
- Server: `POST /api/v1/trash/purge`, `DELETE /api/v1/tasks/{id}/purge`,
  `DELETE /api/v1/projects/{id}/purge`, and the `deleted`/`include_deleted` query
  flags; the op log already carries `deleted_at`.

**Notes** restoring must re-emit the field ops so other devices see it, not just clear
the local row. The server's route for one item is the collection path with `/purge`,
not `/trash/task/{id}`; the app uses the routes the server actually registers. Purging
a project removes every task that references it, and the app mirrors that locally.

### 1.2 Task metadata in the editor

**Status: done.**

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

**Status: done.**

**Why** `parent_id` is read by `views.dart` (the Inbox rule) and copied into records,
but nothing can create a subtask, reorder one, or promote it.

**Scope**
- Create a subtask from a task, from the list, and from the row menu. The composer
  has a Parent chip with a searchable task list, and starting it from “Add subtask”
  pre-fills that parent; the new subtask inherits the parent's project and appears
  beneath its parent immediately, offline.
- Show children indented under their parent, ordered by `position`, with progress
  "completed/total" over **direct** children in the row and in the detail sheet.
- Move a subtask to another parent, promote it to top level, delete it. Moving a
  parent's project moves every descendant (one op per task).
- Collapse/expand per device, remembered locally, not synced.

**Notes** the composer is reused for subtasks, so a subtask gets every attribute a
top-level task gets (date, time, duration, repeat, priority) plus a Parent chip. The
project chip is fixed to the parent's project while a parent is selected, because the
server refuses a subtask in another project. Quick “create subtask with a title” is
no longer a separate text dialog.

**Behaviour, taken from the web client's code** (`web/src/lib/ops.ts`,
`web/src/lib/recurring.ts`, `openspec/specs/subtasks`). These are decided; implement
them, do not re-decide them.

1. **Completing a plain task completes its open descendants.**
   `planCompletePlain` (`ops.ts:1221`) writes `completed_at` on the task and on every
   live descendant that is not already completed — **one completion op per task**, so
   the result converges on every device. Our `setCompleted` currently touches only the
   tapped task; this is the change to make.
2. **Completing a recurring series completes no children.**
   `completeTask` for a series only writes the occurrence record and rolls the series
   (`planCompletion`); descendants are not part of the plan.
3. **Reopening a parent reopens only the parent.** Never reopen descendants.
4. **The last open subtask does not complete the parent.** Offer a one-key action
   ("Complete the parent") instead of doing it silently.
5. **A child whose parent is deleted, completed or not yet received still shows**, at
   the top level of its project, with no write. Today and Upcoming list such a child
   as a normal row.
6. **Progress is derived, never stored.** Direct children only: a grandchild counts
   toward its own parent, not toward the grandparent. A deleted child counts nowhere.
   A completed parent keeps showing its children's progress.
7. **Subtasks of a repeating task carry over to the next occurrence, keeping their
   state.** The record gets `parent_id` equal to the *series'* own parent
   (`recurring.ts:202`); children are neither copied into the record nor reparented,
   so they stay attached to the series as it rolls. A child checked off today is still
   checked on tomorrow's occurrence, and the record itself has no children (its
   progress reads 0/0). This is deliberate in the web client — do not "fix" it by
   resetting children on roll, and do not copy them into the record.

**Notes** ordering already exists (`position`) and the server has `manual-ordering`;
reuse it rather than inventing a second order. The subtask tree is read one level at
a time through the `parent_id` index (`liveSubtree`, `ops.ts`), never by scanning every
task; our `db.entities('task')` returns all rows today, so a per-parent query or an
index is needed before this ships on a large account.

Implemented as: `Repo.childrenOf` (position order), `createSubtask`, `setParent`
(same project, no cycles), `moveToProject` (one op per descendant), and
`subtaskProgress` (direct live children). The home list nests a child under its
parent whenever both are in the same group; an orphan child stays at the top level.
Rows show direct-child progress and a fold chevron; the fold set lives in
`db.meta('ui.collapsed')`, so it is per device and never synced. The row menu has
Add subtask, Move under another task, Move to top level and Delete; the task sheet
has the same Add subtask and shows `done/total`. There is still no per-parent SQL
index: the app reads the replica once per refresh and builds the tree in memory,
which is fine at 10,000 tasks (measured 6–9 s for the whole first copy), but a
future saved-view tree should query children by parent.

---

## Milestone 2 — Sharing and people

Turns the app from single-user to something you can hand to a partner or a team.

### 2.1 Workspaces

**Status: done.**

**Why** `Workspace` is read-only today: the app filters lists by the default workspace
and nothing else.

**Scope**
- List workspaces, switch the active one, create one, rename it.
- Move a project and a task between workspaces.
- Members and groups: see who is in a workspace (read).
- Leave a workspace, and transfer ownership when leaving as the owner.
- Server routes: `workspaces` (21), including `leave` and `transfer`.

**Notes** a task has no `workspace_id` of its own: it follows its project, so moving a
task is moving its project. The workspace screen groups live projects under each
workspace, creates projects in the active one, moves a project with one `workspace_id`
op, and offers rename/members/groups/leave/transfer; the default workspace refuses
rename, leave and transfer exactly as the server does. The directory itself still
arrives through the sync exchange, so the screen works offline and refreshes after
each change.

### 2.2 Sharing and members

**Status: done.**

**Why** a project cannot be shared from the app at all.

**Scope**
- Project members: list, add by email, change role, remove.
- First share must handle the server's refusal for an encrypted account
  (`409 encryption_enabled`) with a sentence that explains why, not a raw error.
- Shared projects are never encrypted: the UI must show that state on the project.
- Server routes: `projects/{id}/members`, `projects/{id}/grants`.

**Notes** the project menu opens a member screen with the owner and members (role,
email, group the role comes from), add-by-email with viewer/editor/admin, change role
and remove. The server may add at once or send an invitation; the screen re-reads the
member list and says which happened, and shows pending invitations read-only (they
are revoked from the invitations screen next). A shared project shows a people icon
in the project list and a "Shared projects are never end-to-end encrypted" banner
here. An encrypted account sees why a personal project cannot be shared before the
button is pressed, and a `409 encryption_enabled` is still mapped to the same
sentence. Group grants are listed read-only; group management is the web app's job.

### 2.3 Invitations

**Status: done.**

**Why** invitations exist in the app only for the admin tab (server invitations).

**Scope**
- Invite someone to a project, and to a workspace.
- Accept or decline an invitation addressed to me (`/me/member-invitations`).
- Pending invitation list with revoke.
- Server routes: `invitations`, `project-invites`, `workspace-invites`,
  `me/member-invitations`.

**Notes** the project sharing screen already adds by email and now shows and revokes
its `pending` list; the workspace menu gains Invite a person and Waiting invitations
(the GET route's `pending` list). An **Invitations** row in the sidebar lists what is
addressed to this account (project or workspace, who invited, role, expiry) and
accepts or declines; accepting syncs before the toast. The token-based invite pages
(`project-invites/{token}`, `workspace-invites/{token}`, public signup preview) are
still web-only: they create an account, which is outside a signed-in app.

### 2.4 Public links

**Status: done for project links and task pages; note pages still need the notes
feature.**

**Why** sharing a list with someone without an account is a server feature the app
cannot reach.

**Scope**
- Create, copy and revoke a public link for a task, a project or a note page.
- Show whether a link is active and what it exposes.
- Server routes: `public` and `public/{token}` (read the shape from the server code
  before designing the screen).

**Notes** the v1.5.0 server has three different things behind "public link":
`projects/{id}/public-links` (a project list at `/public/<slug>-otl_…`),
`tasks/{id}/page` (a task page at `/t/<secret>`, with view/reply/tick), and
`notes/{id}/page` (a note page at `/n/<secret>`). The app implements the first two:
the project menu has Public link… (name, view/tick, list/board, expiry; the URL is
shown and copied once, because the list route never repeats the secret; revoke from
the same screen) and the task sheet has Share page (rights, label, expiry, one-time
URL, unpublish). An encrypted personal task needs an unlocked snapshot to publish;
the app does not create one yet, so the server's refusal is explained. Note pages
are not reachable because the app has no notes feature — that is the notes milestone,
not a missing public-link route.

---

## Milestone 3 — Finish end-to-end encryption

Today the app can unlock and decrypt, but the account lifecycle lives in the web app.
This milestone closes that.

### 3.1 Enable and disable

**Status: done (text fields; file bytes are 3.3).**

**Scope**
- Enable: passphrase (12+ characters), recovery key shown once, key record stored,
  then the migration below. Confirmation copy that says the server will hold
  ciphertext and that the passphrase cannot be recovered by anyone.
- Disable: decrypt every encrypted file first and wait for it to be stored, then
  delete the key record, then re-write content as plaintext.
- Both need a fresh sign-in confirmation (`/auth/reauth`), as the server requires.

**Notes** settings now owns the lifecycle: choose a passphrase with an explicit
unrecoverable warning, save the one-time recovery key, store the record and rewrite;
turn off with a fresh password/code confirmation (the server's `DELETE` is
`sensitive`). The server only requires re-authentication for *replacing* a record,
not for the first create; the app still confirms before disabling. Files are not
touched because the app has no attachments yet, and that is stated in 3.3.

### 3.2 Plaintext migration

**Status: done (the app's entities).**

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

**Notes** the job scans the replica's `fields` table, so it already covers every entity
`fields.dart` names, including the pre-0.21 kinds; there is no per-kind cursor to go
stale. Only personal scope is sealed: a task follows its project, sections/fields/rules/
notes their project, comments/attachments/time entries their task, and a project with
more than one member stays plaintext (stray ciphertext there is rewritten back). The
replica keeps plaintext; only the outbox carries ciphertext, so lists stay readable
during and after the rewrite. Plaintext that arrives from sync is sealed on sight.
Progress counts and a resumable mode are stored under `e2ee.migration`; the purge
button is on the same card.

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

**Status: done (JSON and ZIP; the server has no PDF format).**

**Scope**
- Export the account as zip and as PDF (`GET /api/v1/export?format=zip|pdf`), written
  to a file the user can share, with progress and a cancel.
- Works for an encrypted account by exporting ciphertext plus the wrapped key record,
  and say so in the UI.

**Notes** the 1.5.0 handler accepts `format=json` and `format=zip` only and refuses
anything else with `400 invalid_input`; there is no PDF route, so the app offers the
two formats that exist rather than a button that always fails. The response is
streamed to a temporary file with real progress and a cancel that stops reading (the
server keeps building until the connection closes). The finished file goes through
the system share sheet. For an encrypted account the screen says the file holds
ciphertext plus the wrapped key record.

### 4.2 Statistics

**Status: done.**

**Scope**
- Completed per day/week, by project and by label, from the local replica so it works
  offline.
- Streaks for recurring tasks.
- A compact "this week" card on Today, and a full screen from the sidebar.

**Notes** the screen offers this week, last week, this month, this quarter and this
year; bars are daily up to a month, then weekly, then monthly. Streaks are read from
the occurrence records: consecutive completed occurrences with no missed scheduled
gap (a skip breaks it, an overdue series has none), using the rule's interval as the
tolerance. A label counts once per task that carries it.

### 4.3 Activity feed

**Status: done.**

**Why** there is an audit list in the admin tab, but nothing for the account's own
history.

**Scope**
- `GET /api/v1/activity` (and `/me/activity`) in a scrollable feed: what changed, by
  whom, when.
- Per-task history where the server exposes it (`/tasks/{id}/history`).
- Decrypt encrypted values on the device before showing them.

**Notes** the server's feed is derived from **shared** scopes only (its tests pin
that personal tasks and projects outside a membership never appear), so the app
says so in the empty state instead of pretending the history is missing. Personal
tasks are covered by two routes that do include them: `/tasks/{id}/activity` and
`/tasks/{id}/history`. The task sheet's History button opens the latter, newest
first, with each field's old and new value decrypted through the E2EE session and
label ids resolved to names. `/me/activity` is the security audit log (sign-ins,
tokens), not task history, so it is not used for this screen.

### 4.4 Local theming

**Status: done.**

**Why** the app has four theme choices and two fonts; the server has a theme editor and
instance themes the app ignores.

**Scope**
- Accent colour picker, and a dark/AMOLED pair that can be set independently.
- Row density (comfortable / compact) and a choice of what a row shows.
- Keep everything device-local via `shared_preferences`, as now; do not add a server
  round trip for appearance.
- Instance themes: read the server's theme and use it as the default palette when the
  user has not chosen one.

**Notes** `ui.theme` is now system/light/dark and `ui.dark` picks dark grey or AMOLED
independently (a stored `amoled` value migrates). Accent choices are the instance
default plus eight swatches; density is `VisualDensity` plus tighter row padding; the
row choice is Everything / Dates and priority / Title only. `GET
/api/v1/themes/instance` is read after sign-in: an `instance:<id>` default supplies
accent/canvas/surface/text from its `seeds`; a `builtin:` or empty default keeps the
app's own OpenTodo-like palette, because built-in documents are not in that response.

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
