# OpenTodo 1.8 and 1.9: what changes for OTDA

Checked on 26 November 2026 against the published
[v1.9.0 release](https://github.com/OpenTodoApp/OpenTodo/releases/tag/v1.9.0),
its changelog and OpenAPI document. OpenTodo 1.8.0 was prepared but never
published; its changes are part of 1.9.0. The earlier
[1.8 impact note](opentodo-1.8-impact.md) remains as the point-in-time record.

## Short version

**OTDA needs no server migration or new server variable for 1.9.**

The 1.x compatibility promise still holds: routes and fields are added, not
removed or changed. The task, project, sync and encryption shapes OTDA uses are
unchanged. Every REST route OTDA calls is still present.

The changes that matter to OTDA are **client-side preferences and behaviour**,
not wire-format breaks:

1. The web client refuses to move a repeating series onto a done/skipped/moved
   occurrence; OTDA does not yet.
2. The new “Complete subtasks with parent” preference is not read by OTDA.
3. The new personal-view filter for tasks assigned to other people is not
   supported by OTDA.
4. Workspace feature switches are ignored by OTDA, so features OTDA knows about
   remain visible in a workspace where they were turned off.

None of these lose or corrupt data.

## Support status

**OTDA supports OpenTodo v1.5.0 through v1.9.x. v1.9.0 is the current target.**

No re-login, data conversion or configuration is needed. The 1.9 server adds two
migrations (`0075`, `0076`) which only add a workspace-features column and
calendar-event tables. Moving from 1.7 directly to 1.9 is supported; 1.8’s
changes are included.

## What 1.8 added

- SSO for providers without verified email, behind an off-by-default switch.
- A calendar picker in web quick add.
- Focus in Android notifications / iPhone Live Activity.
- MCP task assignment via `assignee`.
- More Microsoft To Do import fidelity.
- **Month-first dashed ranges** (`3-4 tomatoes` is text, not a date).
- A web-client guard against moving a repeating series onto its own occurrence.

The dashed-range rule was ported to OTDA’s parser in v1.4.6.

## What 1.9 adds

- A phone-first web/UI redesign, including Android/iPhone screens.
- Arabic and Japanese, right-to-left layout.
- Android widgets, notification-shade quick add, and urgent reminders as alarms.
- iPhone Siri/Shortcuts and urgent-reminder alarms.
- Editing calendar events in Day/Week; per-workspace calendar visibility.
- Manual ordering in Today/Upcoming; wildcard filters.
- **Keep open subtasks** (complete a parent without completing its subtasks).
- **Personal views hide tasks assigned to other people**; an option can show
  them again.
- Per-workspace feature switches and workspace-level custom fields.
- Focus sync across devices, paste-a-file quick add, text-size setting, undo
  coverage, sub-project expansion and other web/desktop improvements.
- `409 series_date_taken` for API/CLI/assistant date moves onto a recorded
  occurrence.

## Effect on OTDA, by area

### API, sync and encryption

No required change. Workspaces gain a `features` object, workspaces can own
fields, calendar-event routes are added, reminders gain an `urgent` flag, and a
row-click setting is added. OTDA preserves unknown synced fields and does not
rewrite whole objects, so connecting a 1.9 account does not erase them.

The new `409 series_date_taken` applies to direct API/CLI/assistant writes. OTDA
edits through its offline operation log, and the server explicitly does not
refuse a device’s offline series move; it repairs the date during sync instead.
So OTDA will not start failing sync with a 409.

### Quick add

The 1.9 parser has no further date-grammar change over 1.8. OTDA’s v1.8
dashed-range parity remains current.

### Repeating tasks

OTDA still allows a series to be moved onto one of its own done/skipped/moved
occurrence dates, and does not move a series’ start/deadline with its due date.
The web app refuses that edit and explains why. On OTDA the edit can sync and be
repaired to the next free date, which looks like the date jumping. This is the
same gap documented under 1.8 and is now the most visible remaining difference.

### Subtasks and completion

OpenTodo 1.9 adds the synced **Complete subtasks with parent** preference. OTDA
still completes open descendants whenever a parent is completed. If the
preference is turned off on the web, OTDA will complete subtasks the account
asked to keep open.

OTDA also does not implement the “kept” state that removes those open subtasks
from lists, counts, search and reminders while the parent is complete. Reading
the preference and filtering kept subtasks is a separate, real change.

### Assigned tasks

OTDA does not display or filter assignees. In a shared workspace, a 1.9 web client
hides other people’s tasks from Today/Upcoming/Anytime/Someday by default; OTDA
will still list them. That is a shared-workspace behaviour difference, not a
sync error.

### Workspace features and fields

OTDA ignores workspace feature switches. If Calendar, Focus, Habits, Time
tracking or another feature is turned off for a workspace on the web, OTDA’s own
surfaces remain available. Workspace-defined custom fields are preserved but not
shown. The REST, CLI, MCP and export data remain intact.

### Everything else

The phone redesign, Arabic/Japanese, Android/iPhone widgets and alarms, Siri,
calendar-event editing, manual order, wildcard filters, Focus sync, text size,
workspace fields and the undo additions are upstream web/native features or new
preferences OTDA does not consume. They do not block using a 1.9 server.

## Next, in priority order

1. Refuse a series date that lands on a done/skipped/moved occurrence and move
   its start/deadline with the due date.
2. Read `complete_subtasks_with_parent`, and hide kept subtasks from OTDA’s
   views/counts/reminders when the parent is complete.
3. Respect the personal-view assignment rule in shared workspaces.
4. Optionally honour workspace feature switches.

Items 1–2 change user-visible behaviour; 3–4 matter mainly for shared or
feature-restricted workspaces. Nothing blocks a 1.9 server today.
