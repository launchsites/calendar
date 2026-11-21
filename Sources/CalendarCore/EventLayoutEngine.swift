import Foundation

public struct TimedInterval: Sendable {
    public let id: String
    public let start: Date
    public let end: Date

    public init(id: String, start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public struct LanePlacement: Equatable, Sendable {
    public let id: String
    public let lane: Int
    public let span: Int
    public let lanes: Int

    public var leading: Double { Double(lane) / Double(lanes) }
    public var trailing: Double { Double(lane + span) / Double(lanes) }
}

public struct EventLayoutEngine {
    public static func lanes(for intervals: [TimedInterval]) -> [LanePlacement] {
        let sorted = intervals.sorted(by: chronologicalOrder)

        var placements: [LanePlacement] = []
        var group: [[TimedInterval]] = []
        var groupEnd = Date.distantPast
        for interval in sorted {
            guard interval.end > interval.start else {
                placements.append(LanePlacement(id: interval.id, lane: 0, span: 1, lanes: 1))
                continue
            }
            if interval.start >= groupEnd {
                placements.append(contentsOf: finish(group))
                group.removeAll(keepingCapacity: true)
                groupEnd = interval.end
            } else {
                groupEnd = max(groupEnd, interval.end)
            }
            if let lane = group.firstIndex(where: { $0.last!.end <= interval.start }) {
                group[lane].append(interval)
            } else {
                group.append([interval])
            }
        }
        placements.append(contentsOf: finish(group))
        return placements
    }

    private static func chronologicalOrder(_ first: TimedInterval, _ second: TimedInterval) -> Bool {
        if first.start != second.start { return first.start < second.start }
        if first.end != second.end { return first.end > second.end }
        return first.id < second.id
    }

    private static func finish(_ group: [[TimedInterval]]) -> [LanePlacement] {
        return group.enumerated().flatMap { lane, intervals in
            intervals.map { interval in
                var span = 1
                for neighbour in (lane + 1)..<group.count {
                    if overlaps(interval, lane: group[neighbour]) { break }
                    span += 1
                }
                return LanePlacement(id: interval.id, lane: lane, span: span, lanes: group.count)
            }
        }
    }

    private static func overlaps(_ interval: TimedInterval, lane: [TimedInterval]) -> Bool {
        var low = 0
        var high = lane.count
        while low < high {
            let middle = low + (high - low) / 2
            if lane[middle].end <= interval.start { low = middle + 1 } else { high = middle }
        }
        return low < lane.count && lane[low].start < interval.end
    }
}

public enum TimelineLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case stacked = "Stacked"
    case columns = "Columns"
    public var id: Self { self }
    public var label: String { self == .stacked ? "Adaptive" : rawValue }
}

public struct TimelinePosition: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        let event: String
        let partStart: Date?
    }

    public let lane: LanePlacement
    public let top: Double
    public let height: Double
    public let part: DateInterval?

    public var id: ID { ID(event: lane.id, partStart: part?.start) }
}

public struct TimelineHour: Identifiable, Sendable {
    public let interval: DateInterval
    public let top: Double
    public let height: Double
    fileprivate let segments: [TimelineSegment]

    public var id: Date { interval.start }
}

fileprivate struct TimelineSegment: Sendable {
    let interval: DateInterval
    let top: Double
    let height: Double

    func offset(for date: Date) -> Double {
        top + height * date.timeIntervalSince(interval.start) / interval.duration
    }
}

public struct DayTimeline: Sendable {
    public let hours: [TimelineHour]
    public let positions: [TimelinePosition]

    public var height: Double {
        let lastHourEnd = hours.last.map { $0.top + $0.height } ?? 0
        let lastCardEnd = positions.lazy.map { $0.top + $0.height }.max() ?? 0
        return max(lastHourEnd, lastCardEnd)
    }

    /// The boundaries of the displayed time ruler, including expanded activity spans.
    public var rulerAnchors: [(date: Date, offset: Double)] {
        var result = hours.flatMap { hour in
            hour.segments.isEmpty
                ? [(hour.interval.start, hour.top)]
                : hour.segments.map { ($0.interval.start, $0.top) }
        }
        if let last = hours.last { result.append((last.interval.end, last.top + last.height)) }
        return result
    }

    public func offset(for date: Date) -> Double? {
        guard let hour = hours.first(where: { $0.interval.start <= date && date < $0.interval.end }) else { return nil }
        if let segment = hour.segments.first(where: { $0.interval.start <= date && date < $0.interval.end }) {
            return segment.offset(for: date)
        }
        return hour.top + hour.height * date.timeIntervalSince(hour.interval.start) / hour.interval.duration
    }

    public func date(at offset: Double) -> Date? {
        guard offset.isFinite, let first = hours.first, let last = hours.last else { return nil }
        let y = max(first.top, offset)
        guard let hour = hours.first(where: { y < $0.top + $0.height }) else {
            return last.interval.end.addingTimeInterval(-1)
        }
        if let segment = hour.segments.first(where: { y < $0.top + $0.height && $0.height > 0 }) {
            return segment.interval.start.addingTimeInterval(
                segment.interval.duration * (y - segment.top) / segment.height
            )
        }
        return hour.interval.start.addingTimeInterval(hour.interval.duration * (y - hour.top) / hour.height)
    }
}

public extension EventLayoutEngine {
    /// Assign columns by real overlap before separating minimum-sized hit areas.
    static func positions(for intervals: [TimedInterval], in range: DateInterval,
                          pointsPerHour: Double, minimumHeight: Double) -> [TimelinePosition] {
        let ordered = intervals.compactMap { interval -> TimedInterval? in
            let start = max(interval.start, range.start)
            let end = min(max(interval.start, interval.end), range.end)
            guard start < range.end, interval.start >= range.start || end > range.start else { return nil }
            return TimedInterval(id: interval.id, start: start, end: end)
        }.sorted(by: chronologicalOrder)
        let placements = lanes(for: ordered)
        let lanesByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        let scale = pointsPerHour / 3600
        var active: [TimelinePosition] = []
        var positions: [TimelinePosition] = []
        for interval in ordered {
            guard let lane = lanesByID[interval.id] else { continue }
            let mark = interval.start.timeIntervalSince(range.start) * scale
            let height = max(minimumHeight, interval.end.timeIntervalSince(interval.start) * scale - 2)
            active.removeAll { $0.top + $0.height + 2 <= mark }
            let top = active.reduce(mark) { top, prior in
                guard prior.lane.leading < lane.trailing, lane.leading < prior.lane.trailing else { return top }
                return max(top, prior.top + prior.height + 2)
            }
            let position = TimelinePosition(lane: lane, top: top, height: height, part: nil)
            active.append(position)
            positions.append(position)
        }
        return positions
    }
}

public extension EventLayoutEngine {
    static func dayTimeline(for intervals: [TimedInterval], in range: DateInterval, calendar: Calendar,
                            pointsPerHour: Double, minimumHeight: Double, layout: TimelineLayout,
                            readableIntervals: [TimedInterval]? = nil,
                            bufferIntervals: [TimedInterval] = [], minimumBufferHeight: Double = 26,
                            laneIntervals: [TimedInterval]? = nil, exactHeightIDs: Set<String> = []) -> DayTimeline {
        let scale = pointsPerHour / 3600
        let hours = hourIntervals(in: range, calendar: calendar)
        if layout == .columns {
            let fixedPositions: [TimelinePosition]
            if let laneIntervals {
                let lanes = Dictionary(uniqueKeysWithValues: Self.lanes(for: laneIntervals).map { ($0.id, $0) })
                fixedPositions = intervals.compactMap { interval in
                    let start = max(interval.start, range.start)
                    let end = min(max(interval.end, interval.start.addingTimeInterval(1)), range.end)
                    guard start < end, let lane = lanes[interval.id] else { return nil }
                    return TimelinePosition(lane: lane, top: start.timeIntervalSince(range.start) * scale,
                                            height: max(exactHeightIDs.contains(interval.id) ? 1 : minimumHeight,
                                                        end.timeIntervalSince(start) * scale - 2), part: nil)
                }
            } else {
                fixedPositions = positions(for: intervals, in: range, pointsPerHour: pointsPerHour, minimumHeight: minimumHeight)
            }
            return DayTimeline(
                hours: hours.map {
                    TimelineHour(interval: $0, top: $0.start.timeIntervalSince(range.start) * scale,
                                 height: $0.duration * scale, segments: [])
                },
                positions: fixedPositions
            )
        }

        let visible = intervals.compactMap { event -> TimedInterval? in
            let start = max(event.start, range.start)
            let end = min(max(event.end, event.start.addingTimeInterval(1)), range.end)
            guard start < end else { return nil }
            return TimedInterval(id: event.id, start: start, end: end)
        }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        func clipped(_ intervals: [TimedInterval]) -> [TimedInterval] { intervals.compactMap { event in
            let start = max(event.start, range.start)
            let end = min(max(event.end, event.start.addingTimeInterval(1)), range.end)
            return start < end ? TimedInterval(id: event.id, start: start, end: end) : nil
        } }
        let readable = clipped(readableIntervals ?? intervals)
        let buffers = clipped(bufferIntervals)
        let endings = Dictionary(grouping: readable, by: \.end)
        let bufferEndings = Dictionary(grouping: buffers, by: \.end)
        var boundaries = Set(hours.flatMap { [$0.start, $0.end] })
        for event in visible + readable + buffers {
            boundaries.insert(event.start)
            boundaries.insert(event.end)
        }

        // Keep time moving at its usual scale, then expand it where an event needs a readable card.
        // Events sharing a time span reuse its height and get separate columns.
        var offsets: [Date: Double] = [:]
        var previous = range.start
        var y = 0.0
        let sortedBoundaries = boundaries.sorted()
        for boundary in sortedBoundaries {
            y += boundary.timeIntervalSince(previous) * scale
            for event in endings[boundary] ?? [] {
                if let start = offsets[event.start] { y = max(y, start + minimumHeight + 2) }
            }
            for event in bufferEndings[boundary] ?? [] {
                if let start = offsets[event.start] { y = max(y, start + minimumBufferHeight + 2) }
            }
            offsets[boundary] = y
            previous = boundary
        }

        let timelineHours = hours.map { hour in
            let points = sortedBoundaries.filter { hour.start <= $0 && $0 <= hour.end }
            let segments = zip(points, points.dropFirst()).map { start, end in
                TimelineSegment(interval: DateInterval(start: start, end: end), top: offsets[start]!,
                                height: offsets[end]! - offsets[start]!)
            }
            return TimelineHour(interval: hour, top: offsets[hour.start]!,
                                height: offsets[hour.end]! - offsets[hour.start]!, segments: segments)
        }
        let visibleLanes: [LanePlacement]
        if let laneIntervals { visibleLanes = lanes(for: laneIntervals) }
        else { visibleLanes = lanes(for: visible) }
        let cards = visibleLanes.compactMap { lane -> TimelinePosition? in
            guard let event = byID[lane.id], let start = offsets[event.start], let end = offsets[event.end] else {
                return nil
            }
            return TimelinePosition(lane: lane, top: start, height: end - start - 2, part: nil)
        }
        return DayTimeline(hours: timelineHours, positions: cards)
    }

    private static func hourIntervals(in range: DateInterval, calendar: Calendar) -> [DateInterval] {
        var start = range.start
        var hours: [DateInterval] = []
        while start < range.end {
            let boundary = calendar.dateInterval(of: .hour, for: start)?.end ?? start.addingTimeInterval(3600)
            let end = min(range.end, boundary > start ? boundary : start.addingTimeInterval(3600))
            hours.append(DateInterval(start: start, end: end))
            start = end
        }
        return hours
    }
}
