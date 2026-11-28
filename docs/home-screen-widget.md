# The home-screen widget

```mermaid
flowchart LR
  R[Repo] --> B[buildWidgetSnapshot<br/>pure: sections, rows, 'more']
  B -->|JSON via home_widget<br/>snapshot_all, snapshot_‹projectId›| P[(HomeWidgetPreferences)]
  S[WidgetSettings<br/>look] --> P
  P --> G[Widget (RemoteViews)<br/>never computes anything]
  G -->|tap row| Link[otda://task/…]
  G -->|tick circle| C[CompleteAction → otda://complete]
  G -->|+| Q[QuickAddActivity popup]
```

- **Dart decides, Kotlin draws.** `buildWidgetSnapshot` produces the whole list
  (Overdue / Today / Tomorrow / This week / Later, rows sorted by day and time,
  a `more` count). The widget code only renders it. Snapshots are written for
  "all" and for each project that has a widget (`active_projects`).
- **No snapshot yet?** The widget asks Dart for one (throttled to once a minute)
  through a background broadcast, so a freshly placed widget fills itself.
- **Ticking is optimistic.** `CompleteAction` flips the row in the stored
  snapshots immediately, then the background isolate writes the real change and
  rewrites every snapshot.
- **Project per widget.** The picker (`TasksWidgetConfigActivity`, plain Views)
  works with the Flutter engine dead; it reads `projects_index` from the same
  preferences.

### Widget look (Settings → Home screen widget)

Per device, stored next to the snapshot, applied immediately. The keys and
defaults are mirrored in `widget/widget_settings.dart` and `WidgetStyle` in
`TasksWidget.kt` — change both together.

| Setting | Key | Values | Default |
| --- | --- | --- | --- |
| Text size | `widget_text_scale` | 70–160 (%) | 100 |
| Row spacing | `widget_density` | `compact` · `standard` · `roomy` | `standard` |
| Widget theme | `widget_theme` | `system` · `light` · `dark` | `system` |
| Background opacity | `widget_background` | 20–100 (%) | 100 |
| Section headings | `widget_show_sections` | bool | true |
| Due time and date | `widget_show_due` | bool | true |
| Completed tasks | `widget_show_completed` | bool | true |

Text size scales every font and grows rows and tap targets with it (never below
their base size). Titles are ellipsized by the TextView itself —
so a larger font keeps proportionally fewer characters. A section heading with
nothing left under it (for example after hiding completed tasks) is dropped.
Values are plain ints, strings and bools so the native side needs no special
decoding, and a missing or odd value is simply the default.

