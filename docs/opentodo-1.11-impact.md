# OpenTodo 1.11: what changes for OTDA

Checked on 28 November 2026 against the published
[v1.11.0 release](https://github.com/OpenTodoApp/OpenTodo/releases/tag/v1.11.0),
its changelog and the v1.10.1…v1.11.0 comparison, including both OpenAPI
documents. The intermediate v1.10.2 and v1.10.3 releases are covered here too.

## Short version

**No server migration, re-login or OTDA code change is required for 1.11.0.**

The OpenAPI document is byte-for-byte identical to v1.10.1. There are no new
routes, task fields, sync operations or encryption changes. OTDA v1.5.5 and later
continue to talk to a 1.11.0 server exactly as they did to 1.10.1.

**OTDA supports OpenTodo v1.5.0 through v1.11.x. v1.11.0 is the current target.**

## What changed upstream

### 1.10.2 and 1.10.3

Both are web/phone fixes:

- swipes on older Android System WebViews;
- timeline Earlier/Later and day labels;
- a phone board flick;
- task title alignment and comment send button;
- Process the Inbox swipes that began on the title.

None touches the API, sync, data model or server behaviour. **No effect on OTDA.**

### 1.11.0

- A new look for OpenTodo's own phone web UI: floating tab bar, Today summary
  tiles, Upcoming's next seven days and rounder cards.
- **Habits is complete**: a week board on larger screens, a habit-specific phone
  screen, check-ins for past days, tiny versions, skip days, targets/amounts,
  day notes, streaks and a year heatmap.
- The **New phone screens** switch and the old phone screens are gone; screens
  under 768 px always use the new phone UI.

The phone UI is upstream web UI. OTDA has its own Flutter screens and does not
use it, so the visual changes do not affect OTDA.

## API and sync

The v1.10.1 and v1.11.0 `docs/openapi.json` files are identical (same byte count
and SHA-256). In particular:

- no new or changed task, project, workspace or user fields;
- no new sync operation or cursor change;
- the `/api/v1/habits`, `/api/v1/habits/{id}` and
  `/api/v1/habits/{id}/log` routes **already existed in 1.10.1**;
- no migration, new environment variable or changed setting.

Server-side production code is unchanged; the only internal change in the
comparison is the 1.11 upgrade test fixture.

## Effect on OTDA

### Unchanged

- sync, offline edits, conflict resolution and the replica;
- encryption and attachments;
- quick add, reminders and the home-screen widget;
- the 1.9 and 1.10 client fixes already shipped in OTDA.

### Habits remains an OTDA feature gap

OTDA has no habit-specific UI. A task carrying the habit fields still syncs as
an ordinary repeating task; its unknown fields are preserved in the replica, but
OTDA does not expose:

- the Habits screen or habit rings in Today;
- check-ins for past days, tiny versions or skip days;
- targets/amounts;
- habit day notes;
- streaks, strength or the yearly heatmap;
- the habit-specific reminder form.

This is **not a compatibility break**. It is the largest upstream feature surface
OTDA does not yet present. Existing habit tasks should be treated carefully in
OTDA: completing the underlying occurrence is not the same as the full habit
logging experience upstream.

## Bottom line

A 1.11.0 server is a drop-in target for OTDA. No new build is required for
compatibility. The only product decision is whether to add a native Habits
surface next; that is a sizeable feature, not a server-upgrade task.
