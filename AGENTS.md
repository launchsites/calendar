# Working on Stillday

- Start with the product rules in PRODUCT.md and keep TASKS.md accurate.
- Use EventKit as the source of truth and the CalendarStore boundary for tests. Keep EventKit objects inside the store actor.
- Keep parsing and layout deterministic. Write tests with a fixed date, locale and time zone.
- Run Scripts/test-mac and Scripts/build-mac-app on this Mac. Use the shared Stillday scheme for simulator verification when full Xcode is available.
- Use disposable fixture calendars for mutation tests. Keep personal event data and account credentials out of diagnostics and commits.
- Preserve event properties the editor does not expose. Require explicit confirmation for deletion and explicit calendar selection when destination resolution is ambiguous.
