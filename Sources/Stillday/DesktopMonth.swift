#if os(macOS)
import CalendarCore
import CalendarData
import SwiftUI

struct DesktopMonthGrid: View {
    let model: CalendarModel
    let select: (Date) -> Void
    let eventAction: (CalendarEvent, CalendarEventAction) -> Void
    let openTask: (GoogleTaskDeadline) -> Void

    private let weekdayHeight: CGFloat = 29

    var body: some View {
        let calendar = model.calendar
        let range = model.window(for: .month)
        let days = CalendarWindow.days(in: range, calendar: calendar)
        let weeks = stride(from: 0, to: days.count, by: 7).map { days[$0..<min($0 + 7, days.count)] }
        let events = model.events(in: range).filter { event in
            if model.isImportant(event) { return true }
            if event.isAllDay { return model.showsAllDay(calendarID: event.calendar.id, in: .month) }
            return model.highlights.showTimedEventsInMonth
        }
        let eventDays = dayBuckets(events, days: days, calendar: calendar)
        let taskDays = Dictionary(grouping: model.tasks(in: range, mode: .month), by: \.day)
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7
            let rowHeight = max(64, (geometry.size.height - weekdayHeight) / CGFloat(max(1, weeks.count)))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7) { index in
                        let weekday = (calendar.firstWeekday - 1 + index) % 7
                        Text(calendar.shortStandaloneWeekdaySymbols[weekday])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(height: weekdayHeight)
                            .padding(.leading, 8)
                            .frame(width: columnWidth, alignment: .leading)
                            .accessibilityLabel(calendar.standaloneWeekdaySymbols[weekday])
                    }
                }
                .background(.background.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(weeks, id: \.first) { week in
                            HStack(spacing: 0) {
                                ForEach(week, id: \.self) { day in
                                    let dayEvents = eventDays[day] ?? []
                                    let items = dayEvents.filter(\.isAllDay).map(MonthItem.event)
                                        + (taskDays[day] ?? []).map(MonthItem.task)
                                        + dayEvents.filter { !$0.isAllDay }.map(MonthItem.event)
                                    MonthCell(model: model, day: day, items: items, width: columnWidth, height: rowHeight,
                                              select: select, eventAction: eventAction, openTask: openTask)
                                }
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private enum MonthItem: Identifiable {
    case event(CalendarEvent), task(GoogleTaskDeadline)

    enum ID: Hashable { case event(EventIdentity), task(GoogleTaskDeadline.ID) }

    var id: ID {
        switch self {
        case .event(let event): .event(event.id)
        case .task(let task): .task(task.id)
        }
    }
}

private struct MonthCell: View {
    let model: CalendarModel
    let day: Date
    let items: [MonthItem]
    let width: CGFloat
    let height: CGFloat
    let select: (Date) -> Void
    let eventAction: (CalendarEvent, CalendarEventAction) -> Void
    let openTask: (GoogleTaskDeadline) -> Void
    @State private var showAll = false

    private let entryHeight: CGFloat = 18

    var body: some View {
        let calendar = model.calendar
        let today = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: model.selection)
        let inMonth = calendar.isDate(day, equalTo: model.selection, toGranularity: .month)
        let slots = max(1, Int((height - 27) / entryHeight))
        let count = items.count > slots ? slots - 1 : items.count
        VStack(alignment: .leading, spacing: 0) {
            Button { select(day) } label: {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.monospacedDigit().weight(today ? .semibold : .medium))
                    .foregroundStyle(today ? Color.white : inMonth ? .primary : .secondary)
                    .frame(minWidth: 22, minHeight: 20)
                    .background(today ? model.accentColor : .clear, in: Capsule())
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(day.formatted(.dateTime.weekday().day().month().year()))
            .accessibilityAddTraits(isSelected ? [.isHeader, .isSelected] : .isHeader)
            ForEach(items.prefix(count)) { item in
                entry(item, expanded: false)
            }
            if count < items.count {
                Button {
                    showAll = true
                } label: {
                    Text("+\(items.count - count) more")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: entryHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show all \(items.count) items for \(day.formatted(.dateTime.month().day()))")
                .popover(isPresented: $showAll, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        ScrollView {
                            VStack(spacing: 3) {
                                ForEach(items) { entry($0, expanded: true) }
                            }
                        }
                        .frame(height: min(324, CGFloat(items.count) * 27))
                    }
                    .padding(12)
                    .frame(width: 320)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(today || isSelected ? model.accentColor.opacity(0.07)
                    : .primary.opacity(inMonth ? (calendar.isDateInWeekend(day) ? 0.025 : 0) : 0.05))
        .overlay(alignment: .top) { Rectangle().fill(.secondary.opacity(0.20)).frame(height: 1).allowsHitTesting(false) }
        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.16)).frame(width: 1).allowsHitTesting(false) }
    }

    @ViewBuilder
    private func entry(_ item: MonthItem, expanded: Bool) -> some View {
        let height = expanded ? 24 : entryHeight
        switch item {
        case .event(let event):
            let color = model.eventColor(event).swiftUI
            CalendarEventButton(event: event, model: model, action: eventAction) {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(event.displayTitle).lineLimit(1)
                    if !event.isAllDay && (expanded || width >= 150) {
                        Spacer(minLength: 0)
                        Text(model.time(event.start))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .calendarEventMenu(event, model: model, action: eventAction)
            .accessibilityLabel("\(event.displayTitle), \(model.timeLabel(event))")
            .help("\(event.displayTitle) · \(model.timeLabel(event))")
        case .task(let task):
            Button { openTask(task) } label: {
                TaskLabel(task: task, accent: model.taskIconColor)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .help(task.title)
        }
    }
}
#endif
