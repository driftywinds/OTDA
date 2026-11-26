# OpenTodo 1.8: what changes for OTDA

> **Superseded:** 1.8.0 was never published as a release; its changes shipped in
> v1.9.0. See [the combined 1.8/1.9 note](opentodo-1.9-impact.md) for the
> current status.

Checked on 26 November 2026 against the `v1.8.0` tag: its changelog, the v1.8.0
OpenAPI document, and the v1.7.0…v1.8.0 diff. At the time of writing the tag
exists but the GitHub Release page has not been published yet; the changelog is
dated 24 November 2026.

## Short version

**OTDA needs no server migration to keep working with 1.8.**

The 1.x compatibility promise still holds: routes and fields are added, not
removed or changed. The OpenAPI diff adds one admin SSO field and one MCP
argument; it does not change the task, project, sync or encryption shapes OTDA
uses. The server still serves the v1.5-era routes OTDA calls.

## Support status

**OTDA supports OpenTodo v1.5.0 through v1.8.x. v1.8.0 is the current target and
the version the login screen shows.**

No re-login, data conversion or new server variable is needed. The 1.8 server
adds one (`users.email_assumed`) at start-up; it only grows the schema, so 1.7.x
can still read the database.

## What is new upstream

### Added

- **Single sign-on with providers that send no email confirmation** (for
  example Synology SSO Server), behind an opt-in switch that only creates new
  accounts. The switch is off by default.
- **A date picker in web quick add**, using the same words the line would get if
  typed.
- **Focus outside the app**: Android notifications and an iPhone Live Activity
  for a running Focus session. The new Android/iPhone apps are required for this.
- **MCP task assignment** through `assignee` on `create_tasks` and
  `update_tasks`.
- **Home-network warning** on the upstream Android first-run screen, plus Home
  Assistant remote-access recipes.
- **More Microsoft To Do import fidelity** and a step-by-step export guide.

### Changed / fixed

- **A repeating task cannot be moved onto its own done, skipped or moved
  occurrence** in the web app. The date stays put and the toast says why.
  Changing a repeating task's date also moves its start and deadline with it.
- **Month-first dashed ranges**: `3-4 tomatoes` is a quantity range, not a date.
  `3/4`, `3-4-2027`, and dashed dates after `on`, `by` or `until` remain dates.
- A shared project shows a dot for unread changes instead of a second count.
- A reusable list's ticked section is called **Completed**, and a reusable list
  no longer shows “% done”.
- `ot login` now handles two-factor authentication; the sync indicator no longer
  flashes for routine syncs.
- Microsoft To Do imports keep more recurrence forms, the correct UTC due day,
  and clean notes.

## Effect on OTDA, by area

### Sync and the local replica

No effect. 1.8 adds no task field OTDA must know. New or unknown values are kept
as ordinary fields and sent back unchanged. `users.email_assumed` is an account
column the sync protocol does not carry as a task/project field.

### Auth and admin

No effect on normal email/password or MFA sign-in. OTDA does not implement SSO
administration, so the new `trustMissingEmailVerified` field is simply absent
from its admin UI. The server-side column and provider setting do not change the
session or token calls OTDA makes.

### One real client-side difference: dashed ranges

**Ported in OTDA.** The quick-add parser now follows the 1.8 rule:

- month-first `Buy 3-4 tomatoes` stays a title,
- `Buy on 25-12` is 25 December,
- `Buy 3/4` and `Buy 3-4-2027` are dates,
- day-first locales still read `3-4` as 3 April.

This closes the cross-client mismatch where the 1.8 web app kept the range as
text and OTDA would have saved a due date.

### One deliberate gap: moving a repeating series onto a done occurrence

The 1.8 **web client** refuses a date change that would put a series on one of its
own exception dates (done, skipped or moved), and moves a series' start and
deadline with its due date. OTDA does not yet implement that confirmation guard or
the start/deadline shift.

It is not a server/API break: the data remains valid and syncs. It is a behaviour
difference worth closing next, because an OTDA edit can otherwise put a series on
a done date and the next completion will repair it to a later date, which looks
like the date jumping. The shared `exceptionDatesOf` data is already in
`lib/src/data/series.dart`.

### Focus, MCP, imports and remote-access guidance

Not present in OTDA and not required for compatibility. These are upstream
mobile-app, assistant, importer and onboarding features. The MCP assignee
argument is server-side and does not alter task sync.

### API surface we rely on

The v1.8 OpenAPI diff against v1.7.0 is additive:

- `trustMissingEmailVerified` on the admin SSO configuration, and
- `assignee` on the MCP `create_tasks` / `update_tasks` arguments.

No REST route used by OTDA was removed or changed. The server's own compatibility
document states routes and fields only grow within 1.x.

## Next, but not blocking

1. Refuse a series date that lands on a done/skipped/moved occurrence and say
   why; move its start and deadline with the due date.
2. Read `/api/v1/openapi.json` in a CI contract check.
3. Optionally adopt the 1.8 web quick-add calendar as a composer affordance.

Items 1–2 are compatibility/polish; nothing blocks using a 1.8 server today.
