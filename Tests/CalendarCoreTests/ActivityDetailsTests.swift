import CalendarCore
import Foundation
import Testing

struct ActivityDetailsTests {
    @Test func readableDetailsRoundTripWithoutChangingDescriptionOrCategory() throws {
        let description = "Keep [this] note.\nSecond paragraph.\n"
        var details = ActivityDetails()
        details.before = ActivityBuffer(minutes: 10, kind: .travel, label: "Walk [workshop]", travelMode: .walking)
        details.after = ActivityBuffer(minutes: 15, kind: .recovery, label: "Shower")
        details.display = .background
        details.link = ActivityLink(id: UUID(uuidString: "6022b313-e00d-4535-9479-741e159c829a")!,
                                    title: "Workshop", calendars: ["Fitness | Training [Home] · Fixture", "Shared · Fixture"])
        details.unknownLines = ["[Future option: preserve me]"]
        let notes = details.notes(description: EventCategory.notes(description: description, category: "Fitness"))
        #expect(ActivityDetails.read(from: notes) == details)
        #expect(EventCategory.name(in: notes) == "Fitness")
        #expect(EventCategory.description(in: notes) == description)
        let changedCategory = EventCategory.notes(description: notes, category: "Training")
        #expect(ActivityDetails.read(from: changedCategory) == details)
        #expect(changedCategory?.contains("[Before: 10 minutes]") == true)
        #expect(notes?.contains("[Link ID:") == true)
    }

    @Test func malformedOrFutureFootersRemainVisible() {
        for notes in [
            "Description\n[Calendar details v2]\n[New: value]\n[End calendar details]",
            "Description\n[Calendar details v1]\n[Before: invalid]\n[End calendar details]",
            "Description\n[Calendar details v1]\n[Before: 10 minutes]\n[Before: 12 minutes]\n[End calendar details]"
        ] {
            #expect(ActivityDetails.description(in: notes) == notes)
            #expect(ActivityDetails.read(from: notes) == ActivityDetails())
            #expect(EventCategory.name(in: notes) == nil)
        }
    }

    @Test func bareTimesAndBufferInterpretationsCanBeDismissed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 15))!
        var context = EntryContext(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"), mode: .log)
        let input = "workshop 10 11 before 10m after 15m /Fitness"
        let parsed = try QuickEntryParser().parse(input, context: context)
        #expect(parsed.draft.title == "Workshop")
        #expect(calendar.component(.hour, from: parsed.draft.start) == 10)
        #expect(calendar.component(.hour, from: parsed.draft.end) == 11)
        #expect(parsed.draft.activityDetails.before?.minutes == 10)
        #expect(parsed.draft.activityDetails.after?.minutes == 15)
        #expect(parsed.tokens.count == 4)
        context.ignoredTokens = Set(parsed.tokens.map(\.id))
        let dismissed = try QuickEntryParser().parse(input, context: context)
        #expect(dismissed.draft.title == "Workshop 10 11 before 10m after 15m")
        #expect(dismissed.draft.activityDetails == ActivityDetails())
        #expect(dismissed.tokens.isEmpty)
        #expect(dismissed.draft.start == now)
        let quantity = try QuickEntryParser().parse("10 pushups", context: context)
        #expect(quantity.draft.title == "10 pushups")
        let ignored = context.ignoredTokens
        context.ignoredTokens = []
        let single = try QuickEntryParser().parse("workshop 10", context: context)
        #expect(single.draft.title == "Workshop")
        #expect(calendar.component(.hour, from: single.draft.start) == 10)
        context.ignoredTokens = ignored
        let changed = try QuickEntryParser().parse("long workshop 10 11 before 10m after 15m /Fitness", context: context)
        #expect(changed.tokens.isEmpty)
        #expect(changed.draft.title == "Long workshop 10 11 before 10m after 15m")
    }

    @Test func beforeAndAfterAcceptEitherWordOrderWithoutCrossingClauses() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 18))!
        var context = EntryContext(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"), mode: .log)
        for suffix in ["11m before 5m after", "before 11m after 5m", "11 minutes before after 5 minutes",
                       "before 11 minutes 5 minutes after", "5m after 11m before", "11 MIN BEFORE 5 MIN AFTER"] {
            let parsed = try QuickEntryParser().parse("15:25 15:30 Equipment check " + suffix, context: context)
            #expect(parsed.draft.title == "Equipment check")
            #expect(calendar.component(.hour, from: parsed.draft.start) == 15)
            #expect(calendar.component(.minute, from: parsed.draft.start) == 25)
            #expect(parsed.draft.end.timeIntervalSince(parsed.draft.start) == 300)
            #expect(parsed.draft.activityDetails.before?.minutes == 11)
            #expect(parsed.draft.activityDetails.after?.minutes == 5)
            #expect(parsed.tokens.count == 4)
        }
        let input = "workshop 10 11 5m before 7m after"
        let parsed = try QuickEntryParser().parse(input, context: context)
        context.ignoredTokens = Set(parsed.tokens.filter { $0.id.hasPrefix("buffer:") }.map(\.id))
        let ignored = try QuickEntryParser().parse(input, context: context)
        #expect(ignored.draft.title == "Workshop 5m before 7m after")
        #expect(ignored.draft.activityDetails == ActivityDetails())
        context.ignoredTokens = []
        let hours = try QuickEntryParser().parse("workshop 10 11 1h before 2h after", context: context)
        #expect(hours.draft.activityDetails.before?.minutes == 60)
        #expect(hours.draft.activityDetails.after?.minutes == 120)
        for input in ["workshop 10 11 0m before", "workshop 10 11 25h after", "workshop 10 11 5m before before 10m"] {
            #expect(throws: EntryError.invalidDuration) { try QuickEntryParser().parse(input, context: context) }
        }
    }

    @Test func quickEntryUsesIndependentActivityDefaultsOnlyWhenAddingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 18))!
        let context = EntryContext(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"), mode: .log,
            beforeActivity: ActivityBufferDefaults(kind: .travel, travelMode: .walking),
            afterActivity: ActivityBufferDefaults(kind: .recovery))
        for suffix in ["11m before 5m after", "before 11m after 5m"] {
            let parsed = try QuickEntryParser().parse("15:25 15:30 Equipment check " + suffix, context: context)
            #expect(parsed.draft.activityDetails.before == ActivityBuffer(minutes: 11, kind: .travel, travelMode: .walking))
            #expect(parsed.draft.activityDetails.after == ActivityBuffer(minutes: 5, kind: .recovery))
        }
        let ordinary = try QuickEntryParser().parse("workshop 10 11", context: context)
        #expect(ordinary.draft.activityDetails.before == nil)
        #expect(ordinary.draft.activityDetails.after == nil)
    }

    @Test func theActivityRemainsReadableInsideItsExtensions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let range = CalendarViewMode.day.window(for: day, calendar: calendar)
        let start = range.start + 10 * 3600
        let intervals = [TimedInterval(id: "workshop", start: start - 600, end: start + 5 * 60 + 900)]
        let buffers = [TimedInterval(id: "before", start: start - 600, end: start),
                       TimedInterval(id: "after", start: start + 300, end: start + 1200)]
        let timeline = EventLayoutEngine.dayTimeline(for: intervals, in: range, calendar: calendar,
            pointsPerHour: 76, minimumHeight: 44, layout: .stacked,
            readableIntervals: [TimedInterval(id: "workshop", start: start, end: start + 300)],
            bufferIntervals: buffers)
        let activityHeight = (timeline.offset(for: start + 300) ?? 0) - (timeline.offset(for: start) ?? 0)
        #expect(activityHeight >= 44)
        for buffer in buffers {
            #expect((timeline.offset(for: buffer.end) ?? 0) - (timeline.offset(for: buffer.start) ?? 0) >= 26)
        }
        #expect(timeline.positions.count == 1)
        #expect(timeline.positions[0].height > activityHeight)
    }
}
