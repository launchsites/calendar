import CalendarCore
@testable import CalendarData
import EventKit
import Foundation
import Testing

struct EventKitGuardTests {
    @Test func unavailablePermissionPreventsCalendarQueriesAndWrites() async throws {
        // This test never requests permission or touches an existing calendar.
        guard EKEventStore.authorizationStatus(for: .event) != .fullAccess else { return }
        let store = EventKitCalendarStore()
        let now = Date()
        let result = try await store.snapshot(in: DateInterval(start: now, duration: 3600), hidden: [])
        #expect(result.access != .full)
        #expect(result.events.isEmpty)
        #expect(result.calendars.isEmpty)
        let draft = EventDraft(title: "Fixture", start: now, end: now.addingTimeInterval(1800))
        await #expect(throws: CalendarStoreError.access) {
            try await store.create(draft, calendarID: "unconfigured", requestID: UUID())
        }
        await #expect(throws: CalendarStoreError.access) {
            try await store.create(draft, calendarIDs: ["unconfigured", "another"], requestID: UUID())
        }
    }
}

#if os(macOS)
struct CalendarEditHistoryTests {
    @Test func undoAndRedoRebindEditsAfterAnEventIsRecreated() throws {
        var history = CalendarEditHistory()
        let initial = event(id: "original", minute: 53, version: 1)
        let moved = event(id: "original", minute: 38, version: 2)
        history.record(from: nil, to: initial)
        history.record(from: initial, to: moved)

        let undoMove = try #require(history.next(redo: false))
        #expect(undoMove.expected == moved)
        #expect(undoMove.destination == initial)
        let restored = event(id: "original", minute: 53, version: 3)
        history.finish(undoMove, result: restored, redo: false)

        let undoCreation = try #require(history.next(redo: false))
        #expect(undoCreation.expected == restored)
        #expect(undoCreation.destination == nil)
        history.finish(undoCreation, result: nil, redo: false)

        let redoCreation = try #require(history.next(redo: true))
        #expect(redoCreation.expected == nil)
        #expect(redoCreation.destination == restored)
        let recreated = event(id: "new-identifier", minute: 53, version: 4)
        history.finish(redoCreation, result: recreated, redo: true)

        let redoMove = try #require(history.next(redo: true))
        #expect(redoMove.expected == recreated)
        #expect(redoMove.destination == moved)
    }

    private func event(id: String, minute: Int, version: Int) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: TimeInterval(minute * 60))
        let calendar = CalendarListItem(choice: CalendarChoice(id: "fixture", title: "Fixture", source: "Test", isWritable: true),
                                        color: CalendarColor(red: 0.2, green: 0.4, blue: 0.6))
        return CalendarEvent(id: EventIdentity(identifier: id, start: start, occurrence: nil, calendarID: calendar.id),
                             title: "Fixture", end: start + 3600, isAllDay: false, timeZoneID: nil,
                             modified: Date(timeIntervalSince1970: TimeInterval(version)), isRecurring: false, calendar: calendar)
    }
}
#endif
