# Calendar for Linux

The Linux preview uses the same Swift quick-entry parser, time-around-event notes, and timeline layout as the Apple app. It has a native Qt window with Day, Week and Month views, all-day events, calendar colours and visibility, and a day preview in Month. Use Ctrl+1, Ctrl+2 and Ctrl+3 to change views and Ctrl+N to add an event.

## Desktop appearance

Open the window menu and choose **Appearance**. System uses your Plasma colours and accent when KDE's colour configuration is available. Light and Dark can also be selected manually. The navigator button hides the mini month and calendar list for a full-width timeline. Narrow windows tuck the navigator away automatically. **Visible calendars** is also available from the window menu.

## Drag to create and time around events

In Day or Week, press on an empty part of a day column and drag up or down. Release to open an event draft with those times. Save the draft to create the event. Dragging snaps to 15 minutes by default, and the interval is configurable under **Settings → Display**. Hover over the top or bottom of a writable timed event’s solid section until the resize cursor appears, then drag the edge. Resizing works in increments from the original time, so 19:53 can move to 19:38. The other edge and event details stay as they were.

Choose **Add time before** or **Add time after** in an event to set its duration, purpose, travel mode and optional label. The dotted portions are drawn as part of the same card, without changing the event’s start or end. Walking, cycling, trains and other activities use their own icons. Hover over a compact card to see the full timing details. **Settings → Before & After** controls defaults for each side, the fill and whether time around an event should blend into another event.

## Profiles and settings

Open the **Settings** gear or press Ctrl+Comma. Profiles keep their own selection and ordering of calendars and can have their own accent. Switch profiles from the sidebar or window menu. **All calendars** restores your regular visibility settings. Profiles and preferences are stored locally on Linux.

Display settings include the week start, time format, day layout, hour height and all-day visibility. Quick Entry settings control the default mode, duration, destination and calendar suggestions. Calendar learns from up to 180 days of past events and from new saves. A suggestion appears when at least three events with the same title mostly use one calendar (at least 80%). Dismiss it or choose another calendar. A calendar named with `/calendar` takes priority. The history stays on your device.

## Run from source

Install [Swift 6 or newer](https://www.swift.org/install/linux/), Python 3.11 or newer, `pkg-config`, and the OpenSSL development headers. On Debian 12, the package names for the additional dependencies are:

```sh
sudo apt install git python3-venv pkg-config libssl-dev libegl1 libgl1 libfontconfig1 libdbus-1-3 libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-keysyms1 libxcb-shape0 libxcb-xinerama0
```

Then run from the repository root:

```sh
Scripts/setup-linux
Scripts/run-linux --demo
Scripts/run-linux
```

Setup registers Calendar in the desktop app menu with 256px and 512px icons. If an older install shows a generic icon, rerun `Scripts/setup-linux` and reopen Calendar from the app menu. You can also start it with `Scripts/run-linux`, which uses the installed build without needing Swift on the launcher's PATH. Demo uses sample data in memory.

## Updates

Calendar checks the published GitHub commit at launch and shows a notice when it differs from the installed build. In **Settings → Updates**, check manually, choose **Install update**, then restart Calendar. A Git checkout must be clean and on the main branch. If Calendar was installed from a source archive, updating creates a checkout under your local application data directory. When upgrading from an older build that predates this feature, pull the latest source and run `Scripts/setup-linux` once to register the launcher and record the installed version.

## Connect iCloud

1. Generate a separate [Apple app-specific password](https://support.apple.com/en-us/102654). Your Apple Account needs two-factor authentication.
2. Choose **Connect iCloud** in Calendar and enter your Apple Account email and the generated password.
3. Use **Calendars** to show only the calendars you want. Changes to writable calendars go directly to iCloud over CalDAV and sync to the other devices on that account. Apple’s existing sharing permissions determine access.

The app can remember the password in the Linux Secret Service keyring (for example GNOME Keyring or a compatible wallet). If the service is unavailable, the connection lasts for the current session. Revoke the app-specific password in your Apple Account to remove access.

For a remembered account, Calendar saves calendar events on this device as it syncs. Later launches open the saved view while iCloud checks calendar versions in the background. A changed calendar is downloaded again, and a failed refresh leaves the last saved copy available. You can browse saved events offline. Edits still need iCloud. The cache is stored outside the checkout in the current user's cache directory (`$XDG_CACHE_HOME/stillday` or `~/.cache/stillday`). The database contains event details and has user-only file permissions.

## Preview limits

Calendars stored in iCloud are available. Other Apple Calendar accounts and “On My Mac” calendars require their own provider connections or migration to iCloud. Google Tasks, cross-device profile and settings sync, offline edits, moving saved events by dragging their body, and undo are outside this preview.

Open single events to edit their title, time, and description. The preview renders recurring events and supports creating a weekly repeat, with existing series and invitations read-only. Linked Apple app copies are kept read-only while their round-trip behaviour is tested. Event colour categories still need a Linux UI. The event notes keep the Apple app’s before/after metadata. Updates and deletions require the version of the event you originally opened, so the app can reject a stale change.

Backend and desktop checks use disposable fixtures. Live account behaviour still needs verification against a disposable iCloud calendar.
