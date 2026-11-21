import CalendarCore
@testable import CalendarData
import Foundation
import Testing

struct LinkedActivitiesTests {
    @Test func exactLinkedCopiesMergeInProfileOrderAndDivergentCopiesStayVisible() {
        let first = event(calendar: "fitness")
        let second = event(calendar: "shared")
        let merged = LinkedActivities.presented([first, second], calendarOrder: ["shared", "fitness"])
        #expect(merged.count == 1)
        #expect(merged[0].calendar.id == "shared")
        #expect(merged[0].linkedCalendars.map(\.id) == ["shared", "fitness"])
        #expect(LinkedActivities.presented([first], calendarOrder: []).count == 1)
        let different = event(calendar: "shared", title: "Changed elsewhere")
        #expect(LinkedActivities.presented([first, different], calendarOrder: []).count == 2)
        let tomorrow = event(calendar: "shared", offset: 86_400)
        #expect(LinkedActivities.presented([first, tomorrow], calendarOrder: []).count == 2)
    }

    #if os(macOS)
    @Test func linkedCreationUndoAndRedoKeepBothCopiesInOneHistoryStep() throws {
        var history = CalendarEditHistory()
        let first = event(calendar: "fitness")
        let second = event(calendar: "shared")
        history.recordBatch([(nil, first), (nil, second)])
        let undo = try #require(history.next(redo: false))
        #expect(undo.expected == first)
        #expect(undo.peers.first?.expected == second)
        history.finishBatch(undo, results: [nil, nil], redo: false)
        #expect(history.next(redo: false) == nil)
        let redo = try #require(history.next(redo: true))
        #expect(redo.destination == first)
        #expect(redo.peers.first?.destination == second)
        history.finishBatch(redo, results: [first, second], redo: true)
        #expect(history.next(redo: true) == nil)
        #expect(history.next(redo: false)?.peers.count == 1)
    }
    #endif

    #if os(macOS)
    @Test func undoingALinkedMoveRebindsBothCopiesBeforeUndoingCreation() throws {
        var history = CalendarEditHistory()
        let first = event(calendar: "fitness")
        let second = event(calendar: "shared")
        history.recordBatch([(nil, first), (nil, second)])
        let movedFirst = event(calendar: "fitness", offset: 900)
        let movedSecond = event(calendar: "shared", offset: 900)
        history.recordBatch([(first, movedFirst), (second, movedSecond)])
        let move = try #require(history.next(redo: false))
        history.finishBatch(move, results: [first, second], redo: false)
        let creation = try #require(history.next(redo: false))
        #expect(creation.expected == first)
        #expect(creation.peers.first?.expected == second)
        history.finishBatch(creation, results: [nil, nil], redo: false)
        let redo = try #require(history.next(redo: true))
        history.finishBatch(redo, results: [first, second], redo: true)
        let redoMove = try #require(history.next(redo: true))
        #expect(redoMove.expected == first)
        #expect(redoMove.peers.first?.expected == second)
        #expect(redoMove.destination == movedFirst)
    }
    #endif

    private func event(calendar id: String, title: String = "Run", offset: TimeInterval = 0) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_800_000_000 + offset)
        let calendar = CalendarListItem(choice: .init(id: id, title: id, source: "Fixture", isWritable: true),
                                        color: .init(red: 0.3, green: 0.5, blue: 0.8))
        var details = ActivityDetails()
        details.link = ActivityLink(id: UUID(uuidString: "6022b313-e00d-4535-9479-741e159c829a")!,
                                    title: "Run", calendars: ["fitness", "shared"])
        details.before = ActivityBuffer(minutes: 10)
        return CalendarEvent(id: .init(identifier: id, start: start, occurrence: nil, calendarID: id),
                             title: title, end: start + 3600, isAllDay: false, timeZoneID: "GMT",
                             modified: nil, isRecurring: false, calendar: calendar,
                             notes: details.notes(description: "User notes"))
    }
}
