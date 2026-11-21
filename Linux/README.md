# Calendar for Linux

The Linux preview uses the same Swift quick-entry parser, time-around-event notes, and timeline layout as the Apple app. It has a native Qt window with Day, Week and Month views, all-day events, calendar colours and visibility, and a day preview in Month. Use Ctrl+1, Ctrl+2 and Ctrl+3 to change views and Ctrl+N to add an event.

## Desktop appearance

Open the window menu and choose **Appearance**. System uses your Plasma colours and accent when KDE's colour configuration is available. Light and Dark can also be selected manually. The navigator button hides the mini month and calendar list for a full-width timeline. Narrow windows tuck the navigator away automatically. **Visible calendars** is also available from the window menu.

## Run from source

Install [Swift 6 or newer](https://www.swift.org/install/linux/), Python 3.11 or newer, `pkg-config`, and the OpenSSL development headers. On Debian 12, the package names for the additional dependencies are:

```sh
sudo apt install python3-venv pkg-config libssl-dev libegl1 libgl1 libfontconfig1 libdbus-1-3 libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-keysyms1 libxcb-shape0 libxcb-xinerama0
```

Then run from the repository root:

```sh
Scripts/setup-linux
Scripts/run-linux --demo
Scripts/run-linux
```

Demo uses sample data in memory. A connection to Apple is only needed for the live calendar view.

## Connect iCloud

1. Generate a separate [Apple app-specific password](https://support.apple.com/en-us/102654). Your Apple Account needs two-factor authentication.
2. Choose **Connect iCloud** in Calendar and enter your Apple Account email and the generated password.
3. Use **Calendars** to show only the calendars you want. Changes to writable calendars go directly to iCloud over CalDAV and sync to the other devices on that account. Apple’s existing sharing permissions determine access.

The app can remember the password in the Linux Secret Service keyring (for example GNOME Keyring or a compatible wallet). If the service is unavailable, the connection lasts for the current session. Revoke the app-specific password in your Apple Account to remove access.

## Preview limits

Calendars stored in iCloud are available. Other Apple Calendar accounts and “On My Mac” calendars require their own provider connections or migration to iCloud. Google Tasks, Apple-side profiles and settings syncing, offline edits, drag resizing and undo are outside this preview.

Open single events to edit their title, time, and description. The preview renders recurring events and supports creating a weekly repeat, with existing series and invitations read-only. Linked Apple app copies are kept read-only while their round-trip behaviour is tested. Colour categories and per-profile styling still need a Linux UI. The event notes keep the Apple app’s before/after metadata. Updates and deletions require the version of the event you originally opened, so the app can reject a stale change.

Backend and desktop checks use disposable fixtures. Live account behaviour still needs verification against a disposable iCloud calendar.
