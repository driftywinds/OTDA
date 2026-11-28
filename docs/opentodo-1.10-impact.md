# OpenTodo 1.10: what changes for OTDA

> **Superseded for server compatibility by 1.11:** see
> [the 1.11 impact note](opentodo-1.11-impact.md). The API did not change in
> 1.11; its new surface is the completed Habits feature.

Checked on 27 November 2026 against the published
[v1.10.1 release](https://github.com/OpenTodoApp/OpenTodo/releases/tag/v1.10.1),
its changelog and the v1.9.0…v1.10.1 API diff. v1.10.0 was tagged but never
published; 1.10.1 contains it.

## Short version

**OTDA needs no server migration, re-login or code change for 1.10.1.**

This release does not change the OpenAPI document, the sync shape or any task,
project, workspace or encryption field. It is the phone UI reaching the rest of
the upstream web app. The v1.5-era routes OTDA calls are unchanged.

**OTDA supports OpenTodo v1.5.0 through v1.10.x. v1.10.1 is the current target.**

## What 1.10 adds

- The phone design reaches the rest of the upstream app: the calendar's lists,
  Process the Inbox, boards, a project's timeline, Updates, Habits, Notes,
  Routines and Statistics.
- Phone calendar tasks can be tapped, ticked and swiped; boards scroll under a
  held card; timeline bars can be dragged by touch.
- Process the Inbox gets a phone action bar.
- Tooltip-only explanations become readable by tap on phones and tablets.
- The timeline gets **Earlier**, **Today** and **Later** buttons.
- 1.10.1 fixes a small-phone German weekly-review overflow.

Upgrade notes: no migration and no new or changed variable. The phone screens
come from the server and need no new app.

## Effect on OTDA

### API, sync and encryption

**No effect.** The OpenAPI diff against v1.9.0 is empty. There are no new REST
routes, task fields, workspace fields or error codes. OTDA’s ordinary sync,
offline operations and encryption continue unchanged.

### Auth and admin

No effect. SSO, MFA, sessions and admin routes are untouched.

### Quick add

No parser changes in 1.10. OTDA’s v1.8 dashed-range parity and the rest of its
composer remain current.

### Repeating tasks, subtasks and assignment

No server changes; the client behaviour implemented in OTDA v1.4.7 still covers:

- refusing a series date that lands on a done/skipped/moved occurrence and moving
  start/deadline with the due date,
- `complete_subtasks = keep` and kept-child filtering,
- assignment-aware personal views and the synced “show others” choice,
- workspace Calendar/Reviews feature switches.

The remaining polish from 1.9 is unchanged: no assignee row, no **Assigned to
me** view, no workspace-feature administration and no workspace custom-field UI.

### Phone UI, calendar, boards, Focus and widgets

These are upstream web/native surfaces. OTDA has its own Flutter UI and does not
use the server-rendered phone screens. The Android/iPhone widgets described in
1.9 are upstream native apps, not server features, so OTDA’s widget and reminder
behaviour is unaffected.

### API surface we rely on

No routes or fields were removed or changed between v1.9.0 and v1.10.1. The 1.x
compatibility promise still holds.

## Bottom line

A 1.10.1 server is a drop-in target for OTDA. There is no new build, migration
or compatibility work required for this release; the last app release, v1.4.7,
already carries every 1.9 client fix.
