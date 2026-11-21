#if os(macOS)
import AppKit
import CalendarCore
import CalendarData
import QuartzCore
import SwiftUI

struct DesktopWeekTimeline: View {
    let model: CalendarModel
    let navigationEnabled: Bool
    let selectDay: (Date) -> Void
    let eventAction: (CalendarEvent, CalendarEventAction) -> Void
    let addRange: (DateInterval) -> Void
    let editRange: (CalendarEvent, DateInterval) -> Void
    let openTask: (GoogleTaskDeadline) -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raisedDay: Date?
    @State private var horizontal = WeekHorizontalPosition()
    @State private var cardLayouts = WeekCardLayouts()
    @State private var pinnedRowsDuringScroll: Int?
    @State private var scrollingFrom: Date?

    private let visibleDayCount = 7
    private let bufferDays = 6
    private let gutter: CGFloat = 56
    private let minimumCardHeight: CGFloat = 20
    private let cardGap: CGFloat = 3
    private var hourHeight: CGFloat { model.desktopHourHeight }
    private var horizontalDirection: CGFloat { layoutDirection == .rightToLeft ? -1 : 1 }

    var body: some View {
        let range = model.window(for: .week)
        let calendar = model.calendar
        // Keep enough columns mounted to scroll across several days before rebasing.
        let previousDay = CalendarViewMode.day.advance(range.start, by: -bufferDays, calendar: calendar)
        let nextDay = CalendarViewMode.day.advance(range.end, by: bufferDays, calendar: calendar)
        let buffered = DateInterval(start: calendar.startOfDay(for: previousDay), end: calendar.startOfDay(for: nextDay))
        let days = CalendarWindow.days(in: buffered, calendar: calendar)
        let events = dayBuckets(model.desktopWeekEvents(), days: days, calendar: calendar)
        let tasks = Dictionary(grouping: model.tasks(in: buffered, mode: .week), by: \.day)
        let pinnedCount = days.dropFirst(bufferDays).prefix(visibleDayCount).map { day in
            (events[day] ?? []).filter(\.isAllDay).count + (tasks[day] ?? []).count
        }.max() ?? 0
        let pinnedRows = max(1, min(pinnedCount, 4))
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - gutter) / CGFloat(visibleDayCount)
            VStack(spacing: 0) {
                headers(days, width: width)
                Divider()
                HStack(spacing: 0) {
                    Text("All day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: gutter)
                    let rows = pinnedRowsDuringScroll ?? pinnedRows
                    columns(days, width: width) { day in
                        pinnedItems((events[day] ?? []).filter(\.isAllDay), tasks: tasks[day] ?? [], rows: rows)
                            .frame(width: width, height: CGFloat(rows) * 23 + 4, alignment: .top)
                            .background(dayBackground(day))
                            .overlay(alignment: .leading) { dayDivider }
                    }
                }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        timeline(days, events: events, width: width)
                    }
                    .modifier(WeekScrollZoom(model: model))
                    .onAppear {
                        let isCurrentWeek = range.contains(.now)
                        let hour = isCurrentWeek ? max(0, calendar.component(.hour, from: .now) - 3) : 8
                        proxy.scrollTo(hour, anchor: .top)
                    }
                }
            }
            .background {
                DesktopHorizontalTrackpad(followsMomentum: true, canStart: { _ in
                    navigationEnabled && raisedDay == nil && width > 0
                }, move: { delta in
                    scrollColumns(by: delta, width: width, pinnedRows: pinnedRows)
                }, finish: { _ in
                    settleColumns(width: width)
                }, frame: { time in
                    if let dayShift = horizontal.advanceSnap(at: time) {
                        finishScrolling(by: dayShift)
                    }
                    return horizontal.isSettling
                })
            }
            .onChange(of: navigationEnabled) {
                if !navigationEnabled { resetHorizontalScroll() }
            }
            .onChange(of: width) { resetHorizontalScroll() }
            .onChange(of: days) { cardLayouts.retain(days) }
            .onChange(of: range.start) { _, start in
                if let scrollingFrom, scrollingFrom != start { resetHorizontalScroll() }
            }
        }
    }

    private func columns<Column: View>(_ days: [Date], width: CGFloat,
                                       @ViewBuilder column: @escaping (Date) -> Column) -> some View {
        let visible = Set(days.dropFirst(bufferDays).prefix(visibleDayCount))
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                column(day).accessibilityHidden(!visible.contains(day)).allowsHitTesting(visible.contains(day))
            }
        }
        .frame(width: CGFloat(days.count) * width)
        .modifier(WeekColumnOffset(position: horizontal, leadingColumns: CGFloat(bufferDays) * width * horizontalDirection))
        .frame(width: CGFloat(visibleDayCount) * width, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    private func scrollColumns(by delta: CGFloat, width: CGFloat, pinnedRows: Int) {
        guard width > 0, navigationEnabled, raisedDay == nil else { return }
        horizontal.interruptSnap()
        if pinnedRowsDuringScroll == nil {
            pinnedRowsDuringScroll = pinnedRows
            scrollingFrom = model.window(for: .week).start
        }
        let travel = horizontal.offset + delta
        guard abs(travel) >= CGFloat(bufferDays - 1) * width else {
            horizontal.offset = travel
            return
        }
        let columns = Int(travel / width)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            horizontal.offset = travel - CGFloat(columns) * width
            model.rollDesktopWeek(by: -columns * Int(horizontalDirection))
            scrollingFrom = model.window(for: .week).start
        }
    }

    private func settleColumns(width: CGFloat) {
        guard width > 0, horizontal.offset != 0 else {
            resetHorizontalScroll()
            return
        }
        let columns = Int((horizontal.offset / width).rounded())
        let target = CGFloat(columns) * width
        let dayShift = -columns * Int(horizontalDirection)
        if reduceMotion || horizontal.offset == target {
            finishScrolling(by: dayShift)
        } else {
            horizontal.beginSnap(to: target, dayShift: dayShift, at: CACurrentMediaTime())
        }
    }

    private func finishScrolling(by dayShift: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            resetHorizontalScroll()
            model.rollDesktopWeek(by: dayShift)
        }
    }

    private func resetHorizontalScroll() {
        horizontal.interruptSnap()
        horizontal.offset = 0
        pinnedRowsDuringScroll = nil
        scrollingFrom = nil
    }

    private struct WeekColumnOffset: ViewModifier {
        let position: WeekHorizontalPosition
        let leadingColumns: CGFloat

        func body(content: Content) -> some View {
            content.offset(x: position.offset - leadingColumns)
        }
    }

    private struct WeekScrollZoom: ViewModifier {
        let model: CalendarModel

        func body(content: Content) -> some View {
            if #available(macOS 15, *) {
                content.modifier(AnchoredWeekZoom(model: model))
            } else {
                content.modifier(DesktopTimelinePinch<CGFloat>(model: model))
            }
        }
    }

    @available(macOS 15, *)
    private struct AnchoredWeekZoom: ViewModifier {
        let model: CalendarModel
        @State private var position = ScrollPosition()
        @State private var scrollY: CGFloat = 0

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: {
                    _, offset in scrollY = offset
                }
                .modifier(DesktopTimelinePinch(model: model, capture: { y in
                    (scrollY + y) / model.desktopHourHeight
                }, restore: { hour, y in
                    position.scrollTo(y: max(0, hour * model.desktopHourHeight - y))
                }))
        }
    }

    private func headers(_ days: [Date], width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if let day = days.dropFirst(bufferDays).first {
                Text("W\(model.calendar.component(.weekOfYear, from: day))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: gutter, height: 39)
                    .accessibilityLabel("Week \(model.calendar.component(.weekOfYear, from: day))")
            }
            columns(days, width: width) { day in
                let today = model.calendar.isDateInToday(day)
                Button { selectDay(day) } label: {
                    HStack(spacing: 5) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                        Text(day.formatted(.dateTime.day()))
                            .fontWeight(today ? .semibold : .regular)
                            .foregroundStyle(today ? .white : .primary)
                            .padding(.horizontal, today ? 6 : 0)
                            .padding(.vertical, today ? 3 : 0)
                            .background(today ? model.accentColor : Color.clear, in: Capsule())
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .frame(width: width, height: 39)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(dayBackground(day))
                .overlay(alignment: .leading) { dayDivider }
                .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder
    private func pinnedItems(_ events: [CalendarEvent], tasks: [GoogleTaskDeadline], rows: Int) -> some View {
        let items = VStack(alignment: .leading, spacing: 2) {
            ForEach(events) { event in
                CalendarEventButton(event: event, model: model, action: eventAction) {
                    Text(event.displayTitle)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
                        .calendarEventCardSurface(model.eventColor(event).swiftUI)
                }
                .buttonStyle(.plain)
                .calendarEventMenu(event, model: model, action: eventAction)
            }
            ForEach(tasks) { task in
                Button { openTask(task) } label: {
                    TaskLabel(task: task, accent: model.taskIconColor)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(2)
        if events.count + tasks.count > rows {
            ScrollView { items }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
        } else {
            items.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timeline(_ days: [Date], events: [Date: [CalendarEvent]], width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                columns(days, width: width) { day in
                    dayBackground(day)
                        .frame(width: width)
                        .overlay(alignment: .leading) { dayDivider }
                }
            }
            Canvas { context, size in
                var lines = Path()
                for hour in 0..<24 {
                    let y = CGFloat(hour) * hourHeight + 0.5
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(lines, with: .foreground, lineWidth: 1)
            }
            .foregroundStyle(.secondary.opacity(0.19))
            .frame(width: CGFloat(visibleDayCount) * width)
            .padding(.leading, gutter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            VStack(spacing: 0) {
                ForEach(0..<24) { hour in
                    let clock = Date(timeIntervalSince1970: Double(hour * 3_600))
                    Text(model.time(clock, zone: .gmt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                        .frame(width: gutter, alignment: .trailing)
                        .offset(y: 3)
                        .frame(height: hourHeight, alignment: .top)
                        .id(hour)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter).allowsHitTesting(false)
                columns(days, width: width) { day in
                    let index = days.firstIndex(of: day) ?? 0
                    timedItems(events[day] ?? [], days: days, index: index, width: width)
                        .zIndex(raisedDay == day ? 1 : 0)
                }
            }
            if let today = days.firstIndex(where: model.calendar.isDateInToday) {
                TimelineView(.everyMinute) { context in
                    WeekTimeMarker(model: model, time: context.date, gutter: gutter, position: horizontal,
                                   dayStart: CGFloat(today - bufferDays) * width, columnWidth: width,
                                   gridWidth: CGFloat(visibleDayCount) * width, direction: horizontalDirection)
                    .offset(y: clockSeconds(context.date) / 3_600 * hourHeight - 8)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: 24 * hourHeight, alignment: .top)
    }

    private struct WeekTimeMarker: View {
        let model: CalendarModel
        let time: Date
        let gutter: CGFloat
        let position: WeekHorizontalPosition
        let dayStart: CGFloat
        let columnWidth: CGFloat
        let gridWidth: CGFloat
        let direction: CGFloat

        var body: some View {
            let x = dayStart + position.offset * direction
            if x > -columnWidth, x < gridWidth {
                let minute = model.calendar.component(.minute, from: time)
                    .formatted(.number.precision(.integerLength(2)))
                HStack(spacing: 0) {
                    Text(":\(minute)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .background(.background)
                        .padding(.trailing, 6)
                        .frame(width: gutter, alignment: .trailing)
                    Rectangle().frame(height: 1)
                        .overlay(alignment: .leading) {
                            Circle().frame(width: 7, height: 7).offset(x: (max(0, x) - 3) * direction)
                        }
                }
                .foregroundStyle(model.accentColor)
                .frame(height: 16)
            }
        }
    }

    private func timedItems(_ events: [CalendarEvent], days: [Date], index: Int, width: CGFloat) -> some View {
        let day = days[index]
        let calendar = model.calendar
        let endOfDay = CalendarViewMode.day.window(for: day, calendar: calendar).end
        let layout = cardLayouts.layout(for: day, until: endOfDay, events: events, calendar: calendar,
                                      hourHeight: hourHeight, minimumHeight: minimumCardHeight,
                                      blendsBuffers: model.preferences.blendActivityBuffers ?? false)
        let cards = layout.cards
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.event.id.layoutID, $0) })
        return ZStack(alignment: .topLeading) {
            DesktopTimelineSelection(model: model, dateAtOffset: { offset in
                DesktopTimelineSelection.weekDate(at: offset, hourHeight: hourHeight, day: day, calendar: model.calendar)
            }, offsetForDate: { date in
                date >= endOfDay ? 24 * hourHeight : clockSeconds(date) / 3_600 * hourHeight
            }, addRange: addRange, advanceAfterSwipe: { travel in
                guard navigationEnabled, width > 0, abs(travel.width) > 54,
                      abs(travel.width) > abs(travel.height) * 1.65 else { return }
                let days = max(1, Int((abs(travel.width) / width).rounded()))
                model.rollDesktopWeek(by: (travel.width < 0 ? days : -days) * Int(horizontalDirection))
            },
               allowsCreation: !model.writableCalendars.isEmpty)
            ForEach(layout.overlaps.isEmpty ? [0] : [-1, 0], id: \.self) { pass in
                ForEach(cards, id: \.event.id) { card in
                    let event = card.event
                    if pass == 0 || layout.overlaps.isEmpty || event.activityDetails.before != nil || event.activityDetails.after != nil {
                        let height = max(1, card.height - cardGap)
                        let top = card.top
                        let left = card.lane.leading * width + 1
                        let cardWidth = max(1, (card.lane.trailing - card.lane.leading) * width - 2)
                        let beforeHeight = min(height, card.beforeHeight)
                        let afterHeight = min(height - beforeHeight, card.afterHeight)
                        let color = model.eventColor(event).swiftUI
                        let part: ActivityCardPart = layout.overlaps.isEmpty ? .whole : pass == -1 ? .extensions : .core
                        let covered = (layout.overlaps.byOwner[event.id.layoutID] ?? []).filter { overlap in
                            guard let target = byID[overlap.target.layoutID] else { return false }
                            return target.lane.leading < card.lane.trailing && card.lane.leading < target.lane.trailing
                        }
                        let beforeCovered = covered.filter { $0.side == .before }.map {
                            let offsets = weekOverlapOffsets($0.interval, day: day, end: endOfDay)
                            return (offsets.lowerBound - top)...(offsets.upperBound - top)
                        }
                        let afterOrigin = top + height - afterHeight
                        let afterCovered = covered.filter { $0.side == .after }.map {
                            let offsets = weekOverlapOffsets($0.interval, day: day, end: endOfDay)
                            return (offsets.lowerBound - afterOrigin)...(offsets.upperBound - afterOrigin)
                        }
                        let coreCovered = (layout.overlaps.byTarget[event.id.layoutID] ?? []).compactMap { overlap -> ClosedRange<CGFloat>? in
                            guard let owner = byID[overlap.owner.id.layoutID],
                                  owner.lane.leading < card.lane.trailing, card.lane.leading < owner.lane.trailing else { return nil }
                            let offsets = weekOverlapOffsets(overlap.interval, day: day, end: endOfDay)
                            return (offsets.lowerBound - top)...(offsets.upperBound - top)
                        }
                        CalendarEventButton(event: event, model: model, action: eventAction) {
                            ActivityEventCard(event: event, model: model, height: height,
                                              beforeHeight: beforeHeight, afterHeight: afterHeight, part: part,
                                              beforeCovered: beforeCovered, afterCovered: afterCovered, coreCovered: coreCovered) { mainHeight in
                                DesktopTimedCardLabel(title: event.displayTitle,
                                                      time: model.timeLabel(event), color: color, height: mainHeight,
                                                      compactBarWhenNeeded: part != .whole)
                                    .frame(width: cardWidth)
                            }
                            .frame(width: cardWidth)
                        }
                        .contentShape(ActivityCardHitShape(part: part, before: beforeHeight, after: afterHeight))
                        .accessibilityHidden((pass == -1 && height - beforeHeight - afterHeight > 0)
                                             || (pass == 0 && !layout.overlaps.isEmpty && height - beforeHeight - afterHeight <= 0))
                        .buttonStyle(.plain)
                        .calendarEventMenu(event, model: model, action: eventAction)
                        .accessibilityLabel("\(event.displayTitle), \(model.timeLabel(event))")
                        .help("\(event.displayTitle) · \(model.timeLabel(event))")
                        .modifier(DesktopEventDrag(model: model, event: event, width: cardWidth, height: height,
                                                   canResizeStart: event.start >= day, canResizeEnd: event.end <= endOfDay,
                                                   previewForDrag: { part, value in
                            weekDrag(event, part: part, value: value, days: days, index: index,
                                     columnWidth: width, cardLeft: left, cardTop: top)
                        }, editRange: editRange, onDragChanged: { active in
                            if active { raisedDay = day }
                            else if raisedDay == day { raisedDay = nil }
                        }, hitShape: ActivityCardHitShape(part: part, before: beforeHeight, after: afterHeight)))
                        .offset(x: left, y: top)
                    }
                }
            }
            if !layout.overlaps.isEmpty {
                ActivityOverlapOverlay(marks: layout.overlaps.overlaps.compactMap { overlap in
                    guard let target = byID[overlap.target.layoutID], let owner = byID[overlap.owner.id.layoutID],
                          owner.lane.leading < target.lane.trailing, target.lane.leading < owner.lane.trailing else { return nil }
                    let offsets = weekOverlapOffsets(overlap.interval, day: day, end: endOfDay)
                    let start = offsets.lowerBound
                    let end = min(target.top + max(1, target.height - cardGap), offsets.upperBound)
                    return ActivityOverlapMark(overlap: overlap,
                        rect: CGRect(x: target.lane.leading * width + 1, y: start,
                                     width: max(1, (target.lane.trailing - target.lane.leading) * width - 2), height: max(0, end - start)),
                        index: layout.overlaps.markerOwners(on: overlap.target.layoutID).firstIndex(of: overlap.owner.id.layoutID) ?? 0,
                        clipRect: CGRect(x: target.lane.leading * width + 1, y: target.top,
                                         width: max(1, (target.lane.trailing - target.lane.leading) * width - 2),
                                         height: max(1, target.height - cardGap)))
                }, model: model)
                .frame(height: 24 * hourHeight)
            }

        }
        .frame(width: width, height: 24 * hourHeight, alignment: .topLeading)
    }

    private func weekOffset(_ date: Date, day: Date, end: Date) -> CGFloat {
        date <= day ? 0 : date >= end ? 24 * hourHeight : clockSeconds(date) / 3600 * hourHeight
    }

    private func weekOverlapOffsets(_ interval: DateInterval, day: Date, end: Date) -> ClosedRange<CGFloat> {
        let start = weekOffset(interval.start, day: day, end: end)
        let clockEnd = weekOffset(interval.end, day: day, end: end)
        let finish = clockEnd >= start ? clockEnd : min(24 * hourHeight, start + interval.duration / 3600 * hourHeight)
        return start...max(start, finish)
    }

    private func weekDrag(_ event: CalendarEvent, part: DesktopEventDragPart, value: DragGesture.Value,
                          days: [Date], index: Int, columnWidth: CGFloat, cardLeft: CGFloat,
                          cardTop: CGFloat) -> DesktopEventDragPreview? {
        guard event.start < event.end, columnWidth > 0 else { return nil }
        let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
        let position = cardLeft + value.location.x
        let logicalX = direction > 0 ? position : columnWidth - position
        let dayChange = part == .move ? Int(floor(logicalX / columnWidth)) : 0
        let targetIndex = min(days.count - bufferDays - 1, max(bufferDays, index + dayChange))
        let original = DateInterval(start: event.start, end: event.end)
        let range = part.adjust(original, seconds: value.translation.height / hourHeight * 3_600,
                                days: targetIndex - index, stepMinutes: (model.preferences.eventDragStep ?? .fifteen).rawValue,
                                calendar: model.calendar)
        let targetDay = CalendarViewMode.day.window(for: days[targetIndex], calendar: model.calendar)
        let start = max(targetDay.start, range.start.addingTimeInterval(-Double(event.activityDetails.before?.minutes ?? 0) * 60))
        let end = min(targetDay.end, range.end.addingTimeInterval(Double(event.activityDetails.after?.minutes ?? 0) * 60))
        guard range != original, start < end else { return nil }
        let top = clockSeconds(start) / 3_600 * hourHeight
        let bottom = end == targetDay.end ? 24 * hourHeight : clockSeconds(end) / 3_600 * hourHeight
        let length = bottom > top ? bottom - top : end.timeIntervalSince(start) / 3_600 * hourHeight
        let height = max(1, max(minimumCardHeight, length) - cardGap)
        return DesktopEventDragPreview(range: range,
            offset: CGSize(width: CGFloat(targetIndex - index) * columnWidth * direction, height: top - cardTop),
            height: height)
    }

    private func clockSeconds(_ date: Date) -> Double {
        let time = model.calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((time.hour ?? 0) * 3_600 + (time.minute ?? 0) * 60 + (time.second ?? 0))
    }

    private func dayBackground(_ day: Date) -> Color {
        if model.calendar.isDateInToday(day) { return model.accentColor.opacity(0.07) }
        return .primary.opacity(model.calendar.isDateInWeekend(day) ? 0.035 : 0)
    }

    private var dayDivider: some View {
        Rectangle().fill(.secondary.opacity(0.19)).frame(width: 1).allowsHitTesting(false)
    }
}

struct DesktopTimelineSelection: View {
    let model: CalendarModel
    let dateAtOffset: (CGFloat) -> Date
    let offsetForDate: (Date) -> CGFloat
    let addRange: (DateInterval) -> Void
    var addAt: ((Date) -> Void)? = nil
    var advanceAfterSwipe: ((CGSize) -> Void)? = nil
    var allowsCreation = true

    @GestureState private var selection: DateInterval?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .updating($selection) { value, current, _ in
                    current = selectedRange(value)
                }
                .onEnded { value in
                    if let range = selectedRange(value) {
                        addRange(range)
                    } else {
                        advanceAfterSwipe?(value.translation)
                    }
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                addAt?(dateAtOffset(value.location.y))
            })
            .overlay(alignment: .top) {
                if let selection {
                    let top = offsetForDate(selection.start)
                    let bottom = offsetForDate(selection.end)
                    DesktopTimedCardLabel(title: "New Event",
                                          time: "\(model.time(selection.start))–\(model.time(selection.end))",
                                          color: previewColor, height: max(1, bottom - top - 3))
                        .padding(.horizontal, 2)
                        .offset(y: top)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)
    }

    private var previewColor: Color {
        let calendars = model.writableCalendars
        let defaultID = model.preferences.preferredCalendarID ?? model.snapshot.systemDefaultID
        let calendar = calendars.first { $0.id == defaultID } ?? calendars.first
        return calendar?.color.swiftUI ?? model.accentColor
    }

    private func selectedRange(_ value: DragGesture.Value) -> DateInterval? {
        guard allowsCreation, abs(value.translation.height) >= abs(value.translation.width) * 0.75 else { return nil }
        let start = dateAtOffset(value.startLocation.y)
        let end = dateAtOffset(value.location.y)
        guard start != end else { return nil }
        return DateInterval(start: min(start, end), end: max(start, end))
    }

    static func snappedDate(_ date: Date, in day: DateInterval, calendar: Calendar) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? day.start
        let quarters = (date.timeIntervalSince(hour) / 900).rounded()
        return min(day.end, max(day.start, hour.addingTimeInterval(quarters * 900)))
    }

    static func weekDate(at offset: CGFloat, hourHeight: CGFloat, day: Date, calendar: Calendar) -> Date {
        let range = CalendarViewMode.day.window(for: day, calendar: calendar)
        let quarter = Int((offset / hourHeight * 4).rounded())
        if quarter <= 0 { return range.start }
        if quarter >= 96 { return range.end }
        return calendar.date(bySettingHour: quarter / 4, minute: (quarter % 4) * 15, second: 0,
                             of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first) ?? range.start
    }
}

struct DesktopTimedCardLabel: View {
    let title: String
    let time: String
    let color: Color
    let height: CGFloat
    var compactBarWhenNeeded = false

    var body: some View {
        let titleSize: CGFloat = height >= 64 ? 15 : height >= 42 ? 14 : 13
        let verticalPadding: CGFloat = height >= 42 ? 4 : height >= 34 ? 2 : 0
        VStack(alignment: .leading, spacing: 1) {
            if !compactBarWhenNeeded || height >= 14 {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(height >= 60 ? 2 : 1)
                .layoutPriority(1)
            }
            if height >= 34 {
                Text(time)
                    .font(.system(size: height >= 42 ? 12 : 11).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: height >= 30 ? .topLeading : .leading)
        .clipped()
        .calendarEventCardSurface(color)
    }
}

@MainActor @Observable
final class WeekHorizontalPosition {
    var offset: CGFloat = 0
    @ObservationIgnored private var snap: Snap?

    private struct Snap {
        let from: CGFloat
        let to: CGFloat
        let dayShift: Int
        let started: TimeInterval
    }

    var isSettling: Bool { snap != nil }

    func beginSnap(to target: CGFloat, dayShift: Int, at time: TimeInterval) {
        snap = Snap(from: offset, to: target, dayShift: dayShift, started: time)
    }

    func interruptSnap() {
        snap = nil
    }

    func advanceSnap(at time: TimeInterval) -> Int? {
        guard let snap else { return nil }
        let progress = min(1, max(0, (time - snap.started) / 0.15))
        if progress == 1 {
            offset = snap.to
            self.snap = nil
            return snap.dayShift
        }
        let eased = progress * progress * (3 - 2 * progress)
        offset = snap.from + (snap.to - snap.from) * eased
        return nil
    }
}

private final class WeekCardLayouts {
    struct Card {
        let event: CalendarEvent
        let lane: LanePlacement
        let top: CGFloat
        let height: CGFloat
        let beforeHeight: CGFloat
        let afterHeight: CGFloat
    }

    struct DayLayout {
        let events: [CalendarEvent]
        let cards: [Card]
        let overlaps: ActivityBufferOverlapPlan
        let blendsBuffers: Bool
        let minimumHeight: CGFloat
    }

    private var days: [Date: DayLayout] = [:]
    private var calendar: Calendar?
    private var hourHeight: CGFloat?

    func retain(_ dates: [Date]) {
        let visible = Set(dates)
        days = days.filter { visible.contains($0.key) }
    }

    func layout(for day: Date, until endOfDay: Date, events: [CalendarEvent], calendar: Calendar,
                hourHeight: CGFloat, minimumHeight: CGFloat, blendsBuffers: Bool) -> DayLayout {
        if self.calendar != calendar || self.hourHeight != hourHeight {
            days.removeAll(keepingCapacity: true)
            self.calendar = calendar
            self.hourHeight = hourHeight
        }
        if let layout = days[day], layout.events == events, layout.blendsBuffers == blendsBuffers,
           layout.minimumHeight == minimumHeight { return layout }

        let origin = Date(timeIntervalSinceReferenceDate: 0)
        let pointsPerSecond = hourHeight / 3_600
        func secondsSinceMidnight(_ date: Date) -> Double {
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((time.hour ?? 0) * 3_600 + (time.minute ?? 0) * 60 + (time.second ?? 0))
        }

        // Use wall-clock coordinates so a daylight-saving transition doesn't misalign later hours.
        let timedEvents = events.filter { !$0.isAllDay }
        let overlaps = ActivityBufferOverlapPlan(events: timedEvents, in: DateInterval(start: day, end: endOfDay), enabled: blendsBuffers)
        let intervals = timedEvents.map { event in
            let start = event.occupiedStart <= day ? 0 : secondsSinceMidnight(event.occupiedStart)
            let end = event.occupiedEnd >= endOfDay ? 86_400 : secondsSinceMidnight(event.occupiedEnd)
            let adjustedEnd = end <= start ? start + event.occupiedEnd.timeIntervalSince(event.occupiedStart) : end
            let before = event.activityDetails.before == nil ? 0 : max(0, min(86_400, event.start >= endOfDay ? 86_400 : secondsSinceMidnight(event.start)) - start)
            let after = event.activityDetails.after == nil ? 0 : max(0, end - max(0, event.end <= day ? 0 : secondsSinceMidnight(event.end)))
            let coreIsVisible = event.start < endOfDay && event.end > day
            let coreDuration = max(0, min(event.end, endOfDay).timeIntervalSince(max(event.start, day)))
            let minimumCore = overlaps.affectedIDs.contains(event.id.layoutID) ? coreDuration : minimumHeight / pointsPerSecond
            let readable = (coreIsVisible ? minimumCore : 0) + before + after
            let visibleEnd = min(86_400, max(adjustedEnd, start + readable))
            return TimedInterval(id: event.id.layoutID, start: origin + start, end: origin + visibleEnd)
        }
        let laneIntervals = overlaps.laneIntervals(for: timedEvents)?.map { interval in
            TimedInterval(id: interval.id, start: origin + (interval.start <= day ? 0 : interval.start >= endOfDay ? 86400 : secondsSinceMidnight(interval.start)),
                          end: origin + (interval.end >= endOfDay ? 86400 : interval.end <= day ? 0 : secondsSinceMidnight(interval.end)))
        } ?? intervals
        let lanes = Dictionary(uniqueKeysWithValues: EventLayoutEngine.lanes(for: laneIntervals).map { ($0.id, $0) })
        let cards = zip(timedEvents, intervals).compactMap { event, interval -> Card? in
            guard let lane = lanes[interval.id] else { return nil }
            let top = interval.start.timeIntervalSince(origin) * pointsPerSecond
            let start = event.start <= day ? 0 : event.start >= endOfDay ? 86_400 : secondsSinceMidnight(event.start)
            let end = event.end >= endOfDay ? 86_400 : event.end <= day ? 0 : secondsSinceMidnight(event.end)
            let occupiedEnd = event.occupiedEnd >= endOfDay ? 86_400 : secondsSinceMidnight(event.occupiedEnd)
            let before = event.activityDetails.before == nil ? 0 : max(0, start * pointsPerSecond - top)
            let after = event.activityDetails.after == nil ? 0 : max(0, (occupiedEnd - end) * pointsPerSecond)
            return Card(event: event, lane: lane, top: top,
                        height: interval.end.timeIntervalSince(interval.start) * pointsPerSecond,
                        beforeHeight: before, afterHeight: after)
        }
        let layout = DayLayout(events: events, cards: cards, overlaps: overlaps,
                               blendsBuffers: blendsBuffers, minimumHeight: minimumHeight)
        days[day] = layout
        return layout
    }
}

struct DesktopHorizontalTrackpad: NSViewRepresentable {
    var followsMomentum = false
    var canStart: (CGFloat) -> Bool
    var move: (CGFloat) -> Void
    var finish: (CGFloat?) -> Void
    var frame: ((TimeInterval) -> Bool)? = nil

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.followsMomentum = followsMomentum
        view.canStart = canStart
        view.move = move
        view.finish = finish
        view.frameUpdate = frame
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) {
        view.removeMonitor()
    }

    final class Surface: NSView {
        var followsMomentum = false
        var canStart: (CGFloat) -> Bool = { _ in false }
        var move: (CGFloat) -> Void = { _ in }
        var finish: (CGFloat?) -> Void = { _ in }
        var frameUpdate: ((TimeInterval) -> Bool)?
        private var frameLink: CADisplayLink?
        private var fallbackFrameTimer: Timer?
        private var pendingDistance: CGFloat = 0
        private var pendingFinish = false
        private var monitor: Any?
        private var input = DesktopTrackpadScroll()
        private var momentumWait: Task<Void, Never>?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            input = DesktopTrackpadScroll()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window, event.hasPreciseScrollingDeltas else {
                    return event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                return self.consume(phase: event.phase, momentum: event.momentumPhase,
                                    x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                    time: event.timestamp, point: point) ? nil : event
            }
        }

        func removeMonitor() {
            cancelMomentumWait()
            frameLink?.invalidate()
            frameLink = nil
            fallbackFrameTimer?.invalidate()
            fallbackFrameTimer = nil
            pendingDistance = 0
            pendingFinish = false
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        func consume(phase: NSEvent.Phase, momentum: NSEvent.Phase, x: CGFloat, y: CGFloat,
                     time: TimeInterval, point: CGPoint) -> Bool {
            let startsHere = phase.contains(.began) && visibleRect.contains(point) && canStart(point.y)
            let interruptsCoast = phase.contains(.began) && input.isFollowingMomentum
            if interruptsCoast { cancelMomentumWait() }
            let output = input.receive(phase: phase, momentum: momentum, x: x, y: y, time: time,
                                       startsHere: startsHere, followsMomentum: followsMomentum)
            if interruptsCoast, output == .pass { finishHorizontal(0) }
            switch output {
            case .pass: return false
            case .consume: return true
            case .move(let distance):
                cancelMomentumWait()
                if frameUpdate != nil {
                    pendingFinish = false
                    pendingDistance += distance
                    scheduleFrame()
                } else {
                    move(distance)
                }
                return true
            case .waitForMomentum:
                waitForMomentum()
                return x != 0 || y != 0
            case .finish(let projection):
                cancelMomentumWait()
                finishHorizontal(projection)
                // Let a scroll view that received the initial phase close its gesture too.
                return !momentum.isEmpty || x != 0 || y != 0
            }
        }

        private func waitForMomentum() {
            cancelMomentumWait()
            momentumWait = Task { [weak self] in
                // AppKit sends the momentum-began event after the fingers lift, if there is a coast.
                try? await Task.sleep(for: .milliseconds(45))
                guard !Task.isCancelled, let self else { return }
                self.momentumWait = nil
                // Keep accepting momentum if AppKit delivers its first event late.
                self.finishHorizontal(0)
            }
        }

        private func finishHorizontal(_ projection: CGFloat?) {
            if frameUpdate == nil {
                finish(projection)
            } else {
                pendingFinish = true
                scheduleFrame()
            }
        }

        private func scheduleFrame() {
            if frameLink == nil, fallbackFrameTimer == nil {
                if let window, window.screen != nil {
                    let link = window.displayLink(target: self, selector: #selector(drawFrame(_:)))
                    link.add(to: .main, forMode: .common)
                    frameLink = link
                } else {
                    let timer = Timer(timeInterval: 1.0 / 60, target: self,
                                      selector: #selector(drawFallbackFrame(_:)), userInfo: nil, repeats: true)
                    RunLoop.main.add(timer, forMode: .common)
                    fallbackFrameTimer = timer
                }
            }
            frameLink?.isPaused = false
        }

        @objc private func drawFrame(_ link: CADisplayLink) {
            if !advanceFrame(at: link.targetTimestamp) { link.isPaused = true }
        }

        @objc private func drawFallbackFrame(_ timer: Timer) {
            if !advanceFrame(at: CACurrentMediaTime()) {
                timer.invalidate()
                fallbackFrameTimer = nil
            }
        }

        private func advanceFrame(at time: TimeInterval) -> Bool {
            let distance = pendingDistance
            pendingDistance = 0
            if distance != 0 { move(distance) }
            if pendingFinish {
                pendingFinish = false
                finish(0)
            }
            return frameUpdate?(time) == true
        }

        private func cancelMomentumWait() {
            momentumWait?.cancel()
            momentumWait = nil
        }
    }
}

struct DesktopTrackpadScroll {
    enum Output: Equatable {
        case pass, consume, move(CGFloat), waitForMomentum, finish(CGFloat?)
    }

    private enum Axis { case waiting, vertical, horizontal }
    private var axis = Axis.vertical
    private var initialX: CGFloat = 0
    private var initialY: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastMovement: TimeInterval?
    private var consumeMomentum = false
    private(set) var isFollowingMomentum = false

    mutating func receive(phase: NSEvent.Phase, momentum: NSEvent.Phase, x: CGFloat, y: CGFloat,
                          time: TimeInterval, startsHere: Bool, followsMomentum: Bool = false) -> Output {
        if !momentum.isEmpty {
            if isFollowingMomentum {
                if momentum.contains(.ended) || momentum.contains(.cancelled) {
                    isFollowingMomentum = false
                    return .finish(0)
                }
                return .move(x)
            }
            let output: Output = consumeMomentum ? .consume : .pass
            if momentum.contains(.ended) || momentum.contains(.cancelled) { consumeMomentum = false }
            return output
        }
        if phase.contains(.began) {
            self = DesktopTrackpadScroll()
            axis = startsHere ? .waiting : .vertical
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            guard axis == .horizontal else { return .pass }
            axis = .vertical
            consumeMomentum = true
            guard !phase.contains(.cancelled) else { return .finish(nil) }
            if followsMomentum {
                isFollowingMomentum = true
                return .waitForMomentum
            }
            let elapsed = time - (lastMovement ?? time)
            let projection = elapsed < 0.08 ? min(260, max(-260, velocity * 0.12)) : 0
            return .finish(projection)
        }
        guard !phase.isEmpty, !phase.contains(.mayBegin), axis != .vertical else { return .pass }
        if axis == .waiting {
            initialX += x
            initialY += y
            guard max(abs(initialX), abs(initialY)) >= 7 else { return .pass }
            guard abs(initialX) > abs(initialY) * 1.35 else {
                axis = .vertical
                return .pass
            }
            axis = .horizontal
            lastMovement = time
            return .move(initialX)
        }
        if x != 0 {
            let interval = time - (lastMovement ?? time)
            if interval > 0 { velocity = x / max(1.0 / 120, interval) }
            lastMovement = time
        }
        return .move(x)
    }
}

enum DesktopEventDragPart: Equatable {
    case start, move, end

    func adjust(_ range: DateInterval, seconds: TimeInterval, days: Int = 0,
                stepMinutes: Int, calendar: Calendar) -> DateInterval {
        let step = TimeInterval(stepMinutes * 60)
        let delta = (seconds / step).rounded() * step
        // Keep the existing minute offset even when the handles approach one another.
        let inwardLimit = max(0, floor((range.duration - 1) / step) * step)
        switch self {
        case .start:
            return DateInterval(start: range.start + min(delta, inwardLimit), end: range.end)
        case .end:
            return DateInterval(start: range.start, end: range.end + max(delta, -inwardLimit))
        case .move:
            let dayShifted = calendar.date(byAdding: .day, value: days, to: range.start) ?? range.start
            return DateInterval(start: dayShifted + delta, duration: range.duration)
        }
    }
}

struct DesktopEventDragPreview {
    let range: DateInterval
    let offset: CGSize
    let height: CGFloat
}

struct DesktopTimelinePinch<Anchor>: ViewModifier {
    let model: CalendarModel
    var enabled = true
    var capture: (CGFloat) -> Anchor? = { _ in nil }
    var restore: (Anchor, CGFloat) -> Void = { _, _ in }

    private struct Pinch {
        let initialHeight: CGFloat
        let y: CGFloat
        let anchor: Anchor?
    }

    @State private var pinch: Pinch?
    @GestureState private var pinching = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(MagnifyGesture()
                .updating($pinching) { _, active, _ in active = true }
                .onChanged { value in
                    guard enabled else { return }
                    let current = pinch ?? Pinch(initialHeight: model.desktopHourHeight,
                                                 y: value.startLocation.y, anchor: capture(value.startLocation.y))
                    pinch = current
                    let height = min(260, max(36, current.initialHeight * value.magnification))
                    if height != model.desktopHourHeight { model.desktopZoomHeight = height }
                })
            .onChange(of: model.desktopHourHeight) {
                if let pinch, let anchor = pinch.anchor { restore(anchor, pinch.y) }
            }
            .onChange(of: pinching) { _, active in
                if !active { pinch = nil }
            }
    }
}

struct DesktopEventDrag: ViewModifier {
    let model: CalendarModel
    let event: CalendarEvent
    let width: CGFloat
    let height: CGFloat
    let canResizeStart: Bool
    let canResizeEnd: Bool
    let previewForDrag: (DesktopEventDragPart, DragGesture.Value) -> DesktopEventDragPreview?
    let editRange: (CalendarEvent, DateInterval) -> Void
    var onDragChanged: (Bool) -> Void = { _ in }
    var hitShape: ActivityCardHitShape? = nil

    @Namespace private var cardSpace
    @GestureState private var dragging = false
    @GestureState private var preview: DesktopEventDragPreview?
    @State private var hoveredPart: DesktopEventDragPart?

    func body(content: Content) -> some View {
        if model.writableCalendars.contains(where: { $0.id == event.id.calendarID }) {
            content
                .opacity(preview == nil ? 1 : 0.25)
                .overlay(alignment: .topLeading) {
                    if let preview {
                        DesktopTimedCardLabel(title: event.displayTitle,
                                              time: "\(model.time(preview.range.start))–\(model.time(preview.range.end))",
                                              color: model.eventColor(event).swiftUI, height: preview.height)
                            .frame(width: width)
                            .offset(preview.offset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(hitShape ?? ActivityCardHitShape(part: .whole, before: 0, after: 0))
                .coordinateSpace(name: cardSpace)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if let hitShape, !hitShape.path(in: CGRect(x: 0, y: 0, width: width, height: height)).contains(point) {
                            hoveredPart = nil
                            return
                        }
                        let hovered = part(at: point.y)
                        if hoveredPart != hovered {
                            hoveredPart = hovered
                        }
                    case .ended:
                        hoveredPart = nil
                    }
                }
                .modifier(DesktopEventPointer(part: hoveredPart, dragging: dragging))
                .onChange(of: dragging) { _, active in
                    onDragChanged(active)
                }
                .onDisappear {
                    if dragging { onDragChanged(false) }
                }
                .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(cardSpace))
                    .updating($dragging) { _, active, _ in active = true }
                    .updating($preview) { value, current, _ in
                        current = previewForDrag(part(at: value.startLocation.y), value)
                    }
                    .onEnded { value in
                        if let result = previewForDrag(part(at: value.startLocation.y), value) {
                            editRange(event, result.range)
                        }
                    })
                .zIndex(preview == nil ? 0 : 1)
        } else {
            content
        }
    }

    private func part(at y: CGFloat) -> DesktopEventDragPart {
        if hitShape?.part == .extensions { return .move }
        let before = hitShape?.part == .core ? (hitShape?.before ?? 0) : 0
        let after = hitShape?.part == .core ? (hitShape?.after ?? 0) : 0
        let coreHeight = max(0, height - before - after)
        let edge = min(6, coreHeight / 4)
        if canResizeStart && y - before < edge { return .start }
        if canResizeEnd && y - before >= coreHeight - edge { return .end }
        return .move
    }

    private struct DesktopEventPointer: ViewModifier {
        let part: DesktopEventDragPart?
        let dragging: Bool

        func body(content: Content) -> some View {
            if #available(macOS 15, *) {
                let style: PointerStyle? = switch part {
                case .start, .end: .rowResize
                case .move: dragging ? .grabActive : .grabIdle
                case nil: nil
                }
                content.pointerStyle(style)
            } else {
                content
                    .onChange(of: part) { updateCursor() }
                    .onChange(of: dragging) { updateCursor() }
                    .onDisappear { if part != nil { NSCursor.arrow.set() } }
            }
        }

        private func updateCursor() {
            switch part {
            case .start, .end: NSCursor.resizeUpDown.set()
            case .move: (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
            case nil: NSCursor.arrow.set()
            }
        }
    }
}
#endif
