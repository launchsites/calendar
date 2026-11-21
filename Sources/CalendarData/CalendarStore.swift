import CalendarCore
import Foundation

public enum CalendarAccess: Equatable, Sendable {
    case unknown, writeOnly, denied, restricted, full
}

public struct CalendarColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct CalendarListItem: Identifiable, Equatable, Sendable {
    public var id: String { choice.id }
    public let choice: CalendarChoice
    public let color: CalendarColor

    public init(choice: CalendarChoice, color: CalendarColor) {
        self.choice = choice
        self.color = color
    }
}

public struct EventIdentity: Hashable, Sendable {
    public let identifier: String
    public let start: Date
    public let occurrence: Date?
    public let calendarID: String

    public init(identifier: String, start: Date, occurrence: Date?, calendarID: String) {
        self.identifier = identifier
        self.start = start
        self.occurrence = occurrence
        self.calendarID = calendarID
    }

    public var layoutID: String {
        "\(identifier):\(calendarID):\(start.timeIntervalSinceReferenceDate):\(occurrence?.timeIntervalSinceReferenceDate ?? 0)"
    }
}

public struct CalendarEvent: Identifiable, Equatable, Sendable {
    public let id: EventIdentity
    public let title: String
    public let end: Date
    public let isAllDay: Bool
    public let timeZoneID: String?
    public let modified: Date?
    public let isRecurring: Bool
    public let calendar: CalendarListItem
    public let notes: String?
    public let linkedCalendars: [CalendarListItem]
    public let activityDetails: ActivityDetails

    public var start: Date { id.start }
    public var displayTitle: String { title.isEmpty ? "Untitled event" : title }
    public var draft: EventDraft {
        EventDraft(title: title, start: start, end: end, allDay: isAllDay, timeZoneID: timeZoneID, notes: notes)
    }

    public init(id: EventIdentity, title: String, end: Date, isAllDay: Bool, timeZoneID: String?,
                modified: Date?, isRecurring: Bool, calendar: CalendarListItem, notes: String? = nil,
                linkedCalendars: [CalendarListItem] = []) {
        self.id = id
        self.title = title
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID
        self.modified = modified
        self.isRecurring = isRecurring
        self.calendar = calendar
        self.notes = notes
        self.linkedCalendars = linkedCalendars
        activityDetails = ActivityDetails.read(from: notes)
    }

    public var occupiedStart: Date {
        start.addingTimeInterval(isAllDay ? 0 : -Double(activityDetails.before?.minutes ?? 0) * 60)
    }
    public var occupiedEnd: Date {
        end.addingTimeInterval(isAllDay ? 0 : Double(activityDetails.after?.minutes ?? 0) * 60)
    }

    public func showingCalendars(_ calendars: [CalendarListItem]) -> CalendarEvent {
        CalendarEvent(id: id, title: title, end: end, isAllDay: isAllDay, timeZoneID: timeZoneID,
                      modified: modified, isRecurring: isRecurring, calendar: calendar, notes: notes,
                      linkedCalendars: calendars)
    }
}

public struct CalendarSnapshot: Sendable {
    public var access: CalendarAccess
    public var calendars: [CalendarListItem]
    public var systemDefaultID: String?
    public var events: [CalendarEvent]
    public var fetchMilliseconds: Double

    public init(access: CalendarAccess, calendars: [CalendarListItem] = [], systemDefaultID: String? = nil,
                events: [CalendarEvent] = [], fetchMilliseconds: Double = 0) {
        self.access = access
        self.calendars = calendars
        self.systemDefaultID = systemDefaultID
        self.events = events
        self.fetchMilliseconds = fetchMilliseconds
    }
}

public enum MutationScope: String, CaseIterable, Identifiable, Sendable {
    case occurrence = "This event"
    case future = "This and future events"
    public var id: Self { self }
}

public enum CalendarStoreError: LocalizedError, Equatable, Sendable {
    case access, missingCalendar, readOnly, missingEvent, eventChanged, invalidEvent, permissionRequest, writeFailed
    case linkedEventChanged, duplicateLinkedCalendar

    public var errorDescription: String? {
        switch self {
        case .access: "Allow full calendar access in system settings to continue."
        case .missingCalendar: "The selected calendar is unavailable. Choose another calendar."
        case .readOnly: "This calendar is read-only. Choose a writable calendar."
        case .missingEvent: "This event was moved or removed. Close this sheet and check the calendar."
        case .eventChanged: "This event changed since you opened it. Reopen the event to review the latest details."
        case .invalidEvent: "Enter a title and an end time after the start."
        case .permissionRequest: "Calendar access couldn’t be requested. Try again or check system settings."
        case .linkedEventChanged: "A linked copy changed or is unavailable. Review the copies, or choose to edit this copy separately."
        case .duplicateLinkedCalendar: "Each linked copy needs a different calendar."
        case .writeFailed: "The device calendar couldn’t apply this change. Check the calendar and try again."
        }
    }
}

public protocol CalendarStore: Sendable {
    func requestAccess() async throws
    func snapshot(in window: DateInterval, hidden: Set<String>) async throws -> CalendarSnapshot
    func calendarUsage(in window: DateInterval) async -> CalendarUsage?
    func create(_ draft: EventDraft, calendarID: String, requestID: UUID) async throws
    func update(_ event: CalendarEvent, with draft: EventDraft, calendarID: String, scope: MutationScope) async throws
    func delete(_ event: CalendarEvent, scope: MutationScope) async throws
}

#if os(macOS)
public protocol CalendarEditHistoryStore: CalendarStore {
    func replayCalendarEdit(redo: Bool) async throws -> Bool
}
#endif

public protocol LinkedCalendarStore: CalendarStore {
    func create(_ draft: EventDraft, calendarIDs: [String], requestID: UUID) async throws
    func updateLinked(_ original: CalendarEvent, with draft: EventDraft, calendarID: String,
                      scope: MutationScope, allCopies: Bool) async throws
    func deleteLinked(_ original: CalendarEvent, scope: MutationScope, allCopies: Bool) async throws
}

/// Presentation groups exact copies. A conflicting copy remains visible for review.
public enum LinkedActivities {
    private struct Key: Hashable {
        let id: UUID
        let start: Date
    }

    public static func presented(_ events: [CalendarEvent], calendarOrder: [String]) -> [CalendarEvent] {
        let ranks = Dictionary(calendarOrder.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: min)
        let grouped = Dictionary(grouping: events.filter { $0.activityDetails.link != nil }) {
            Key(id: $0.activityDetails.link!.id, start: $0.start)
        }
        var emitted: Set<Key> = []
        return events.compactMap { event in
            guard let link = event.activityDetails.link else { return event }
            let key = Key(id: link.id, start: event.start)
            let peers = grouped[key] ?? [event]
            guard peers.allSatisfy({ $0.draft == event.draft && $0.isRecurring == event.isRecurring }),
                  Set(peers.map(\.calendar.id)).count == peers.count else { return event }
            guard emitted.insert(key).inserted else { return nil }
            let ordered = peers.sorted {
                let left = ranks[$0.calendar.id] ?? .max
                let right = ranks[$1.calendar.id] ?? .max
                return left == right ? $0.calendar.id < $1.calendar.id : left < right
            }
            return ordered[0].showingCalendars(ordered.map(\.calendar))
        }
    }
}
