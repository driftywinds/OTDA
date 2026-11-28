# Settings

Two kinds, shown in one screen:

- **Account preferences** (`week_start`, `date_format`, `time_format`,
  `row_layout`, …) live in the op log under `user_prefs/me` and **follow you to
  every device** on the next sync. `system` means "follow this phone".
- **This device** (theme mode, independent dark/AMOLED style, accent, density, row
  detail, font, notification options, widget look) is stored locally and never
  synced. An instance theme read after sign-in supplies the default palette until
  an accent is chosen.
- **Security** is account state, not a preference: Settings → Two-factor
  authentication enrols TOTP, shows recovery codes once, lists remembered browsers
  and turns the factor off (each change asks for a fresh password or code).

Admins and owners get a second **Server** tab (`admin_view.dart`) over the admin
API.

