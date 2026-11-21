import CalendarCore
import Foundation
import Testing

struct EventLayoutTests {
    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func event(_ id: String, _ start: Int, _ end: Int) -> TimedInterval {
        TimedInterval(id: id, start: base.addingTimeInterval(Double(start * 60)),
                      end: base.addingTimeInterval(Double(end * 60)))
    }

    @Test func touchingEventsKeepFullWidthAndSeparateHitAreas() {
        let entries = [event("short", 0, 3), event("next", 3, 60)]
        let layout = EventLayoutEngine.positions(for: entries, in: DateInterval(start: base, duration: 3600),
                                                 pointsPerHour: 76, minimumHeight: 44)
        #expect(layout.count == 2)
        #expect(layout.allSatisfy { $0.lane.leading == 0 && $0.lane.trailing == 1 })
        #expect(layout[0].height == 44)
        #expect(layout[1].top >= layout[0].height)
    }

    @Test func trueOverlapsHaveStableLanes() {
        let entries = [event("a", 0, 120), event("b", 0, 60), event("c", 0, 50),
                       event("d", 60, 90), event("e", 120, 180), event("point", 10, 10)]
        let result = EventLayoutEngine.lanes(for: entries)
        let lanes = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        #expect(lanes["a"]?.lane == 0)
        #expect(lanes["b"]?.lane == 1)
        #expect(lanes["c"]?.lane == 2)
        #expect(lanes["d"]?.span == 2)
        #expect(lanes["e"]?.lanes == 1)
        #expect(lanes["point"]?.lanes == 1)
        #expect(result == EventLayoutEngine.lanes(for: Array(entries.reversed())))
    }

    @Test func busyHourGrowsWithoutPushingCardsPastItsEnd() throws {
        let entries = [event("first", 10, 35), event("overlap", 25, 50), event("short", 35, 40),
                       event("next hour", 60, 65)]
        let layout = dayTimeline(entries)
        let hour = try #require(layout.hours.first)
        let nextHour = layout.hours[1]
        let busyCards = layout.positions.filter { $0.top < nextHour.top }
        let cards = Dictionary(uniqueKeysWithValues: busyCards.map { ($0.lane.id, $0) })
        let first = try #require(cards["first"])
        let overlap = try #require(cards["overlap"])
        let short = try #require(cards["short"])

        #expect(hour.height > 76)
        #expect(nextHour.top == hour.top + hour.height)
        #expect(busyCards.count == 3)
        #expect(first.lane.trailing <= overlap.lane.leading)
        #expect(short.lane.trailing <= overlap.lane.leading)
        #expect(overlap.top < first.top + first.height)
        #expect(short.top >= first.top + first.height)
        #expect(short.height >= 44 - 0.000001)
        #expect(busyCards.allSatisfy { $0.top + $0.height <= nextHour.top })
        #expect(layout.positions.last?.top == nextHour.top)
        #expect(layout.offset(for: nextHour.id) == nextHour.top)
        let nearEnd = try #require(layout.offset(for: hour.id.addingTimeInterval(59 * 60)))
        #expect(nearEnd < nextHour.top)
    }

    @Test func crossHourEventsRemainOneCardBesideOverlaps() throws {
        let longer = event("long", 30, 90)
        let uninterrupted = dayTimeline([longer])
        #expect(uninterrupted.positions.count == 1)
        let interrupted = dayTimeline([longer, event("short", 40, 45)])
        let longCards = interrupted.positions.filter { $0.lane.id == "long" }
        try #require(longCards.count == 1)
        let longCard = try #require(longCards.first)
        let shortCard = try #require(interrupted.positions.first { $0.lane.id == "short" })
        #expect(longCard.lane.trailing <= shortCard.lane.leading)
        #expect(longCard.top < interrupted.hours[1].top)
        #expect(longCard.top + longCard.height > interrupted.hours[1].top)
    }

    @Test func consecutiveShortEventsStayFullWidthInAdaptiveLayout() throws {
        let layout = dayTimeline([event("first", 15, 18), event("second", 18, 21)])
        try #require(layout.positions.count == 2)
        #expect(layout.positions.allSatisfy { $0.lane.lanes == 1 })
        #expect(layout.positions[0].top + layout.positions[0].height <= layout.positions[1].top)
        #expect(layout.hours[0].height > 76)
    }

    @Test func stackedTimelineRetainsEmptyAndRepeatedClockHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Lisbon"))
        let fallBack = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let day = try #require(calendar.dateInterval(of: .day, for: fallBack))
        let timeline = EventLayoutEngine.dayTimeline(for: [], in: day, calendar: calendar,
                                                      pointsPerHour: 76, minimumHeight: 44, layout: .stacked)
        #expect(timeline.hours.count == 25)
        #expect(timeline.hours.filter { calendar.component(.hour, from: $0.id) == 1 }.count == 2)
        #expect(timeline.height == 25 * 76)
        let repeatedHour = timeline.hours.last { calendar.component(.hour, from: $0.id) == 1 }
        let secondOneThirty = try #require(repeatedHour).id.addingTimeInterval(1800)
        let offset = try #require(timeline.offset(for: secondOneThirty))
        #expect(timeline.date(at: offset) == secondOneThirty)
    }

    @Test func timelineScrollOffsetKeepsClockTimeAcrossDifferentLayouts() throws {
        let crowded = dayTimeline([event("a", 10, 15), event("b", 12, 20), event("c", 12, 17)])
        let quiet = dayTimeline([])
        let time = base.addingTimeInterval(14 * 60 + 30)
        let crowdedOffset = try #require(crowded.offset(for: time))
        let quietOffset = try #require(quiet.offset(for: time))
        #expect(crowdedOffset > quietOffset)
        let savedTime = try #require(crowded.date(at: crowdedOffset))
        #expect(abs(savedTime.timeIntervalSince(time)) < 0.001)
        let restoredOffset = try #require(quiet.offset(for: savedTime))
        #expect(abs(restoredOffset - quietOffset) < 0.001)
    }

    private func dayTimeline(_ entries: [TimedInterval]) -> DayTimeline {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return EventLayoutEngine.dayTimeline(for: entries, in: DateInterval(start: base, duration: 7200),
                                             calendar: calendar, pointsPerHour: 76, minimumHeight: 44, layout: .stacked)
    }

    @Test func columnsModeUsesSideBySideLanesForOverlaps() {
        let range = DateInterval(start: base, duration: 7200)
        for entries in [
            [event("first", 0, 40), event("second", 35, 90)],
            [event("first", 0, 60), event("second", 40, 90)],
            [event("first", 0, 60), event("second", 53, 59)],
            [event("first", 0, 60), event("second", 0, 3)],
        ] {
            let layout = EventLayoutEngine.dayTimeline(for: entries, in: range, calendar: .current,
                                                       pointsPerHour: 76, minimumHeight: 44, layout: .columns)
            #expect(layout.positions.map(\.lane.lanes) == [2, 2])
            #expect(layout.positions.map(\.lane.lane) == [0, 1])
        }
    }

    @Test func denseFixtureHasOnePlacementPerEvent() {
        for count in [0, 10, 100, 1000] {
            let entries = (0..<count).map { event(String($0), $0 % 700, $0 % 700 + 20) }
            let range = DateInterval(start: base, duration: 86400)
            let layout = EventLayoutEngine.positions(for: entries, in: range, pointsPerHour: 76, minimumHeight: 44)
            #expect(layout.count == count)
            #expect(Set(layout.map(\.lane.id)).count == count)
            let stacked = EventLayoutEngine.dayTimeline(for: entries, in: range, calendar: .current,
                                                        pointsPerHour: 76, minimumHeight: 44, layout: .stacked)
            #expect(Set(stacked.positions.map(\.lane.id)).count == count)
            #expect(stacked.positions.count == count)
        }
    }
}
