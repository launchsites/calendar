#if os(macOS)
import CalendarCore
import Foundation
@testable import Stillday
import Testing

struct DesktopEventDragTests {
    @Test func relativeStepsPreserveTheExistingMinuteOffset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 19, minute: 53)))
        let original = DateInterval(start: start, duration: 45 * 60)
        let earlier = DesktopEventDragPart.move.adjust(original, seconds: -900, stepMinutes: 15, calendar: calendar)
        #expect(calendar.component(.minute, from: earlier.start) == 38)
        #expect(earlier.duration == original.duration)
        let extended = DesktopEventDragPart.end.adjust(original, seconds: 30 * 60, stepMinutes: 30, calendar: calendar)
        #expect(extended.start == original.start)
        #expect(extended.end == original.end + 30 * 60)
    }

    @Test func resizingKeepsTheOppositeEdgeAndClampsToAValidStep() {
        let original = DateInterval(start: Date(timeIntervalSince1970: 1_800_000_000), duration: 31 * 60)
        let start = DesktopEventDragPart.start.adjust(original, seconds: 3600, stepMinutes: 15, calendar: .current)
        #expect(start.start == original.start + 30 * 60)
        #expect(start.end == original.end)
        let end = DesktopEventDragPart.end.adjust(original, seconds: -3600, stepMinutes: 15, calendar: .current)
        #expect(end.start == original.start)
        #expect(end.end == original.end - 30 * 60)
    }

    @Test func movingToAnotherDayPreservesLocalStartAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Lisbon"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 19, minute: 53)))
        let original = DateInterval(start: date, duration: 60 * 60)
        let moved = DesktopEventDragPart.move.adjust(original, seconds: 0, days: 1, stepMinutes: 15, calendar: calendar)
        #expect(calendar.component(.hour, from: moved.start) == 19)
        #expect(calendar.component(.minute, from: moved.start) == 53)
        #expect(moved.start.timeIntervalSince(original.start) == 23 * 3600)
        #expect(moved.duration == original.duration)
    }
}
#endif
