import CalendarCore
import Foundation

public struct ActivityBufferOverlap: Identifiable, Sendable {
    public enum Side: Int, Sendable { case before, after }
    public let owner: CalendarEvent
    public let target: EventIdentity
    public let side: Side
    public let interval: DateInterval
    public var id: String { owner.id.layoutID + ":\(side.rawValue):" + target.layoutID }
}

/// Sweep the actual event cores and their extensions once per cached layout.
/// Extensions never become independent events or change the stored event times.
public struct ActivityBufferOverlapPlan: Sendable {
    public let overlaps: [ActivityBufferOverlap]
    public let byOwner: [String: [ActivityBufferOverlap]]
    public let byTarget: [String: [ActivityBufferOverlap]]
    public let owners: Set<String>
    public let affectedIDs: Set<String>
    private let markerOrder: [String: [String]]
    public var isEmpty: Bool { overlaps.isEmpty }

    public init(events: [CalendarEvent], in range: DateInterval, enabled: Bool) {
        struct Buffer {
            let event: CalendarEvent
            let side: ActivityBufferOverlap.Side
            let start: Date
            let end: Date
        }
        struct Endpoint {
            let date: Date
            // Ends precede starts at the same instant: adjacent events do not overlap.
            let kind: Int
            let index: Int
        }
        let events = enabled ? events.filter { !$0.isAllDay && $0.start < $0.end } : []
        var buffers: [Buffer] = []
        var endpoints: [Endpoint] = []
        for (index, event) in events.enumerated() {
            if event.start < range.end && event.end > range.start {
                endpoints += [Endpoint(date: max(event.start, range.start), kind: 2, index: index),
                              Endpoint(date: min(event.end, range.end), kind: 0, index: index)]
            }
            for (side, start, end) in [(ActivityBufferOverlap.Side.before, event.occupiedStart, event.start),
                                      (.after, event.end, event.occupiedEnd)] {
                let start = max(start, range.start), end = min(end, range.end)
                guard start < end else { continue }
                let index = buffers.count
                buffers.append(Buffer(event: event, side: side, start: start, end: end))
                endpoints += [Endpoint(date: start, kind: 3, index: index), Endpoint(date: end, kind: 1, index: index)]
            }
        }
        endpoints.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            return $0.index < $1.index
        }
        var activeCores: Set<Int> = [], activeBuffers: Set<Int> = []
        var matches: [ActivityBufferOverlap] = []
        func append(_ buffer: Buffer, _ target: CalendarEvent) {
            guard buffer.event.id != target.id else { return }
            let start = max(buffer.start, target.start), end = min(buffer.end, target.end)
            guard start < end else { return }
            matches.append(ActivityBufferOverlap(owner: buffer.event, target: target.id, side: buffer.side,
                                                  interval: DateInterval(start: start, end: end)))
        }
        for endpoint in endpoints {
            switch endpoint.kind {
            case 0: activeCores.remove(endpoint.index)
            case 1: activeBuffers.remove(endpoint.index)
            case 2:
                for index in activeBuffers { append(buffers[index], events[endpoint.index]) }
                activeCores.insert(endpoint.index)
            default:
                for index in activeCores { append(buffers[endpoint.index], events[index]) }
                activeBuffers.insert(endpoint.index)
            }
        }
        matches.sort { $0.id < $1.id }
        overlaps = matches
        byOwner = Dictionary(grouping: matches, by: { $0.owner.id.layoutID })
        byTarget = Dictionary(grouping: matches, by: { $0.target.layoutID })
        owners = Set(byOwner.keys)
        affectedIDs = owners.union(byTarget.keys)
        markerOrder = byTarget.mapValues { Array(Set($0.map { $0.owner.id.layoutID })).sorted() }
    }

    public func laneIntervals(for events: [CalendarEvent]) -> [TimedInterval]? {
        guard !isEmpty else { return nil }
        return events.filter { !$0.isAllDay }.map { event in
            TimedInterval(id: event.id.layoutID,
                          start: owners.contains(event.id.layoutID) ? event.start : event.occupiedStart,
                          end: owners.contains(event.id.layoutID) ? event.end : event.occupiedEnd)
        }
    }

    public func markerOwners(on target: String) -> [String] {
        markerOrder[target] ?? []
    }
}
