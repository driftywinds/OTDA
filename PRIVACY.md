# OTDA Privacy Policy

**App:** OTDA - **O**pen**T**o**D**o for **A**ndroid (`com.dw.otda`)
**Effective date:** 19 November 2026
**Last updated:** 19 November 2026

## The short version

OTDA does not collect your data. There is no account with us, no analytics, no
advertising, no crash reporting and no tracking of any kind. The app stores your
tasks on your phone and sends them only to the OpenTodo server **you** choose —
usually your own. We never receive them.

## What the app stores, and where

| What | Where it lives | Who can read it |
| --- | --- | --- |
| Tasks, projects, labels, notes, settings | A database inside the app's private storage on your device | The app, and your OpenTodo server once it syncs |
| Signed-in session (cookie or API token) | The device's secure storage (Android Keystore / iOS Keychain) | Only the app |
| Display preferences (theme, font, server history) | The app's private preferences on your device | Only the app |
| Home-screen widget data (a small JSON snapshot) | The app's private preferences on your device, read by the widget | The app and the widget |
| Reminders | Android's alarm and notification system, on your device | Your device |

Deleting the app deletes all of it from your device. Data that has already synced
lives on your OpenTodo server; removing it there is done through that server, by
you or its administrator.

## What is sent over the network

The app talks to exactly one server: the OpenTodo address you type on the sign-in
screen. There are no other endpoints, no telemetry and no third-party services.

To that server it sends:

- your tasks and the changes you make, so other devices of yours can see them;
- the credential you signed in with (a session cookie or an API token);
- requests to fetch your own profile picture, when your account has one.

That traffic goes to a server you control or chose. We do not operate it, cannot
read it, and receive no copy of it. If your server uses HTTPS, the traffic is
encrypted in transit; whether it does is a property of your server, not the app.

The app also downloads your account's profile picture from that same server and
keeps it in memory while it is shown.

## What we never do

- No analytics or usage statistics.
- No advertising, ad identifiers or tracking pixels.
- No crash or error reporting to us or anyone else.
- No access to your contacts, calendar, photos, location, microphone, camera or
  files. The app does not ask for them.
- No selling, sharing or transmitting data to third parties.
- No developer-operated backend: there is nowhere for us to collect data even if
  we wanted to.

## Permissions and why they exist

| Permission | Why the app asks |
| --- | --- |
| Internet | To reach the OpenTodo server you configure. |
| Notifications | To show task reminders you created. |
| Exact alarms | To fire a reminder at the time you set instead of minutes later. Without it the app falls back to approximate alarms and says so in Settings. |
| Run at startup | To re-arm your reminders after the phone restarts. |
| Vibrate | To make a reminder noticeable. |

None of these are used for anything else, and none of them send data anywhere.

## Children

The app is not directed at children and collects no personal information from
anyone, so it collects none from children.

## Your choices

- **Reminders:** turn them off in Settings, or mute the channels in Android's app
  settings.
- **The widget:** remove it from your home screen; its stored snapshot is removed
  with it.
- **Signing out:** clears the stored session from the device.
- **Everything:** clearing the app's storage or uninstalling it removes all data
  the app holds on this device.

## Changes to this policy

If the app ever starts collecting something, this document will say so before that
version ships, and the date at the top will change. The app is open source, so the
history of this file is public.

## Contact

Questions about this policy: **hi@drifty.win**

Source code and this document:
<https://github.com/driftywinds/OTDA>
