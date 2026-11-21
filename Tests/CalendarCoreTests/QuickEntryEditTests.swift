import CalendarCore
import Foundation
import Testing

struct QuickEntryEditTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        value.locale = Locale(identifier: "en_GB")
        return value
    }
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    var context: EntryContext {
        EntryContext(now: date(11, 18), calendar: calendar, locale: Locale(identifier: "en_GB"), mode: .log)
    }
    var original: EventDraft {
        var value = EventDraft(title: "Original title", start: date(9, 14, 10), end: date(9, 15),
                               timeZoneID: calendar.timeZone.identifier, notes: "Keep my description.\n\n[School]")
        var details = ActivityDetails()
        details.before = ActivityBuffer(minutes: 8, kind: .preparation, label: "Get ready")
        details.link = ActivityLink(id: UUID(uuidString: "6022b313-e00d-4535-9479-741e159c829a")!,
                                   title: value.title, calendars: ["Work", "Home"])
        value.activityDetails = details
        return value
    }

    @Test func mixedClockFormatsWorkAndTitleNumbersStayLiteralWhenTheRangeIsComplete() throws {
        let parser = QuickEntryParser()
        for text in ["14:36 15 workshop", "workshop 14:36 15", "14 15:00 workshop"] {
            let parsed = try parser.parse(text, context: context)
            #expect(parsed.draft.title == "Workshop")
            #expect(parsed.draft.start == date(11, 14, text.hasPrefix("14 15") ? 0 : 36))
            #expect(parsed.draft.end == date(11, 15))
        }
        #expect(try parser.parse("Dune 2 18:00", context: context).draft.title == "Dune 2")
        #expect(try parser.parse("18:00 19:00 Dune 2", context: context).draft.title == "Dune 2")
        #expect(try parser.parse("16:42 do 10 pushups", context: context).draft.title == "Do 10 pushups")
    }

    @Test func editingInterpretsOnlyWrittenFieldsAndKeepsNotesLinksAndExistingPurpose() throws {
        let value = try QuickEntryParser().parseEdit("14:36 15 workshop 11m before 5m after /Fitness", original: original, context: context)
        #expect(value.draft.title == "Workshop")
        #expect(value.draft.start == date(9, 14, 36))
        #expect(value.draft.end == date(9, 15))
        #expect(value.requestedCalendar == "Fitness")
        #expect(value.draft.activityDetails.before == ActivityBuffer(minutes: 11, kind: .preparation, label: "Get ready"))
        #expect(value.draft.activityDetails.after == ActivityBuffer(minutes: 5, kind: .travel, travelMode: .walking))
        #expect(value.draft.activityDetails.link == original.activityDetails.link)
        #expect(EventCategory.description(in: value.draft.notes) == EventCategory.description(in: original.notes))
        #expect(EventCategory.name(in: value.draft.notes) == "School")
    }

    @Test func titleOnlyAndPartialTimingChangesPreserveUnspecifiedFields() throws {
        let parser = QuickEntryParser()
        let title = try parser.parseEdit("renamed event", original: original, context: context)
        var expected = original
        expected.title = "renamed event"
        #expect(title.draft == expected)
        let moved = try parser.parseEdit("14:36 workshop", original: original, context: context)
        #expect(moved.draft.start == date(9, 14, 36))
        #expect(moved.draft.end.timeIntervalSince(moved.draft.start) == original.end.timeIntervalSince(original.start))
        let day = try parser.parseEdit("workshop yesterday", original: original, context: context)
        #expect(day.draft.start == date(10, 14, 10))
        #expect(day.draft.end == date(10, 15))
        let duration = try parser.parseEdit("workshop for 15m", original: original, context: context)
        #expect(duration.draft.start == original.start)
        #expect(duration.draft.end == original.start + 900)
        #expect(duration.draft.notes == original.notes)
        var allDay = original
        allDay.allDay = true
        allDay.start = date(9, 0)
        allDay.end = date(11, 0)
        let shifted = try parser.parseEdit("trip tomorrow", original: allDay, context: context)
        #expect(shifted.draft.allDay)
        #expect(shifted.draft.start == date(12, 0))
        #expect(shifted.draft.end == date(14, 0))
        #expect(throws: EntryError.allDayConflict) {
            try parser.parseEdit("trip for 15m", original: allDay, context: context)
        }
    }

    @Test func editInterpretationsCanBeDismissedAndRecurrenceIsPreserved() throws {
        let parser = QuickEntryParser()
        let input = "14:36 15 workshop"
        let parsed = try parser.parseEdit(input, original: original, context: context)
        var ignored = context
        ignored.ignoredTokens = Set(parsed.tokens.map(\.id))
        let literal = try parser.parseEdit(input, original: original, context: ignored)
        #expect(literal.draft.title == input)
        #expect(literal.draft.start == original.start)
        #expect(literal.draft.end == original.end)
        let allDay = try parser.parseEdit("all day workshop tomorrow", original: original, context: context)
        #expect(allDay.draft.allDay)
        #expect(allDay.draft.start == date(12, 0))
        #expect(allDay.draft.end == date(13, 0))
        #expect(throws: EntryError.recurrenceEdit) {
            try parser.parseEdit("every Friday 17:00 workshop", original: original, context: context)
        }
    }

    @Test func defaultBuffersAreFiveMinutesWalkingAndOlderSettingsRemainReadable() throws {
        #expect(ActivityBufferDefaults().buffer() == ActivityBuffer(minutes: 5, kind: .travel, travelMode: .walking))
        let old = Data(#"{"kind":"Preparation","travelMode":"Unspecified"}"#.utf8)
        let decoded = try JSONDecoder().decode(ActivityBufferDefaults.self, from: old)
        #expect(decoded.minutes == 5)
        #expect(decoded.kind == .preparation)
        let custom = ActivityBufferDefaults(minutes: 12, kind: .travel, travelMode: .train)
        #expect(try JSONDecoder().decode(ActivityBufferDefaults.self, from: JSONEncoder().encode(custom)) == custom)
    }
}
