import CalendarCore
import CalendarData
import Foundation

private struct Item: Decodable {
    let id: String
    let start: Date
    let end: Date
    let notes: String?

    var event: CalendarEvent {
        CalendarEvent(id: EventIdentity(identifier: id, start: start, occurrence: nil, calendarID: ""),
                      title: "", end: end, isAllDay: false, timeZoneID: nil, modified: nil,
                      isRecurring: false, calendar: Self.calendar, notes: notes)
    }

    private static let calendar = CalendarListItem(
        choice: CalendarChoice(id: "", title: "", source: "", isWritable: false),
        color: CalendarColor(red: 0, green: 0, blue: 0)
    )
}

private struct Buffers: Decodable {
    let before: ActivityBuffer?
    let after: ActivityBuffer?
}

private struct UsageEntry: Decodable {
    let title: String
    let calendarID: String
}

private struct CalendarOption: Decodable {
    let id: String
    let title: String
}

private struct Request: Decodable {
    let operation: String
    let text: String?
    let now: Date?
    let slot: Date?
    let timeZone: String?
    let mode: EntryMode?
    let duration: Int?
    let notes: String?
    let description: String?
    let days: [Date]?
    let items: [Item]?
    let pointsPerHour: Double?
    let adaptive: Bool?
    let blend: Bool?
    let snapMinutes: Int?
    let beforeDefault: ActivityBufferDefaults?
    let afterDefault: ActivityBufferDefaults?
    let buffers: Buffers?
    let usage: CalendarUsage?
    let choices: [UsageEntry]?
    let calendars: [CalendarOption]?
    let preferredCalendar: String?
    let requestedCalendar: String?
}

private enum BridgeError: LocalizedError {
    case invalidCommand
    var errorDescription: String? { "Calendar could not process this request." }
}

private func encodeBuffer(_ buffer: ActivityBuffer?) -> Any {
    guard let buffer else { return NSNull() }
    return ["minutes": buffer.minutes, "kind": buffer.kind.rawValue, "label": buffer.label,
            "travelMode": buffer.travelMode.rawValue]
}

private func editorData(notes: String?) -> [String: Any] {
    let activity = ActivityDetails.read(from: notes)
    return ["description": ActivityDetails.description(in: notes) ?? "",
            "before": encodeBuffer(activity.before), "after": encodeBuffer(activity.after)]
}

private func encodeDraft(_ parsed: ParsedEntry, calendar: Calendar) -> [String: Any] {
    let draft = parsed.draft
    let zone = draft.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
    return [
        "title": draft.title,
        "start": draft.start.timeIntervalSince1970,
        "end": draft.end.timeIntervalSince1970,
        "allDay": draft.allDay,
        "notes": draft.notes ?? "",
        "activity": editorData(notes: draft.notes),
        "requestedCalendar": parsed.requestedCalendar ?? "",
        "explicitDate": parsed.fields.contains(.date),
        "explicitEnd": parsed.fields.contains(.end) || parsed.fields.contains(.duration),
        "explicitStart": parsed.fields.contains(.start),
        "timeZone": zone.identifier,
        "repeatWeekly": draft.repetition == .weekly,
        "notice": parsed.notice ?? "",
    ]
}

private func track(_ request: Request, events: [CalendarEvent], in range: DateInterval,
                   calendar: Calendar) -> [String: Any] {
    let points = min(160, max(36, request.pointsPerHour ?? 68))
    let adaptive = request.adaptive == true
    let related = events.filter { $0.occupiedStart < range.end && $0.occupiedEnd >= range.start }
    let byID = Dictionary(uniqueKeysWithValues: related.map { ($0.id.layoutID, $0) })
    let overlaps = ActivityBufferOverlapPlan(events: related, in: range, enabled: request.blend == true)
    let occupied = related.map { TimedInterval(id: $0.id.layoutID, start: $0.occupiedStart, end: $0.occupiedEnd) }
    let cores = related.map { TimedInterval(id: $0.id.layoutID, start: $0.start, end: $0.end) }
    let bands = related.flatMap { event in
        [(event.occupiedStart, event.start), (event.end, event.occupiedEnd)].compactMap { start, end in
            start < end ? TimedInterval(id: event.id.layoutID, start: start, end: end) : nil
        }
    }
    let timeline = EventLayoutEngine.dayTimeline(
        for: occupied, in: range, calendar: calendar, pointsPerHour: points,
        minimumHeight: adaptive ? 40 : 18, layout: adaptive ? .stacked : .columns,
        readableIntervals: cores, bufferIntervals: bands, minimumBufferHeight: 20,
        laneIntervals: overlaps.laneIntervals(for: related), exactHeightIDs: overlaps.affectedIDs
    )
    let bottom = (timeline.hours.last.map { $0.top + $0.height }) ?? 0
    func offset(_ date: Date) -> Double {
        if date <= range.start { return 0 }
        if date >= range.end { return bottom }
        return timeline.offset(for: date) ?? bottom
    }
    let cards: [[String: Any]] = timeline.positions.compactMap { position in
        guard let event = byID[position.lane.id] else { return nil }
        let coreTop = offset(event.start)
        let coreBottom = offset(event.end)
        let before = event.activityDetails.before
        let after = event.activityDetails.after
        // Fixed timelines still need a usable target for very short events without buffers.
        let height = adaptive || before != nil || after != nil
            ? max(2, offset(event.occupiedEnd) - position.top)
            : max(2, position.height + 2)
        let markers: [[String: Any]] = (overlaps.byTarget[position.lane.id] ?? []).map {
            ["owner": $0.owner.id.identifier, "start": offset($0.interval.start) - position.top,
             "end": offset($0.interval.end) - position.top]
        }
        return [
            "id": event.id.identifier, "top": position.top, "height": height,
            "leading": position.lane.leading, "trailing": position.lane.trailing,
            "coreTop": coreTop - position.top,
            "coreBottom": before == nil && after == nil ? height : coreBottom - position.top,
            "before": encodeBuffer(before), "after": encodeBuffer(after),
            "markers": markers,
            "behind": overlaps.owners.contains(position.lane.id),
        ]
    }
    let step = Double([5, 10, 15, 30, 60].contains(request.snapMinutes ?? 15) ? (request.snapMinutes ?? 15) : 15) * 60
    // Query the same time ruler used to draw the cards. This also covers expanded Day spans and DST.
    let grid = stride(from: 0.0, to: range.duration, by: step).map { range.start.addingTimeInterval($0) } + [range.end]
    return [
        "height": max(bottom, timeline.height),
        "now": timeline.offset(for: request.now ?? Date()) as Any? ?? NSNull(),
        "hours": timeline.hours.map { ["start": $0.interval.start.timeIntervalSince1970, "top": $0.top] },
        "snap": grid.map { ["time": $0.timeIntervalSince1970, "top": offset($0)] },
        "ruler": timeline.rulerAnchors.map { ["time": $0.date.timeIntervalSince1970, "top": $0.offset] },
        "cards": cards,
    ]
}

private func run(_ request: Request) throws -> Any {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = request.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    switch request.operation {
    case "parse":
        let parsed = try QuickEntryParser().parse(
            request.text ?? "",
            context: EntryContext(now: request.now ?? Date(), calendar: calendar, locale: .current,
                                  mode: request.mode ?? .schedule, defaultDuration: request.duration ?? 60,
                                  selectedSlot: request.slot, beforeActivity: request.beforeDefault ?? .init(),
                                  afterActivity: request.afterDefault ?? .init())
        )
        return encodeDraft(parsed, calendar: calendar)
    case "activity":
        return editorData(notes: request.notes)
    case "saveActivity":
        var details = ActivityDetails.read(from: request.notes)
        let existingDescription = ActivityDetails.description(in: request.notes) ?? ""
        if details.before == request.buffers?.before && details.after == request.buffers?.after
            && existingDescription == (request.description ?? "") {
            return request.notes ?? ""
        }
        details.before = request.buffers?.before
        details.after = request.buffers?.after
        return details.notes(description: request.description) ?? ""
    case "learnCalendars":
        var usage = request.usage ?? CalendarUsage()
        for choice in request.choices ?? [] {
            usage.record(title: choice.title, calendarID: choice.calendarID)
        }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(usage))
    case "suggestCalendar":
        let result = CalendarPrediction.resolve(
            requested: request.requestedCalendar, title: request.text ?? "",
            calendars: (request.calendars ?? []).map {
                CalendarChoice(id: $0.id, title: $0.title, source: "iCloud", isWritable: true)
            }, aliases: [:], rules: [:], preferredID: request.preferredCalendar, systemID: nil,
            locale: .current, history: request.usage
        )
        switch result {
        case .selected(let id, let reason):
            return ["id": id, "suggested": reason == .history]
        case .choose(let message):
            return ["message": message]
        }
    case "layout":
        let events = (request.items ?? []).map(\.event)
        return (request.days ?? []).compactMap { day in
            calendar.dateInterval(of: .day, for: day).map {
                track(request, events: events, in: $0, calendar: calendar)
            }
        }
    default:
        throw BridgeError.invalidCommand
    }
}

private func respond(to data: Data) throws -> Data {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    do {
        let request = try decoder.decode(Request.self, from: data)
        return try JSONSerialization.data(withJSONObject: ["value": run(request)])
    } catch {
        return try JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
    }
}

if CommandLine.arguments.dropFirst().first == "--stream" {
    while let line = readLine() {
        var response = try respond(to: Data(line.utf8))
        response.append(10)
        FileHandle.standardOutput.write(response)
    }
} else {
    let response = try respond(to: FileHandle.standardInput.readDataToEndOfFile())
    FileHandle.standardOutput.write(response)
}
