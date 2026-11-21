import CalendarCore
import Foundation
import Testing

struct QuickEntryTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func date(_ year: Int = 2026, _ month: Int = 11, _ day: Int = 9, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parse(_ input: String, mode: EntryMode = .log, now: Date? = nil, slot: Date? = nil) throws -> ParsedEntry {
        try QuickEntryParser().parse(input, context: EntryContext(
            now: now ?? date(2026, 11, 9, 20, 30), calendar: calendar,
            locale: Locale(identifier: "en_GB"), mode: mode, selectedSlot: slot
        ))
    }

    @Test func retrospectiveExamplesAndExplicitToday() throws {
        for text in ["18:25 19:10 sketching /gaming", "today 18:25 19:10 sketching /gaming"] {
            let parsed = try parse(text)
            #expect(parsed.draft.title == "Sketching")
            #expect(parsed.requestedCalendar == "gaming")
            #expect(parsed.draft.start == date(2026, 11, 9, 18, 25))
            #expect(parsed.draft.end == date(2026, 11, 9, 19, 10))
        }
        #expect(try parse("yesterday 18:25 19:10 gaming").draft.start == date(2026, 11, 8, 18, 25))
        #expect(try parse("today 18:25 sketching", mode: .schedule).draft.start == date(2026, 11, 9, 18, 25))
    }

    @Test func twoTimesCanAppearAnywhereInTheEntry() throws {
        for text in ["design review 18:00 19:00", "18:00 design review 19:00", "design 18:00 review 19:00"] {
            let event = try parse(text).draft
            #expect(event.title == "Design review")
            #expect(event.start == date(2026, 11, 9, 18))
            #expect(event.end == date(2026, 11, 9, 19))
        }

        let overnight = try parse("late shift 23:30 packing 01:15").draft
        #expect(overnight.title == "Late shift packing")
        #expect(overnight.start == date(2026, 11, 9, 23, 30))
        #expect(overnight.end == date(2026, 11, 10, 1, 15))
    }

    @Test func dateWordsWorkAroundTheTitleAndTimes() throws {
        let yesterday = try parse("project review 18:00 yesterday 19:00", mode: .schedule,
                                  slot: date(2026, 11, 12, 7)).draft
        #expect(yesterday.title == "Project review")
        #expect(yesterday.start == date(2026, 11, 8, 18))
        #expect(yesterday.end == date(2026, 11, 8, 19))

        for word in ["tomorrow", "tommorow", "tomorow"] {
            let tomorrow = try parse("project review 18:00 19:00 \(word)").draft
            #expect(tomorrow.start == date(2026, 11, 10, 18))
            #expect(tomorrow.end == date(2026, 11, 10, 19))
        }

        let appointment = try parse("Appointment on 2026-11-12 at 5:15pm for 45m /Personal Time")
        #expect(appointment.draft.title == "Appointment")
        #expect(appointment.draft.start == date(2026, 11, 12, 17, 15))
        #expect(appointment.draft.end == date(2026, 11, 12, 18))
        #expect(appointment.requestedCalendar == "Personal Time")
    }

    @Test func naturalRangeConnectorsAndBareTitleNumbers() throws {
        for text in ["Dune 2 from 6pm to 7pm", "Dune 2 between 6pm and 7pm",
                     "Dune 2 18:00–19:00", "18:00 Dune 2 until 19:00"] {
            let event = try parse(text).draft
            #expect(event.title == "Dune 2")
            #expect(event.start == date(2026, 11, 9, 18))
            #expect(event.end == date(2026, 11, 9, 19))
        }
        #expect(try parse("Studio 54: the story").draft.title == "Studio 54: the story")
    }

    @Test func theLastSlashSelectsTheCalendarAndEarlierSlashesStayInTheTitle() throws {
        let parsed = try parse("10:10 10:40 Review sample report / send feedback /work")
        #expect(parsed.draft.title == "Review sample report / send feedback")
        #expect(parsed.draft.start == date(2026, 11, 9, 10, 10))
        #expect(parsed.draft.end == date(2026, 11, 9, 10, 40))
        #expect(parsed.requestedCalendar == "work")

        let qualified = try parse("9:20 9:35 Testing / messaging /Work · iCloud")
        #expect(qualified.draft.title == "Testing / messaging")
        #expect(qualified.requestedCalendar == "Work · iCloud")
        #expect(try parse("dinner 18:00 / Work Projects").requestedCalendar == "Work Projects")
        #expect(try parse("dinner 18:00 /Work/Projects").requestedCalendar == "Work/Projects")
        let multiple = try parse("18:00 dinner /Home /Work")
        #expect(multiple.draft.title == "Dinner /Home")
        #expect(multiple.requestedCalendar == "Work")
    }

    @Test func scheduleModeAndDuration() throws {
        #expect(try parse("18:00 dinner").draft.start == date(2026, 11, 9, 18))
        #expect(try parse("18:00 dinner", mode: .schedule).draft.start == date(2026, 11, 10, 18))
        let workshop = try parse("tomorrow 17:00 workshop").draft
        #expect(workshop.start == date(2026, 11, 10, 17))
        #expect(workshop.end == date(2026, 11, 10, 18))
        let appointment = try parse("5:15pm appointment for 45m /Personal Time")
        #expect(appointment.draft.end.timeIntervalSince(appointment.draft.start) == 2700)
        #expect(appointment.requestedCalendar == "Personal Time")
    }

    @Test func overnightAndWeeklyRecurrence() throws {
        let night = try parse("23:00 01:00 work").draft
        #expect(night.end == date(2026, 11, 10, 1))
        let boxing = try parse("every Tuesday 19:00 boxing").draft
        #expect(boxing.repetition == .weekly)
        #expect(boxing.start == date(2026, 11, 10, 19))
        #expect(try parse("every Monday 6pm-7pm class").draft.start == date(2026, 11, 16, 18))
        #expect(try parse("next Mon 8am Coffee").draft.start == date(2026, 11, 16, 8))
    }

    @Test func selectedSlotAndAllDay() throws {
        let slot = date(2026, 11, 12, 7)
        let slotEntry = try parse("Breakfast", slot: slot)
        #expect(slotEntry.draft.start == slot)
        #expect(slotEntry.notice != nil)
        #expect(try parse("today 07:00 Breakfast", slot: slot).draft.start == date(2026, 11, 9, 7))
        let holiday = try parse("2026-03-29 all day Holiday").draft
        #expect(holiday.allDay)
        #expect(holiday.end.timeIntervalSince(holiday.start) == 23 * 3600)
        #expect(holiday.timeZoneID == nil)
        #expect(try parse("G").draft.title == "G")
    }

    @Test func daylightSavingAndTimeZones() throws {
        #expect(throws: EntryError.ambiguousTime) { try parse("2026-03-29 01:30 Gap") }
        #expect(throws: EntryError.ambiguousTime) { try parse("2026-10-25 01:30 Repeated") }
        let event = try parse("2026-10-25 01:30 call @UTC /Work")
        #expect(event.draft.start == date(2026, 10, 25, 1, 30).addingTimeInterval(3600))
        #expect(event.draft.timeZoneID == "GMT" || event.draft.timeZoneID == "UTC")
        let remote = try parse("today 18:30 Call @America/New_York").draft
        #expect(remote.start == date(2026, 11, 9, 23, 30))
        #expect(remote.timeZoneID == "America/New_York")
    }

    @Test func invalidInputKeepsSaveBlocked() {
        #expect(throws: EntryError.invalidRange) { try parse("18:00 18:00 dinner") }
        #expect(throws: EntryError.tooManyTimes) { try parse("18:00 dinner 19:00 20:00") }
        #expect(throws: EntryError.invalidDate) { try parse("dinner today 18:00 tomorrow") }
        #expect(throws: EntryError.invalidTime) { try parse("dinner 18:1") }
        #expect(throws: EntryError.invalidTime) { try parse("18:00- dinner") }
        #expect(throws: EntryError.invalidRange) { try parse("18:00 19:00 dinner for 45m") }
        #expect(throws: EntryError.invalidTime) { try parse("25:11 dinner") }
        #expect(throws: EntryError.invalidTime) { try parse("18:1 dinner") }
        #expect(throws: EntryError.invalidDate) { try parse("2026-02-31 Holiday") }
        #expect(throws: EntryError.invalidDuration) { try parse("18:00 dinner for 0m") }
        #expect(throws: EntryError.invalidCalendar) { try parse("18:00 dinner /") }
        #expect(throws: EntryError.invalidZone) { try parse("18:00 dinner @Neverland") }
        #expect(throws: EntryError.unsupportedRecurrence) { try parse("every second Tuesday 19:00 boxing") }
    }
}
