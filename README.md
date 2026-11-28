<p align="center">
  <img src="assets/app-icon.png" alt="OTDA" width="120">
</p>

# OTDA

**O**pen**T**o**D**o for **A**ndroid — a Flutter client for
[OpenTodo](https://github.com/OpenTodoApp/OpenTodo) servers.

Offline-first, with the same data model as the server so every device converges.

<p align="center">
  <a href="https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/driftywinds/OTDA">
    <img src="https://raw.githubusercontent.com/driftywinds/driftywinds/refs/heads/main/Images/custom_badge_obtainium.png"
      alt="Get it on Obtainium" height="75">
  </a>
  <a href="https://play.google.com/store/apps/details?id=com.dw.otda">
    <img src="https://raw.githubusercontent.com/driftywinds/scrobr/main/assets/google-play-badge.png"
      alt="Get it on Google Play" height="75">
  </a>
</p>

<p align="center">
  <img src="assets/readme/hero.png"
    alt="OTDA on two Android phones: Inbox with pinned tasks and a Today list, beside the task drawer"
    width="100%">
</p>

<p align="center">
  <sub><i>Your tasks, on your server — pinned work, a daily plan and a widget that stays in step.</i></sub>
</p>

- Tasks: projects, sections, labels, priorities, deadlines, start/Someday,
  estimates, energy, subtasks, repeating occurrences and a Trash with restore.
- Views: Inbox, Today, Upcoming, Anytime, Someday, History, Search, a month
  calendar and project lists.
- Workspaces and sharing: switch or create workspaces, share projects with roles
  and invitations, and publish read-only or tickable public links.
- Capture: quick-add from one line, reminders, the Android home-screen widget and
  a quick-add popup.
- Security: optional end-to-end encryption with a recovery key, app lock, TOTP
  two-factor, per-task history and JSON/ZIP export.
- Notes: Markdown with headings, lists, quotes, code, tables, links and tappable
  checklists.
- Not yet: comments, images inside notes, an in-app PDF viewer, note public pages,
  and the device relay.

- Package / bundle id: `com.dw.otda`
- Target server: OpenTodo **v1.11.0** (`/api/v1`), backward-compatible with
  **v1.5.0 and later**; see [the 1.11 impact note](docs/opentodo-1.11-impact.md)
- Platforms: Android, iOS (the home-screen widget, the quick-add popup and the
  exact-alarm reminders are Android only)

## Screens

<p align="center">
  <a href="assets/readme/overview.png">
    <img src="assets/readme/overview.png"
      alt="Today, Inbox, Upcoming and the workspace drawer across four Android screens"
      width="100%">
  </a>
</p>

<p align="center">
  <sub>Today, Inbox, Upcoming and the workspace drawer — one local replica, every screen in step.</sub>
</p>

<table align="center">
  <tr>
    <td align="center" width="33%">
      <a href="assets/readme/inbox.jpg">
        <img src="assets/readme/inbox.jpg" alt="Inbox with pinned tasks, Done today and the rest of the day" width="220">
      </a>
      <br>
      <sub><b>Inbox</b><br>Everything, in one place</sub>
    </td>
    <td align="center" width="33%">
      <a href="assets/readme/today.jpg">
        <img src="assets/readme/today.jpg" alt="Today with pinned tasks, overdue items, timed tasks and Done today" width="220">
      </a>
      <br>
      <sub><b>Today</b><br>Pinned, overdue and done</sub>
    </td>
    <td align="center" width="33%">
      <a href="assets/readme/upcoming.jpg">
        <img src="assets/readme/upcoming.jpg" alt="Upcoming grouped by Tomorrow, Tuesday, Wednesday and Thursday" width="220">
      </a>
      <br>
      <sub><b>Upcoming</b><br>The days ahead</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="33%">
      <a href="assets/readme/projects.jpg">
        <img src="assets/readme/projects.jpg" alt="The navigation drawer showing projects, views and account actions" width="220">
      </a>
      <br>
      <sub><b>Projects</b><br>Projects and navigation</sub>
    </td>
    <td align="center" width="33%">
      <a href="assets/readme/workspaces.jpg">
        <img src="assets/readme/workspaces.jpg" alt="Workspaces screen showing the Personal workspace and its projects" width="220">
      </a>
      <br>
      <sub><b>Workspaces</b><br>Projects, members and access</sub>
    </td>
    <td align="center" width="33%">
      <a href="assets/readme/settings.jpg">
        <img src="assets/readme/settings.jpg" alt="Settings with account details, two-factor authentication and date preferences" width="220">
      </a>
      <br>
      <sub><b>Settings</b><br>Account, security and dates</sub>
    </td>
  </tr>
</table>

### The widget

<p align="center">
  <a href="assets/readme/widget.webp">
    <img src="assets/readme/widget.webp"
      alt="OTDA home-screen widget with Pinned, Done today, Overdue, Today and Tomorrow sections"
      width="300">
  </a>
</p>

<p align="center">
  <sub>The same pinned tasks and Done today, above the rest of the day — without opening the app.</sub>
</p>

## Documentation

The product overview stays here. The engineering notes live in the docs:

| Guide | What it covers |
| --- | --- |
| [Architecture and repository map](docs/architecture.md) | The three layers, the Android process model, and where each part of the repo lives. |
| [The quick-add parser](docs/quick-add-parser.md) | The grammar, examples, live highlighting, and how to add a phrase or language. |
| [Data model and sync](docs/data-model-and-sync.md) | The local replica, op log, hybrid clock, conflict rule and repeating-task records. |
| [Reminders](docs/reminders.md) | The pure planner, Android alarms and snooze handling. |
| [The home-screen widget](docs/home-screen-widget.md) | Snapshot building, native rendering, tap actions and widget look settings. |
| [Settings](docs/settings.md) | Account preferences versus device-only settings, and the server tab. |
| [Sign-in](docs/sign-in.md) | Sessions, API tokens and the platform keystore. |
| [Testing](docs/testing.md) | Local commands, test groups and the integration server. |
| [Releasing](docs/releasing.md) | CI, the release workflow and the signing secrets. |
| [API spec](docs/api-spec.md) | Regenerating spec/API.md and the filtered OpenAPI file. |
| [OpenTodo 1.11 compatibility](docs/opentodo-1.11-impact.md) | What changed upstream and what it means for OTDA. |

## Install

- **Android:** install from Google Play, or add the GitHub repo to Obtainium.
- **iOS:** build from source with Flutter; the Android-only pieces are the widget,
  quick-add popup and exact-alarm reminders.
- **Server:** OpenTodo **v1.5.0 or later**; OTDA currently targets **v1.11.0**.

## Privacy

OTDA collects nothing: no analytics, no ads, no crash reporting, and no server of
ours. Your tasks stay on your device and go only to the OpenTodo server you sign
in to. The full policy is [PRIVACY.md](PRIVACY.md).
