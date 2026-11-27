# OpenTodo 1.8 and 1.9: what changes for OTDA

> **Superseded for server compatibility by 1.10:** see
> [the 1.10 impact note](opentodo-1.10-impact.md). The 1.9 client fixes below are
> implemented; 1.10 adds no API change.

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

The changes that mattered to OTDA are now handled:

1. A repeating series date is refused when it lands on a done/skipped/moved
   occurrence, and its start/deadline move with a free date.
2. `complete_subtasks = keep` is read; kept subtasks are hidden from lists while
   remaining visible in their completed parent.
3. Personal views hide tasks assigned to another account unless the synced
   “show others” choice is on.
4. Workspace `features` are read; Calendar and Statistics disappear when the
   active workspace switches them off.

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

OTDA’s date picker now reads the series’ exception dates before writing. A date
that is already done, skipped or moved leaves the series alone and shows a toast;
a free date moves the series, with its start and deadline shifted by the same
number of days. The 1.9 API’s `409 series_date_taken` is not needed on OTDA’s
offline sync path, but the client now prevents the same bad edit at the source.

### Subtasks and completion

OTDA reads `user_prefs.complete_subtasks`. With `keep`, completing a parent writes
only the parent; open descendants stay open and are filtered from lists, search,
counts, reminders and the widget by the completed-ancestor rule. They remain in
the parent’s Subtasks section, and reopening the parent brings them back. The
same preference is exposed as **Complete subtasks with parent** under
Settings → Lists.

### Assigned tasks

Personal views (Today, Upcoming, Anytime and Someday) hide tasks whose
`assignee_id` is neither empty nor the signed-in account, unless the synced
`today_assignees = all` choice is on. The choice is in the new **View options**
menu in those views. Project lists, the Inbox and search still show every task,
and the header count/Today stats count only the user’s own tasks.

### Workspace features and fields

OTDA reads `Workspace.features`. When the active workspace switches Calendar off,
the Calendar destination disappears and the view falls back to Today; when
Reviews is off, Statistics and the Today progress card are hidden. Other
workspace features (Notes, Habits, Focus, Routines, Locations) do not have OTDA
surfaces. Workspace-defined custom fields are preserved but not shown. Data is
never deleted.

### Everything else

The phone redesign, Arabic/Japanese, Android/iPhone widgets and alarms, Siri,
calendar-event editing, manual order, wildcard filters, Focus sync, text size,
workspace custom fields and the undo additions are upstream web/native surfaces
OTDA does not implement. They do not block using a 1.9 server.

## Remaining polish

- Showing the assignee on a task row and offering an **Assigned to me** view.
- Workspace feature administration (OTDA reads the switches; it does not edit
  them).
- Workspace-defined custom-field editing/display.

Nothing blocks a 1.9 server today.
