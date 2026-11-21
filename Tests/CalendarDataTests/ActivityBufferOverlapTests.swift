import CalendarCore
import Foundation
import Testing
@testable import CalendarData

struct ActivityBufferOverlapTests {
    let day: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 12))!
    }()
    var range: DateInterval { DateInterval(start: day, duration: 86400) }
    func event(_ id: String, start: Double, end: Double, before: Int = 0, after: Int = 0, allDay: Bool = false) -> CalendarEvent {
        var details = ActivityDetails()
        if before > 0 { details.before = ActivityBuffer(minutes: before, kind: .travel, travelMode: .walking) }
        if after > 0 { details.after = ActivityBuffer(minutes: after, kind: .travel, travelMode: .walking) }
        let source = CalendarListItem(choice: .init(id: id, title: id, source: "Fixture", isWritable: true),
                                     color: .init(red: 0.9, green: 0.2, blue: 0.1))
        return CalendarEvent(id: .init(identifier: id, start: day + start * 60, occurrence: nil, calendarID: id),
                             title: id, end: day + end * 60, isAllDay: allDay, timeZoneID: "GMT", modified: nil,
                             isRecurring: false, calendar: source, notes: details.notes(description: "Keep notes."))
    }
    func lanes(_ events: [CalendarEvent], plan: ActivityBufferOverlapPlan) -> [String: LanePlacement] {
        let intervals = plan.laneIntervals(for: events) ?? events.map {
            TimedInterval(id: $0.id.layoutID, start: $0.occupiedStart, end: $0.occupiedEnd)
        }
        return Dictionary(uniqueKeysWithValues: EventLayoutEngine.lanes(for: intervals).map { ($0.id, $0) })
    }

    @Test func bufferOverlapCanUseOneColumnWithoutChangingStoredEvents() throws {
        let workshop = event("Workshop", start: 600, end: 660, before: 15, after: 10)
        let call = event("Call", start: 580, end: 595)
        let events = [workshop, call]
        let disabled = ActivityBufferOverlapPlan(events: events, in: range, enabled: false)
        #expect(disabled.isEmpty)
        #expect(lanes(events, plan: disabled)[workshop.id.layoutID]?.lanes == 2)
        let plan = ActivityBufferOverlapPlan(events: events, in: range, enabled: true)
        #expect(plan.overlaps.count == 1)
        #expect(lanes(events, plan: plan)[workshop.id.layoutID]?.lanes == 1)
        #expect(lanes(events, plan: plan)[call.id.layoutID]?.lanes == 1)
        let overlap = try #require(plan.overlaps.first)
        #expect(overlap.side == .before)
        #expect(overlap.interval == DateInterval(start: day + 585 * 60, end: day + 595 * 60))
        #expect(overlap.owner.id == workshop.id)
        #expect(overlap.target == call.id)
        #expect(workshop.start == day + 600 * 60)
        #expect(workshop.activityDetails.before?.minutes == 15)
    }

    @Test func realCoreOverlapsStillUseColumnsAndAfterTimeIsClippedPrecisely() {
        let workshop = event("Workshop", start: 600, end: 660, before: 15, after: 10)
        let work = event("Work", start: 630, end: 645)
        let call = event("Call", start: 665, end: 680)
        let events = [workshop, work, call]
        let plan = ActivityBufferOverlapPlan(events: events, in: range, enabled: true)
        #expect(lanes(events, plan: plan)[workshop.id.layoutID]?.lanes == 2)
        #expect(lanes(events, plan: plan)[work.id.layoutID]?.lanes == 2)
        #expect(lanes(events, plan: plan)[call.id.layoutID]?.lanes == 1)
        #expect(plan.overlaps.count == 1)
        #expect(plan.overlaps.first?.side == .after)
        #expect(plan.overlaps.first?.interval == DateInterval(start: day + 665 * 60, end: day + 670 * 60))
    }

    @Test func touchingEventsAndAllDayItemsDoNotCauseBlends() {
        let workshop = event("Workshop", start: 600, end: 660, before: 15, after: 10)
        let touchingBefore = event("Earlier", start: 560, end: 585)
        let touchingAfter = event("Later", start: 670, end: 690)
        let allDay = event("All day", start: 0, end: 1440, allDay: true)
        let events = [workshop, touchingBefore, touchingAfter, allDay]
        let plan = ActivityBufferOverlapPlan(events: events, in: range, enabled: true)
        #expect(plan.isEmpty)
        #expect(plan.laneIntervals(for: events) == nil)
    }

    @Test func crossMidnightExtensionsKeepOnlyTheVisibleSharedMinutes() {
        let nextDay = event("Tomorrow", start: 1445, end: 1500, before: 20)
        let call = event("Late call", start: 1420, end: 1435)
        let plan = ActivityBufferOverlapPlan(events: [nextDay, call], in: range, enabled: true)
        #expect(plan.overlaps.count == 1)
        #expect(plan.overlaps.first?.interval == DateInterval(start: day + 1425 * 60, end: day + 1435 * 60))
        #expect(lanes([nextDay, call], plan: plan)[call.id.layoutID]?.lanes == 1)
        let next = ActivityBufferOverlapPlan(events: [nextDay, call], in: DateInterval(start: range.end, duration: 86400), enabled: true)
        #expect(next.isEmpty)
    }

    @Test func adaptiveTimeMappingAndNativeOverlapUseDifferentSpans() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let workshop = event("Workshop", start: 600, end: 660, before: 15)
        let call = event("Call", start: 585, end: 595)
        let events = [workshop, call]
        let plan = ActivityBufferOverlapPlan(events: events, in: range, enabled: true)
        let intervals = events.map { TimedInterval(id: $0.id.layoutID, start: $0.occupiedStart, end: $0.occupiedEnd) }
        let readable = events.map { TimedInterval(id: $0.id.layoutID, start: $0.start, end: $0.end) }
        let timeline = EventLayoutEngine.dayTimeline(for: intervals, in: range, calendar: calendar,
            pointsPerHour: 76, minimumHeight: 44, layout: .stacked, readableIntervals: readable,
            laneIntervals: plan.laneIntervals(for: events))
        #expect(timeline.positions.count == 2)
        #expect(timeline.positions.allSatisfy { $0.lane.lanes == 1 })
        #expect((timeline.offset(for: call.end) ?? 0) - (timeline.offset(for: call.start) ?? 0) >= 44)
        #expect((timeline.offset(for: workshop.start) ?? 0) > (timeline.offset(for: call.end) ?? 0))
        let shortCall = event("Short call", start: 598, end: 600)
        let shortEvents = [workshop, shortCall]
        let shortPlan = ActivityBufferOverlapPlan(events: shortEvents, in: range, enabled: true)
        let fixed = EventLayoutEngine.dayTimeline(for: shortEvents.map {
            TimedInterval(id: $0.id.layoutID, start: $0.occupiedStart, end: $0.occupiedEnd)
        }, in: range, calendar: calendar, pointsPerHour: 76, minimumHeight: 44, layout: .columns,
            laneIntervals: shortPlan.laneIntervals(for: shortEvents), exactHeightIDs: shortPlan.affectedIDs)
        #expect(fixed.positions.allSatisfy { $0.lane.lanes == 1 })
        let shortPosition = fixed.positions.first { $0.lane.id == shortCall.id.layoutID }!
        #expect(shortPosition.top + shortPosition.height <= 600.0 / 60 * 76)
        let instant = event("Instant", start: 720, end: 720)
        let withInstant = shortEvents + [instant]
        let instantTimeline = EventLayoutEngine.dayTimeline(for: withInstant.map {
            TimedInterval(id: $0.id.layoutID, start: $0.occupiedStart, end: $0.occupiedEnd)
        }, in: range, calendar: calendar, pointsPerHour: 76, minimumHeight: 44, layout: .columns,
            laneIntervals: shortPlan.laneIntervals(for: withInstant), exactHeightIDs: shortPlan.affectedIDs)
        #expect(instantTimeline.positions.contains { $0.lane.id == instant.id.layoutID })
    }

    @Test func sweepProducesOneMatchPerConcurrentPairWithStableMarkerOrder() {
        let events = (0..<1000).map { index in
            event("Fixture \(index)", start: Double(index), end: Double(index) + 0.5, before: 1)
        }
        let plan = ActivityBufferOverlapPlan(events: events, in: range, enabled: true)
        #expect(plan.overlaps.count == 999)
        #expect(Set(plan.overlaps.map(\.id)).count == 999)
        #expect(plan.markerOwners(on: events[0].id.layoutID) == [events[1].id.layoutID])
    }
}
