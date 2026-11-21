# Calendar

Calendar is a native SwiftUI calendar for iPhone, iPad, and Mac. It reads and writes the calendars configured on the device through EventKit. Quick entry, preferences, and predictions run locally.

## Run on iPhone or iPad

1. Install full Xcode 26 or later with iOS platform support. For simulator testing, also install an iOS Simulator runtime. Open `Stillday.xcodeproj` and choose the shared **Stillday** scheme.
2. Select an iPhone simulator or plug in and unlock your iPhone. For a physical device, add your Apple Account in Xcode Settings, select a signing team in Signing & Capabilities, and turn on Developer Mode if prompted. Replace the example bundle ID in Signing & Capabilities and in the app’s Info.plist with an identifier for your signing team.
3. Choose **Allow Calendar Access** and grant full access. For testing, create a disposable calendar in the simulator’s system Calendar app. Use that calendar by name when saving test entries.

A simulator build can also be attempted with:

```sh
xcodebuild -project Stillday.xcodeproj -scheme Stillday \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The iOS minimum is 17 and the Mac minimum is 14, which allow SwiftUI Observation and the current EventKit full-access APIs. An iOS 26+ runtime is the intended first verification target. System controls adopt the OS treatment where available. Signing, provisioning, and the installed SDK affect reproducibility.

## Run on Mac

From the project directory with Swift 6 and the macOS SDK:

```sh
Scripts/build-mac-app
open .build/Stillday.app
Scripts/test-mac
```

The Mac app shares Day, Week, Month, and Settings with iPhone and iPad. Week places all seven days on one full-width hourly grid with all-day events and tasks above it. Drag up or down in empty space in Day or Week to select a time range in 15-minute increments. Release to open a draft, adjust its dates if needed, then choose Save. Drag a writable timed event from the middle to move it or from its top or bottom edge to resize it. Existing events keep their original minute offset and move in 15-minute steps by default. Change the step under Calendar Display in Settings. Click an event to edit its fields in place. Open the Mac Settings window from the gear or with Command-Comma.

The bundle is signed ad hoc for local development. The command-line package build does not register App Shortcuts metadata. To restore access after denying it, enable Calendar under System Settings → Privacy & Security → Calendars.

## Quick entry

| Command | Preview |
| --- | --- |
| `18:25 19:10 sketching /Gaming` | Today, 18:25–19:10, in Gaming |
| `design review 18:00 19:00` | Today, 18:00–19:00 in Log activity |
| `project review 18:00 yesterday 19:00` | Yesterday, 18:00–19:00 |
| `dinner tomorrow from 6pm to 7pm` | Tomorrow, 18:00–19:00 |
| `tomorrow 5pm workshop for 45m` | Tomorrow, 17:00–17:45 |
| `23:00 01:00 work` | Ends the following day |
| `every Tuesday 19:00 boxing` | Weekly from the next applicable Tuesday |
| `2026-11-09 all day holiday` | All day on that date |
| `18:30 call @Europe/Lisbon` | Uses the stated IANA time zone |

Put today, yesterday, tomorrow, an ISO date or a time anywhere in the entry. The first time starts the event and the second ends it, including mixed formats such as `14:36 15 workshop`. An earlier end time rolls over to the following day. Use a clock such as 18:00 or 6pm, or bare hours such as `workshop 10 11`. The timing chips show what was recognised and let you keep an interpreted number in the title instead.

**Log activity** keeps date-less times on today, even when they have passed. **Schedule ahead** moves a passed time to the next day. An explicit date or tapped time slot takes priority. A title-only command previews a suggested start and duration. Input keywords are English, with localised weekday names accepted where available. The final slash selects a calendar by its full name or alias. Earlier slashes remain in the event title. Use `/Name · Account` to disambiguate duplicate calendar names. Settings → Quick Entry → Default calendar chooses the fallback when no explicit calendar, saved rule or history suggestion applies. The same setting is available under Calendars. A calendar used at least 80% of the time for the same title is suggested after three or more examples. Dismiss the suggestion with the X, pick a different calendar, or turn suggestions off in Settings. An explicit slash name or saved rule takes priority over history.

To change the calendar picker order, open Settings → Manage Profiles, select a profile, then open Calendar Order. Drag calendars into position, go back and save the profile. Each profile keeps its own order.

To colour events within one calendar, enable **Settings → Event categories**, add a name and colour, then pick it when adding or editing an event. The tag follows the event in its description, while Stillday shows it separately.

## Activity timing and linked calendars

Quick entry accepts bare hour numbers. For example, `workshop 10 11 before 10m after 15m /Fitness` previews a 10:00–11:00 event with time around it. `15:25 15:30 Equipment check 11m before 5m after` also works: the extra time may come before or after the words before/after. The removable timing chips show the interpretation. Remove a chip to use that part of the entry as title text, or choose Recognise times again to reset the interpretation.

Time around event has separate Before and After rows. Open either row to change its duration and purpose, including travel, preparation, setup, cleanup, recovery or a custom label. Travel also has an optional mode. The timeline joins the extensions and activity into one card, with a dotted colour strip around the solid activity strip. Adaptive view expands short extensions so their labels stay readable. Timeline labels show just the activity icon and duration. Settings → Calendar Display → Time Around Event sets independent before/after purposes and travel modes. New extensions default to five minutes of walking on each side. You can change the duration, purpose and mode independently for each side. These defaults apply when adding extensions, including quick entry, without changing existing events. Extensions use the same background as the event by default; choose Lighter on that settings page to distinguish the fill.

The title field in an existing event also accepts quick-entry times, dates, durations, before/after clauses and `/calendar`. The preview shows the result; choose Apply to event to update the form, or Save to apply it when saving. Keep as title only leaves the input literal. Unspecified fields, notes and links stay intact. The X on a Before/After page closes the whole editor without saving; Back returns to its previous page.

Settings → Calendar Display → Time Around Event also offers **Blend overlapping before/after time**, off by default. When another event happens during an extension, its fill stays dominant while the extension's dotted colour replaces its solid stripe only over the shared minutes. Unoccupied extensions keep their usual appearance, and overlapping main activities still use columns. This changes presentation only. In a fixed time grid, very short shared events can be compact bars; hover or click for details, or zoom in. Adaptive Day keeps short activities readable by stretching the time ruler.

Use Also add to when creating an event to save linked copies in additional calendars. Each copy stays in its own calendar. Calendar shows matching copies together and uses the active profile's calendar order for the primary colour. Editing updates the linked copies by default. Turn off Update linked copies to separate a copy, or choose whether to delete the linked activity or remove just the current calendar's copy. A changed or missing copy blocks a group update so you can review it. Non-repeating linked creation and edits participate in the Mac session's undo and redo.


These extra details use a versioned, human-readable bracketed footer in the native event notes. Calendar hides the recognised footer in its description editor. Other apps show the readable notes and the core event's start and end. The before/after portions reserve time visually in Calendar.

## Local verification

Run the automated tests with the Mac script above. For iOS, use the shared scheme with an installed simulator runtime or your own development signing profile. Use disposable calendars when testing writes.

See [PRODUCT.md](PRODUCT.md) for behavior and [ARCHITECTURE.md](ARCHITECTURE.md) for the EventKit safety model and settings format.

## Google Tasks setup

The shipped build displays device calendars immediately. To enable Google Tasks sign-in in a build, enable the Google Tasks API in an owned Google Cloud project and create an iOS OAuth client for your build’s bundle ID. Add the public client ID to `Resources/Info.plist` as `StilldayGoogleTasksClientID` and register the reversed client ID under `CFBundleURLTypes` → `CFBundleURLSchemes`. Add test users to the OAuth consent screen if the project is in testing, and rebuild. The app requests `tasks.readonly` from the system browser and uses PKCE. No client secret or backend is required.

Once configured, use Settings → Connections → Google Tasks, choose a connection and tap Connect Google Tasks. Add a named connection for each additional Google account. Calendar Display controls where tasks appear. Google’s API exposes the scheduled day and completion timestamp without the scheduled time of day.

## Linux preview

See [Calendar for Linux](Linux/README.md) for the desktop build and iCloud connection.
