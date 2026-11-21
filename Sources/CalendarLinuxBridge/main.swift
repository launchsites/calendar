import CalendarCore
import Foundation

private struct Item: Decodable {
    let id: String
    let start: Date
    let end: Date
    let notes: String?
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
}

private enum BridgeError: LocalizedError {
    case invalidCommand
    var errorDescription: String? { "Calendar could not process this request." }
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
        "requestedCalendar": parsed.requestedCalendar ?? "",
        "timeZone": zone.identifier,
        "repeatWeekly": draft.repetition == .weekly,
        "notice": parsed.notice ?? "",
    ]
}

private func layout(_ request: Request, calendar: Calendar) -> [[String: Any]] {
    let points = min(160, max(36, request.pointsPerHour ?? 68))
    let adaptive = request.adaptive == true && request.days?.count == 1
    return (request.days ?? []).compactMap { day in
        guard let range = calendar.dateInterval(of: .day, for: day) else { return nil }
        let related = (request.items ?? []).filter { $0.start < range.end && $0.end >= range.start }
        let intervals = related.map { TimedInterval(id: $0.id, start: $0.start, end: $0.end) }
        let timeline = EventLayoutEngine.dayTimeline(
            for: intervals, in: range, calendar: calendar, pointsPerHour: points,
            minimumHeight: adaptive ? 38 : 18, layout: adaptive ? .stacked : .columns
        )
        let bufferBands: [[String: Any]] = related.flatMap { event -> [[String: Any]] in
            let details = ActivityDetails.read(from: event.notes)
            return [(details.before, false), (details.after, true)].compactMap { buffer, after in
                guard let buffer else { return nil }
                let duration = Double(buffer.minutes) * 60
                let start = after ? event.end : event.start.addingTimeInterval(-duration)
                let end = after ? event.end.addingTimeInterval(duration) : event.start
                guard start < range.end && end > range.start else { return nil }
                let top = timeline.offset(for: max(start, range.start)) ?? 0
                let bottom = end >= range.end ? timeline.height : timeline.offset(for: end) ?? top
                return ["id": event.id, "top": top, "height": max(0, bottom - top),
                        "label": "\(buffer.minutes) min · \(buffer.title)"]
            }
        }
        let cards = timeline.positions.map { card -> [String: Any] in
            ["id": card.lane.id, "top": card.top, "height": card.height,
             "leading": card.lane.leading, "trailing": card.lane.trailing]
        }
        return [
            "height": timeline.height,
            "now": timeline.offset(for: request.now ?? Date()) as Any? ?? NSNull(),
            "hours": timeline.hours.map {
                ["start": $0.interval.start.timeIntervalSince1970, "top": $0.top]
            },
            "cards": cards,
            "buffers": bufferBands,
        ]
    }
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
                                  selectedSlot: request.slot)
        )
        return encodeDraft(parsed, calendar: calendar)
    case "describe":
        return ActivityDetails.description(in: request.notes) ?? ""
    case "replaceDescription":
        let details = ActivityDetails.read(from: request.notes)
        return details.notes(description: request.description) ?? ""
    case "layout":
        return layout(request, calendar: calendar)
    default:
        throw BridgeError.invalidCommand
    }
}

do {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let request = try decoder.decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    let response = try JSONSerialization.data(withJSONObject: ["value": run(request)])
    FileHandle.standardOutput.write(response)
} catch {
    let response = try JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
    FileHandle.standardOutput.write(response)
}
