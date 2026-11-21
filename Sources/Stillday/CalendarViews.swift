import CalendarCore
import CalendarData
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum CalendarEventAction {
    case open, edit, delete
}

struct CalendarEventButton<Label: View>: View {
    let event: CalendarEvent
    let model: CalendarModel
    let action: (CalendarEvent, CalendarEventAction) -> Void
    @ViewBuilder let label: () -> Label
    #if os(macOS)
    @State private var inspectedEvent: CalendarEvent?
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            if inspectedEvent == nil { inspectedEvent = event }
        } label: { label() }
            .popover(item: $inspectedEvent, arrowEdge: .trailing) { original in
                EventDetailsSheet(model: model, event: original, presentation: .popover(onDelete: {
                    inspectedEvent = nil
                    action(original, .delete)
                }))
            }
        #else
        Button { action(event, .open) } label: { label() }
        #endif
    }
}

private struct ActivityOwnsSurface: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var activityOwnsSurface: Bool {
        get { self[ActivityOwnsSurface.self] }
        set { self[ActivityOwnsSurface.self] = newValue }
    }
}

private struct CalendarEventSurface: ViewModifier {
    let color: Color
    @Environment(\.activityOwnsSurface) private var activityOwnsSurface
    func body(content: Content) -> some View {
        if activityOwnsSurface { content }
        else {
            content.background(color.opacity(0.19))
                .background(.background)
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
                .clipShape(.rect(cornerRadius: 6))
                .contentShape(Rectangle())
        }
    }
}

extension View {
    func calendarEventCardSurface(_ color: Color) -> some View {
        modifier(CalendarEventSurface(color: color))
    }

    func calendarEventMenu(_ event: CalendarEvent, model: CalendarModel,
                           action: @escaping (CalendarEvent, CalendarEventAction) -> Void,
                           hideAllDayBanner: (() -> Void)? = nil) -> some View {
        contextMenu {
            Button(model.isImportant(event) ? "Remove from Month Highlights" : "Mark Important",
                   systemImage: model.isImportant(event) ? "star.slash" : "star") {
                model.toggleImportance(event)
            }
            if model.writableCalendars.contains(where: { $0.id == event.id.calendarID }) {
                Button("Edit Event", systemImage: "pencil") { action(event, .edit) }
                Button("Delete Event", systemImage: "trash", role: .destructive) { action(event, .delete) }
            }
            if let hideAllDayBanner {
                Button("Hide All-Day Events Banner", systemImage: "eye.slash", action: hideAllDayBanner)
            }
        }
    }
}

struct DayView: View {
    let model: CalendarModel
    let navigationEnabled: Bool
    let eventAction: (CalendarEvent, CalendarEventAction) -> Void
    let openTask: (GoogleTaskDeadline) -> Void
    let showPreviewDate: (Date?) -> Void
    let addRange: (DateInterval) -> Void
    #if os(macOS)
    let editRange: (CalendarEvent, DateInterval) -> Void
    #endif
    let addAt: (Date) -> Void
    @ScaledMetric(relativeTo: .body) private var scaledHeight = 44.0
    @ScaledMetric(relativeTo: .caption) private var gutter = 43.0
    @Environment(\.scenePhase) private var phase
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewport = Viewport()
    @State private var paging = Paging()
    #if os(macOS)
    @State private var draggingEvent = false
    #endif
    @State private var expandedTasksDay: Date?
    @State private var taskExpansionFeedback = 0

    private let topPadding: CGFloat = 6
    private let bottomPadding: CGFloat = 8

    private final class Viewport {
        var timeAtTop: Date?
        var dragClock: Date?
        #if os(macOS)
        var trackpadDay: DateInterval?
        var trackpadTravel: CGFloat = 0
        #endif
        var isPulling = false
        var gaveFeedback = false
        var pullStart: CGFloat?
        var startedAtEdge: PullEdge?
        var layouts: [DateInterval: CachedLayout] = [:]
        var scrolls: [DateInterval: PageScroll] = [:]

        func scroll(for range: DateInterval) -> PageScroll {
            if let existing = scrolls[range] { return existing }
            let new = PageScroll()
            scrolls[range] = new
            return new
        }
    }

    @Observable fileprivate final class PageScroll {
        let initialID = UUID()
        var ready: UUID?
        var scrollY: CGFloat = 0
        var maximumOffset: CGFloat?
        @ObservationIgnored var pending: Placement?
        @ObservationIgnored var bannerFrame = CGRect.null
        #if os(iOS)
        @ObservationIgnored weak var nativeScroll: UIScrollView?
        @ObservationIgnored weak var bannerAnchor: UIView?
        #endif
        var hasNativePull: Bool {
            #if os(iOS)
            nativeScroll != nil
            #else
            false
            #endif
        }
    }

    fileprivate struct Placement {
        let id: UUID
        let offset: CGFloat
        var atEnd = false
    }

    @Observable fileprivate final class Paging {
        var turn: Turn?
        var offset = CGSize.zero
        var waitingForPage = false
        var settling: UUID?
        var pull = 0.0
        var pullEdge: PullEdge?
        var feedback = 0

        func reset() {
            turn = nil
            offset = .zero
            waitingForPage = false
            settling = nil
            pull = 0
            pullEdge = nil
        }
    }

    fileprivate struct Turn {
        let range: DateInterval
        let placement: Placement
        let entry: CGSize
    }

    fileprivate enum Landing: Equatable { case clock(Date?), start, end }

    fileprivate enum PullEdge {
        case top, bottom
        var step: Int { self == .top ? -1 : 1 }
        var landing: Landing { self == .top ? .end : .start }
        var destination: String { self == .top ? "previous day" : "next day" }
    }

    private struct TimelinePage {
        let range: DateInterval
        let timeline: DayTimeline
        let overlaps: ActivityBufferOverlapPlan
        let events: [String: CalendarEvent]
        let tasks: [GoogleTaskDeadline]
        let allDay: [CalendarEvent]
        let expandedListHeight: CGFloat?
        let bannerHeight: CGFloat
    }

    private struct LayoutInput: Equatable {
        let events: [CalendarEvent]
        let calendar: Calendar
        let pointsPerHour: Double
        let minimumHeight: Double
        let layout: TimelineLayout
        let blendsBuffers: Bool
    }

    private struct CachedLayout {
        let input: LayoutInput
        let timeline: DayTimeline
        let overlaps: ActivityBufferOverlapPlan
        let events: [String: CalendarEvent]
    }

    private struct ScrollTarget: Hashable { let day: Date }
    var body: some View {
        let range = model.window(for: .day)
        let previous = adjacent(to: range, step: -1)
        let next = adjacent(to: range, step: 1)
        let ranges = [range, previous, next]
        let pages = ranges.map(makePage)
        let incomingReady = paging.turn.map { viewport.scroll(for: $0.range).ready == $0.placement.id } ?? false
        GeometryReader { geometry in
            let size = geometry.size
            horizontalNavigation(
                PagingLayer(paging: paging, size: size, reduceMotion: reduceMotion, current: range,
                            pages: pages, incomingReady: incomingReady) { page, active, placement in
                    pageScroll(page, scroll: viewport.scroll(for: page.range), viewportSize: size,
                               active: active, placement: placement)
                },
                page: pages[0], size: size
            )
            .onChange(of: incomingReady) { _, ready in
                guard ready else { return }
                if paging.waitingForPage, let turn = paging.turn {
                    settle(turn, from: range, size: size)
                    return
                }
                #if os(macOS)
                if viewport.trackpadDay == range, abs(viewport.trackpadTravel) >= size.width {
                    moveTrackpad(by: 0, size: size)
                }
                #endif
            }
            #if os(macOS)
            .onChange(of: range.start) {
                if viewport.trackpadDay == range, viewport.trackpadTravel != 0 {
                    moveTrackpad(by: 0, size: size)
                }
            }
            #endif
        }
        .onChange(of: range.start) { _, _ in
            expandedTasksDay = nil
            let visible = Set(ranges)
            viewport.layouts = viewport.layouts.filter { visible.contains($0.key) }
            viewport.scrolls = viewport.scrolls.filter { visible.contains($0.key) }
            #if os(macOS)
            if viewport.trackpadDay != range {
                viewport.trackpadDay = nil
                paging.reset()
                showPreviewDate(nil)
            }
            #else
            paging.reset()
            showPreviewDate(nil)
            #endif
            viewport.isPulling = false
            viewport.pullStart = nil
            viewport.startedAtEdge = nil
            viewport.dragClock = nil
            if let current = pages.first, let scroll = viewport.scrolls[range], scroll.ready != nil {
                viewport.timeAtTop = current.timeline.date(at: scroll.scrollY - topPadding)
            }
        }
        .onChange(of: navigationEnabled) { _, enabled in
            if !enabled {
                expandedTasksDay = nil
                #if os(macOS)
                viewport.trackpadDay = nil
                #endif
                paging.reset()
                showPreviewDate(nil)
            }
        }
        .onChange(of: phase) { _, phase in
            if phase != .active { expandedTasksDay = nil }
        }
        .onChange(of: model.message) { _, message in
            if message != nil { paging.reset(); showPreviewDate(nil) }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: paging.feedback)
        .sensoryFeedback(.impact(weight: .light), trigger: taskExpansionFeedback)
    }

    private func makePage(for range: DateInterval) -> TimelinePage {
        let dailyEvents = model.events(in: range)
        let events = dailyEvents.filter { !$0.isAllDay }
        let allDay = dailyEvents.filter { $0.isAllDay && model.showsAllDay(calendarID: $0.calendar.id, in: .day) }
        let tasks = model.tasks(in: range, mode: .day)
        let rows = (allDay.isEmpty ? 0 : 1) + (tasks.isEmpty ? 0 : 1)
        let rowHeight = CGFloat(max(44, scaledHeight))
        let expandedListHeight = expandedTasksDay == range.start && !tasks.isEmpty
            ? min(CGFloat(tasks.count) * rowHeight, 176) : nil
        let extraHeight = expandedListHeight.map { $0 + 2 * rowHeight + 3 } ?? 0
        let bannerHeight = rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) + 6 + extraHeight
        #if os(macOS)
        let pointsPerHour = Double(model.desktopHourHeight)
        #else
        let pointsPerHour = Double(model.preferences.pointsPerHour)
        #endif
        let input = LayoutInput(events: events, calendar: model.calendar,
            pointsPerHour: pointsPerHour,
            minimumHeight: max(scaledHeight, Double(model.preferences.minimumEventHeight)),
            layout: model.preferences.timelineLayout ?? .stacked,
            blendsBuffers: model.preferences.blendActivityBuffers ?? false)
        let layout: CachedLayout
        if let cached = viewport.layouts[range], cached.input == input {
            layout = cached
        } else {
            let overlaps = ActivityBufferOverlapPlan(events: events, in: range, enabled: input.blendsBuffers)
            let intervals = events.map { TimedInterval(id: $0.id.layoutID, start: $0.occupiedStart, end: $0.occupiedEnd) }
            let readable = events.map { TimedInterval(id: $0.id.layoutID, start: $0.start, end: $0.end) }
            let buffers = events.flatMap { event -> [TimedInterval] in
                var parts: [TimedInterval] = []
                if event.occupiedStart < event.start {
                    parts.append(TimedInterval(id: event.id.layoutID + ":before", start: event.occupiedStart, end: event.start))
                }
                if event.end < event.occupiedEnd {
                    parts.append(TimedInterval(id: event.id.layoutID + ":after", start: event.end, end: event.occupiedEnd))
                }
                return parts
            }
            let timeline = EventLayoutEngine.dayTimeline(
                for: intervals, in: range, calendar: input.calendar, pointsPerHour: input.pointsPerHour,
                minimumHeight: input.minimumHeight, layout: input.layout, readableIntervals: readable,
                bufferIntervals: buffers, minimumBufferHeight: max(26, input.minimumHeight * 0.55),
                laneIntervals: overlaps.laneIntervals(for: events), exactHeightIDs: overlaps.affectedIDs
            )
            layout = CachedLayout(input: input, timeline: timeline, overlaps: overlaps,
                                  events: Dictionary(uniqueKeysWithValues: events.map { ($0.id.layoutID, $0) }))
            viewport.layouts[range] = layout
        }
        return TimelinePage(range: range, timeline: layout.timeline, overlaps: layout.overlaps, events: layout.events,
                            tasks: tasks, allDay: allDay, expandedListHeight: expandedListHeight,
                            bannerHeight: bannerHeight)
    }

    private func banner(for page: TimelinePage, scroll: PageScroll, active: Bool) -> some View {
        DayHighlights(model: model, tasks: page.tasks, allDay: page.allDay, rowHeight: max(44, scaledHeight),
                      expandedListHeight: page.expandedListHeight,
                      animateHighlights: active && navigationEnabled && phase == .active,
                      eventAction: eventAction, openTask: openTask) {
            if $0 && expandedTasksDay != page.range.start {
                taskExpansionFeedback += 1
            }
            expandedTasksDay = $0 ? page.range.start : nil
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            scroll.bannerFrame = $0
        }
        #if os(iOS)
        .background {
            BannerTouchAnchor { scroll.bannerAnchor = $0 }
        }
        #endif
    }

    private func contentHeight(for page: TimelinePage) -> CGFloat {
        page.timeline.height + topPadding + bottomPadding + page.bannerHeight
    }

    private func destinationOffset(_ landing: Landing, page: TimelinePage, viewportHeight: CGFloat) -> CGFloat {
        let maximum = viewport.scroll(for: page.range).maximumOffset
            ?? max(0, contentHeight(for: page) - viewportHeight)
        switch landing {
        case .start: return 0
        case .end: return maximum
        case .clock(let time):
            guard let time, let offset = page.timeline.offset(for: time), offset > 0 else { return 0 }
            return min(maximum, offset + topPadding)
        }
    }

    @ViewBuilder
    private func pageScroll(_ page: TimelinePage, scroll: PageScroll, viewportSize: CGSize,
                            active: Bool, placement: Placement?) -> some View {
        // The incoming page is placed while offscreen. Its request disappears on activation.
        let request = placement ?? (active && scroll.ready == nil && model.hasDaySnapshot(page.range)
            ? Placement(id: scroll.initialID, offset: initialOffset(for: page)) : nil)
        let content = canvas(page, viewportHeight: viewportSize.height, scroll: scroll)
            .overlay(alignment: .top) {
                if page.bannerHeight > 0 {
                    PinnedBanner(scroll: scroll, content: banner(for: page, scroll: scroll, active: active))
                }
            }
        if #available(iOS 18, macOS 15, *) {
            trackScroll(page, scroll: scroll, viewportSize: viewportSize, active: active) { content }
                .defaultScrollAnchor(.top, for: .initialOffset)
                .modifier(DayScrollPlacement(request: request, scroll: scroll, bannerHeight: page.bannerHeight,
                                             active: active, contentHeight: contentHeight(for: page),
                                             model: model, timeline: page.timeline, topPadding: topPadding,
                                             allowsZoom: active && navigationEnabled && paging.turn == nil))
        } else {
            ScrollViewReader { proxy in
                trackScroll(page, scroll: scroll, viewportSize: viewportSize, active: active) {
                    content.overlay(alignment: .topLeading) {
                        Color.clear.frame(width: 1, height: 1)
                            .id(ScrollTarget(day: page.range.start))
                            .padding(.top, request?.offset ?? 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .defaultScrollAnchor(.top)
                #if os(macOS)
                .modifier(DesktopTimelinePinch<CGFloat>(model: model,
                    enabled: active && navigationEnabled && paging.turn == nil))
                #endif
                .task(id: request?.id) {
                    guard let request, scroll.ready != request.id else { return }
                    proxy.scrollTo(ScrollTarget(day: page.range.start), anchor: .top)
                    await Task.yield()
                    if !Task.isCancelled { scroll.ready = request.id }
                }
            }
        }
    }

    @available(iOS 18, macOS 15, *)
    private struct DayScrollPlacement: ViewModifier {
        let request: Placement?
        let scroll: PageScroll
        let bannerHeight: CGFloat
        let active: Bool
        let contentHeight: CGFloat
        let model: CalendarModel
        let timeline: DayTimeline
        let topPadding: CGFloat
        let allowsZoom: Bool
        @State private var position = ScrollPosition()

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onChange(of: bannerHeight) { old, new in
                    guard active, scroll.pending == nil, scroll.ready != nil, scroll.scrollY > 1 else { return }
                    position.scrollTo(y: max(0, scroll.scrollY + new - old))
                }
                .task(id: request?.id) {
                    guard let request, scroll.ready != request.id else { return }
                    let maximum = scroll.maximumOffset ?? request.offset
                    let offset = request.atEnd ? maximum : min(request.offset, maximum)
                    scroll.pending = Placement(id: request.id, offset: offset, atEnd: request.atEnd)
                    #if os(iOS)
                    if positionNative(request) { return }
                    #endif
                    if abs(scroll.scrollY - offset) <= 0.5 {
                        finish(request.id)
                        return
                    }
                    if request.atEnd { position.scrollTo(edge: .bottom) }
                    else if offset == 0 { position.scrollTo(edge: .top) }
                    else { position.scrollTo(y: offset) }

                    // An offscreen viewport can clamp an offset without sending another geometry event.
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled, scroll.pending?.id == request.id else { return }
                    #if os(iOS)
                    if positionNative(request) { return }
                    #endif
                    finish(request.id)
                }
                #if os(macOS)
                .modifier(DesktopTimelinePinch(model: model, enabled: allowsZoom, capture: { y in
                    timeline.date(at: scroll.scrollY + y - topPadding - bannerHeight)
                }, restore: { date, y in
                    guard let offset = timeline.offset(for: date) else { return }
                    position.scrollTo(y: max(0, offset + topPadding + bannerHeight - y))
                }))
                #endif
        }

        private func finish(_ id: UUID) {
            scroll.pending = nil
            scroll.ready = id
        }

        #if os(iOS)
        private func positionNative(_ request: Placement) -> Bool {
            guard let native = scroll.nativeScroll,
                  abs(native.contentSize.height - contentHeight) < 2, native.bounds.height > 0 else { return false }
            let inset = native.adjustedContentInset
            let maximum = max(0, native.contentSize.height - native.bounds.height + inset.top + inset.bottom)
            native.stopScrollingAndZooming()
            let offset = request.atEnd ? maximum : min(request.offset, maximum)
            native.setContentOffset(CGPoint(x: native.contentOffset.x, y: offset - inset.top), animated: false)
            scroll.scrollY = native.contentOffset.y + inset.top
            scroll.maximumOffset = maximum
            finish(request.id)
            return true
        }
        #endif
    }

    private func canvas(_ page: TimelinePage, viewportHeight: CGFloat, scroll: PageScroll) -> some View {
        let timeline = page.timeline
        return ZStack(alignment: .topLeading) {
            hourGrid(timeline.hours)
            #if os(macOS)
            if navigationEnabled && !model.writableCalendars.isEmpty,
               let last = timeline.hours.last {
                let endOffset = last.top + last.height
                DesktopTimelineSelection(model: model, dateAtOffset: { offset in
                    if offset >= endOffset { return page.range.end }
                    let date = timeline.date(at: offset) ?? page.range.start
                    return DesktopTimelineSelection.snappedDate(date, in: page.range, calendar: model.calendar)
                }, offsetForDate: { date in
                    date >= page.range.end ? endOffset : timeline.offset(for: date) ?? 0
                }, addRange: { range in
                    if paging.turn == nil { addRange(range) }
                }, addAt: { date in
                    if date < page.range.end { addAt(date) }
                })
                .frame(height: endOffset)
                .padding(.leading, gutter)
            }
            #endif
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - gutter - 8)
                let placements = Dictionary(uniqueKeysWithValues: timeline.positions.map { ($0.lane.id, $0) })
                ForEach(page.overlaps.isEmpty ? [0] : [-1, 0], id: \.self) { pass in
                    ForEach(timeline.positions) { placement in
                        if let event = page.events[placement.lane.id], pass == 0 || page.overlaps.isEmpty
                            || event.activityDetails.before != nil || event.activityDetails.after != nil {
                            let left = gutter + placement.lane.leading * width
                            let cardWidth = max(1, (placement.lane.trailing - placement.lane.leading) * width - 3)
                            let beforeEnd = timeline.offset(for: min(max(event.start, page.range.start), page.range.end)) ?? timeline.height
                            let afterStart = timeline.offset(for: min(max(event.end, page.range.start), page.range.end)) ?? timeline.height
                            let beforeHeight = event.activityDetails.before == nil ? 0 : min(placement.height, max(0, beforeEnd - placement.top))
                            let afterHeight = event.activityDetails.after == nil ? 0 : min(placement.height - beforeHeight, max(0, placement.top + placement.height - afterStart))
                            let card = eventCard(event, width: cardWidth, height: placement.height, part: placement.part,
                                                 beforeHeight: beforeHeight, afterHeight: afterHeight,
                                                 renderPart: page.overlaps.isEmpty ? .whole : pass == -1 ? .extensions : .core,
                                                 beforeCovered: pass == -1 ? coveredBuffer(event, side: .before, origin: placement.top, page: page, placements: placements) : [],
                                                 afterCovered: pass == -1 ? coveredBuffer(event, side: .after, origin: afterStart, page: page, placements: placements) : [],
                                                 coreCovered: coveredCore(event, origin: placement.top, page: page, placements: placements))
                                .accessibilityHidden((pass == -1 && placement.height - beforeHeight - afterHeight > 0)
                                                     || (pass == 0 && !page.overlaps.isEmpty && placement.height - beforeHeight - afterHeight <= 0))
                            #if os(macOS)
                            card.modifier(DesktopEventDrag(model: model, event: event, width: cardWidth,
                                                           height: placement.height, canResizeStart: event.start >= page.range.start,
                                                           canResizeEnd: event.end <= page.range.end, previewForDrag: { part, value in
                                dayDrag(event, part: part, value: value, page: page, cardTop: placement.top)
                            }, editRange: { event, range in
                                if paging.turn == nil { editRange(event, range) }
                            }, onDragChanged: { draggingEvent = $0 },
                               hitShape: ActivityCardHitShape(part: page.overlaps.isEmpty ? .whole : pass == -1 ? .extensions : .core,
                                                             before: beforeHeight, after: afterHeight)))
                            .offset(x: left, y: placement.top)
                            #else
                            card.offset(x: left, y: placement.top)
                            #endif
                        }
                    }
                }
                if !page.overlaps.isEmpty {
                    ActivityOverlapOverlay(marks: dayOverlapMarks(page, width: width, placements: placements), model: model)
                        .frame(height: timeline.height)
                }
            }
            TimeRuler(timeline: timeline, hourLabels: timeline.hours.map {
                model.time($0.interval.start, hourOnly: true)
            }, model: model, scroll: scroll, viewportHeight: viewportHeight,
                      topPadding: topPadding + page.bannerHeight, gutter: gutter,
                      showsCurrentTime: phase == .active && model.calendar.isDateInToday(page.range.start))
        }
        .frame(height: timeline.height + bottomPadding)
        .padding(.top, topPadding + page.bannerHeight)
    }

    private func coveredBuffer(_ event: CalendarEvent, side: ActivityBufferOverlap.Side, origin: CGFloat,
                               page: TimelinePage, placements: [String: TimelinePosition]) -> [ClosedRange<CGFloat>] {
        guard let owner = placements[event.id.layoutID] else { return [] }
        return (page.overlaps.byOwner[event.id.layoutID] ?? []).compactMap { overlap in
            guard overlap.side == side, let target = placements[overlap.target.layoutID],
                  owner.lane.leading < target.lane.trailing, target.lane.leading < owner.lane.trailing else { return nil }
            let start = page.timeline.offset(for: overlap.interval.start) ?? 0
            let end = page.timeline.offset(for: overlap.interval.end) ?? page.timeline.height
            return (start - origin)...(end - origin)
        }
    }

    private func coveredCore(_ event: CalendarEvent, origin: CGFloat, page: TimelinePage,
                             placements: [String: TimelinePosition]) -> [ClosedRange<CGFloat>] {
        guard let target = placements[event.id.layoutID] else { return [] }
        return (page.overlaps.byTarget[event.id.layoutID] ?? []).compactMap { overlap -> ClosedRange<CGFloat>? in
            guard let owner = placements[overlap.owner.id.layoutID],
                  owner.lane.leading < target.lane.trailing, target.lane.leading < owner.lane.trailing else { return nil }
            let start = (page.timeline.offset(for: overlap.interval.start) ?? 0) - origin
            let end = (page.timeline.offset(for: overlap.interval.end) ?? page.timeline.height) - origin
            return start...end
        }
    }

    private func dayOverlapMarks(_ page: TimelinePage, width: CGFloat,
                                 placements: [String: TimelinePosition]) -> [ActivityOverlapMark] {
        page.overlaps.overlaps.compactMap { overlap in
            guard let target = placements[overlap.target.layoutID], let owner = placements[overlap.owner.id.layoutID],
                  owner.lane.leading < target.lane.trailing, target.lane.leading < owner.lane.trailing else { return nil }
            let start = max(target.top, page.timeline.offset(for: overlap.interval.start) ?? 0)
            let end = min(target.top + target.height, page.timeline.offset(for: overlap.interval.end) ?? page.timeline.height)
            let rect = CGRect(x: gutter + target.lane.leading * width, y: start,
                              width: max(1, (target.lane.trailing - target.lane.leading) * width - 3), height: max(0, end - start))
            return ActivityOverlapMark(overlap: overlap, rect: rect,
                index: page.overlaps.markerOwners(on: overlap.target.layoutID).firstIndex(of: overlap.owner.id.layoutID) ?? 0,
                clipRect: CGRect(x: rect.minX, y: target.top, width: rect.width, height: target.height))
        }
    }

    #if os(macOS)
    private func dayDrag(_ event: CalendarEvent, part: DesktopEventDragPart, value: DragGesture.Value,
                         page: TimelinePage, cardTop: CGFloat) -> DesktopEventDragPreview? {
        guard event.start < event.end,
              abs(value.translation.height) >= abs(value.translation.width) * 0.75 else { return nil }
        let timeline = page.timeline
        let y = cardTop + value.startLocation.y
        guard let from = timeline.date(at: y), let to = timeline.date(at: y + value.translation.height) else { return nil }
        let original = DateInterval(start: event.start, end: event.end)
        let range = part.adjust(original, seconds: to.timeIntervalSince(from),
                                stepMinutes: (model.preferences.eventDragStep ?? .fifteen).rawValue,
                                calendar: model.calendar)
        let start = max(page.range.start, range.start)
        let end = min(page.range.end, range.end)
        guard range != original, start < end, let top = timeline.offset(for: start) else { return nil }
        let bottom = timeline.offset(for: end) ?? timeline.hours.last.map { $0.top + $0.height } ?? timeline.height
        return DesktopEventDragPreview(range: range, offset: CGSize(width: 0, height: top - cardTop),
                                       height: max(15, bottom - top - 2))
    }
    #endif

    private struct TimeRuler: View {
        let timeline: DayTimeline
        let hourLabels: [String]
        let model: CalendarModel
        let scroll: PageScroll
        let viewportHeight: CGFloat
        let topPadding: CGFloat
        let gutter: CGFloat
        let showsCurrentTime: Bool
        @ScaledMetric(relativeTo: .caption) private var labelClearance = 14.0

        var body: some View {
            Group {
                if showsCurrentTime {
                    TimelineView(.everyMinute) { context in
                        let minute = model.calendar.dateInterval(of: .minute, for: context.date)?.start ?? context.date
                        labels(now: minute)
                    }
                } else {
                    labels(now: nil)
                }
            }
            .allowsHitTesting(false)
        }

        private func labels(now: Date?) -> some View {
            let offset = now.flatMap { timeline.offset(for: $0) }.flatMap { y in
                y + topPadding - scroll.scrollY + 4 <= viewportHeight ? y : nil
            }
            return ZStack(alignment: .topLeading) {
                ForEach(Array(zip(timeline.hours, hourLabels)), id: \.0.id) { hour, label in
                    if !overlaps(hour, offset: offset) {
                        timeLabel(label)
                            .foregroundStyle(.secondary)
                            .frame(height: 0)
                            .offset(y: hour.top)
                            .accessibilityHidden(true)
                    }
                }
                if let now, let offset {
                    let fullTime = model.time(now)
                    let minute = model.calendar.component(.minute, from: now)
                        .formatted(.number.precision(.integerLength(2)))
                    let replacesHour = timeline.hours.contains { overlaps($0, offset: offset) }
                    HStack(spacing: 6) {
                        timeLabel(replacesHour ? fullTime : ":\(minute)")
                            .fontWeight(.semibold)
                        HStack(spacing: 0) {
                            Circle().frame(width: 7, height: 7)
                            Rectangle().frame(height: 2)
                        }
                    }
                    .foregroundStyle(model.accentColor)
                    .frame(height: 7)
                    .offset(y: offset - 3.5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current time, \(fullTime)")
                }
            }
        }

        private func overlaps(_ hour: TimelineHour, offset: Double?) -> Bool {
            guard let offset else { return false }
            return abs(hour.top - offset) < labelClearance
        }

        private func timeLabel(_ value: String) -> some View {
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: gutter - 10, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func trackScroll<Content: View>(_ page: TimelinePage, scroll: PageScroll, viewportSize: CGSize,
                                            active: Bool, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            ScrollView {
                content()
                    #if os(iOS)
                    .background {
                        NativeDayPull(onAttach: { scroll.nativeScroll = $0 }, ignoresStart: { start, window in
                            guard page.expandedListHeight != nil, let banner = scroll.bannerAnchor else { return false }
                            return banner.bounds.contains(banner.convert(start, from: window))
                        }) { state, travel, top, bottom in
                            guard active else { return }
                            handleNativePull(state, travel: travel, distanceToTop: top,
                                             distanceToBottom: bottom, from: page.range, size: viewportSize)
                        }
                    }
                    #endif
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(geometry, topPadding: topPadding)
            } action: { _, metrics in
                scroll.scrollY = metrics.scrollY
                scroll.maximumOffset = metrics.maximumOffset
                if let request = scroll.pending,
                   abs(metrics.scrollY - (request.atEnd ? metrics.maximumOffset : min(request.offset, metrics.maximumOffset))) <= 0.5 {
                    scroll.pending = nil
                    scroll.ready = request.id
                }
                if active, paging.turn == nil, scroll.ready != nil {
                    viewport.timeAtTop = page.timeline.date(at: metrics.timelineOffset)
                    if !scroll.hasNativePull, viewport.isPulling, navigationEnabled {
                        updateOverscrollPull(metrics)
                    }
                }
            }
            .onScrollPhaseChange { old, new, context in
                guard active, !scroll.hasNativePull, paging.turn == nil else { return }
                if new == .interacting {
                    viewport.isPulling = true
                    viewport.gaveFeedback = false
                } else if old == .interacting {
                    viewport.isPulling = false
                    let release = ScrollMetrics(context.geometry, topPadding: topPadding)
                    if release.topOverscroll > 0 || release.bottomOverscroll > 0 { updateOverscrollPull(release) }
                    finishPull(from: page.range, size: viewportSize)
                }
            }
            .overlay(alignment: .bottom) {
                if active {
                    PullIndicator(paging: paging, scroll: scroll, date: adjacent(to: page.range, step: 1).start,
                                  edge: .bottom, inset: 34, accent: model.accentColor, reduceMotion: reduceMotion)
                }
            }
            .overlay(alignment: .top) {
                if active {
                    PullIndicator(paging: paging, scroll: scroll, date: adjacent(to: page.range, step: -1).start,
                                  edge: .top, inset: page.bannerHeight + 23, accent: model.accentColor,
                                  reduceMotion: reduceMotion)
                }
            }
            .accessibilityAction(named: Text("Next day at midnight")) {
                if active { turnAtEdge(.bottom, from: page.range, size: viewportSize) }
            }
            .accessibilityAction(named: Text("End of previous day")) {
                if active { turnAtEdge(.top, from: page.range, size: viewportSize) }
            }
        } else {
            ScrollView {
                content().onGeometryChange(for: Double.self) { geometry in
                    -geometry.frame(in: .scrollView(axis: .vertical)).minY - topPadding
                } action: { offset in
                    scroll.scrollY = offset + topPadding
                    if active, paging.turn == nil { viewport.timeAtTop = page.timeline.date(at: offset) }
                }
            }
        }
    }

    private struct ScrollMetrics: Equatable {
        let timelineOffset: Double
        let topOverscroll: Double
        let bottomOverscroll: Double
        let scrollY: CGFloat
        let maximumOffset: CGFloat

        @available(iOS 18, macOS 15, *)
        init(_ geometry: ScrollGeometry, topPadding: CGFloat) {
            let insets = geometry.contentInsets
            let bottom = max(-insets.top, geometry.contentSize.height - geometry.containerSize.height + insets.bottom)
            scrollY = geometry.contentOffset.y + insets.top
            timelineOffset = scrollY - topPadding
            topOverscroll = max(0, -scrollY)
            bottomOverscroll = max(0, geometry.contentOffset.y - bottom)
            maximumOffset = bottom + insets.top
        }
    }

    private func clock(_ time: Date?, on range: DateInterval) -> Date? {
        guard let time else { return nil }
        let calendar = model.calendar
        let rounded = Date(timeIntervalSinceReferenceDate: time.timeIntervalSinceReferenceDate.rounded())
        let clock = calendar.dateComponents([.hour, .minute, .second], from: rounded)
        guard let date = calendar.nextDate(after: range.start.addingTimeInterval(-1), matching: clock,
                                           matchingPolicy: .nextTime),
              date < range.end else { return nil }
        return date
    }

    private func initialOffset(for page: TimelinePage) -> CGFloat {
        let timeline = page.timeline
        if let target = clock(viewport.timeAtTop, on: page.range), let offset = timeline.offset(for: target) {
            return offset > 0 ? offset + topPadding : 0
        }
        let now = Date()
        if let current = timeline.hours.firstIndex(where: { $0.interval.start <= now && now < $0.interval.end }) {
            let offset = timeline.hours[max(0, current - 1)].top
            return offset > 0 ? offset + topPadding : 0
        }
        let offset = timeline.hours.first(where: { model.calendar.component(.hour, from: $0.id) == 8 })?.top ?? 0
        return offset > 0 ? offset + topPadding : 0
    }

    private func adjacent(to range: DateInterval, step: Int) -> DateInterval {
        let calendar = model.calendar
        let day = CalendarViewMode.day.advance(range.start, by: step, calendar: calendar)
        return CalendarViewMode.day.window(for: day, calendar: calendar)
    }

    @ViewBuilder
    private func horizontalNavigation<Content: View>(_ content: Content, page: TimelinePage, size: CGSize) -> some View {
        let origin = page.range
        let scroll = viewport.scroll(for: origin)
        #if os(iOS)
        if #available(iOS 18, *) {
            content.gesture(CalendarPageSwipe(
                onChanged: { drag($0.width, from: origin, size: size) },
                onCancelled: { cancelDrag() },
                allowsTouch: { touch in
                    guard page.bannerHeight > 0, let banner = scroll.bannerAnchor,
                          banner.window != nil, banner.window === touch.window else { return true }
                    return !banner.bounds.contains(touch.location(in: banner))
                },
                onEnded: { travel, projected in endDrag(travel, projected: projected, from: origin, size: size) }
            ))
        } else {
            content.simultaneousGesture(legacyDrag(from: page, scroll: scroll, size: size))
        }
        #else
        content
            .clipped()
            .simultaneousGesture(legacyDrag(from: page, scroll: scroll, size: size))
            .background {
                DesktopHorizontalTrackpad(canStart: { y in
                    navigationEnabled && !draggingEvent && paging.settling == nil && !paging.waitingForPage
                        && (paging.turn?.entry.height ?? 0) == 0 && y >= page.bannerHeight
                }, move: { distance in
                    moveTrackpad(by: distance, size: size)
                }, finish: { projection in
                    finishTrackpad(projection, size: size)
                })
            }
        #endif
    }

    #if os(macOS)
    private func moveTrackpad(by distance: CGFloat, size: CGSize) {
        guard navigationEnabled, !draggingEvent, size.width > 0, paging.settling == nil,
              !paging.waitingForPage, (paging.turn?.entry.height ?? 0) == 0 else { return }
        let origin = model.window(for: .day)
        if viewport.trackpadDay != origin {
            viewport.trackpadDay = origin
            viewport.trackpadTravel = 0
        }
        viewport.trackpadTravel += distance
        let travel = viewport.trackpadTravel
        if travel == 0, paging.turn == nil { return }
        drag(travel, from: origin, size: size)
        guard abs(travel) >= size.width, let turn = paging.turn,
              viewport.scroll(for: turn.range).ready == turn.placement.id else { return }
        // Once a full day has passed under the fingers, carry the remaining motion into the next day.
        viewport.trackpadTravel = travel + turn.entry.width * size.width
        viewport.trackpadDay = turn.range
        commit(turn)
        showPreviewDate(nil)
    }

    private func finishTrackpad(_ projection: CGFloat?, size: CGSize) {
        let origin = model.window(for: .day)
        guard viewport.trackpadDay == origin else { return }
        viewport.trackpadDay = nil
        guard let projection else {
            cancelDrag()
            return
        }
        let travel = viewport.trackpadTravel
        endDrag(CGSize(width: travel, height: 0), projected: CGSize(width: travel + projection, height: 0),
                from: origin, size: size, thresholdWidth: size.width * 0.7)
    }
    #endif

    private func legacyDrag(from page: TimelinePage, scroll: PageScroll, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .onChanged { value in
                #if os(macOS)
                guard !draggingEvent else { return }
                #endif
                guard page.bannerHeight == 0 || !scroll.bannerFrame.contains(value.startLocation) else { return }
                if paging.turn != nil || abs(value.translation.width) > 1.65 * abs(value.translation.height) {
                    drag(value.translation.width, from: page.range, size: size)
                }
            }
            .onEnded { value in
                #if os(macOS)
                guard !draggingEvent else { return }
                #endif
                guard page.bannerHeight == 0 || !scroll.bannerFrame.contains(value.startLocation) else { return }
                endDrag(value.translation, projected: value.predictedEndTranslation, from: page.range, size: size)
            }
    }

    private func drag(_ x: CGFloat, from origin: DateInterval, size: CGSize) {
        let width = size.width
        guard navigationEnabled, width > 0, paging.settling == nil, !paging.waitingForPage,
              (paging.turn?.entry.height ?? 0) == 0 else { return }
        if paging.turn == nil {
            let page = makePage(for: origin)
            let offset = viewport.scroll(for: origin).scrollY
            viewport.dragClock = page.timeline.date(at: offset - topPadding)
        }
        let direction = x < 0 ? 1 : -1
        if paging.turn?.entry.width != CGFloat(direction) {
            let step = layoutDirection == .rightToLeft ? -direction : direction
            let next = adjacent(to: origin, step: step)
            let offset = destinationOffset(.clock(clock(viewport.dragClock, on: next)), page: makePage(for: next),
                                           viewportHeight: size.height)
            paging.turn = Turn(range: next, placement: Placement(id: UUID(), offset: offset),
                               entry: CGSize(width: direction, height: 0))
        }
        paging.pull = 0
        paging.pullEdge = nil
        paging.offset.width = max(-width, min(width, x))
        showPreviewDate(abs(x) >= width * 0.33 ? paging.turn?.range.start : nil)
    }

    private func endDrag(_ travel: CGSize, projected: CGSize, from origin: DateInterval, size: CGSize,
                         thresholdWidth: CGFloat? = nil) {
        guard paging.turn != nil, paging.settling == nil, !paging.waitingForPage, paging.turn?.entry.height == 0 else { return }
        guard abs(travel.width) > 1.35 * abs(travel.height),
              DayPaging.horizontalDirection(translation: travel.width, projected: projected.width,
                                            width: thresholdWidth ?? size.width) != nil else {
            cancelDrag()
            return
        }
        drag(travel.width, from: origin, size: size)
        if let turn = paging.turn { settle(turn, from: origin, size: size) }
    }

    private func cancelDrag() {
        guard paging.turn != nil, paging.settling == nil, !paging.waitingForPage, paging.turn?.entry.height == 0 else { return }
        let token = UUID()
        paging.settling = token
        showPreviewDate(nil)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), completionCriteria: .removed) {
            paging.offset = .zero
        } completion: {
            if paging.settling == token { paging.reset() }
        }
    }

    #if os(iOS)
    private func handleNativePull(_ state: UIGestureRecognizer.State, travel: CGPoint,
                                  distanceToTop: CGFloat, distanceToBottom: CGFloat,
                                  from day: DateInterval, size: CGSize) {
        guard day == model.window(for: .day), navigationEnabled,
              paging.turn == nil, paging.settling == nil else { return }
        switch state {
        case .began:
            viewport.gaveFeedback = false
            viewport.pullStart = nil
            viewport.startedAtEdge = distanceToTop <= 4 ? .top : distanceToBottom <= 4 ? .bottom : nil
        case .changed:
            let edge: PullEdge = travel.y > 0 ? .top : .bottom
            let distance = edge == .top ? distanceToTop : distanceToBottom
            let vertical = abs(travel.y)
            guard distance <= 4, vertical > abs(travel.x) else {
                clearPull()
                return
            }
            if paging.pullEdge != edge {
                viewport.pullStart = viewport.startedAtEdge == edge ? 0 : vertical
            }
            let progress = DayPaging.pullProgress(travel: vertical - (viewport.pullStart ?? vertical),
                                                  viewportHeight: size.height)
            setPullProgress(progress, edge: edge)
        case .ended:
            finishPull(from: day, size: size)
        case .cancelled, .failed:
            clearPull()
        default:
            break
        }
    }
    #endif

    private func updateOverscrollPull(_ metrics: ScrollMetrics) {
        let edge: PullEdge = metrics.topOverscroll > 0 ? .top : .bottom
        let distance = edge == .top ? metrics.topOverscroll : metrics.bottomOverscroll
        setPullProgress(DayPaging.pullProgress(overscroll: distance), edge: edge)
    }

    private func clearPull() {
        viewport.pullStart = nil
        paging.pull = 0
        paging.pullEdge = nil
    }

    private func finishPull(from origin: DateInterval, size: CGSize) {
        if paging.pull >= 1, let edge = paging.pullEdge {
            turnAtEdge(edge, from: origin, size: size)
        } else {
            clearPull()
        }
        viewport.startedAtEdge = nil
    }

    private func setPullProgress(_ progress: Double, edge: PullEdge) {
        paging.pull = progress
        paging.pullEdge = edge
        if progress == 1 && !viewport.gaveFeedback {
            viewport.gaveFeedback = true
            paging.feedback += 1
        }
    }

    private func turnAtEdge(_ edge: PullEdge, from origin: DateInterval, size: CGSize) {
        guard navigationEnabled, paging.turn == nil, paging.settling == nil else { return }
        let range = adjacent(to: origin, step: edge.step)
        let target = destinationOffset(edge.landing, page: makePage(for: range),
                                       viewportHeight: size.height)
        let turn = Turn(range: range, placement: Placement(id: UUID(), offset: target, atEnd: edge == .top),
                        entry: CGSize(width: 0, height: edge.step))
        paging.turn = turn
        settle(turn, from: origin, size: size)
    }

    private func settle(_ turn: Turn, from origin: DateInterval, size: CGSize) {
        guard viewport.scroll(for: turn.range).ready == turn.placement.id else {
            paging.waitingForPage = true
            return
        }
        let token = UUID()
        paging.waitingForPage = false
        paging.settling = token
        showPreviewDate(turn.range.start)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.27), completionCriteria: .removed) {
            paging.offset = CGSize(width: -turn.entry.width * size.width, height: -turn.entry.height * size.height)
            if turn.entry.height == 0 { paging.pull = 0 }
        } completion: {
            guard paging.settling == token, model.window(for: .day) == origin else { return }
            commit(turn)
        }
    }

    private func commit(_ turn: Turn) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        if #available(iOS 18, macOS 15, *) { transaction.scrollContentOffsetAdjustmentBehavior = .disabled }
        withTransaction(transaction) {
            paging.reset()
            model.selection = turn.range.start
        }
    }

    private struct PagingLayer<Surface: View>: View {
        let paging: Paging
        let size: CGSize
        let reduceMotion: Bool
        let current: DateInterval
        let pages: [TimelinePage]
        let incomingReady: Bool
        @ViewBuilder let surface: (TimelinePage, Bool, Placement?) -> Surface

        var body: some View {
            let turn = paging.turn
            let shift = incomingReady && !reduceMotion ? paging.offset : .zero
            Color.clear.frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    ForEach(pages, id: \.range.start) { page in
                        let active = page.range == current
                        let incoming = turn?.range == page.range ? turn : nil
                        let entry = active ? CGSize.zero : incoming?.entry ?? CGSize(width: 2, height: 0)
                        surface(page, active, incoming?.placement)
                            .frame(width: size.width, height: size.height)
                            .background(.background, ignoresSafeAreaEdges: [])
                            .offset(x: entry.width * size.width + shift.width, y: entry.height * size.height + shift.height)
                            .opacity(active || (incoming != nil && incomingReady && !reduceMotion) ? 1 : 0)
                            .allowsHitTesting(active && paging.settling == nil && !paging.waitingForPage)
                            .accessibilityHidden(!active)
                    }
                }
        }
    }

    private struct PinnedBanner<Content: View>: View {
        let scroll: PageScroll
        let content: Content

        var body: some View {
            content.offset(y: scroll.scrollY)
        }
    }

    private struct PullIndicator: View {
        let paging: Paging
        let scroll: PageScroll
        let date: Date
        let edge: PullEdge
        let inset: CGFloat
        let accent: Color
        let reduceMotion: Bool
        @ScaledMetric(relativeTo: .title3) private var diameter = 62.0

        var body: some View {
            let progress = paging.pullEdge == edge ? paging.pull : 0
            let atEdge = scroll.maximumOffset.map { maximum in
                edge == .top ? scroll.scrollY <= 10 : maximum - scroll.scrollY <= 10
            } ?? false
            let visible = (atEdge || progress > 0)
                && (paging.turn?.entry.width ?? 0) == 0
                && (paging.pullEdge == nil || paging.pullEdge == edge)
            ZStack {
                if visible {
                    VStack(spacing: 7) {
                        ZStack {
                            Circle().strokeBorder(accent.opacity(0.32), lineWidth: 3)
                            if progress > 0 {
                                Circle().trim(from: 0, to: progress)
                                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .padding(1.5)
                            }
                            Text(date.formatted(.dateTime.day()))
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(progress >= 1 ? accent : .primary)
                        }
                        .padding(5)
                        .frame(width: diameter, height: diameter)
                        .calendarControlGlass(in: Circle(), interactive: false)

                        Text(progress >= 1 ? "Release for \(edge.destination)" : "Pull for \(edge.destination)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(edge == .top ? .top : .bottom, inset)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func hourGrid(_ hours: [TimelineHour]) -> some View {
        VStack(spacing: 0) {
            ForEach(hours) { hour in
                let date = hour.interval.start
                let canAdd = !model.writableCalendars.isEmpty
                Rectangle().fill(Color.secondary.opacity(0.14)).frame(height: 1)
                .padding(.leading, gutter - 2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: hour.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { if canAdd { addAt(date) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(canAdd ? "New event at \(model.time(date))" : model.time(date))
                .accessibilityAddTraits(canAdd ? .isButton : [])
                .accessibilityAction { if canAdd { addAt(date) } }
            }
        }
    }

    private func eventCard(_ event: CalendarEvent, width: Double, height: Double, part: DateInterval?,
                           beforeHeight: Double, afterHeight: Double, renderPart: ActivityCardPart = .whole,
                           beforeCovered: [ClosedRange<CGFloat>] = [], afterCovered: [ClosedRange<CGFloat>] = [],
                           coreCovered: [ClosedRange<CGFloat>] = []) -> some View {
        let continued = part.map { $0.start > event.start } ?? false
        let time = part.map { "\(model.time($0.start))–\(model.time($0.end))" } ?? model.timeLabel(event)
        return CalendarEventButton(event: event, model: model, action: eventAction) {
            ActivityEventCard(event: event, model: model, height: height,
                              beforeHeight: beforeHeight, afterHeight: afterHeight, part: renderPart,
                              beforeCovered: beforeCovered, afterCovered: afterCovered, coreCovered: coreCovered) { mainHeight in
            #if os(macOS)
            DesktopTimedCardLabel(title: continued ? "↳ \(event.displayTitle)" : event.displayTitle,
                                  time: time, color: model.eventColor(event).swiftUI, height: mainHeight)
                .frame(width: width)
            #else
            VStack(alignment: .leading, spacing: 1) {
                if renderPart == .whole || mainHeight >= scaledHeight * 0.65 {
                HStack(spacing: 4) {
                    if continued {
                        Image(systemName: "arrow.turn.down.right").accessibilityHidden(true)
                    }
                    Text(event.displayTitle)
                        .lineLimit(mainHeight >= scaledHeight * 1.4 ? 2 : 1)
                }
                .font(.subheadline.weight(.semibold))
                if width >= 62 && (renderPart == .whole || mainHeight >= scaledHeight) {
                    Text(time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.74))
                        .lineLimit(1)
                }
                }
            }
            .padding(.leading, width > 32 ? 8 : 2)
            .padding(.trailing, width > 32 ? 8 : 2)
            .padding(.vertical, 4)
            .frame(width: width, height: mainHeight, alignment: .topLeading)
            .clipped()
            .calendarEventCardSurface(model.eventColor(event).swiftUI)
            #endif
            }
            .frame(width: width)
        }
        .contentShape(ActivityCardHitShape(part: renderPart, before: beforeHeight, after: afterHeight))
        .buttonStyle(.plain)
        .calendarEventMenu(event, model: model, action: eventAction)
        .accessibilityLabel("\(event.displayTitle), \(model.timeLabel(event)), \(event.calendar.choice.title)")
    }
}

#if os(iOS)
private struct BannerTouchAnchor: UIViewRepresentable {
    let onAttach: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        onAttach(view)
    }
}

private struct NativeDayPull: UIViewRepresentable {
    let onAttach: (UIScrollView?) -> Void
    let ignoresStart: (CGPoint, UIWindow?) -> Bool
    let onPan: (UIGestureRecognizer.State, CGPoint, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        context.coordinator.observer = self
        context.coordinator.attach(from: anchor)
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attach(from: self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(from: self)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var observer: NativeDayPull
        private weak var scroll: UIScrollView?
        private var fingerOrigin = CGPoint.zero
        private var ignorePan = false

        init(_ observer: NativeDayPull) { self.observer = observer }

        func attach(from anchor: Anchor) {
            var view = anchor.superview
            while let ancestor = view {
                if let scroll = ancestor as? UIScrollView {
                    guard self.scroll !== scroll else { return }
                    detach()
                    self.scroll = scroll
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                    observer.onAttach(scroll)
                    return
                }
                view = ancestor.superview
            }
            detach()
        }

        func detach() {
            guard let scroll else { return }
            scroll.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
            observer.onAttach(nil)
            self.scroll = nil
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            guard let scroll else { return }
            let finger = pan.location(in: scroll.window)
            if pan.state == .began {
                fingerOrigin = finger
                let translation = pan.translation(in: scroll.window)
                let start = CGPoint(x: finger.x - translation.x, y: finger.y - translation.y)
                ignorePan = observer.ignoresStart(start, scroll.window)
            }
            guard !ignorePan else { return }
            let travel = CGPoint(x: finger.x - fingerOrigin.x, y: finger.y - fingerOrigin.y)
            let insets = scroll.adjustedContentInset
            let bottom = max(-insets.top, scroll.contentSize.height - scroll.bounds.height + insets.bottom)
            let distanceToTop = max(0, scroll.contentOffset.y + insets.top)
            let distanceToBottom = max(0, bottom - scroll.contentOffset.y)
            observer.onPan(pan.state, travel, distanceToTop, distanceToBottom)
        }
    }
}
#endif

struct WeekView: View {
    let model: CalendarModel
    let eventAction: (CalendarEvent, CalendarEventAction) -> Void
    let select: (Date) -> Void
    let openTask: (GoogleTaskDeadline) -> Void

    var body: some View {
        let range = model.window(for: .week)
        let days = CalendarWindow.days(in: range, calendar: model.calendar)
        let buckets = dayBuckets(model.events(in: range), days: days, calendar: model.calendar)
        let tasksByDay = Dictionary(grouping: model.tasks(in: range, mode: .week), by: \.day)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let events = buckets[day] ?? []
                    let tasks = tasksByDay[day] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Button { select(day) } label: {
                            HStack {
                                Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                                    .font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.calendar.isDateInToday(day) ? model.accentColor : .primary)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(tasks) { task in
                            Button { openTask(task) } label: {
                                TaskLabel(task: task, accent: model.taskIconColor)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if events.isEmpty && tasks.isEmpty {
                            if model.hasLoaded(range) {
                                Text("Nothing scheduled").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(events) { event in
                                CalendarEventButton(event: event, model: model, action: eventAction) {
                                    HStack(spacing: 10) {
                                        Capsule().fill(model.eventColor(event).swiftUI).frame(width: 4, height: 24)
                                        Text(event.displayTitle)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(model.timeLabel(event))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .calendarEventMenu(event, model: model, action: eventAction)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    Divider().padding(.leading, 18)
                }
            }
        }
    }
}

#if os(iOS)
struct MonthView: View {
    let model: CalendarModel
    let select: (Date) -> Void
    @State private var preview: MonthDaySummary?
    @ScaledMetric(relativeTo: .caption2) private var entryHeight = 16.0
    @ScaledMetric(relativeTo: .caption) private var dateHeight = 23.0

    private let weekdayHeight: CGFloat = 24
    private let gutter: CGFloat = 6

    var body: some View {
        let calendar = model.calendar
        let range = model.window(for: .month)
        let days = CalendarWindow.days(in: range, calendar: calendar)
        let weeks = stride(from: 0, to: days.count, by: 7).map { days[$0..<min($0 + 7, days.count)] }
        let visibleEvents = model.events(in: range).filter { event in
            if model.isImportant(event) { return true }
            if event.isAllDay { return model.showsAllDay(calendarID: event.calendar.id, in: .month) }
            return model.highlights.showTimedEventsInMonth
        }
        let events = dayBuckets(visibleEvents, days: days, calendar: calendar)
        let tasks = Dictionary(grouping: model.tasks(in: range, mode: .month), by: \.day)
        GeometryReader { geometry in
            let columnWidth = max(0, geometry.size.width - 2 * gutter) / 7
            let rowHeight = max(dateHeight + entryHeight * 2 + 6,
                floor((geometry.size.height - weekdayHeight) / CGFloat(max(1, weeks.count))))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7) { index in
                        let weekday = (calendar.firstWeekday - 1 + index) % 7
                        Text(calendar.shortStandaloneWeekdaySymbols[weekday])
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: columnWidth, height: weekdayHeight)
                            .accessibilityLabel(calendar.standaloneWeekdaySymbols[weekday])
                    }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(weeks, id: \.first) { week in
                            HStack(spacing: 0) {
                                ForEach(week, id: \.self) { day in
                                    let dayEvents = events[day] ?? []
                                    let items = dayEvents.filter(\.isAllDay).map(MonthDayItem.event)
                                        + (tasks[day] ?? []).map(MonthDayItem.task)
                                        + dayEvents.filter { !$0.isAllDay }.map(MonthDayItem.event)
                                    dayCell(MonthDaySummary(day: day, items: items), width: columnWidth, height: rowHeight)
                                }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, gutter)
        }
        .sheet(item: $preview) { summary in
            MonthDayPreview(model: model, summary: summary, openDay: {
                preview = nil
                select(summary.day)
            })
        }
    }

    private func dayCell(_ summary: MonthDaySummary, width: CGFloat, height: CGFloat) -> some View {
        let calendar = model.calendar
        let today = calendar.isDateInToday(summary.day)
        let selected = calendar.isDate(summary.day, inSameDayAs: model.selection)
        let inMonth = calendar.isDate(summary.day, equalTo: model.selection, toGranularity: .month)
        let slots = max(1, Int((height - dateHeight - 4) / (entryHeight + 1)))
        let count = summary.items.count > slots ? slots - 1 : summary.items.count
        return VStack(alignment: .leading, spacing: 1) {
            Text(summary.day.formatted(.dateTime.day()))
                .font(.caption.weight(today ? .bold : .medium).monospacedDigit())
                .foregroundStyle(today ? Color.white : inMonth ? .primary : .secondary)
                .padding(.horizontal, 4)
                .frame(minWidth: 20, minHeight: 20)
                .background(today ? model.accentColor : .clear, in: Capsule())
                .frame(maxWidth: .infinity, minHeight: dateHeight)
            ForEach(summary.items.prefix(count)) { item in
                itemLabel(item)
            }
            if count < summary.items.count {
                Text("+\(summary.items.count - count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: entryHeight)
            }
        }
        .padding(.horizontal, 1.5)
        .padding(.top, 2)
        .frame(width: width, height: height, alignment: .top)
        .background(selected ? model.accentColor.opacity(0.07) : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(.secondary.opacity(0.18)).frame(height: 0.5).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(LongPressGesture(minimumDuration: 0.38, maximumDistance: 12)
            .exclusively(before: TapGesture())
            .onEnded { _ in preview = summary })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.day.formatted(.dateTime.weekday().day().month().year())), \(summary.items.count) items")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { preview = summary }
    }

    private func itemLabel(_ item: MonthDayItem) -> some View {
        let color: Color
        let title: String
        let completed: Bool
        switch item {
        case .event(let event):
            color = model.eventColor(event).swiftUI
            title = event.displayTitle
            completed = false
        case .task(let task):
            color = model.taskIconColor
            title = task.title
            completed = task.isCompleted
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .strikethrough(completed)
            .foregroundStyle(completed ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: entryHeight, alignment: .leading)
            .background(color.opacity(completed ? 0.07 : 0.18), in: RoundedRectangle(cornerRadius: 3))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(color.opacity(completed ? 0.4 : 0.9))
                    .frame(width: 1.5).padding(.vertical, 2)
            }
    }
}

private enum MonthDayItem: Identifiable {
    case event(CalendarEvent), task(GoogleTaskDeadline)

    enum ID: Hashable { case event(EventIdentity), task(GoogleTaskDeadline.ID) }

    var id: ID {
        switch self {
        case .event(let event): .event(event.id)
        case .task(let task): .task(task.id)
        }
    }
}

private struct MonthDaySummary: Identifiable {
    let day: Date
    let items: [MonthDayItem]
    var id: Date { day }
}

private struct MonthDayPreview: View {
    let model: CalendarModel
    let summary: MonthDaySummary
    let openDay: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: MonthDayItem?

    var body: some View {
        NavigationStack {
            List {
                if summary.items.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar")
                        .listRowBackground(Color.clear)
                }
                ForEach(summary.items) { item in
                    Button { selected = item } label: {
                        switch item {
                        case .event(let event):
                            HStack(spacing: 9) {
                                CalendarSwatch(color: model.eventColor(event))
                                Text(event.displayTitle)
                                Spacer(minLength: 5)
                                Text(model.timeLabel(event))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .task(let task):
                            TaskLabel(task: task, accent: model.taskIconColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(summary.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open Day", action: openDay)
                }
            }
        }
        .sheet(item: $selected) { item in
            switch item {
            case .event(let event):
                EventDetailsSheet(model: model, event: event, editing: false)
            case .task(let task):
                GoogleTaskSheet(task: task, accent: model.taskIconColor,
                                connectionName: model.taskConnectionName(for: task))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif

struct DayHighlights: View {
    let model: CalendarModel
    let tasks: [GoogleTaskDeadline]
    let allDay: [CalendarEvent]
    let rowHeight: CGFloat
    let expandedListHeight: CGFloat?
    let animateHighlights: Bool
    let eventAction: (CalendarEvent, CalendarEventAction) -> Void
    let openTask: (GoogleTaskDeadline) -> Void
    let setTasksExpanded: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var badgeSize = 28.0

    private var tasksExpanded: Bool { expandedListHeight != nil }

    var body: some View {
        if !tasks.isEmpty || !allDay.isEmpty {
            VStack(spacing: 0) {
                if !allDay.isEmpty {
                    allDayHeader
                }
                if !allDay.isEmpty && !tasks.isEmpty {
                    bannerDivider
                }
                if !tasks.isEmpty {
                    tasksHeader
                        .zIndex(1)
                    if let expandedListHeight {
                        expandedTasks(height: expandedListHeight)
                            .transition(.offset(y: -8).combined(with: .opacity))
                    }
                }
            }
            .calendarControlGlass(in: RoundedRectangle(cornerRadius: 24), interactive: false)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: tasksExpanded)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var allDayHeader: some View {
        HStack(spacing: 6) {
            Text("All day")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Hide All-Day Events Banner", systemImage: "eye.slash") {
                        model.highlights.allDay.day = false
                    }
                }
                .accessibilityAction(named: Text("Hide All-Day Events Banner")) {
                    model.highlights.allDay.day = false
                }

            HighlightTicker(entries: allDay, active: animateHighlights) { event in
                CalendarEventButton(event: event, model: model, action: eventAction) {
                    HStack(spacing: 6) {
                        CalendarSwatch(color: model.eventColor(event))
                        Text(event.displayTitle).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .calendarEventMenu(event, model: model, action: eventAction) {
                    model.highlights.allDay.day = false
                }
            }
        }
        .frame(height: rowHeight)
    }

    private var bannerDivider: some View {
        Rectangle().fill(.secondary.opacity(0.22)).frame(height: 1).padding(.horizontal, 12)
    }

    private var tasksHeader: some View {
        HStack(spacing: 6) {
            Text(tasks.count.formatted())
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(model.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
                .frame(width: badgeSize, height: badgeSize)
                .background(.quaternary, in: Circle())
                .padding(.leading, 10)

            if tasksExpanded {
                Text("Tasks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
            } else {
                HighlightTicker(entries: tasks, active: animateHighlights,
                                autoScroll: model.highlights.autoScrollTaskBanner) { task in
                    TaskLabel(task: task, accent: model.taskIconColor)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                }
            }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture().exclusively(before: TapGesture()).onEnded { gesture in
                switch gesture {
                case .first:
                    if !tasksExpanded { setTasksExpanded(true) }
                case .second:
                    setTasksExpanded(!tasksExpanded)
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tasks.count == 1 ? Text("1 task") : Text("\(tasks.count) tasks"))
        .accessibilityValue(tasksExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { setTasksExpanded(!tasksExpanded) }
    }

    private func expandedTasks(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            bannerDivider
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        Button { openTask(task) } label: {
                            TaskLabel(task: task, accent: model.taskIconColor)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(height: rowHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: height)
            .scrollBounceBehavior(.basedOnSize)

            bannerDivider
            Toggle(isOn: Binding(
                get: { model.highlights.autoScrollTaskBanner },
                set: { model.highlights.autoScrollTaskBanner = $0 }
            )) {
                Label("Auto-scroll tasks", systemImage: "arrow.left")
            }
            .toggleStyle(.switch)
            .tint(model.accentColor)
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: rowHeight)

            bannerDivider
            Button {
                setTasksExpanded(false)
                model.highlights.googleTasks.day = false
            } label: {
                Label("Hide Tasks Banner", systemImage: "eye.slash")
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HighlightTicker<Entry: Identifiable & Equatable, Content: View>: View {
    let entries: [Entry]
    let active: Bool
    var autoScroll = true
    @ViewBuilder let content: (Entry) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var contentWidth: CGFloat = 0
    @State private var restingOffset: CGFloat = 0
    @State private var resumeAt = Date.now.addingTimeInterval(1.5)
    @State private var dragOrigin: CGFloat?
    @GestureState private var gestureActive = false

    private let itemSpacing: CGFloat = 6
    private let speed: CGFloat = 36
    private var cycleWidth: CGFloat { contentWidth + itemSpacing }
    private var direction: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            if reduceMotion || !autoScroll {
                ScrollView(.horizontal) {
                    items.padding(.trailing, 8)
                }
                .scrollIndicators(.hidden)
            } else {
                let overflows = contentWidth > width + 0.5
                let moving = overflows && active && dragOrigin == nil
                let rail = HStack(spacing: itemSpacing) {
                    items
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                    if overflows {
                        items.accessibilityHidden(true)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { context in
                    let distance = moving ? offset(at: context.date) : wrap(restingOffset)
                    rail
                        .offset(x: overflows ? -direction * distance : 0)
                        .frame(width: width, height: geometry.size.height, alignment: .leading)
                }
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(scrub, including: overflows && active ? .all : .none)
                .onChange(of: overflows) { _, _ in reset() }
                .onChange(of: active) { wasActive, _ in
                    if wasActive && dragOrigin == nil { restingOffset = offset(at: .now) }
                    finishScrub()
                }
                .onChange(of: gestureActive) { _, dragging in
                    if !dragging && dragOrigin != nil { finishScrub() }
                }
            }
        }
        .onChange(of: entries) { _, _ in reset() }
    }

    private var items: some View {
        HStack(spacing: itemSpacing) {
            ForEach(entries, content: content)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($gestureActive) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard dragOrigin != nil || abs(value.translation.width) > 1.5 * abs(value.translation.height) else { return }
                let origin = dragOrigin ?? offset(at: value.time)
                dragOrigin = origin
                restingOffset = wrap(origin - direction * value.translation.width)
            }
            .onEnded { value in
                guard let dragOrigin else { return }
                restingOffset = wrap(dragOrigin - direction * value.translation.width)
                finishScrub()
            }
    }

    private func offset(at date: Date) -> CGFloat {
        let elapsed = max(0, date.timeIntervalSince(resumeAt))
        return wrap(restingOffset + CGFloat(elapsed) * speed)
    }

    private func wrap(_ offset: CGFloat) -> CGFloat {
        let remainder = offset.truncatingRemainder(dividingBy: cycleWidth)
        return remainder < 0 ? remainder + cycleWidth : remainder
    }

    private func finishScrub() {
        dragOrigin = nil
        resumeAt = .now.addingTimeInterval(1.5)
    }

    private func reset() {
        restingOffset = 0
        finishScrub()
    }
}

struct GoogleTaskSheet: View {
    let task: GoogleTaskDeadline
    let accent: Color
    let connectionName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TaskLabel(task: task, accent: accent).font(.headline)
                    LabeledContent("Scheduled", value: task.day.formatted(.dateTime.day().month(.wide).year()))
                    if let completed = task.completedAt {
                        LabeledContent("Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                    } else if task.isCompleted {
                        LabeledContent("Status", value: "Completed")
                    }
                    LabeledContent("Google Tasks list", value: task.list)
                    if let connectionName {
                        LabeledContent("Connection", value: connectionName)
                    }
                }
            }
            .navigationTitle("Task")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss.callAsFunction) }
            }
        }
    }
}

struct TaskLabel: View {
    let task: GoogleTaskDeadline
    let accent: Color

    var body: some View {
        Label {
            Text(task.title)
                .strikethrough(task.isCompleted)
                .foregroundStyle(task.isCompleted ? .secondary : .primary)
        } icon: {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(task.isCompleted ? Color.secondary : accent)
        }
        .accessibilityLabel(task.isCompleted ? Text("\(task.title), completed") : Text(task.title))
    }
}

func dayBuckets(_ events: [CalendarEvent], days: [Date], calendar: Calendar) -> [Date: [CalendarEvent]] {
    guard let first = days.first, let last = days.last else { return [:] }
    var result: [Date: [CalendarEvent]] = [:]
    for event in events {
        var date = max(calendar.startOfDay(for: event.occupiedStart), first)
        while date <= last && (date < event.occupiedEnd || calendar.isDate(date, inSameDayAs: event.occupiedStart)) {
            result[date, default: []].append(event)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = calendar.startOfDay(for: next)
        }
    }
    return result.mapValues { dayEvents in
        dayEvents.filter(\.isAllDay) + dayEvents.filter { !$0.isAllDay }
    }
}

enum ActivityCardPart: Equatable { case whole, extensions, core }

struct ActivityCardHitShape: Shape {
    let part: ActivityCardPart
    let before: CGFloat
    let after: CGFloat
    func path(in rect: CGRect) -> Path {
        let before = min(rect.height, max(0, before)), after = min(rect.height - before, max(0, after))
        var path = Path()
        if part == .whole { path.addRect(rect) }
        if part == .core {
            path.addRect(CGRect(x: rect.minX, y: rect.minY + before, width: rect.width,
                                height: max(0, rect.height - before - after)))
        }
        if part == .extensions {
            if before > 0 { path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: before)) }
            if after > 0 { path.addRect(CGRect(x: rect.minX, y: rect.maxY - after, width: rect.width, height: after)) }
        }
        return path
    }
}

struct ActivityEventCard<Content: View>: View {
    let event: CalendarEvent
    let model: CalendarModel
    let height: CGFloat
    let beforeHeight: CGFloat
    let afterHeight: CGFloat
    var part: ActivityCardPart = .whole
    var beforeCovered: [ClosedRange<CGFloat>] = []
    var afterCovered: [ClosedRange<CGFloat>] = []
    var coreCovered: [ClosedRange<CGFloat>] = []
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        let details = event.activityDetails
        let color = model.eventColor(event).swiftUI
        let before = min(height, max(0, beforeHeight))
        let after = min(height - before, max(0, afterHeight))
        let main = max(0, height - before - after)
        VStack(alignment: .leading, spacing: 0) {
            if before > 0 {
                if part != .core, let buffer = details.before {
                    bufferLabel(buffer, position: "before", height: before, covered: beforeCovered)
                } else { Color.clear.frame(height: before) }
            }
            if main > 0 {
                if part != .extensions {
                    content(main)
                        .environment(\.activityOwnsSurface, true)
                        .background(color.opacity(0.19))
                        .background(.background)
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 3) {
                                ForEach(event.linkedCalendars.dropFirst()) { calendar in
                                    Circle().fill(calendar.color.swiftUI).frame(width: 5, height: 5)
                                }
                            }
                            .padding(4).accessibilityHidden(true)
                        }
                } else { Color.clear.frame(height: main) }
            }
            if after > 0 {
                if part != .core, let buffer = details.after {
                    bufferLabel(buffer, position: "after", height: after, covered: afterCovered)
                } else { Color.clear.frame(height: after) }
            }
        }
        .frame(height: height)
        .overlay(alignment: .leading) {
            Canvas { context, size in
                for (start, end, dotted) in [(CGFloat.zero, before, true),
                                            (before, before + main, false),
                                            (before + main, size.height, true)] where end > start {
                    guard dotted ? part != .core : part != .extensions else { continue }
                    let spans = dotted ? [start..<end] : Self.uncovered(in: start..<end, covered: coreCovered)
                    for span in spans {
                        var path = Path()
                        path.move(to: CGPoint(x: 1.5, y: span.lowerBound))
                        path.addLine(to: CGPoint(x: 1.5, y: span.upperBound))
                        context.stroke(path, with: .color(color.opacity(dotted ? 0.7 : 1)),
                            style: StrokeStyle(lineWidth: 3, lineCap: dotted ? .round : .butt,
                                               dash: dotted ? [1, 5] : []))
                    }
                }
            }
            .frame(width: 3).allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(ActivityCardHitShape(part: part, before: before, after: after))
    }

    private func bufferLabel(_ buffer: ActivityBuffer, position: String, height: CGFloat,
                             covered: [ClosedRange<CGFloat>]) -> some View {
        let color = model.eventColor(event).swiftUI
        let visible = Self.largestGap(height: height, covered: covered)
        return ZStack(alignment: .topLeading) {
            color.opacity(model.preferences.bufferBackground.fillOpacity)
            if visible.length >= 20 {
                HStack(spacing: 5) {
                    Image(systemName: buffer.symbol).imageScale(.small)
                    Text("\(buffer.minutes) \(buffer.minutes == 1 ? "min" : "mins")").lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption2).foregroundStyle(color.opacity(0.85))
                .padding(.horizontal, 8)
                .frame(height: visible.length)
                .clipped().offset(y: visible.lowerBound)
            }
        }
        .frame(height: height)
        .background(.background)
        .accessibilityLabel("\(buffer.minutes) minutes \(position), \(buffer.title)")
    }

    private static func uncovered(in bounds: Range<CGFloat>, covered: [ClosedRange<CGFloat>]) -> [Range<CGFloat>] {
        var cursor = bounds.lowerBound
        var gaps: [Range<CGFloat>] = []
        for range in covered.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(bounds.lowerBound, min(bounds.upperBound, range.lowerBound))
            let end = max(bounds.lowerBound, min(bounds.upperBound, range.upperBound))
            if start > cursor { gaps.append(cursor..<start) }
            cursor = max(cursor, end)
        }
        if bounds.upperBound > cursor { gaps.append(cursor..<bounds.upperBound) }
        return gaps
    }

    private static func largestGap(height: CGFloat, covered: [ClosedRange<CGFloat>]) -> Range<CGFloat> {
        uncovered(in: 0..<height, covered: covered).max(by: { $0.length < $1.length }) ?? 0..<0
    }

}

private extension Range where Bound == CGFloat {
    var length: CGFloat { upperBound - lowerBound }
}

struct ActivityOverlapMark {
    let overlap: ActivityBufferOverlap
    let rect: CGRect
    let index: Int
    var clipRect: CGRect? = nil
}

struct ActivityOverlapOverlay: View {
    let marks: [ActivityOverlapMark]
    let model: CalendarModel
    var body: some View {
        let owners = Dictionary(marks.map { ($0.overlap.owner.id.layoutID, $0.overlap.owner) }, uniquingKeysWith: { first, _ in first })
        let colors = owners.mapValues { model.eventColor($0).swiftUI }
        Canvas { context, _ in
            for mark in marks where mark.rect.height > 0 && mark.rect.width > 0 {
                var context = context
                context.clip(to: Path(roundedRect: mark.clipRect ?? mark.rect, cornerRadius: 6))
                context.clip(to: Path(mark.rect))
                guard let color = colors[mark.overlap.owner.id.layoutID] else { continue }
                let fade = min(0.45, 6 / max(1, mark.rect.height))
                let gradient = Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: color.opacity(0.03), location: fade),
                    .init(color: color.opacity(0.03), location: 1 - fade), .init(color: .clear, location: 1)])
                context.fill(Path(mark.rect), with: .linearGradient(gradient,
                    startPoint: CGPoint(x: mark.rect.midX, y: mark.rect.minY),
                    endPoint: CGPoint(x: mark.rect.midX, y: mark.rect.maxY)))
                var path = Path()
                let x = mark.rect.minX + 1.5
                path.move(to: CGPoint(x: x, y: mark.rect.minY))
                path.addLine(to: CGPoint(x: x, y: mark.rect.maxY))
                context.stroke(path, with: .color(color.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [1, 5], dashPhase: CGFloat(mark.index % 3) * 2))
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
