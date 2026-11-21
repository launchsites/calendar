import CalendarCore
import CalendarData
import Foundation
import SwiftUI

@MainActor @Observable
final class CalendarModel {
    struct Query: Hashable {
        let window: DateInterval
        let hidden: Set<String>
        let included: Set<String>?
        let revision: Int
    }

    struct TasksQuery: Hashable {
        let window: DateInterval
        let required: DateInterval
        let zone: TimeZone
        let revisions: [String: Int]
    }

    private(set) var taskAccounts: [GoogleTasksAccount] = []
    private static let settingsKey = "Stillday.Settings.v1"
    private static let usageKey = "Stillday.CalendarUsage.v1"
    let store: any CalendarStore
    private let defaults: UserDefaults
    var selection = Date() {
        didSet {
            #if os(macOS)
            desktopWeekStart = nil
            #endif
        }
    }
    var mode: CalendarViewMode = .day
    var snapshot = CalendarSnapshot(access: .unknown)
    var displayedQuery: Query?
    private var daySnapshots: [Query: CalendarSnapshot] = [:]
    var revision = 0
    var message: String?
    var requesting = false
    #if os(macOS)
    var desktopZoomHeight: CGFloat?
    var desktopHourHeight: CGFloat { desktopZoomHeight ?? CGFloat(preferences.pointsPerHour) }
    private var desktopWeekStart: Date?

    func rollDesktopWeek(by days: Int) {
        guard days != 0 else { return }
        let calendar = self.calendar
        let start = window(for: .week).start
        selection = CalendarViewMode.day.advance(selection, by: days, calendar: calendar)
        desktopWeekStart = calendar.startOfDay(for: CalendarViewMode.day.advance(start, by: days, calendar: calendar))
    }

    private var desktopWeekFetchWindow: DateInterval {
        let calendar = self.calendar
        let week = CalendarViewMode.week.window(for: window(for: .week).start, calendar: calendar)
        return DateInterval(start: CalendarViewMode.week.advance(week.start, by: -1, calendar: calendar),
                            end: CalendarViewMode.week.advance(week.end, by: 2, calendar: calendar))
    }

    func desktopWeekEvents() -> [CalendarEvent] {
        // While the next range loads, keep all matching events from the previous range visible.
        let requested = query
        guard let displayedQuery, displayedQuery.hidden == requested.hidden,
              displayedQuery.included == requested.included else { return [] }
        return presentationEvents(snapshot.events)
    }

    func replayCalendarEdit(redo: Bool) {
        guard let history = store as? any CalendarEditHistoryStore else { return }
        Task {
            do {
                if try await history.replayCalendarEdit(redo: redo) { invalidate() }
            } catch {
                message = error.localizedDescription
                invalidate()
            }
        }
    }
    #endif
    private(set) var calendarUsage: CalendarUsage? {
        didSet {
            if let calendarUsage, let data = try? JSONEncoder().encode(calendarUsage) {
                defaults.set(data, forKey: Self.usageKey)
            }
        }
    }
    @ObservationIgnored private var usageSeed: Task<CalendarUsage?, Never>?
    var preferences: Preferences {
        didSet {
            #if os(macOS)
            if oldValue.pointsPerHour != preferences.pointsPerHour { desktopZoomHeight = nil }
            if oldValue.weekStart != preferences.weekStart { desktopWeekStart = nil }
            #endif
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: Self.settingsKey)
            }
        }
    }

    init(store: any CalendarStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.settingsKey).flatMap {
            try? JSONDecoder().decode(Preferences.self, from: $0)
        } ?? Preferences()
        calendarUsage = defaults.data(forKey: Self.usageKey).flatMap {
            try? JSONDecoder().decode(CalendarUsage.self, from: $0)
        }
        mode = visibleModes[0]
        taskAccounts = taskConnections.map { GoogleTasksAccount(id: $0.id) }
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        if let first = preferences.weekStart.firstWeekday { calendar.firstWeekday = first }
        return calendar
    }

    var colorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var selectedAccentColor: Preferences.AccentColor? {
        get {
            if let profile = activeProfile { return profile.accentColor }
            return preferences.accentColor
        }
        set {
            if var profile = activeProfile {
                profile.accentColor = newValue
                saveProfile(profile)
            } else {
                preferences.accentColor = newValue
            }
        }
    }

    var accentColor: Color { selectedAccentColor.map(swiftUIColor) ?? .accentColor }

    func swiftUIColor(_ color: Preferences.AccentColor) -> Color {
        return Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
                     blue: Double(color.blue) / 255)
    }

    var profiles: [CalendarProfile] { preferences.calendarProfiles ?? [] }

    var activeProfile: CalendarProfile? {
        profiles.first { $0.id == preferences.activeCalendarProfileID }
    }

    func switchProfile(_ id: UUID?) {
        preferences.activeCalendarProfileID = id
    }

    func saveProfile(_ profile: CalendarProfile) {
        var profiles = self.profiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        preferences.calendarProfiles = profiles
    }

    func removeProfile(_ id: UUID) {
        var updated = preferences
        updated.calendarProfiles = profiles.filter { $0.id != id }
        if updated.activeCalendarProfileID == id { updated.activeCalendarProfileID = nil }
        preferences = updated
    }

    func calendarIsVisible(_ id: String) -> Bool {
        activeProfile?.calendarIDs.contains(id) ?? !preferences.hiddenCalendars.contains(id)
    }

    func setCalendar(_ id: String, visible: Bool) {
        if var profile = activeProfile {
            if visible { profile.calendarIDs.insert(id) } else { profile.calendarIDs.remove(id) }
            saveProfile(profile)
        } else {
            if visible { preferences.hiddenCalendars.remove(id) } else { preferences.hiddenCalendars.insert(id) }
        }
    }

    private func importanceKey(_ event: CalendarEvent) -> String {
        let occurrence = event.isRecurring ? event.id.occurrence ?? event.start : nil
        return "\(event.id.calendarID):\(event.id.identifier):\(occurrence?.timeIntervalSinceReferenceDate ?? 0)"
    }

    func isImportant(_ event: CalendarEvent) -> Bool {
        preferences.importantEventIDs?.contains(importanceKey(event)) == true
    }

    func toggleImportance(_ event: CalendarEvent) {
        var important = preferences.importantEventIDs ?? []
        let key = importanceKey(event)
        if !important.insert(key).inserted { important.remove(key) }
        preferences.importantEventIDs = important
    }

    var query: Query {
        #if os(macOS)
        if mode == .week { return query(for: desktopWeekFetchWindow) }
        #endif
        return query(for: window(for: mode))
    }

    private func query(for window: DateInterval) -> Query {
        let profile = activeProfile
        return Query(window: window, hidden: profile == nil ? preferences.hiddenCalendars : [],
                     included: profile?.calendarIDs, revision: revision)
    }

    func window(for mode: CalendarViewMode) -> DateInterval {
        #if os(macOS)
        if mode == .week, let start = desktopWeekStart {
            let calendar = self.calendar
            let end = calendar.startOfDay(for: CalendarViewMode.day.advance(start, by: 7, calendar: calendar))
            return DateInterval(start: start, end: end)
        }
        #endif
        return mode.window(for: selection, calendar: calendar)
    }

    func hasLoaded(_ window: DateInterval) -> Bool {
        let requested = query(for: window)
        return displayedQuery?.window == window && displayedQuery?.hidden == requested.hidden
            && displayedQuery?.included == requested.included
    }

    func events(in window: DateInterval) -> [CalendarEvent] {
        if hasLoaded(window) { return presentationEvents(snapshot.events) }
        return mode == .day ? presentationEvents(daySnapshots[query(for: window)]?.events ?? []) : []
    }

    func hasDaySnapshot(_ window: DateInterval) -> Bool {
        hasLoaded(window) || daySnapshots[query(for: window)] != nil
    }

    private func presentationEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let sources = Dictionary(grouping: snapshot.calendars, by: \.choice.qualifiedTitle)
        return LinkedActivities.presented(events, calendarOrder: editingCalendars.map(\.id)).map { event in
            guard let link = event.activityDetails.link else { return event }
            var seen: Set<String> = [event.calendar.id]
            let others = link.calendars.compactMap { name -> CalendarListItem? in
                guard let matches = sources[name], matches.count == 1,
                      seen.insert(matches[0].id).inserted else { return nil }
                return matches[0]
            }
            return event.showingCalendars([event.calendar] + others)
        }
    }

    var editingCalendars: [CalendarListItem] {
        guard let profile = activeProfile else { return snapshot.calendars }
        return calendars(in: profile)
    }

    func calendars(in profile: CalendarProfile) -> [CalendarListItem] {
        let included = snapshot.calendars.filter { profile.calendarIDs.contains($0.id) }
        var remaining = Dictionary(uniqueKeysWithValues: included.map { ($0.id, $0) })
        let ordered = (profile.calendarOrder ?? []).compactMap { remaining.removeValue(forKey: $0) }
        return ordered + included.filter { remaining[$0.id] != nil }
    }

    var writableCalendars: [CalendarListItem] { editingCalendars.filter { $0.choice.isWritable } }

    var visibleModes: [CalendarViewMode] {
        let hidden = preferences.hiddenViews ?? []
        let visible = CalendarViewMode.allCases.filter { !hidden.contains($0) }
        return visible.isEmpty ? [.day] : visible
    }

    func setView(_ view: CalendarViewMode, visible: Bool) {
        var hidden = Set(CalendarViewMode.allCases).subtracting(visibleModes)
        if visible {
            hidden.remove(view)
        } else {
            guard visibleModes.count > 1 else { return }
            hidden.insert(view)
        }
        preferences.hiddenViews = hidden.isEmpty ? nil : hidden
        if !visible && mode == view { mode = visibleModes[0] }
    }

    var highlights: CalendarHighlightOptions {
        get { preferences.highlightOptions ?? CalendarHighlightOptions() }
        set { preferences.highlightOptions = newValue }
    }

    var taskConnections: [GoogleTaskConnection] { preferences.googleTaskConnections ?? [.primary] }
    var taskIconColor: Color { highlights.useAccentForTaskIcons ? accentColor : .secondary }

    func taskConnectionName(for task: GoogleTaskDeadline) -> String? {
        guard taskConnections.count > 1 else { return nil }
        return taskConnections.first { $0.id == task.id.connectionID }?.name
    }

    func addTaskConnection(name: String) -> GoogleTaskConnection {
        let connection = GoogleTaskConnection(name: name)
        preferences.googleTaskConnections = taskConnections + [connection]
        taskAccounts.append(GoogleTasksAccount(id: connection.id))
        return connection
    }

    func renameTaskConnection(_ id: String, to name: String) {
        var connections = taskConnections
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].name = name
        preferences.googleTaskConnections = connections
    }

    func removeTaskConnection(_ id: String) {
        guard let account = taskAccounts.first(where: { $0.id == id }), account.disconnect() else { return }
        if id == GoogleTaskConnection.primary.id { return }
        var updated = preferences
        updated.googleTaskConnections = taskConnections.filter { $0.id != id }
        updated.calendarProfiles = profiles.map { profile in
            var profile = profile
            profile.taskConnectionIDs.remove(id)
            return profile
        }
        preferences = updated
        taskAccounts.removeAll { $0.id == id }
    }

    private var visibleTaskAccounts: [GoogleTasksAccount] {
        let included = activeProfile?.taskConnectionIDs
        return taskAccounts.filter { $0.isConnected && (included?.contains($0.id) ?? true) }
    }

    private func showsTasks(in mode: CalendarViewMode) -> Bool {
        switch mode {
        case .day: highlights.googleTasks.day
        case .week: highlights.showTasksInWeek
        case .month: highlights.googleTasks.month
        }
    }

    func tasks(in range: DateInterval, mode: CalendarViewMode) -> [GoogleTaskDeadline] {
        guard showsTasks(in: mode) else { return [] }
        return visibleTaskAccounts.flatMap { $0.deadlines(in: range, timeZone: calendar.timeZone) }
            .filter { highlights.showCompletedTasks || !$0.isCompleted }
            .sorted {
                if $0.day != $1.day { return $0.day < $1.day }
                if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    var tasksQuery: TasksQuery? {
        let accounts = visibleTaskAccounts
        guard !accounts.isEmpty, showsTasks(in: mode) else { return nil }
        let revisions = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.revision) })
        switch mode {
        case .day:
            let day = window(for: .day).start
            let calendar = self.calendar
            func span(_ radius: Int) -> DateInterval {
                DateInterval(start: CalendarViewMode.day.advance(day, by: -radius, calendar: calendar),
                             end: CalendarViewMode.day.advance(day, by: radius + 1, calendar: calendar))
            }
            return TasksQuery(window: span(3), required: span(1), zone: calendar.timeZone, revisions: revisions)
        case .week:
            #if os(macOS)
            let range = desktopWeekFetchWindow
            #else
            let range = window(for: .week)
            #endif
            return TasksQuery(window: range, required: range, zone: calendar.timeZone, revisions: revisions)
        case .month:
            let range = window(for: mode)
            return TasksQuery(window: range, required: range, zone: calendar.timeZone, revisions: revisions)
        }
    }

    func loadTasks(_ query: TasksQuery) async {
        let accounts = visibleTaskAccounts.filter { query.revisions[$0.id] == $0.revision }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await account.load(in: query.window, required: query.required, timeZone: query.zone) }
            }
        }
    }

    func invalidateTasks() {
        for account in visibleTaskAccounts { account.invalidate() }
    }

    func showsAllDay(calendarID: String, in mode: CalendarViewMode) -> Bool {
        let source = preferences.allDayCalendars?[calendarID] ?? CalendarHighlightOptions.Visibility()
        switch mode {
        case .day: return highlights.allDay.day && source.day
        case .month: return highlights.allDay.month && source.month
        case .week: return true
        }
    }

    var eventCategoriesEnabled: Bool {
        get { preferences.eventCategoriesEnabled ?? !(preferences.categoryColours?.isEmpty ?? true) }
        set { preferences.eventCategoriesEnabled = newValue }
    }

    var calendarSuggestionsEnabled: Bool {
        get { preferences.calendarSuggestionsEnabled ?? true }
        set { preferences.calendarSuggestionsEnabled = newValue }
    }

    var categoryNames: [String] {
        (preferences.categoryColours ?? [:]).keys.map { preferences.categoryNames?[$0] ?? $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func categoryColor(_ name: String) -> CalendarColor? {
        guard let color = preferences.categoryColours?[EventCategory.key(name)] else { return nil }
        return CalendarColor(red: Double(color.red) / 255, green: Double(color.green) / 255,
                             blue: Double(color.blue) / 255)
    }

    func eventColor(_ event: CalendarEvent) -> CalendarColor {
        guard eventCategoriesEnabled, let name = EventCategory.name(in: event.notes) else {
            return event.calendar.color
        }
        return categoryColor(name) ?? event.calendar.color
    }

    func prepareCalendarUsage() async {
        guard calendarSuggestionsEnabled, calendarUsage == nil, snapshot.access == .full else { return }
        if usageSeed == nil {
            let now = Date()
            guard let start = calendar.date(byAdding: .day, value: -180, to: now) else { return }
            let window = DateInterval(start: start, end: now)
            usageSeed = Task { [store] in await store.calendarUsage(in: window) }
        }
        let seed = await usageSeed?.value
        if calendarUsage == nil { calendarUsage = seed }
        usageSeed = nil
    }

    func recordCalendarChoice(title: String, calendarID: String) {
        guard calendarSuggestionsEnabled else { return }
        var usage = calendarUsage ?? CalendarUsage()
        usage.record(title: title, calendarID: calendarID)
        calendarUsage = usage
    }

    func invalidate() { revision += 1 }

    func load(_ requestedQuery: Query) async {
        let isDay = mode == .day
        do {
            let value: CalendarSnapshot
            if isDay, let cached = daySnapshots[requestedQuery] {
                value = cached
            } else {
                value = try await fetchSnapshot(for: requestedQuery)
            }
            try Task.checkCancellation()
            guard query == requestedQuery else { return }
            snapshot = value
            displayedQuery = requestedQuery
            if isDay && value.access == .full {
                await prefetchDays(around: requestedQuery, including: value)
            } else {
                daySnapshots.removeAll()
            }
        } catch is CancellationError {
            return
        } catch {
            guard query == requestedQuery else { return }
            message = error.localizedDescription
        }
    }

    private func fetchSnapshot(for query: Query) async throws -> CalendarSnapshot {
        let hidden = query.included.map { Set(snapshot.calendars.map(\.id)).subtracting($0) } ?? query.hidden
        var value = try await store.snapshot(in: query.window, hidden: hidden)
        if let included = query.included { value.events.removeAll { !included.contains($0.id.calendarID) } }
        return value
    }

    private func prefetchDays(around current: Query, including value: CalendarSnapshot) async {
        let calendar = self.calendar
        let neighbors = [-1, 1].map { step in
            let date = CalendarViewMode.day.advance(current.window.start, by: step, calendar: calendar)
            return query(for: CalendarViewMode.day.window(for: date, calendar: calendar))
        }
        let wanted = Set(neighbors + [current])
        var cache = daySnapshots.filter { wanted.contains($0.key) }
        cache[current] = value
        daySnapshots = cache
        for neighbor in neighbors where daySnapshots[neighbor] == nil {
            guard let next = try? await fetchSnapshot(for: neighbor),
                  !Task.isCancelled, query == current else { return }
            if next.access == .full { daySnapshots[neighbor] = next }
        }
    }

    func requestAccess() async {
        guard !requesting else { return }
        requesting = true
        defer {
            requesting = false
            invalidate()
        }
        do {
            try await store.requestAccess()
        } catch {
            message = error.localizedDescription
        }
    }

    func advance(_ step: Int) {
        #if os(macOS)
        if mode == .week, desktopWeekStart != nil {
            rollDesktopWeek(by: step * 7)
            return
        }
        #endif
        selection = mode.advance(selection, by: step, calendar: calendar)
    }

    func time(_ date: Date, zone: TimeZone? = nil, hourOnly: Bool = false) -> String {
        let hours = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: hourOnly ? .narrow : .abbreviated))
        var style = hourOnly ? hours : hours.minute()
        style.timeZone = zone ?? calendar.timeZone
        // Unicode hour-cycle overrides retain the user's locale conventions.
        var components = Locale.Components(locale: .current)
        switch preferences.timeFormat {
        case .system: break
        case .twelveHour: components.hourCycle = .oneToTwelve
        case .twentyFourHour: components.hourCycle = .zeroToTwentyThree
        }
        style.locale = Locale(components: components)
        return date.formatted(style)
    }

    func timeLabel(_ event: CalendarEvent) -> String {
        event.isAllDay ? "All day" : "\(time(event.start))–\(time(event.end))"
    }
}

extension CalendarColor {
    var swiftUI: Color { Color(red: red, green: green, blue: blue) }
}

struct CalendarSwatch: View {
    let color: CalendarColor

    var body: some View {
        Circle()
            .fill(color.swiftUI)
            .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)
    }
}

struct CalendarName: View {
    let calendar: CalendarListItem

    var body: some View {
        HStack(spacing: 8) {
            CalendarSwatch(color: calendar.color)
            Text(calendar.choice.qualifiedTitle)
        }
    }
}
