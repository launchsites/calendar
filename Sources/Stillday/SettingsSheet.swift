import AuthenticationServices
import CalendarCore
import CalendarData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsSheet: View {
    @Bindable var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Form {
                if matches("profile switch groups shared") {
                    Section("Profiles") {
                        if !model.profiles.isEmpty {
                            ActiveProfilePicker(model: model)
                        }
                        NavigationLink { CalendarProfilesSettings(model: model) } label: {
                            Label("Manage Profiles", systemImage: "person.crop.circle")
                        }
                    }
                }
                Section {
                    if matches("appearance accent colour color theme") {
                        NavigationLink { AppearanceSettings(model: model) } label: {
                            Label("Appearance", systemImage: "paintpalette")
                        }
                    }
                    if matches("calendar display day week month layout timeline tabs tasks all-day timed format before after travel walking preparation") {
                        NavigationLink { CalendarDisplaySettings(model: model) } label: {
                            Label("Calendar Display", systemImage: "calendar")
                        }
                    }
                    if matches("connections google tasks outlook timetree accounts refresh") {
                        NavigationLink { ConnectionsSettings(model: model) } label: {
                            Label("Connections", systemImage: "link")
                        }
                    }
                    if matches("calendars visibility default categories tags") {
                        NavigationLink { CalendarsSettings(model: model) } label: {
                            Label("Calendars", systemImage: "calendar.badge.checkmark")
                        }
                    }
                    if matches("quick entry duration default mode learn suggestions title calendar history before after travel walking preparation") {
                        NavigationLink { QuickEntrySettings(model: model) } label: {
                            Label("Quick Entry", systemImage: "plus.bubble")
                        }
                    }
                    if matches("advanced aliases rules diagnostics import export density") {
                        NavigationLink { AdvancedSettingsView(model: model) } label: {
                            Label("Advanced", systemImage: "slider.horizontal.3")
                        }
                    }
                    if matches("privacy help notifications") {
                        NavigationLink { PrivacyHelpView() } label: {
                            Label("Privacy and Help", systemImage: "questionmark.circle")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .searchable(text: $search, prompt: "Find a setting")
            .navigationTitle("Settings")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inlineLarge)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: dismiss.callAsFunction) }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 650)
        #endif
    }

    private func matches(_ keywords: String) -> Bool {
        search.isEmpty || keywords.localizedStandardContains(search.trimmingCharacters(in: .whitespaces))
    }
}

#if os(macOS)
struct DesktopSettings: View {
    let model: CalendarModel
    @State private var section: Page? = .appearance
    @State private var search = ""

    private enum Page: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case display = "Calendar Display"
        case calendars = "Calendars"
        case profiles = "Profiles"
        case connections = "Connections"
        case quickEntry = "Quick Entry"
        case advanced = "Advanced"
        case help = "Privacy and Help"

        var id: Self { self }

        var icon: (symbol: String, tint: Color) {
            switch self {
            case .appearance: ("paintpalette.fill", .purple)
            case .display: ("calendar", .blue)
            case .calendars: ("calendar.badge.checkmark", .teal)
            case .profiles: ("person.crop.circle.fill", .indigo)
            case .connections: ("link", .green)
            case .quickEntry: ("bolt.fill", .orange)
            case .advanced: ("slider.horizontal.3", .gray)
            case .help: ("lock.shield.fill", .cyan)
            }
        }

        var keywords: String {
            switch self {
            case .appearance: "theme colour color accent"
            case .display: "day week month view layout timeline tabs tasks all-day timed format before after travel walking preparation"
            case .calendars: "visibility default categories tags"
            case .profiles: "switch groups shared"
            case .connections: "google tasks outlook timetree accounts refresh"
            case .quickEntry: "duration default mode learn suggestions title calendar history before after travel walking preparation"
            case .advanced: "aliases rules diagnostics import export density"
            case .help: "notifications examples"
            }
        }
    }

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pages = Page.allCases.filter { query.isEmpty || ($0.rawValue + " " + $0.keywords).localizedStandardContains(query) }
        let selected = section ?? .appearance
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a setting", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { search = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 8))
                .padding(.horizontal, 12)
                List(pages, selection: $section) { page in
                    HStack(spacing: 9) {
                        Image(systemName: page.icon.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 23, height: 23)
                            .background(page.icon.tint, in: .rect(cornerRadius: 6))
                            .accessibilityHidden(true)
                        Text(page.rawValue)
                    }
                    .padding(.vertical, 3)
                    .tag(page)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .top) {
                    if pages.isEmpty {
                        Text("No matching settings")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .frame(width: 220)
            .background(.primary.opacity(0.035))
            Divider()
            NavigationStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(selected.rawValue)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 5)
                        .accessibilityAddTraits(.isHeader)
                    settingsPage(selected)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .id(selected)
        }
        .frame(width: 760, height: 590)
    }

    @ViewBuilder
    private func settingsPage(_ page: Page) -> some View {
        switch page {
        case .appearance: AppearanceSettings(model: model)
        case .display: CalendarDisplaySettings(model: model)
        case .calendars: CalendarsSettings(model: model)
        case .profiles: CalendarProfilesSettings(model: model, showsActiveProfile: true)
        case .connections: ConnectionsSettings(model: model)
        case .quickEntry: QuickEntrySettings(model: model)
        case .advanced: AdvancedSettingsView(model: model)
        case .help: PrivacyHelpView()
        }
    }
}
#endif

private struct AppearanceSettings: View {
    @Bindable var model: CalendarModel
    @Environment(\.self) private var environment

    var body: some View {
        Form {
            ColorPicker(model.activeProfile.map { "\($0.name) accent colour" } ?? "Accent colour", selection: Binding(
                get: { model.accentColor },
                set: { model.selectedAccentColor = storedColour($0, in: environment) }
            ), supportsOpacity: false)
            if model.selectedAccentColor != nil {
                Button("Use System Accent") { model.selectedAccentColor = nil }
            }
            Picker("Appearance", selection: $model.preferences.appearance) {
                ForEach(Preferences.Appearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle("Use accent colour for task icons", isOn: $model.highlights.useAccentForTaskIcons)
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

private struct QuickEntrySettings: View {
    @Bindable var model: CalendarModel

    var body: some View {
        Form {
            Picker("Default mode", selection: $model.preferences.defaultMode) {
                ForEach(EntryMode.allCases) { Text($0.label).tag($0) }
            }
            Stepper("Default duration · \(model.preferences.defaultDuration) min",
                    value: $model.preferences.defaultDuration, in: 5...240, step: 5)
            Toggle("Suggest calendars from history", isOn: $model.calendarSuggestionsEnabled)
            Section {
                DestinationPicker(title: "Default calendar", calendars: model.writableCalendars,
                                  selected: $model.preferences.preferredCalendarID, emptyLabel: "System default")
            } footer: {
                Text("Used when you have not specified a calendar and there is no saved rule or smart suggestion.")
            }
            NavigationLink("Time Around Event") { ActivityTimingSettings(model: model) }
        }
        .formStyle(.grouped)
        .navigationTitle("Quick Entry")
    }
}

private struct CalendarsSettings: View {
    @Bindable var model: CalendarModel

    var body: some View {
        Form {
            Section {
                DestinationPicker(title: "Default calendar", calendars: model.snapshot.calendars.filter(\.choice.isWritable),
                                  selected: $model.preferences.preferredCalendarID, emptyLabel: "System default")
                NavigationLink("Event Categories") { EventCategorySettings(model: model) }
            }
            Section {
                ForEach(model.snapshot.calendars) { calendar in
                    Toggle(isOn: Binding(
                        get: { model.calendarIsVisible(calendar.id) },
                        set: { model.setCalendar(calendar.id, visible: $0) }
                    )) { CalendarName(calendar: calendar) }
                }
            } header: {
                Text(model.activeProfile?.name ?? "Calendars")
            } footer: {
                Text("Changes apply to the active view. A calendar can appear in more than one profile.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendars")
    }
}

private struct CalendarDisplaySettings: View {
    @Bindable var model: CalendarModel

    var body: some View {
        Form {
            Section("Layout and time") {
                NavigationLink("Time Around Event") { ActivityTimingSettings(model: model) }
                Picker("Day view layout", selection: Binding(
                    get: { model.preferences.timelineLayout ?? .stacked },
                    set: { model.preferences.timelineLayout = $0 }
                )) {
                    ForEach(TimelineLayout.allCases) { Text($0.label).tag($0) }
                }
                Picker("Week starts on", selection: $model.preferences.weekStart) {
                    ForEach(Preferences.WeekStart.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Time format", selection: $model.preferences.timeFormat) {
                    ForEach(Preferences.TimeFormat.allCases) { Text($0.label).tag($0) }
                }
                #if os(macOS)
                Picker("Move and resize in", selection: Binding(
                    get: { model.preferences.eventDragStep ?? .fifteen },
                    set: { model.preferences.eventDragStep = $0 }
                )) {
                    ForEach(Preferences.EventDragStep.allCases) { step in
                        Text(step.rawValue == 1 ? "1 minute" : "\(step.rawValue) minutes").tag(step)
                    }
                }
                #endif
            }
            Section {
                ForEach(CalendarViewMode.allCases) { mode in
                    let isVisible = model.visibleModes.contains(mode)
                    Toggle(mode.rawValue, isOn: Binding(
                        get: { model.visibleModes.contains(mode) },
                        set: { model.setView(mode, visible: $0) }
                    ))
                    .disabled(isVisible && model.visibleModes.count == 1)
                }
            } header: {
                Text("Calendar tabs")
            } footer: {
                Text("Keep at least one tab visible.")
            }
            Section("Google Tasks") {
                Toggle("Show in Day", isOn: $model.highlights.googleTasks.day)
                Toggle("Show in Week", isOn: $model.highlights.showTasksInWeek)
                Toggle("Show in Month", isOn: $model.highlights.googleTasks.month)
                Toggle("Show completed tasks", isOn: $model.highlights.showCompletedTasks)
            }
            Section("All-day events") {
                Toggle("Show in Day", isOn: $model.highlights.allDay.day)
                Toggle("Show in Month", isOn: $model.highlights.allDay.month)
                NavigationLink("Choose all-day calendars") { AllDayCalendarSettings(model: model) }
            }
            Section("Month") {
                Toggle("Show timed events", isOn: $model.highlights.showTimedEventsInMonth)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar Display")
    }
}

struct ActivityTimingSettings: View {
    @Bindable var model: CalendarModel

    var body: some View {
        Form {
            Section {
                defaultLink("Before", defaults: $model.preferences.beforeActivity)
                defaultLink("After", defaults: $model.preferences.afterActivity)
            } header: {
                Text("Default activities")
            } footer: {
                Text("Used when you add time before or after an event, including quick entry. Existing events keep their activity settings.")
            }
            Section {
                Toggle("Blend overlapping before/after time", isOn: Binding(
                    get: { model.preferences.blendActivityBuffers ?? false },
                    set: { model.preferences.blendActivityBuffers = $0 }
                ))
            } footer: {
                Text("The other event keeps its fill and width. Its solid stripe becomes dotted in the travel/preparation colour only during the shared time. Event overlaps still use columns.")
            }
            Section("Appearance") {
                Picker("Background", selection: $model.preferences.bufferBackground) {
                    ForEach(Preferences.ActivityBufferBackground.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tint(model.accentColor)
        .navigationTitle("Time Around Event")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func defaultLink(_ title: String, defaults: Binding<ActivityBufferDefaults>) -> some View {
        NavigationLink {
            ActivityDefaultEditor(title: title, defaults: defaults)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                let value = defaults.wrappedValue
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(value.minutes) min")
                    Text(value.kind == .travel && value.travelMode != .unspecified
                         ? "\(value.kind.rawValue) · \(value.travelMode.rawValue)" : value.kind.rawValue)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct ActivityDefaultEditor: View {
    let title: String
    @Binding var defaults: ActivityBufferDefaults

    var body: some View {
        Form {
            Section {
                Stepper("Duration · \(defaults.minutes) min", value: $defaults.minutes, in: 1...1440)
                Picker("Purpose", selection: $defaults.kind) {
                    ForEach(ActivityBufferKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if defaults.kind == .travel {
                    Picker("Travel mode", selection: $defaults.travelMode) {
                        ForEach(ActivityTravelMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            } footer: {
                Text("You can choose a different activity on individual events.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(title) activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct ActiveProfilePicker: View {
    let model: CalendarModel

    var body: some View {
        Picker("Active profile", selection: Binding(
            get: { model.activeProfile?.id }, set: { model.switchProfile($0) }
        )) {
            Text("No profile").tag(nil as UUID?)
            ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}

private struct CalendarProfilesSettings: View {
    let model: CalendarModel
    var showsActiveProfile = false

    var body: some View {
        Form {
            if showsActiveProfile && !model.profiles.isEmpty {
                Section { ActiveProfilePicker(model: model) }
            }
            Section {
                ForEach(model.profiles) { profile in
                    NavigationLink(profile.name) { CalendarProfileEditor(model: model, profile: profile) }
                }
                NavigationLink {
                    CalendarProfileEditor(model: model, profile: CalendarProfile(name: ""))
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
            } footer: {
                #if os(macOS)
                Text("Profiles group calendars and task connections already available on this device. Right-click the Settings button to switch quickly.")
                #else
                Text("Profiles group calendars and task connections already available on this device. Press and hold the Settings button to switch quickly.")
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profiles")
    }
}

private struct CalendarProfileEditor: View {
    let model: CalendarModel
    @State var profile: CalendarProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.self) private var environment
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section {
                TextField("Profile name", text: $profile.name)
                ColorPicker("Profile accent colour", selection: Binding(
                    get: { profile.accentColor.map(model.swiftUIColor) ?? .accentColor },
                    set: { profile.accentColor = storedColour($0, in: environment) }
                ), supportsOpacity: false)
                if profile.accentColor != nil {
                    Button("Use System Accent") { profile.accentColor = nil }
                }
            }
            Section("Calendars") {
                NavigationLink("Calendar Order") {
                    CalendarProfileOrderSettings(model: model, profile: $profile)
                }
                ForEach(model.snapshot.calendars) { calendar in
                    Toggle(isOn: membership(calendar.id, in: $profile.calendarIDs)) { CalendarName(calendar: calendar) }
                }
            }
            Section("Google Tasks connections") {
                ForEach(model.taskConnections) { connection in
                    Toggle(connection.name, isOn: membership(connection.id, in: $profile.taskConnectionIDs))
                }
            }
            if model.profiles.contains(where: { $0.id == profile.id }) {
                Button("Remove Profile", role: .destructive) { confirmingRemoval = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.saveProfile(profile)
                    dismiss()
                }
                .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog("Remove this profile?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Profile", role: .destructive) {
                model.removeProfile(profile.id)
                dismiss()
            }
        }
    }

    private func membership(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { included in
            if included { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
}

private struct CalendarProfileOrderSettings: View {
    let model: CalendarModel
    @Binding var profile: CalendarProfile

    var body: some View {
        let calendars = model.calendars(in: profile).filter(\.choice.isWritable)
        List {
            Section {
                ForEach(calendars) { calendar in
                    CalendarName(calendar: calendar)
                }
                .onMove { source, destination in
                    var ids = calendars.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    let included = Set(ids)
                    let others = (profile.calendarOrder ?? []).filter { !included.contains($0) }
                    profile.calendarOrder = ids + others
                }
                if calendars.isEmpty {
                    Text("Select editable calendars in this profile to arrange them here.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Drag calendars into the order you want in the event picker.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("Calendar Order")
    }
}

private struct ConnectionsSettings: View {
    let model: CalendarModel

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    GoogleTaskConnectionsSettings(model: model)
                } label: {
                    LabeledContent {
                        let count = model.taskAccounts.filter(\.isConnected).count
                        Text(count == 0 ? "Disconnected" : "\(count) connected")
                    } label: {
                        Label("Google Tasks", systemImage: "checkmark.circle")
                    }
                }
            }
            Section("Calendar accounts") {
                Text("Add Outlook and other calendar accounts in the device’s Calendar settings.")
                Text("For TimeTree, use a calendar both apps can see, or copy individual TimeTree events to an external calendar.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
    }
}

private struct GoogleTaskConnectionsSettings: View {
    let model: CalendarModel
    @State private var name = ""
    @State private var addedID: String?

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(model.taskConnections) { connection in
                    if let account = model.taskAccounts.first(where: { $0.id == connection.id }) {
                        NavigationLink {
                            GoogleTaskConnectionSettings(model: model, account: account)
                        } label: {
                            LabeledContent(connection.name, value: account.isConnected ? "Connected" : "Disconnected")
                        }
                    }
                }
            }
            Section("Add another account") {
                TextField("Account label, e.g. Personal", text: $name)
                Button("Add Google Tasks Connection", systemImage: "plus") {
                    let connection = model.addTaskConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    name = ""
                    addedID = connection.id
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Google Tasks")
        .navigationDestination(item: $addedID) { id in
            if let account = model.taskAccounts.first(where: { $0.id == id }) {
                GoogleTaskConnectionSettings(model: model, account: account)
            }
        }
    }
}

private struct GoogleTaskConnectionSettings: View {
    let model: CalendarModel
    let account: GoogleTasksAccount
    @Environment(\.webAuthenticationSession) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var connectionLabel = ""

    var body: some View {
        Form {
            Section("Status") {
                if account.isConnecting {
                    ProgressView("Signing in to Google…")
                } else if account.isRefreshing {
                    ProgressView("Refreshing Google Tasks…")
                } else if account.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(model.accentColor)
                } else {
                    Label("Disconnected", systemImage: "circle")
                }
                if let refreshed = account.lastRefreshed {
                    LabeledContent("Last refreshed", value: refreshed.formatted(date: .abbreviated, time: .standard))
                }
                if let error = account.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
            }
            Section {
                if account.client == nil {
                    Text("Google sign-in needs to be configured for this build.").foregroundStyle(.secondary)
                } else if account.isConnected {
                    Button("Refresh Google Tasks", systemImage: "arrow.clockwise") { refresh() }
                    if account.error != nil {
                        Button("Reconnect Google Tasks", systemImage: "link") { connect() }
                    }
                } else {
                    Button("Connect Google Tasks", systemImage: "link") { connect() }
                }
            }
            .disabled(account.isConnecting || account.isRefreshing)
            Section("Name") {
                TextField("Account label", text: $connectionLabel)
                Button("Save Name") {
                    model.renameTaskConnection(account.id, to: trimmedLabel)
                    connectionLabel = trimmedLabel
                }
                .disabled(trimmedLabel.isEmpty || trimmedLabel == savedLabel)
            }
            if account.isConnected || account.id != GoogleTaskConnection.primary.id {
                Button(account.id == GoogleTaskConnection.primary.id ? "Disconnect" : "Remove Connection",
                       role: .destructive) { confirmingRemoval = true }
                    .disabled(account.isConnecting)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(savedLabel)
        .onAppear { connectionLabel = savedLabel }
        .confirmationDialog("Disconnect this Google Tasks account?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                model.removeTaskConnection(account.id)
                if !model.taskConnections.contains(where: { $0.id == account.id }) { dismiss() }
            }
        }
    }

    private var savedLabel: String { model.taskConnections.first { $0.id == account.id }?.name ?? "Google Tasks" }
    private var trimmedLabel: String { connectionLabel.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func connect() {
        Task { await account.connect(using: browser) }
    }

    private func refresh() {
        let query = model.tasksQuery
        let range = query?.window ?? model.window(for: .week)
        Task { await account.load(in: range, required: query?.required ?? range,
                                  timeZone: model.calendar.timeZone, force: true) }
    }
}

private struct AllDayCalendarSettings: View {
    let model: CalendarModel

    var body: some View {
        Form {
            if model.snapshot.calendars.isEmpty {
                Text("Calendars you add to this device will appear here.").foregroundStyle(.secondary)
            }
            ForEach(model.snapshot.calendars) { calendar in
                Section {
                    Toggle("Day", isOn: visibility(for: calendar.id, \.day))
                    Toggle("Month", isOn: visibility(for: calendar.id, \.month))
                } header: {
                    CalendarName(calendar: calendar)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("All-day calendars")
    }

    private func visibility(for id: String, _ key: WritableKeyPath<CalendarHighlightOptions.Visibility, Bool>) -> Binding<Bool> {
        Binding(
            get: { (model.preferences.allDayCalendars?[id] ?? .init())[keyPath: key] },
            set: { visible in
                var calendars = model.preferences.allDayCalendars ?? [:]
                var options = calendars[id] ?? .init()
                options[keyPath: key] = visible
                calendars[id] = options
                model.preferences.allDayCalendars = calendars
            }
        )
    }
}

struct EventCategorySettings: View {
    @Bindable var model: CalendarModel
    @Environment(\.self) private var environment
    @State private var category = ""
    @State private var colour = Color.blue

    var body: some View {
        let name = EventCategory.validatedName(category)
        Form {
            Section {
                Toggle("Use event categories", isOn: $model.eventCategoriesEnabled)
            } footer: {
                Text("Colour individual events within the same calendar. The tag is saved at the end of the description so other calendar apps can read it.")
            }
            if model.eventCategoriesEnabled {
                Section("Add a category") {
                    TextField("Name, e.g. School", text: $category)
                    ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                    Button("Save category") {
                        guard let name else { return }
                        let key = EventCategory.key(name)
                        var updated = model.preferences
                        updated.categoryColours = (updated.categoryColours ?? [:])
                            .merging([key: storedColour(colour, in: environment)]) { _, new in new }
                        updated.categoryNames = (updated.categoryNames ?? [:]).merging([key: name]) { _, new in new }
                        model.preferences = updated
                        category = ""
                    }
                    .disabled(name == nil)
                }
                if !model.categoryNames.isEmpty {
                    Section("Saved categories") {
                        ForEach(model.categoryNames, id: \.self) { name in
                            HStack {
                                let key = EventCategory.key(name)
                                ColorPicker(name, selection: Binding(
                                    get: { model.categoryColor(name)?.swiftUI ?? .blue },
                                    set: { model.preferences.categoryColours?[key] = storedColour($0, in: environment) }
                                ), supportsOpacity: false)
                                Spacer()
                                Button(role: .destructive) {
                                    var updated = model.preferences
                                    updated.categoryColours?.removeValue(forKey: key)
                                    updated.categoryNames?.removeValue(forKey: key)
                                    model.preferences = updated
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(name)")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Event categories")
    }
}

private func storedColour(_ colour: Color, in environment: EnvironmentValues) -> Preferences.AccentColor {
    let resolved = colour.resolve(in: environment)
    func byte(_ component: Float) -> UInt8 {
        guard component.isFinite else { return 0 }
        return UInt8((min(max(component, 0), 1) * 255).rounded())
    }
    return .init(red: byte(resolved.red), green: byte(resolved.green), blue: byte(resolved.blue))
}

private struct PrivacyHelpView: View {
    var body: some View {
        Form {
            Section("Privacy") {
                Text("Commands are parsed on this device and events are saved to your system calendars. Calendar accounts handle their own syncing.")
                Text("Manage calendar access and accounts in system settings.")
            }
            Section("Quick entry examples") {
                Text("18:25 19:10 Sketching /Gaming")
                Text("yesterday 18:25 19:10 Gaming")
                Text("tomorrow 5pm Workshop for 45m")
                Text("23:00 01:00 Work")
                Text("every Tuesday 19:00 Boxing")
                Text("2026-11-09 all day Holiday")
                Text("18:30 Call @Europe/Lisbon")
            }
            Section("Notifications") {
                Text("Existing event alerts stay with the event. Manage alerts in the system Calendar app.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy and help")
    }
}

private struct AdvancedSettingsView: View {
    @Bindable var model: CalendarModel
    @State private var export = false
    @State private var importFile = false
    @State private var pendingSettings: Data?
    @State private var confirmImport = false
    @State private var document = SettingsDocument(data: Data())
    @State private var error: String?

    var body: some View {
        Form {
            Section("Destinations") {
                NavigationLink("Calendar aliases") { CalendarRulesView(model: model, isAlias: true) }
                NavigationLink("Title and keyword rules") { CalendarRulesView(model: model, isAlias: false) }
            }
            Section("Timeline") {
                Stepper("Hour height · \(model.preferences.pointsPerHour) pt",
                        value: $model.preferences.pointsPerHour, in: 60...120, step: 2)
                Stepper("Minimum card height · \(model.preferences.minimumEventHeight) pt",
                        value: $model.preferences.minimumEventHeight, in: 44...64, step: 2)
            }
            Section {
                Button("Export settings") {
                    do {
                        document = SettingsDocument(data: try model.preferences.exportData())
                        export = true
                    } catch { self.error = error.localizedDescription }
                }
                Button("Import settings") { importFile = true }
            } header: {
                Text("Settings file")
            } footer: {
                Text("Exports contain display and quick-entry preferences. Calendar names, mappings and events stay on this device.")
            }
            Section("Diagnostics") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                LabeledContent("Calendar access", value: accessDescription)
                LabeledContent("Calendars available", value: model.snapshot.calendars.count.formatted())
                LabeledContent("Last range fetch", value: model.snapshot.fetchMilliseconds.formatted(.number.precision(.fractionLength(1))) + " ms")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .fileExporter(isPresented: $export, document: document, contentType: .json, defaultFilename: "Calendar Settings") {
            if case .failure(let issue) = $0 { error = issue.localizedDescription }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
                let data = try Data(contentsOf: url)
                var checked = model.preferences
                try checked.importData(data)
                pendingSettings = data
                confirmImport = true
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Apply imported display and quick-entry settings?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Apply settings") {
                guard let data = pendingSettings else { return }
                defer { pendingSettings = nil }
                do {
                    var updated = model.preferences
                    try updated.importData(data)
                    model.preferences = updated
                } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { pendingSettings = nil }
        }
        .alert("Settings file", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var accessDescription: String {
        switch model.snapshot.access {
        case .unknown: "Awaiting permission"
        case .writeOnly: "Write only"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .full: "Full access"
        }
    }
}

private struct CalendarRulesView: View {
    @Bindable var model: CalendarModel
    let isAlias: Bool
    @State private var keyword = ""
    @State private var calendarID: String?

    private var rules: [String: String] { isAlias ? model.preferences.aliases : model.preferences.rules }

    var body: some View {
        Form {
            Section {
                TextField(isAlias ? "Alias" : "Title or keyword", text: $keyword)
                DestinationPicker(calendars: model.writableCalendars, selected: $calendarID)
                Button("Save rule") {
                    guard let calendarID else { return }
                    setRule(CalendarPrediction.normalize(keyword, locale: .current), calendarID)
                    keyword = ""
                }
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || calendarID == nil)
            } footer: {
                Text(isAlias
                     ? "Use an alias after / in quick entry."
                     : "Rules suggest a calendar when the event title matches a word or phrase.")
            }
            Section("Saved rules") {
                if rules.isEmpty { Text("No rules yet").foregroundStyle(.secondary) }
                ForEach(rules.keys.sorted(), id: \.self) { key in
                    HStack {
                        LabeledContent(key) {
                            if let calendar = model.snapshot.calendars.first(where: { $0.id == rules[key] }) {
                                CalendarName(calendar: calendar)
                            } else {
                                Text("Unavailable")
                            }
                        }
                        Button(role: .destructive) { setRule(key, nil) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(key)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isAlias ? "Calendar aliases" : "Calendar rules")
    }

    private func setRule(_ key: String, _ id: String?) {
        if isAlias { model.preferences.aliases[key] = id }
        else { model.preferences.rules[key] = id }
    }
}

private struct SettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
