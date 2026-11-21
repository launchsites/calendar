import CalendarCore
import CoreGraphics
import EventKit
import Foundation

public actor EventKitCalendarStore: LinkedCalendarStore {
    // Access and use the store only through this actor. EKObjects never leave it.
    private lazy var store = EKEventStore()
    private var completedCreates: [UUID] = []
    private var permissionRequestInFlight = false
    #if os(macOS)
    private var editHistory = CalendarEditHistory()
    #endif

    public init() {}

    public func requestAccess() async throws {
        guard access == .unknown || access == .writeOnly else { return }
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true
        defer { permissionRequestInFlight = false }
        do {
            let _: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestFullAccessToEvents { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        } catch {
            throw CalendarStoreError.permissionRequest
        }
    }

    public func snapshot(in window: DateInterval, hidden: Set<String>) throws -> CalendarSnapshot {
        try Task.checkCancellation()
        let access = self.access
        guard access == .full else { return CalendarSnapshot(access: access) }
        let started = ProcessInfo.processInfo.systemUptime
        let calendars = store.calendars(for: .event)
        let items = calendars.map(Self.listItem).sorted {
            $0.choice.qualifiedTitle.localizedStandardCompare($1.choice.qualifiedTitle) == .orderedAscending
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let visible = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: window.start.addingTimeInterval(-86_400),
                                                 end: window.end.addingTimeInterval(86_400), calendars: visible)
        let results = visible.isEmpty ? [] : store.events(matching: predicate)
        try Task.checkCancellation()

        var eventsByID: [EventIdentity: CalendarEvent] = [:]
        for event in results {
            guard let id = event.calendar?.calendarIdentifier, let calendar = byID[id],
                  let value = Self.snapshot(event, calendar: calendar),
                  value.occupiedStart < window.end,
                  value.occupiedEnd > window.start || value.occupiedStart >= window.start else { continue }
            eventsByID[value.id] = value
        }
        let events = eventsByID.values.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id.layoutID < $1.id.layoutID
        }
        return CalendarSnapshot(access: access, calendars: items,
                                systemDefaultID: store.defaultCalendarForNewEvents?.calendarIdentifier,
                                events: events, fetchMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    public func calendarUsage(in window: DateInterval) -> CalendarUsage? {
        guard access == .full else { return nil }
        let calendars = store.calendars(for: .event).filter(\.allowsContentModifications)
        var usage = CalendarUsage()
        guard !calendars.isEmpty else { return usage }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        var seen: Set<String> = []
        let observations = store.events(matching: predicate).compactMap { event -> (Date, String, String)? in
            guard !event.hasRecurrenceRules, !event.isDetached, event.status != .canceled,
                  let start = event.startDate, start >= window.start, start < window.end,
                  let title = event.title, let calendarID = event.calendar?.calendarIdentifier,
                  seen.insert(event.calendarItemIdentifier).inserted else { return nil }
            return (start, title, calendarID)
        }
        for (_, title, calendarID) in observations.sorted(by: { $0.0 < $1.0 }) {
            usage.record(title: title, calendarID: calendarID)
        }
        return usage
    }

    public func create(_ draft: EventDraft, calendarID: String, requestID: UUID) throws {
        if completedCreates.contains(requestID) { return }
        let event = try saveNewEvent(draft, calendarID: calendarID)
        completedCreates.append(requestID)
        if completedCreates.count > 64 { completedCreates.removeFirst() }
        #if os(macOS)
        editHistory.discardRedo()
        if !event.hasRecurrenceRules, let saved = savedSnapshot(event) {
            editHistory.record(from: nil, to: saved)
        }
        #endif
    }

    private func saveNewEvent(_ draft: EventDraft, calendarID: String) throws -> EKEvent {
        let event = try preparedEvent(draft, calendarID: calendarID)
        try write { try store.save(event, span: .thisEvent, commit: true) }
        return event
    }

    private func preparedEvent(_ draft: EventDraft, calendarID: String) throws -> EKEvent {
        try requireAccess()
        try validate(draft)
        let calendar = try writableCalendar(calendarID)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        if let notes = draft.notes { event.notes = notes }
        event.isAllDay = draft.allDay
        event.startDate = draft.start
        event.endDate = draft.end
        if !draft.allDay, let zone = draft.timeZoneID {
            event.timeZone = TimeZone(identifier: zone)
        }
        if draft.repetition == .weekly {
            event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)]
        }
        return event
    }

    public func update(_ original: CalendarEvent, with draft: EventDraft, calendarID: String,
                       scope: MutationScope) throws {
        if original.activityDetails.link != nil {
            try updateLinked(original, with: draft, calendarID: calendarID, scope: scope, allCopies: true)
            return
        }
        guard let savedEvent = try saveChanges(original, with: draft, calendarID: calendarID, scope: scope)
        else { return }
        #if os(macOS)
        editHistory.discardRedo()
        if !original.isRecurring, let saved = savedSnapshot(savedEvent) {
            editHistory.record(from: original, to: saved)
        }
        #endif
    }

    private func saveChanges(_ original: CalendarEvent, with draft: EventDraft, calendarID: String,
                             scope: MutationScope, restoring: Bool = false) throws -> EKEvent? {
        try requireAccess()
        try validate(draft, preservingTitle: restoring ? draft.title : original.title)
        let event = try unchangedEvent(original)
        _ = try writableCalendar(original.id.calendarID)
        if calendarID != original.id.calendarID {
            event.calendar = try writableCalendar(calendarID)
        }
        Self.apply(draft, to: event, original: original)
        if draft == original.draft && calendarID == original.id.calendarID { return nil }
        try write { try store.save(event, span: span(for: scope, event: original), commit: true) }
        return event
    }

    private static func apply(_ draft: EventDraft, to event: EKEvent, original: CalendarEvent) {
        if draft.title != original.title { event.title = draft.title }
        if draft.notes != original.notes { event.notes = draft.notes }
        if draft.allDay != original.isAllDay { event.isAllDay = draft.allDay }
        if draft.start != original.start { event.startDate = draft.start }
        if draft.end != original.end { event.endDate = draft.end }
        if draft.timeZoneID != original.timeZoneID {
            event.timeZone = draft.timeZoneID.flatMap(TimeZone.init(identifier:))
        }
    }

    public func delete(_ original: CalendarEvent, scope: MutationScope) throws {
        if original.activityDetails.link != nil {
            try deleteLinked(original, scope: scope, allCopies: true)
            return
        }
        try removeEvent(original, scope: scope)
        #if os(macOS)
        editHistory.discardRedo()
        editHistory.discardEdits(for: original.id)
        #endif
    }

    private func removeEvent(_ original: CalendarEvent, scope: MutationScope) throws {
        try requireAccess()
        let event = try unchangedEvent(original)
        _ = try writableCalendar(original.id.calendarID)
        try write { try store.remove(event, span: span(for: scope, event: original), commit: true) }
    }

    private var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .unknown
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .fullAccess: .full
        @unknown default: .restricted
        }
    }

    private func requireAccess() throws {
        guard access == .full else { throw CalendarStoreError.access }
    }

    private func validate(_ draft: EventDraft, preservingTitle: String? = nil) throws {
        guard draft.end > draft.start,
              draft.title == preservingTitle || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CalendarStoreError.invalidEvent }
    }

    private func writableCalendar(_ id: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: id) else { throw CalendarStoreError.missingCalendar }
        guard calendar.allowsContentModifications else { throw CalendarStoreError.readOnly }
        return calendar
    }

    private func unchangedEvent(_ original: CalendarEvent) throws -> EKEvent {
        let id = original.id
        guard let calendar = store.calendar(withIdentifier: id.calendarID) else {
            throw CalendarStoreError.missingCalendar
        }
        // The identifier lookup can return the first occurrence of a series. Use the
        // displayed occurrence and a bounded date predicate, then require a unique match.
        let predicate = store.predicateForEvents(withStart: id.start.addingTimeInterval(-60),
                                                 end: id.start.addingTimeInterval(60), calendars: [calendar])
        let matches = store.events(matching: predicate).filter {
            $0.eventIdentifier == id.identifier && $0.startDate == id.start && $0.occurrenceDate == id.occurrence
        }
        guard matches.count == 1, let event = matches.first,
              let current = Self.snapshot(event, calendar: Self.listItem(calendar)) else {
            throw CalendarStoreError.missingEvent
        }
        guard current.title == original.title, current.end == original.end,
              current.isAllDay == original.isAllDay, current.timeZoneID == original.timeZoneID,
              current.isRecurring == original.isRecurring, current.modified == original.modified,
              current.notes == original.notes else {
            throw CalendarStoreError.eventChanged
        }
        return event
    }

    private func span(for scope: MutationScope, event: CalendarEvent) -> EKSpan {
        scope == .future && event.isRecurring ? .futureEvents : .thisEvent
    }

    private enum PendingChange {
        case save(EKEvent, EKSpan)
        case remove(EKEvent, EKSpan)
    }

    private func commitChanges(_ changes: [PendingChange]) throws {
        do {
            for change in changes {
                switch change {
                case let .save(event, span): try store.save(event, span: span, commit: false)
                case let .remove(event, span): try store.remove(event, span: span, commit: false)
                }
            }
            try store.commit()
        } catch {
            store.reset()
            throw CalendarStoreError.writeFailed
        }
    }

    private func write(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            store.reset()
            throw CalendarStoreError.writeFailed
        }
    }

    private static func listItem(_ calendar: EKCalendar) -> CalendarListItem {
        let converted = calendar.cgColor?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    intent: .defaultIntent, options: nil)
        let rgb = converted?.components ?? [0.15, 0.50, 0.56]
        return CalendarListItem(
            choice: CalendarChoice(id: calendar.calendarIdentifier, title: calendar.title,
                                   source: calendar.source?.title ?? "Device", isWritable: calendar.allowsContentModifications),
            color: CalendarColor(red: rgb[0], green: rgb[1], blue: rgb[2])
        )
    }

    private static func snapshot(_ event: EKEvent, calendar: CalendarListItem) -> CalendarEvent? {
        guard let identifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate else {
            return nil
        }
        return CalendarEvent(
            id: EventIdentity(identifier: identifier, start: start, occurrence: event.occurrenceDate, calendarID: calendar.id),
            title: event.title ?? "", end: end, isAllDay: event.isAllDay, timeZoneID: event.timeZone?.identifier,
            modified: event.lastModifiedDate, isRecurring: event.hasRecurrenceRules, calendar: calendar, notes: event.notes
        )
    }
}

#if os(macOS)
extension EventKitCalendarStore: CalendarEditHistoryStore {
    private func savedSnapshot(_ event: EKEvent) -> CalendarEvent? {
        guard let identifier = event.eventIdentifier,
              let committed = store.event(withIdentifier: identifier),
              committed.startDate == event.startDate,
              let calendar = committed.calendar, calendar.calendarIdentifier == event.calendar?.calendarIdentifier
        else { return nil }
        return Self.snapshot(committed, calendar: Self.listItem(calendar))
    }

    public func replayCalendarEdit(redo: Bool) throws -> Bool {
        guard let change = editHistory.next(redo: redo) else { return false }
        let steps = [change.single] + change.peers
        var prepared: [(EKEvent, CalendarEvent?, CalendarEvent?)] = []
        for step in steps {
            if let expected = step.expected {
                let event = try unchangedEvent(expected)
                _ = try writableCalendar(expected.calendar.id)
                if let destination = step.destination {
                    _ = try writableCalendar(destination.calendar.id)
                    try validate(destination.draft, preservingTitle: destination.title)
                }
                prepared.append((event, step.expected, step.destination))
            } else if let destination = step.destination {
                prepared.append((try preparedEvent(destination.draft, calendarID: destination.calendar.id),
                                 nil, destination))
            }
        }
        let pending: [PendingChange] = try prepared.map { event, expected, destination in
            if let destination {
                if let expected {
                    event.calendar = try writableCalendar(destination.calendar.id)
                    Self.apply(destination.draft, to: event, original: expected)
                }
                return .save(event, .thisEvent)
            }
            return .remove(event, .thisEvent)
        }
        try commitChanges(pending)
        let results = prepared.map { event, _, destination in destination == nil ? nil : savedSnapshot(event) }
        editHistory.finishBatch(change, results: results, redo: redo)
        return true
    }

}

struct CalendarEditHistory {
    struct Change {
        var expected: CalendarEvent?
        let destination: CalendarEvent?
        var peers: [Change] = []
        var single: Change { Change(expected: expected, destination: destination) }
    }

    private var undo: [Change] = []
    private var redo: [Change] = []

    mutating func record(from previous: CalendarEvent?, to saved: CalendarEvent) {
        recordBatch([(previous, saved)])
    }

    mutating func recordBatch(_ changes: [(CalendarEvent?, CalendarEvent?)]) {
        let entries = changes.map { Change(expected: $0.1, destination: $0.0) }
        guard var first = entries.first else { return }
        first.peers = Array(entries.dropFirst())
        undo.append(first)
        if undo.count > 100 { undo.removeFirst() }
    }

    mutating func discardRedo() { redo.removeAll() }

    mutating func discardEdits(for id: EventIdentity) {
        undo.removeAll { change in
            ([change.single] + change.peers).contains {
                $0.expected?.id.identifier == id.identifier && $0.expected?.calendar.id == id.calendarID
            }
        }
    }

    func next(redo replay: Bool) -> Change? { replay ? redo.last : undo.last }

    mutating func finish(_ change: Change, result: CalendarEvent?, redo replay: Bool) {
        finishBatch(change, results: [result], redo: replay)
    }

    mutating func finishBatch(_ change: Change, results: [CalendarEvent?], redo replay: Bool) {
        let steps = [change.single] + change.peers
        if replay { Self.advance(&redo, steps: steps, results: results) }
        else { Self.advance(&undo, steps: steps, results: results) }
        guard steps.count == results.count,
              zip(steps, results).allSatisfy({ $0.destination == nil || $1 != nil }) else { return }
        var reverse = zip(steps, results).map { Change(expected: $1, destination: $0.expected) }
        var first = reverse.removeFirst()
        first.peers = reverse
        if replay { undo.append(first) } else { redo.append(first) }
    }

    private static func advance(_ stack: inout [Change], steps: [Change], results: [CalendarEvent?]) {
        stack.removeLast()
        for (step, result) in zip(steps, results) {
            guard let previous = step.destination, let result else { continue }
            func rebound(_ entry: Change) -> Change {
                var entry = entry
                if let expected = entry.expected, expected.id == previous.id,
                   expected.draft == previous.draft, expected.modified == previous.modified {
                    entry.expected = result
                }
                entry.peers = entry.peers.map(rebound)
                return entry
            }
            stack = stack.map(rebound)
        }
    }
}

#endif

extension EventKitCalendarStore {
    public func create(_ draft: EventDraft, calendarIDs: [String], requestID: UUID) throws {
        guard !completedCreates.contains(requestID) else { return }
        var seen: Set<String> = []
        let ids = calendarIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw CalendarStoreError.missingCalendar }
        if ids.count == 1 {
            try create(draft, calendarID: ids[0], requestID: requestID)
            return
        }
        try requireAccess()
        let calendars = try ids.map(writableCalendar)
        var draft = draft
        var details = draft.activityDetails
        details.link = ActivityLink(id: requestID, title: draft.title,
                                    calendars: calendars.map { Self.listItem($0).choice.qualifiedTitle })
        draft.activityDetails = details
        let events = try ids.map { try preparedEvent(draft, calendarID: $0) }
        try commitChanges(events.map { .save($0, .thisEvent) })
        completedCreates.append(requestID)
        if completedCreates.count > 64 { completedCreates.removeFirst() }
        #if os(macOS)
        editHistory.discardRedo()
        if draft.repetition == .none {
            let saved = events.compactMap(savedSnapshot)
            if saved.count == events.count { editHistory.recordBatch(saved.map { (nil, Optional($0)) }) }
        }
        #endif
    }

    private func linkedPeers(_ original: CalendarEvent, requireMatching: Bool) throws -> [(EKEvent, CalendarEvent)] {
        let current = try unchangedEvent(original)
        guard let link = original.activityDetails.link else { return [(current, original)] }
        let calendars = store.calendars(for: .event)
        func find(radius: TimeInterval) -> [(EKEvent, CalendarEvent)] {
            let predicate = store.predicateForEvents(withStart: original.start.addingTimeInterval(-radius),
                                                     end: original.start.addingTimeInterval(radius), calendars: calendars)
            var seen: Set<EventIdentity> = []
            return store.events(matching: predicate).compactMap { event in
                guard let calendar = event.calendar, let snapshot = Self.snapshot(event, calendar: Self.listItem(calendar)),
                      snapshot.activityDetails.link?.id == link.id,
                      !original.isRecurring || snapshot.id.occurrence == original.id.occurrence,
                      seen.insert(snapshot.id).inserted else { return nil }
                return (event, snapshot)
            }
        }
        var peers = find(radius: 86_400)
        if peers.count < link.copyCount { peers = find(radius: 366 * 86_400) }
        if requireMatching {
            guard peers.count == link.copyCount,
                  Set(peers.map { $0.1.calendar.id }).count == peers.count,
                  peers.allSatisfy({ $0.1.draft == original.draft && $0.1.isRecurring == original.isRecurring })
            else { throw CalendarStoreError.linkedEventChanged }
        }
        if requireMatching {
            for (_, snapshot) in peers { _ = try writableCalendar(snapshot.calendar.id) }
        } else {
            _ = try writableCalendar(original.calendar.id)
        }
        guard peers.contains(where: { $0.1.id == original.id }) else { throw CalendarStoreError.missingEvent }
        return peers
    }

    public func updateLinked(_ original: CalendarEvent, with draft: EventDraft, calendarID: String,
                             scope: MutationScope, allCopies: Bool) throws {
        guard original.activityDetails.link != nil else {
            try update(original, with: draft, calendarID: calendarID, scope: scope)
            return
        }
        try requireAccess()
        try validate(draft, preservingTitle: original.title)
        let peers = try linkedPeers(original, requireMatching: allCopies)
        let destination = try writableCalendar(calendarID)
        if allCopies, draft == original.draft, calendarID == original.calendar.id { return }
        let others = peers.filter { $0.1.id != original.id }
        if allCopies, others.contains(where: { $0.1.calendar.id == calendarID }) {
            throw CalendarStoreError.duplicateLinkedCalendar
        }
        let names = peers.map {
            $0.1.id == original.id ? Self.listItem(destination).choice.qualifiedTitle : $0.1.calendar.choice.qualifiedTitle
        }
        var changes: [(EKEvent, CalendarEvent, EventDraft)] = []
        for (event, snapshot) in peers where allCopies || snapshot.calendar.choice.isWritable {
            var value = allCopies || snapshot.id == original.id ? draft : snapshot.draft
            var details = value.activityDetails
            if allCopies {
                details.link = ActivityLink(id: original.activityDetails.link!.id, title: draft.title, calendars: names)
            } else if snapshot.id == original.id || others.count < 2 {
                details.link = nil
            } else {
                details.link = ActivityLink(id: original.activityDetails.link!.id, title: snapshot.title,
                                           calendars: others.map { $0.1.calendar.choice.qualifiedTitle })
            }
            value.activityDetails = details
            changes.append((event, snapshot, value))
        }
        let pending: [PendingChange] = changes.map { event, snapshot, value in
            if snapshot.id == original.id { event.calendar = destination }
            Self.apply(value, to: event, original: snapshot)
            return .save(event, span(for: scope, event: snapshot))
        }
        try commitChanges(pending)
        #if os(macOS)
        editHistory.discardRedo()
        if !original.isRecurring {
            let saved = changes.compactMap { savedSnapshot($0.0) }
            if saved.count == changes.count {
                editHistory.recordBatch(zip(changes.map { Optional($0.1) }, saved.map(Optional.init)).map { ($0, $1) })
            }
        }
        #endif
    }

    public func deleteLinked(_ original: CalendarEvent, scope: MutationScope, allCopies: Bool) throws {
        guard original.activityDetails.link != nil else {
            try delete(original, scope: scope)
            return
        }
        try requireAccess()
        let peers = try linkedPeers(original, requireMatching: allCopies)
        let removed = allCopies ? peers : peers.filter { $0.1.id == original.id }
        let remaining = allCopies ? [] : peers.filter { $0.1.id != original.id }
        var pending: [PendingChange] = removed.map { .remove($0.0, span(for: scope, event: $0.1)) }
        for (event, snapshot) in remaining where snapshot.calendar.choice.isWritable {
            var details = snapshot.activityDetails
            details.link = remaining.count < 2 ? nil : ActivityLink(
                id: original.activityDetails.link!.id, title: snapshot.title,
                calendars: remaining.map { $0.1.calendar.choice.qualifiedTitle })
            event.notes = details.notes(description: ActivityDetails.description(in: snapshot.notes))
            pending.append(.save(event, span(for: scope, event: snapshot)))
        }
        try commitChanges(pending)
        #if os(macOS)
        editHistory.discardRedo()
        for (_, snapshot) in peers { editHistory.discardEdits(for: snapshot.id) }
        #endif
    }
}
