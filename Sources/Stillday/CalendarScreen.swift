import CalendarCore
import CalendarData
import EventKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CalendarScreen: View {
    enum Sheet: Identifiable {
        case quickAdd(Date?), createRange(DateInterval), details(CalendarEvent, editing: Bool), delete(CalendarEvent)
        case deadline(GoogleTaskDeadline), settings, jump
        #if os(macOS)
        case reschedule(CalendarEvent, DateInterval)
        #endif
        var id: String {
            switch self {
            case .quickAdd: "add"
            case .createRange: "add-range"
            case .details(let event, _): event.id.layoutID
            case .delete(let event): "delete-\(event.id.layoutID)"
            case .deadline(let task): "task-\(task.id)"
            case .settings: "settings"
            case .jump: "jump"
            #if os(macOS)
            case .reschedule(let event, _): "reschedule-\(event.id.layoutID)"
            #endif
            }
        }
    }

    @Bindable var model: CalendarModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.openSettings) private var showDesktopSettings
    @State private var pendingTimelineEdits: Set<EventIdentity> = []
    @FocusState private var focusedDateArrow: Int?
    #endif
    @State private var sheet: Sheet?
    @State private var previewDay: Date?
    @State private var profileMenuOpen = false
    @State private var profileHoldOrigin: CGPoint?
    @State private var highlightedProfileItem: ProfileMenuItem?
    @State private var profileHighlightOffset: CGFloat = 0
    @State private var visibleProfileMenuHeight: CGFloat?
    @ScaledMetric(relativeTo: .body) private var profileRowHeight = 44.0
    @ScaledMetric(relativeTo: .body) private var scaledProfileMenuWidth = 220.0
    private let shortcut = QuickEntryLaunch.shared
    @State private var storeChanged: Task<Void, Never>?
    private let gearSize: CGFloat = 48
    private let profileMenuGap: CGFloat = 7
    private let profileMenuPadding: CGFloat = 10
    private let profileMenuSideInset: CGFloat = 18
    private let profileDividerHeight: CGFloat = 20

    private enum ProfileMenuItem: Hashable {
        case profile(UUID), divider(Int), settings

        var isDivider: Bool {
            if case .divider = self { return true }
            return false
        }
    }

    private struct GearAnchor: PreferenceKey {
        static var defaultValue: Anchor<CGRect>? { nil }
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = nextValue() ?? value
        }
    }

    private var shouldRefreshTasks: Bool {
        scenePhase == .active && sheet == nil && model.tasksQuery != nil
    }

    var body: some View {
        calendarNavigation
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlayPreferenceValue(GearAnchor.self, alignment: .topTrailing, profileMenuOverlay)
        .task(id: model.query) { [query = model.query] in await model.load(query) }
        .task(id: model.snapshot.access == .full && model.calendarSuggestionsEnabled) {
            await model.prepareCalendarUsage()
        }
        .task(id: model.tasksQuery) { [query = model.tasksQuery] in
            if let query {
                await model.loadTasks(query)
            }
        }
        .task(id: shouldRefreshTasks) {
            guard shouldRefreshTasks else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(180))
                    try Task.checkCancellation()
                    model.invalidateTasks()
                } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.invalidate()
                model.invalidateTasks()
            } else {
                closeProfileMenu()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in
            storeChanged?.cancel()
            storeChanged = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                model.invalidate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).receive(on: DispatchQueue.main)) { _ in
            model.invalidate()
        }
        .onChange(of: shortcut.pending, initial: true) { presentShortcutIfReady() }
        .onChange(of: model.writableCalendars.isEmpty) { presentShortcutIfReady() }
        .onChange(of: model.mode) { previewDay = nil }
        .sheet(item: $sheet, onDismiss: presentShortcutIfReady) { item in
            switch item {
            case .quickAdd(let slot):
                QuickAddSheet(model: model, slot: slot)
            case .createRange(let range):
                QuickAddSheet(model: model, slot: range.start, selectedRange: range)
            case .details(let event, let editing):
                EventDetailsSheet(model: model, event: event, editing: editing)
            #if os(macOS)
            case .reschedule(let event, let range):
                EventDetailsSheet(model: model, event: event, editing: true, initialRange: range)
            #endif
            case .delete(let event):
                EventDeletionSheet(model: model, event: event)
            case .deadline(let task):
                GoogleTaskSheet(task: task, accent: model.taskIconColor, connectionName: model.taskConnectionName(for: task))
            case .settings:
                SettingsSheet(model: model)
            case .jump:
                JumpSheet(date: $model.selection)
                    .environment(\.calendar, model.calendar)
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Calendar", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private func presentShortcutIfReady() {
        guard shortcut.pending, sheet == nil, !model.writableCalendars.isEmpty else { return }
        shortcut.pending = false
        sheet = .quickAdd(nil)
    }

    private var header: some View {
        let date = heading
        return HStack(spacing: 12) {
            Button {
                model.selection = Date()
            } label: {
                Text(date)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.4)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .contextMenu {
                Button("Jump to date", systemImage: "calendar") { sheet = .jump }
                Button(previousLabel, systemImage: "chevron.left") { model.advance(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button(nextLabel, systemImage: "chevron.right") { model.advance(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .accessibilityLabel("\(String(date.characters)), return to today")
            .accessibilityAddTraits(.isHeader)
            .accessibilityAction(named: Text("Jump to date")) { sheet = .jump }
            .accessibilityAction(named: Text(previousLabel)) { model.advance(-1) }
            .accessibilityAction(named: Text(nextLabel)) { model.advance(1) }
            .help("Tap for today. Press and hold for date navigation.")

            Spacer(minLength: 0)

            settingsGear
        }
    }

    private var settingsGear: some View {
        Button(action: openSettings) {
            Image(systemName: "gearshape")
                .font(.title3.weight(.semibold))
                .frame(width: gearSize, height: gearSize)
                .contentShape(Circle())
                .calendarControlGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityValue(model.activeProfile?.name ?? "No profile")
        .accessibilityAction(named: Text("Switch profile")) { profileMenuOpen = true }
        .help("Tap for Settings. Press and hold to switch profiles.")
        .keyboardShortcut(",", modifiers: .command)
        #if os(iOS)
        .overlay {
            ProfileGearTouchSurface(onTap: openSettings, onHold: handleProfileHold)
                .accessibilityHidden(true)
        }
        #else
        .onLongPressGesture(minimumDuration: 0.32) { profileMenuOpen = true }
        #endif
        .anchorPreference(key: GearAnchor.self, value: .bounds) { $0 }
    }

    private var profileMenuItems: [ProfileMenuItem] {
        let current = model.activeProfile?.id
        let others = model.profiles.filter { $0.id != current }.map { ProfileMenuItem.profile($0.id) }
        var items: [ProfileMenuItem] = []
        if let current {
            items.append(.profile(current))
            if !others.isEmpty { items.append(.divider(0)) }
        }
        items.append(contentsOf: others)
        if !items.isEmpty { items.append(.divider(1)) }
        items.append(.settings)
        return items
    }

    private var profileMenuWidth: CGFloat { min(280, scaledProfileMenuWidth) }

    private var profileMenuHeight: CGFloat {
        profileMenuItems.reduce(2 * profileMenuPadding) { height, item in
            height + profileItemHeight(item)
        }
    }

    private func profileItemHeight(_ item: ProfileMenuItem) -> CGFloat {
        item.isDivider ? profileDividerHeight : profileRowHeight
    }

    private func profileMenuOverlay(_ anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geometry in
            if profileMenuOpen, let anchor {
                let gear = geometry[anchor]
                let height = min(profileMenuHeight, max(0, geometry.size.height - gear.maxY - profileMenuGap - 8))
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeProfileMenu)
                    .accessibilityHidden(true)
                if height > 0 {
                    profilePanel(height: height)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleProfileMenuHeight = $0 }
                        .position(x: gear.maxX - profileMenuWidth / 2, y: gear.maxY + profileMenuGap + height / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: profileMenuOpen)
    }

    private func profilePanel(height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(profileMenuItems, id: \.self) { item in
                    if item.isDivider {
                        Divider()
                            .padding(.horizontal, profileMenuSideInset)
                            .frame(height: profileItemHeight(item))
                    } else {
                        profileRow(item)
                    }
                }
            }
            .padding(.vertical, profileMenuPadding)
            .background(alignment: .top) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.primary.opacity(0.22))
                    .frame(height: profileRowHeight)
                    .padding(.horizontal, 10)
                    .offset(y: profileHighlightOffset)
                    .opacity(highlightedProfileItem == nil ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(profileHoldOrigin != nil || height >= profileMenuHeight)
        .frame(width: profileMenuWidth, height: height)
        .clipShape(shape)
        .calendarControlGlass(in: shape, interactive: false)
        .accessibilityAction(.escape, closeProfileMenu)
    }

    private func profileRow(_ item: ProfileMenuItem) -> some View {
        let current: Bool
        let title: String
        if case .profile(let id) = item {
            current = id == model.activeProfile?.id
            title = model.profiles.first { $0.id == id }?.name ?? ""
        } else {
            current = false
            title = "Open Settings"
        }
        return Button { chooseProfileItem(item) } label: {
            HStack(spacing: 8) {
                Text(title).fontWeight(current ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if current {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .font(.body)
            .padding(.horizontal, profileMenuSideInset)
            .frame(height: profileItemHeight(item))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func profileItem(at point: CGPoint) -> (item: ProfileMenuItem, offset: CGFloat)? {
        let top = gearSize + profileMenuGap
        let height = visibleProfileMenuHeight ?? profileMenuHeight
        guard point.x >= gearSize - profileMenuWidth, point.x <= gearSize,
              point.y >= top, point.y < top + height else { return nil }
        var rowTop = top + profileMenuPadding
        for item in profileMenuItems {
            let bottom = rowTop + profileItemHeight(item)
            if point.y >= rowTop && point.y < bottom {
                return item.isDivider ? nil : (item, rowTop - top)
            }
            rowTop = bottom
        }
        return nil
    }

    private func chooseProfileItem(_ item: ProfileMenuItem) {
        closeProfileMenu()
        switch item {
        case .profile(let id): model.switchProfile(id)
        case .settings: openSettings()
        case .divider: break
        }
    }

    private func closeProfileMenu() {
        profileMenuOpen = false
        profileHoldOrigin = nil
        highlightedProfileItem = nil
        visibleProfileMenuHeight = nil
    }

    private func openSettings() {
        closeProfileMenu()
        #if os(macOS)
        showDesktopSettings()
        #else
        sheet = .settings
        #endif
    }

    #if os(iOS)
    private func handleProfileHold(_ state: UIGestureRecognizer.State, point: CGPoint) -> Bool {
        switch state {
        case .began:
            profileHoldOrigin = point
            profileMenuOpen = true
        case .changed:
            guard let origin = profileHoldOrigin else { return false }
            let target = abs(point.y - origin.y) > 4 ? profileItem(at: point) : nil
            guard target?.item != highlightedProfileItem else { return false }

            let slidesBetweenRows = highlightedProfileItem != nil && target != nil
            if !slidesBetweenRows, let target {
                profileHighlightOffset = target.offset
            }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: slidesBetweenRows ? 0.16 : 0.2)) {
                if let target { profileHighlightOffset = target.offset }
                highlightedProfileItem = target?.item
            }
            return target != nil
        case .ended:
            if let item = highlightedProfileItem, profileItem(at: point)?.item == item {
                chooseProfileItem(item)
            } else {
                profileHoldOrigin = nil
                highlightedProfileItem = nil
                if !CGRect(x: 0, y: 0, width: gearSize, height: gearSize + profileMenuGap).contains(point) {
                    closeProfileMenu()
                }
            }
        case .cancelled, .failed:
            closeProfileMenu()
        default: break
        }
        return false
    }
    #endif

    private var heading: AttributedString {
        let selection = model.mode == .day ? previewDay ?? model.selection : model.selection
        var date = model.mode == .month
            ? selection.formatted(.dateTime.month(.wide).year().attributed)
            : selection.formatted(.dateTime.day().month(.wide).year().attributed)
        for run in date.runs where run.dateField == .year {
            date[run.range].foregroundColor = model.accentColor
        }
        return date
    }

    private var previousLabel: String { "Previous \(model.mode.rawValue.lowercased())" }
    private var nextLabel: String { "Next \(model.mode.rawValue.lowercased())" }

    private func floatingControls<Content: View>(_ controls: Content, verticalPadding: CGFloat = 8) -> some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                GlassEffectContainer(spacing: 8) { controls }
            } else {
                controls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity)
    }

    #if os(iOS)
    private var controlRow: some View {
        let controlHeight: CGFloat = 52
        let modes = model.visibleModes
        return HStack(spacing: 12) {
            CalendarModePicker(selection: $model.mode, modes: modes) {
                model.setView($0, visible: false)
            }
                .frame(height: controlHeight)
                .frame(maxWidth: 320)
            Button(action: addEvent) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: controlHeight, height: controlHeight)
                    .contentShape(Circle())
                    .calendarControlGlass(in: Circle(), tint: model.accentColor,
                                          interactive: !model.writableCalendars.isEmpty)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New event")
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.writableCalendars.isEmpty)
            .opacity(model.writableCalendars.isEmpty ? 0.5 : 1)
        }
    }
    #endif

    private var calendarNavigation: some View {
        #if os(macOS)
        desktopNavigation
        #else
        calendarPage(for: model.mode)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                floatingControls(controlRow, verticalPadding: 3)
                    .zIndex(1)
            }
        #endif
    }

    #if os(macOS)
    private var desktopNavigation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(desktopHeading)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                desktopDateNavigation
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            if model.mode != .week { Divider() }
            content(for: model.mode)
                .frame(maxWidth: model.mode == .day ? 760 : .infinity, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Jump to date", systemImage: "calendar") { sheet = .jump }
                    .labelStyle(.iconOnly)
                    .help("Jump to date")
                Button("New event", systemImage: "plus", action: addEvent)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.writableCalendars.isEmpty)
                    .help("New event")
            }
            ToolbarItem(placement: .principal) {
                desktopModePicker
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape", action: openSettings)
                    .labelStyle(.iconOnly)
                    .help("Settings")
                    .contextMenu {
                        ForEach(model.profiles) { profile in
                            Button(profile.name, systemImage: profile.id == model.activeProfile?.id ? "checkmark" : "person") {
                                model.switchProfile(profile.id)
                            }
                        }
                        if !model.profiles.isEmpty { Divider() }
                        Button("Open Settings", action: openSettings)
                    }
            }
        }
    }

    private var desktopModePicker: some View {
        HStack(spacing: 2) {
            ForEach(model.visibleModes) { mode in
                let selected = model.mode == mode
                Button { model.mode = mode } label: {
                    Text(mode.rawValue)
                        .font(.callout.weight(selected ? .semibold : .medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 26)
                        .background(.primary.opacity(selected ? 0.14 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    if model.visibleModes.count > 1 {
                        Button("Hide \(mode.rawValue) Tab", systemImage: "eye.slash") {
                            model.setView(mode, visible: false)
                        }
                    }
                }
            }
        }
        .padding(3)
        .calendarControlGlass(in: Capsule(), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar view")
    }

    private var desktopDateNavigation: some View {
        HStack(spacing: 6) {
            desktopDateArrow(-1, title: previousLabel, icon: "chevron.left")
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { model.selection = .now } label: {
                Text("Today").foregroundStyle(.primary).padding(.horizontal, 12).frame(height: 26)
                    .background(.primary.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Go to today")
            desktopDateArrow(1, title: nextLabel, icon: "chevron.right")
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .font(.callout.weight(.medium))
    }

    private func desktopDateArrow(_ step: Int, title: String, icon: String) -> some View {
        Button { model.advance(step) } label: {
            Image(systemName: icon)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .calendarControlGlass(in: Circle())
                .overlay(alignment: .bottom) {
                    if focusedDateArrow == step {
                        Capsule().fill(.secondary).frame(width: 9, height: 1).padding(.bottom, 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($focusedDateArrow, equals: step)
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .help(title)
    }

    private var desktopHeading: AttributedString {
        switch model.mode {
        case .day: return heading
        case .week, .month:
            var title = model.selection.formatted(.dateTime.month(.wide).year().attributed)
            for run in title.runs where run.dateField == .year {
                title[run.range].font = .largeTitle.weight(.regular)
            }
            return title
        }
    }
    #endif

    @ViewBuilder
    private func calendarPage(for mode: CalendarViewMode) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content(for: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top, spacing: 0) { floatingControls(header) }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content(for: mode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { floatingControls(header).background(.regularMaterial) }
        }
    }

    @ViewBuilder
    private func content(for mode: CalendarViewMode) -> some View {
        if model.displayedQuery == nil {
            ContentUnavailableView("Opening calendar", systemImage: "calendar")
        } else if model.snapshot.access != .full {
            permissionView
        } else if model.snapshot.calendars.isEmpty {
            ContentUnavailableView("No calendars available", systemImage: "calendar.badge.exclamationmark",
                                   description: Text("Add a calendar account in system settings, then return here."))
        } else {
            #if os(macOS)
            let handlesOwnDragging = mode != .month
            #else
            let handlesOwnDragging = mode == .day
            #endif
            if handlesOwnDragging {
                calendarCanvas(for: mode)
            } else {
                swipeNavigation(calendarCanvas(for: mode).contentShape(Rectangle()))
            }
        }
    }

    @ViewBuilder
    private func swipeNavigation<Content: View>(_ content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18, *) {
            content.gesture(CalendarPageSwipe(onEnded: { travel, _ in advanceAfterSwipe(travel) }))
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 26).onEnded { advanceAfterSwipe($0.translation) })
        }
        #else
        content.simultaneousGesture(DragGesture(minimumDistance: 26).onEnded { advanceAfterSwipe($0.translation) })
        #endif
    }

    private func advanceAfterSwipe(_ travel: CGSize) {
        guard sheet == nil, abs(travel.width) > 54,
              abs(travel.width) > 1.65 * abs(travel.height) else { return }
        model.advance(travel.width < 0 ? 1 : -1)
    }

    @ViewBuilder
    private func calendarCanvas(for mode: CalendarViewMode) -> some View {
        switch mode {
        case .day:
            #if os(macOS)
            DayView(model: model, navigationEnabled: sheet == nil, eventAction: handleEvent,
                    openTask: { sheet = .deadline($0) }, showPreviewDate: showPreviewDate,
                    addRange: addEvent(in:), editRange: editDesktopEvent, addAt: addEvent(at:))
            #else
            DayView(model: model, navigationEnabled: sheet == nil, eventAction: handleEvent,
                    openTask: { sheet = .deadline($0) }, showPreviewDate: showPreviewDate,
                    addRange: addEvent(in:), addAt: addEvent(at:))
            #endif
        case .week:
            #if os(macOS)
            DesktopWeekTimeline(model: model, navigationEnabled: sheet == nil,
                                selectDay: selectDay, eventAction: handleEvent,
                                addRange: addEvent(in:), editRange: editDesktopEvent) {
                sheet = .deadline($0)
            }
            #else
            WeekView(model: model, eventAction: handleEvent, select: selectDay) { sheet = .deadline($0) }
            #endif
        case .month:
            #if os(macOS)
            DesktopMonthGrid(model: model, select: selectDay, eventAction: handleEvent) { task in
                sheet = .deadline(task)
            }
            #else
            MonthView(model: model, select: selectDay)
            #endif
        }
    }

    private func addEvent() {
        guard sheet == nil, !model.writableCalendars.isEmpty else { return }
        sheet = .quickAdd(nil)
    }

    private func addEvent(in range: DateInterval) {
        guard sheet == nil, !model.writableCalendars.isEmpty else { return }
        sheet = .createRange(range)
    }

    private func addEvent(at slot: Date) {
        guard sheet == nil else { return }
        sheet = .quickAdd(slot)
    }

    #if os(macOS)
    private func editDesktopEvent(_ event: CalendarEvent, _ range: DateInterval) {
        guard sheet == nil, model.writableCalendars.contains(where: { $0.id == event.id.calendarID }),
              range.start != event.start || range.end != event.end else { return }
        if event.isRecurring {
            sheet = .reschedule(event, range)
            return
        }
        guard pendingTimelineEdits.insert(event.id).inserted else { return }
        var draft = event.draft
        draft.start = range.start
        draft.end = range.end
        Task {
            defer {
                pendingTimelineEdits.remove(event.id)
                model.invalidate()
            }
            do {
                try await model.store.update(event, with: draft, calendarID: event.id.calendarID, scope: .occurrence)
            } catch {
                model.message = error.localizedDescription
            }
        }
    }
    #endif

    private func showPreviewDate(_ date: Date?) {
        guard previewDay != date else { return }
        withAnimation(.easeInOut(duration: 0.12)) { previewDay = date }
    }

    private func handleEvent(_ event: CalendarEvent, action: CalendarEventAction) {
        guard sheet == nil else { return }
        switch action {
        case .open: sheet = .details(event, editing: false)
        case .edit: sheet = .details(event, editing: true)
        case .delete: sheet = .delete(event)
        }
    }
    private func selectDay(_ date: Date) {
        model.selection = date
        model.mode = .day
    }

    private var permissionView: some View {
        ContentUnavailableView {
            Label("Your calendars", systemImage: "calendar")
        } description: {
            switch model.snapshot.access {
            case .unknown, .writeOnly:
                Text("Allow full calendar access to see and edit the calendars already on this device.")
            case .denied:
                Text("Turn on full calendar access in system settings.")
            case .restricted:
                Text("Calendar access is restricted on this device.")
            case .full:
                EmptyView()
            }
        } actions: {
            switch model.snapshot.access {
            case .unknown, .writeOnly:
                Button("Allow Calendar Access") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.requesting)
            case .denied:
                Button("Open System Settings") {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    #else
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        openURL(url)
                    }
                    #endif
                }
                .buttonStyle(.bordered)
            case .restricted, .full:
                EmptyView()
            }
        }
    }
}

#if os(iOS)
private struct ProfileGearTouchSurface: UIViewRepresentable {
    let onTap: () -> Void
    let onHold: (UIGestureRecognizer.State, CGPoint) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped))
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.32
        hold.allowableMovement = 10
        hold.delegate = coordinator
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: ProfileGearTouchSurface
        private let openingFeedback = UIImpactFeedbackGenerator(style: .medium)
        private let selectionFeedback = UISelectionFeedbackGenerator()

        init(_ surface: ProfileGearTouchSurface) { self.surface = surface }

        @objc func tapped() { surface.onTap() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            openingFeedback.prepare()
            return true
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            let enteredRow = surface.onHold(recognizer.state, recognizer.location(in: recognizer.view))
            if recognizer.state == .began {
                openingFeedback.impactOccurred()
                selectionFeedback.prepare()
            } else if enteredRow {
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }
        }
    }
}

@available(iOS 18, *)
struct CalendarPageSwipe: UIGestureRecognizerRepresentable {
    var onChanged: (CGSize) -> Void = { _ in }
    var onCancelled: () -> Void = {}
    var allowsTouch: (UITouch) -> Bool = { _ in true }
    let onEnded: (CGSize, CGSize) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(allowsTouch: allowsTouch)
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allowsTouch = allowsTouch
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let movement = recognizer.translation(in: recognizer.view)
        let travel = CGSize(width: movement.x, height: movement.y)
        switch recognizer.state {
        case .began, .changed:
            onChanged(travel)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view)
            onEnded(travel, CGSize(width: movement.x + velocity.x * 0.16, height: movement.y + velocity.y * 0.16))
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsTouch: (UITouch) -> Bool

        init(allowsTouch: @escaping (UITouch) -> Bool) {
            self.allowsTouch = allowsTouch
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            allowsTouch(touch)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > 1.65 * abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer
        }
    }
}

private struct CalendarModePicker: View {
    @Binding var selection: CalendarViewMode
    let modes: [CalendarViewMode]
    let hide: (CalendarViewMode) -> Void

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var fingerX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let segmentWidth = width / CGFloat(modes.count)
            let selected = modes.firstIndex(of: selection)
            let x = fingerX.map { layoutDirection == .rightToLeft ? width - $0 : $0 }
            let position = x.map { min(width - segmentWidth, max(0, $0 - segmentWidth / 2)) }
                ?? selected.map { CGFloat($0) * segmentWidth }
            ZStack(alignment: .leading) {
                if let position {
                    Capsule()
                        .fill(.primary.opacity(0.13))
                        .frame(width: max(0, segmentWidth - 2))
                        .padding(.horizontal, 1)
                        .offset(x: layoutDirection == .rightToLeft ? -position : position)
                        .allowsHitTesting(false)
                }
                HStack(spacing: 0) {
                    ForEach(modes) { mode in
                        segment(mode)
                            .frame(width: segmentWidth)
                    }
                }
            }
            .contentShape(Capsule())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($fingerX) { value, fingerX, _ in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            fingerX = value.location.x
                        }
                    }
                    .onEnded { value in
                        guard width > 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                        let x = layoutDirection == .rightToLeft ? width - value.location.x : value.location.x
                        let index = min(modes.count - 1, max(0, Int(x / segmentWidth)))
                        selection = modes[index]
                    }
            )
            .animation(reduceMotion || fingerX != nil ? nil : .easeOut(duration: 0.16), value: position)
        }
        .padding(4)
        .calendarControlGlass(in: Capsule(), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar view")
    }

    private func segment(_ mode: CalendarViewMode) -> some View {
        Button {
            selection = mode
        } label: {
            Text(mode.rawValue)
                .font(.subheadline.weight(selection == mode ? .semibold : .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.interaction, Capsule())
                .contentShape(.contextMenuPreview, Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
        .contextMenu {
            if modes.count > 1 {
                Button("Hide \(mode.rawValue) Tab", systemImage: "eye.slash") { hide(mode) }
            }
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func calendarControlGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(tint?.opacity(0.24) ?? .clear, in: shape)
                .background(.regularMaterial, in: shape)
        }
    }
}

private struct JumpSheet: View {
    @Binding var date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var target = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Date", selection: $target, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Jump to date")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: dismiss.callAsFunction) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Go") {
                            date = target
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { target = date }
        #if os(macOS)
        .frame(width: 370, height: 410)
        #endif
    }
}
