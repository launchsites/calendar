# Architecture

- **CalendarCore** contains portable parsing, date windows, calendar prediction, preferences, and interval layout. The clock and calendar are explicit parser inputs.
- **CalendarData** defines the injectable store protocol and immutable snapshots. An actor owns the production EventKit store. SwiftUI receives value types only.
- **Stillday** owns UI state on the main actor. Visible range tasks are cancelled as navigation changes, and responses are checked against the current query before publishing. An EventKit synchronous query already in progress can finish on the store actor. Store notifications are coalesced, and the active window refreshes when the app returns to the foreground.
- **Quick Entry shortcut** uses the same SwiftUI form and preview. Xcode builds register its App Intents metadata.

Mutations resolve the event through a short predicate around its original displayed start, then check identifier, calendar, occurrence date and the snapshot fields. This avoids using a series identifier to mutate an arbitrary occurrence. Existing EventKit properties remain on the re-fetched event. The editor applies only changed fields. A date or ID change prompts a reload. The create sheet blocks simultaneous saves and the actor remembers recent completed request IDs for in-process replay protection.

Full access is requested before event queries. Calendar identifiers can change as accounts are updated. A missing explicit or preferred destination requires a new selection. A query is limited to one Day, Week or visible Month grid. The app reports whether EventKit accepted a local write. Provider sync and conflict resolution remain with the OS and calendar accounts.

## Settings format

Display and entry preferences are stored in local UserDefaults. The portable JSON schema has version 1 and fields `appearance`, `weekStart`, `timeFormat`, `defaultMode`, `defaultDuration`, `pointsPerHour`, and `minimumEventHeight`. An optional `accentColor` stores sRGB red, green and blue bytes. The optional `timelineLayout` selects Stacked or Columns. Older settings files use the system accent and the Stacked layout. Optional highlight display switches are portable. Calendar-specific visibility and category names stay local. Import validates the version and numeric bounds before confirmation. Calendar IDs, visibility, aliases, title rules and calendar data stay on the device. There are no app credentials or telemetry.

## Apple API references

- [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)
- [Retrieving events and reminders](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders)
- [Updating with notifications](https://developer.apple.com/documentation/eventkit/updating-with-notifications)
- [App Intent supported modes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)

## Linux desktop

The Linux Swift package builds a small JSON bridge to the shared parser, activity metadata and layout engine. The Qt desktop client uses this bridge and queries iCloud over CalDAV on worker threads. It applies changes with HTTP preconditions and uses the system keyring for remembered credentials. The Apple targets continue to use EventKit.
