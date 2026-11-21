import CalendarCore
import CalendarData
import SwiftUI

struct QuickAddSheet: View {
    let model: CalendarModel
    let slot: Date?
    let selectedRange: DateInterval?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var entryFocused: Bool
    @State private var input = ""
    @State private var mode: EntryMode = .log
    @State private var openedAt = Date()
    @State private var exampleVariant = Int.random(in: 0..<3)
    @State private var adjustedDraft: EventDraft?
    @State private var destinationOverride: String?
    @State private var dismissedSuggestion = false
    @State private var category: String?
    @State private var showFields = false
    @State private var manualEntry = false
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var learnRule = false
    @State private var ignoredTokens: Set<String> = []
    @State private var additionalCalendars: Set<String> = []

    init(model: CalendarModel, slot: Date?, selectedRange: DateInterval? = nil) {
        self.model = model
        self.slot = slot
        self.selectedRange = selectedRange
        _adjustedDraft = State(initialValue: selectedRange.map {
            EventDraft(title: "", start: $0.start, end: $0.end, timeZoneID: model.calendar.timeZone.identifier)
        })
    }

    private var parsed: Result<ParsedEntry, Error> {
        Result {
            try QuickEntryParser().parse(input, context: EntryContext(
                now: openedAt, calendar: model.calendar, locale: .current,
                mode: mode, defaultDuration: model.preferences.defaultDuration, selectedSlot: slot,
                ignoredTokens: ignoredTokens, beforeActivity: model.preferences.beforeActivity,
                afterActivity: model.preferences.afterActivity
            ))
        }
    }

    private var entryExample: String {
        let calendar = model.calendar
        let examples: [String]
        switch calendar.component(.hour, from: openedAt) {
        case 6..<11:
            examples = ["Breakfast /Meals", "Walk /Fitness", "Workshop /Fitness"]
        case 11..<14:
            examples = ["Lunch /Meals", "Lunch break /Work", "Walk /Fitness"]
        case 14..<17:
            examples = ["Golf /Sport", "Errands /Home", "Coffee /Social"]
        case 17..<21:
            examples = ["Dinner /Meals", "Walk /Fitness", "Catch-up /Social"]
        default:
            examples = ["Sleep /Home", "Reading /Home", "Film /Home"]
        }

        func time(_ date: Date) -> String {
            String(format: "%02d:%02d", calendar.component(.hour, from: date),
                   calendar.component(.minute, from: date))
        }

        let end = openedAt.addingTimeInterval(3600)
        return "\(time(openedAt)) \(time(end)) \(examples[exampleVariant])"
    }

    var body: some View {
        let result = parsed
        let entry = try? result.get()
        let draft = adjustedDraft ?? entry?.draft
        let resolution = destination(entry: entry, draft: draft)
        let chosen = destinationOverride ?? resolution.id

        NavigationStack {
            Form {
                if selectedRange != nil, let draft {
                    rangeFields(draft: draft, chosen: chosen, resolution: resolution)
                } else {
                    Section {
                        TextField("Quick entry", text: $input, prompt: Text(entryExample))
                            .focused($entryFocused)
                            .submitLabelForCalendar()
                        if let tokens = entry?.tokens, !tokens.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 6) {
                                    ForEach(tokens) { token in
                                        Button {
                                            ignoredTokens.insert(token.id)
                                        } label: {
                                            HStack(spacing: 5) {
                                                Text(token.label)
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 7)
                                            .background(model.accentColor.opacity(0.12), in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(model.accentColor)
                                        .accessibilityLabel("\(token.label). Use \(token.source) as title text.")
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                        if !ignoredTokens.isEmpty {
                            Button("Recognise times again") { ignoredTokens.removeAll() }
                                .font(.caption)
                        }
                        DestinationPicker(calendars: model.writableCalendars, selected: Binding(
                            get: { chosen },
                            set: {
                                destinationOverride = $0
                                dismissedSuggestion = $0 == nil
                                learnRule = false
                            }
                        ))
                        AdditionalCalendarPicker(model: model, primary: chosen, selected: $additionalCalendars)
                        if model.eventCategoriesEnabled {
                            EventCategoryPicker(model: model, selected: $category)
                        }
                        if draft != nil {
                            if destinationOverride == nil {
                                destinationNotice(resolution)
                            } else {
                                Toggle("Remember this title’s calendar", isOn: $learnRule)
                            }
                        }
                    }
                    Section {
                        Picker("Mode", selection: $mode) {
                            ForEach(EntryMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let draft {
                        Section("Preview") {
                            EventSummary(draft: draft, model: model)
                            if adjustedDraft == nil, let notice = entry?.notice {
                                Text(notice).font(.caption).foregroundStyle(.secondary)
                            }
                            if showFields {
                                DraftFields(draft: Binding(
                                    get: { adjustedDraft ?? draft },
                                    set: { adjustedDraft = $0 }
                                ), allowsRepeat: true)
                                TextField("Add a description", text: Binding(
                                    get: { ActivityDetails.description(in: adjustedDraft?.notes ?? draft.notes) ?? "" },
                                    set: { text in
                                        var adjusted = adjustedDraft ?? draft
                                        adjusted.notes = adjusted.activityDetails.notes(description: text.isEmpty ? nil : text)
                                        adjustedDraft = adjusted
                                    }
                                ), axis: .vertical)
                                .lineLimit(2...6)
                            } else {
                                Button("Adjust event") {
                                    adjustedDraft = draft
                                    showFields = true
                                    entryFocused = false
                                }
                            }
                        }
                    } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if case .failure(let issue) = result {
                            Section("Check entry") {
                                Text(issue.localizedDescription).foregroundStyle(.secondary)
                                Button("Use event form") {
                                    let start = slot ?? openedAt
                                    adjustedDraft = EventDraft(
                                        title: input,
                                        start: start,
                                        end: start.addingTimeInterval(Double(model.preferences.defaultDuration * 60)),
                                        timeZoneID: model.calendar.timeZone.identifier
                                    )
                                    manualEntry = true
                                    showFields = true
                                    entryFocused = false
                                }
                            }
                        }
                    }
                }
                if let draft, !draft.allDay {
                    Section("Time around event") {
                        ActivityFields(draft: Binding(get: { adjustedDraft ?? draft }, set: { adjustedDraft = $0 }),
                                       preferences: model.preferences, closeEditor: dismiss.callAsFunction)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            .tint(model.accentColor)
            .navigationTitle("New event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let draft, let chosen { save(draft, to: chosen) }
                    }
                    .disabled(saving || !valid(draft) || !model.writableCalendars.contains { $0.id == chosen })
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { if selectedRange == nil { mode = model.preferences.defaultMode } }
        .task {
            entryFocused = true
            await model.prepareCalendarUsage()
        }
        .onChange(of: input) {
            if input.isEmpty { ignoredTokens.removeAll() }
            resetPreview()
        }
        .onChange(of: ignoredTokens) { resetPreview() }
        .onChange(of: mode) { resetPreview() }
        .onChange(of: entry?.requestedCalendar) { _, requested in
            if requested != nil {
                destinationOverride = nil
                dismissedSuggestion = false
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 650)
        #endif
    }

    @ViewBuilder
    private func rangeFields(draft: EventDraft, chosen: String?, resolution: CalendarResolution) -> some View {
        let binding = Binding(get: { adjustedDraft ?? draft }, set: { adjustedDraft = $0 })
        Section("Event") {
            TextField("Title", text: binding.title)
                .focused($entryFocused)
            DraftDates(draft: binding)
            Picker("Repeat", selection: binding.repetition) {
                ForEach(RepeatRule.allCases) { Text($0.label).tag($0) }
            }
        }
        Section {
            DestinationPicker(calendars: model.writableCalendars, selected: Binding(
                get: { chosen }, set: {
                    destinationOverride = $0
                    dismissedSuggestion = $0 == nil
                }
            ))
            AdditionalCalendarPicker(model: model, primary: chosen, selected: $additionalCalendars)
            if destinationOverride == nil { destinationNotice(resolution) }
            if model.eventCategoriesEnabled {
                EventCategoryPicker(model: model, selected: $category)
            }
        }
        Section("Description") {
            TextField("Add a description", text: Binding(
                get: { ActivityDetails.description(in: binding.wrappedValue.notes) ?? "" },
                set: { binding.wrappedValue.notes = binding.wrappedValue.activityDetails.notes(description: $0.isEmpty ? nil : $0) }
            ), axis: .vertical)
            .lineLimit(2...6)
        }
    }

    private func resetPreview() {
        adjustedDraft = nil
        learnRule = false
        showFields = false
        manualEntry = false
        error = nil
    }

    @ViewBuilder
    private func destinationNotice(_ resolution: CalendarResolution) -> some View {
        switch resolution {
        case .choose(let explanation):
            Text(explanation).font(.caption).foregroundStyle(.secondary)
        case .selected(_, .rule):
            Text("Suggested by your calendar rules.").font(.caption).foregroundStyle(.secondary)
        case .selected(let id, .history):
            HStack {
                Label("Usually used for this title", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    dismissedSuggestion = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss \(model.writableCalendars.first { $0.id == id }?.choice.title ?? "calendar") suggestion")
            }
        default:
            EmptyView()
        }
    }

    private func destination(entry: ParsedEntry?, draft: EventDraft?) -> CalendarResolution {
        if dismissedSuggestion { return .choose("Choose a calendar for this event.") }
        let available = Set(model.writableCalendars.map(\.id))
        let preferred = model.preferences.preferredCalendarID.flatMap {
            model.activeProfile == nil || available.contains($0) ? $0 : nil
        }
        return CalendarPrediction.resolve(
            requested: manualEntry ? nil : entry?.requestedCalendar, title: draft?.title ?? "",
            calendars: model.editingCalendars.map(\.choice), aliases: model.preferences.aliases,
            rules: model.preferences.rules, preferredID: preferred,
            systemID: model.snapshot.systemDefaultID, locale: .current,
            history: model.calendarSuggestionsEnabled ? model.calendarUsage : nil
        )
    }

    private func save(_ draft: EventDraft, to calendarID: String) {
        guard !saving else { return }
        var draft = draft
        if model.eventCategoriesEnabled, let category {
            draft.notes = EventCategory.notes(description: draft.notes, category: category)
        }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                await model.prepareCalendarUsage()
                if !additionalCalendars.subtracting([calendarID]).isEmpty {
                    guard let store = model.store as? any LinkedCalendarStore else { throw CalendarStoreError.writeFailed }
                    let ids = [calendarID] + model.snapshot.calendars.map(\.id).filter(additionalCalendars.contains)
                    guard Set(ids).subtracting([calendarID]) == additionalCalendars.subtracting([calendarID])
                    else { throw CalendarStoreError.missingCalendar }
                    try await store.create(draft, calendarIDs: ids, requestID: requestID)
                } else {
                    try await model.store.create(draft, calendarID: calendarID, requestID: requestID)
                }
                model.recordCalendarChoice(title: draft.title, calendarID: calendarID)
                if learnRule {
                    let key = CalendarPrediction.normalize(draft.title, locale: .current)
                    model.preferences.rules[key] = calendarID
                }
                model.invalidate()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                model.invalidate()
            }
        }
    }
}

struct EventDetailsSheet: View {
    enum Presentation {
        case sheet
        case popover(onDelete: () -> Void)
    }

    let model: CalendarModel
    let event: CalendarEvent
    private let startsEditing: Bool
    private let presentation: Presentation
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Bool
    @State private var confirmingDeletion = false
    @State private var deleted = false
    @State private var applyToLinked = true
    @State private var draft: EventDraft
    @State private var titleEntry: String
    @State private var titleIgnoredTokens: Set<String> = []
    @State private var titleOpenedAt = Date()
    @State private var titleIsLiteral = false
    @State private var description: String
    @State private var category: String?
    @State private var destination: String?
    @State private var scope: MutationScope = .occurrence
    @State private var working = false
    @State private var error: String?
    #if os(macOS)
    @FocusState private var inspectorTitleFocused: Bool
    #endif

    init(model: CalendarModel, event: CalendarEvent, editing: Bool = false,
         presentation: Presentation = .sheet, initialRange: DateInterval? = nil) {
        self.model = model
        self.event = event
        self.presentation = presentation
        startsEditing = editing
        _editing = State(initialValue: editing)
        var initialDraft = event.draft
        if let initialRange {
            initialDraft.start = initialRange.start
            initialDraft.end = initialRange.end
        }
        _draft = State(initialValue: initialDraft)
        _titleEntry = State(initialValue: initialDraft.title)
        let category = Self.category(for: event, model: model)
        _description = State(initialValue: Self.description(for: event, category: category) ?? "")
        _category = State(initialValue: category)
        _destination = State(initialValue: event.id.calendarID)
    }

    var body: some View {
        #if os(macOS)
        switch presentation {
        case .sheet: sheetContent
        case .popover(let onDelete): popoverContent(onDelete: onDelete)
        }
        #else
        sheetContent
        #endif
    }

    private var sheetContent: some View {
        NavigationStack {
            Form {
                if editing {
                    Section("Event") {
                        TextField("Title", text: $titleEntry)
                        titleEntryPreview
                        DraftDates(draft: $draft)
                    }
                    if event.activityDetails.link != nil {
                        Section("Linked activity") {
                            linkedDetails
                            Toggle("Update linked copies", isOn: $applyToLinked)
                            if !applyToLinked {
                                Text("Saving separates this copy from the linked activity.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if event.isRecurring { CalendarName(calendar: event.calendar) }
                        else { DestinationPicker(calendars: model.writableCalendars, selected: $destination) }
                    }
                    Section("Description") {
                        TextField("Add a description", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                    }
                    if !draft.allDay {
                        Section("Time around event") { ActivityFields(draft: $draft, preferences: model.preferences, closeEditor: dismiss.callAsFunction) }
                    }
                    if model.eventCategoriesEnabled {
                        Section { EventCategoryPicker(model: model, selected: $category) }
                    }
                    if event.isRecurring {
                        Picker("Apply changes to", selection: $scope) {
                            ForEach(MutationScope.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                } else {
                    Section {
                        EventSummary(draft: event.draft, model: model)
                        CalendarName(calendar: event.calendar)
                        if event.activityDetails.link != nil { linkedDetails }
                        ActivityDetailsSummary(details: event.activityDetails)
                    }
                    Section("Description") {
                        if let notes = eventDescription,
                           !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(notes).textSelection(.enabled)
                        } else {
                            Text("No description").foregroundStyle(.secondary)
                        }
                    }
                    if model.eventCategoriesEnabled, let name = eventCategory {
                        Section {
                            LabeledContent("Category") { EventCategoryLabel(model: model, name: name) }
                        }
                    }
                    if event.isRecurring || !isWritable {
                        Section {
                            if event.isRecurring { Label("Repeating event", systemImage: "repeat") }
                            if !isWritable { Label("Read-only calendar", systemImage: "lock") }
                        }
                    }
                    Button(model.isImportant(event) ? "Remove from Month Highlights" : "Mark Important",
                           systemImage: model.isImportant(event) ? "star.slash" : "star") {
                        model.toggleImportance(event)
                    }
                    if isWritable {
                        Button("Delete Event", role: .destructive) { confirmingDeletion = true }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            .tint(model.accentColor)
            .navigationTitle(editing ? "Edit event" : "Event details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "Cancel" : "Done") {
                        if editing && !startsEditing {
                            draft = event.draft
                            titleEntry = event.title
                            titleIgnoredTokens = []
                            titleIsLiteral = false
                            description = eventDescription ?? ""
                            category = eventCategory
                            destination = event.id.calendarID
                            scope = .occurrence
                            error = nil
                            editing = false
                        } else { dismiss() }
                    }
                    .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("Save", action: update)
                            .disabled(!canSave)
                    } else if isWritable {
                        Button("Edit") {
                            editing = true
                            error = nil
                        }
                        .disabled(working)
                    }
                }
            }
        }
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $confirmingDeletion, onDismiss: { if deleted { dismiss() } }) {
            EventDeletionSheet(model: model, event: event) { deleted = true }
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #endif
    }

    #if os(macOS)
    private func popoverContent(onDelete: @escaping () -> Void) -> some View {
        let chosenCalendar = model.writableCalendars.first { $0.id == effectiveDestination } ?? event.calendar
        let color = chosenCalendar.id == event.calendar.id ? model.eventColor(event) : chosenCalendar.color
        let hasChanges = editedDraft != event.draft || effectiveDestination != event.id.calendarID
            || titleEntry != draft.title
            || (!applyToLinked && event.activityDetails.link != nil)
        return VStack(alignment: .leading, spacing: 9) {
            VStack(spacing: 7) {
                inspectorRow {
                    if isWritable {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Title", text: $titleEntry)
                                .textFieldStyle(.plain)
                                .focused($inspectorTitleFocused)
                                .onSubmit(applyTitleEntry)
                            titleEntryPreview
                        }
                    } else {
                        Text(event.displayTitle)
                    }
                }
                .font(.title3.weight(.semibold))

                inspectorRow {
                    if isWritable {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) { DraftDates(draft: $draft) }
                                .padding(.top, 8)
                        } label: {
                            EventSummary(draft: draft, model: model, showsTitle: false)
                        }
                    } else {
                        EventSummary(draft: draft, model: model, showsTitle: false)
                    }
                }
            }
            .padding(.leading, 9)
            .overlay(alignment: .leading) { Capsule().fill(color.swiftUI).frame(width: 3) }

            inspectorRow {
                if isWritable && !event.isRecurring {
                    HStack(spacing: 7) {
                        CalendarSwatch(color: chosenCalendar.color)
                        Menu {
                            Picker("Calendar", selection: $destination) {
                                ForEach(model.writableCalendars) { calendar in
                                    Text(calendar.choice.qualifiedTitle).tag(Optional(calendar.id))
                                }
                            }
                        } label: {
                            Text(chosenCalendar.choice.qualifiedTitle).lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Calendar, \(chosenCalendar.choice.qualifiedTitle)")
                    }
                } else {
                    CalendarName(calendar: chosenCalendar)
                }
            }

            inspectorRow {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Description").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if isWritable {
                        TextField("Add a description", text: $description, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...7)
                            .accessibilityLabel("Description")
                    } else if description.isEmpty {
                        Text("No description").foregroundStyle(.secondary)
                    } else {
                        ViewThatFits(in: .vertical) {
                            Text(description).fixedSize(horizontal: false, vertical: true)
                            ScrollView { Text(description).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        .textSelection(.enabled)
                        .frame(maxHeight: 150, alignment: .topLeading)
                    }
                }
            }

            if isWritable && !draft.allDay {
                inspectorRow {
                    DisclosureGroup("Activity options") {
                        ActivityFields(draft: $draft, preferences: model.preferences, closeEditor: dismiss.callAsFunction).padding(.top, 8)
                    }
                }
            } else {
                ActivityDetailsSummary(details: event.activityDetails)
            }
            if event.activityDetails.link != nil {
                inspectorRow {
                    VStack(alignment: .leading, spacing: 7) {
                        linkedDetails
                        if isWritable { Toggle("Update linked copies", isOn: $applyToLinked) }
                    }
                }
            }
            if model.eventCategoriesEnabled && isWritable {
                inspectorRow { EventCategoryPicker(model: model, selected: $category) }
            } else if let category {
                inspectorRow { EventCategoryLabel(model: model, name: category) }
            }
            if event.isRecurring && isWritable && hasChanges {
                Picker("Apply changes to", selection: $scope) {
                    ForEach(MutationScope.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    model.toggleImportance(event)
                } label: {
                    Image(systemName: model.isImportant(event) ? "star.fill" : "star")
                }
                .help(model.isImportant(event) ? "Remove from Month Highlights" : "Mark Important")
                .accessibilityLabel(model.isImportant(event) ? "Remove from Month Highlights" : "Mark Important")
                if isWritable {
                    Button("Delete Event", systemImage: "trash", role: .destructive, action: onDelete)
                        .labelStyle(.iconOnly)
                        .help("Delete Event")
                        .disabled(hasChanges)
                }
                Spacer()
                if hasChanges {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: update)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSave)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.top, 3)
        }
        .padding(12)
        .frame(width: 350)
        .disabled(working)
        .defaultFocus($inspectorTitleFocused, isWritable, priority: .userInitiated)
        .task {
            // A popover's native disclosure button can claim initial focus before SwiftUI's
            // default focus runs. Request the title after the presentation is attached.
            await Task.yield()
            if isWritable { inspectorTitleFocused = true }
        }
        .interactiveDismissDisabled(hasChanges || working)
    }

    private func inspectorRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.065), in: .rect(cornerRadius: 9))
    }
    #endif

    private var isWritable: Bool { model.writableCalendars.contains { $0.id == event.id.calendarID } }
    private var eventCategory: String? { Self.category(for: event, model: model) }
    private var eventDescription: String? { Self.description(for: event, category: eventCategory) }

    private static func category(for event: CalendarEvent, model: CalendarModel) -> String? {
        guard let name = EventCategory.name(in: event.notes),
              model.eventCategoriesEnabled || model.categoryColor(name) != nil else { return nil }
        return name
    }

    private static func description(for event: CalendarEvent, category: String?) -> String? {
        category == nil ? ActivityDetails.description(in: event.notes) : EventCategory.description(in: event.notes)
    }

    private var linkedDetails: some View {
        Label(event.activityDetails.link?.calendars.joined(separator: " • ") ?? "", systemImage: "link")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var titleResult: Result<ParsedEntry, Error>? {
        guard !titleIsLiteral, titleEntry != draft.title else { return nil }
        return Result {
            try QuickEntryParser().parseEdit(titleEntry, original: draft, context: EntryContext(
                now: titleOpenedAt, calendar: model.calendar, locale: .current, mode: .log,
                defaultDuration: model.preferences.defaultDuration, ignoredTokens: titleIgnoredTokens,
                beforeActivity: model.preferences.beforeActivity, afterActivity: model.preferences.afterActivity))
        }
    }

    private var titleInterpretation: ParsedEntry? {
        guard case .success(let parsed) = titleResult else { return nil }
        return parsed
    }

    private var titleEntryIssue: String? {
        guard case .failure(let error) = titleResult else { return nil }
        return error.localizedDescription
    }

    private var titleCalendar: CalendarResolution? {
        guard let requested = titleInterpretation?.requestedCalendar else { return nil }
        return CalendarPrediction.resolve(requested: requested, title: "", calendars: model.writableCalendars.map(\.choice),
            aliases: model.preferences.aliases, rules: [:], preferredID: nil, systemID: nil, locale: .current)
    }

    private var titleCalendarIssue: String? {
        if case .choose(let message) = titleCalendar { return message }
        return nil
    }

    private var effectiveDestination: String? { titleCalendar?.id ?? destination }

    @ViewBuilder private var titleEntryPreview: some View {
        if titleIsLiteral {
            Button("Interpret title as quick entry") { titleIsLiteral = false }.font(.caption)
        } else if let issue = titleEntryIssue ?? titleCalendarIssue {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue).foregroundStyle(.secondary)
                Button("Keep as title only") { titleIsLiteral = true }
            }
            .font(.caption)
        } else if let parsed = titleInterpretation, !parsed.fields.isEmpty || parsed.requestedCalendar != nil {
            VStack(alignment: .leading, spacing: 8) {
                EventSummary(draft: parsed.draft, model: model)
                if parsed.requestedCalendar != nil,
                   let calendar = model.writableCalendars.first(where: { $0.id == effectiveDestination }) {
                    CalendarName(calendar: calendar)
                }
                if !parsed.tokens.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(parsed.tokens) { token in
                                Button {
                                    titleIgnoredTokens.insert(token.id)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(token.label)
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(model.accentColor.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain).foregroundStyle(model.accentColor)
                                .accessibilityLabel("\(token.label). Use \(token.source) as title text.")
                            }
                        }
                    }
                }
                HStack {
                    Button("Apply to event", action: applyTitleEntry)
                    Button("Keep as title only") { titleIsLiteral = true }
                }
            }
            .font(.caption)
        }
    }

    private func applyTitleEntry() {
        guard let parsed = titleInterpretation, titleCalendarIssue == nil else { return }
        if let id = titleCalendar?.id { destination = id }
        draft = parsed.draft
        titleEntry = parsed.draft.title
        titleIgnoredTokens = []
    }

    private var editedDraft: EventDraft {
        var draft = titleInterpretation?.draft ?? draft
        if titleIsLiteral { draft.title = titleEntry }
        let content = EventCategory.notes(description: description.isEmpty ? nil : description, category: category)
        draft.notes = draft.activityDetails.notes(description: content)
        return draft
    }

    private var canSave: Bool {
        isWritable && !working && titleEntryIssue == nil && titleCalendarIssue == nil
            && valid(editedDraft, preservingTitle: event.title)
            && model.writableCalendars.contains { $0.id == effectiveDestination }
    }

    private func update() {
        guard canSave, let destination = effectiveDestination else { return }
        let draft = editedDraft
        mutate {
            if event.activityDetails.link != nil, let store = model.store as? any LinkedCalendarStore {
                try await store.updateLinked(event, with: draft, calendarID: destination,
                                             scope: scope, allCopies: applyToLinked)
            } else {
                try await model.store.update(event, with: draft, calendarID: destination, scope: scope)
            }
        }
    }

    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await operation()
                model.invalidate()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                model.invalidate()
            }
        }
    }
}

private struct EventCategoryPicker: View {
    let model: CalendarModel
    @Binding var selected: String?

    var body: some View {
        let names = model.categoryNames
        let canonical = selected.flatMap { current in
            names.first { EventCategory.key($0) == EventCategory.key(current) }
        }
        if names.isEmpty && selected == nil {
            NavigationLink("Set up event categories") { EventCategorySettings(model: model) }
        } else {
            Picker("Category", selection: Binding(get: { canonical ?? selected }, set: { selected = $0 })) {
                Text("None").tag(nil as String?)
                ForEach(names, id: \.self) { name in
                    EventCategoryLabel(model: model, name: name).tag(Optional(name))
                }
                if let selected, canonical == nil {
                    EventCategoryLabel(model: model, name: selected).tag(Optional(selected))
                }
            }
        }
    }
}

private struct EventCategoryLabel: View {
    let model: CalendarModel
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            if let colour = model.categoryColor(name) { CalendarSwatch(color: colour) }
            Text(name)
        }
    }
}

struct EventDeletionSheet: View {
    let model: CalendarModel
    let event: CalendarEvent
    var onDeleted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EventSummary(draft: event.draft, model: model)
                }
                Section {
                    if event.activityDetails.link != nil {
                        Button("Delete Linked Activity", role: .destructive) { remove(.occurrence, allCopies: true) }
                        Button("Remove from \(event.calendar.choice.title) Only", role: .destructive) {
                            remove(.occurrence, allCopies: false)
                        }
                        if event.isRecurring {
                            Button("Delete All Future Linked Occurrences", role: .destructive) { remove(.future, allCopies: true) }
                        }
                    } else {
                        Button(event.isRecurring ? "Delete This Occurrence" : "Delete Event", role: .destructive) {
                            remove(.occurrence)
                        }
                        if event.isRecurring {
                            Button("Delete This and Future Events", role: .destructive) { remove(.future) }
                        }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            .navigationTitle("Delete event?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(working)
                }
            }
        }
        .interactiveDismissDisabled(working)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 440, height: 310)
        #endif
    }

    private func remove(_ scope: MutationScope, allCopies: Bool = true) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                if event.activityDetails.link != nil, let store = model.store as? any LinkedCalendarStore {
                    try await store.deleteLinked(event, scope: scope, allCopies: allCopies)
                } else {
                    try await model.store.delete(event, scope: scope)
                }
                model.invalidate()
                onDeleted()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                model.invalidate()
            }
        }
    }
}

private struct EventSummary: View {
    let draft: EventDraft
    let model: CalendarModel
    var showsTitle = true

    var body: some View {
        let zone = draft.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? model.calendar.timeZone
        var calendar = model.calendar
        let _ = calendar.timeZone = zone
        let inclusiveEnd = draft.allDay ? draft.end.addingTimeInterval(-1) : draft.end

        VStack(alignment: .leading, spacing: 6) {
            if showsTitle { Text(draft.title.isEmpty ? "Untitled event" : draft.title).font(.headline) }
            Text(summary(start: draft.start, end: inclusiveEnd, calendar: calendar))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !draft.allDay && zone != model.calendar.timeZone {
                Text(zone.identifier).font(.caption).foregroundStyle(.secondary)
            }
            if draft.repetition == .weekly {
                Label("Repeats weekly", systemImage: "repeat").font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(start: Date, end: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        let first = start.formatted(style)
        let last = end.formatted(style)
        let sameDay = calendar.isDate(start, inSameDayAs: end)
        if draft.allDay { return sameDay ? "\(first) · All day" : "\(first) – \(last) · All day" }
        let from = model.time(start, zone: calendar.timeZone)
        let to = model.time(end, zone: calendar.timeZone)
        return sameDay ? "\(first) · \(from)–\(to)" : "\(first) \(from) → \(last) \(to)"
    }
}

private struct DraftFields: View {
    @Binding var draft: EventDraft
    let allowsRepeat: Bool

    var body: some View {
        TextField("Title", text: $draft.title)
        DraftDates(draft: $draft)
        if allowsRepeat {
            Picker("Repeat", selection: $draft.repetition) {
                ForEach(RepeatRule.allCases) { Text($0.label).tag($0) }
            }
        }
    }
}

private struct DraftDates: View {
    @Binding var draft: EventDraft
    @Environment(\.calendar) private var deviceCalendar
    @Environment(\.timeZone) private var deviceZone

    var body: some View {
        Toggle("All day", isOn: Binding(get: { draft.allDay }, set: { value in changeAllDay(value) }))
        DatePicker("Starts", selection: Binding(
            get: { draft.start },
            set: { draft.start = draft.allDay ? deviceCalendar.startOfDay(for: $0) : $0 }
        ), displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
            .environment(\.timeZone, zone)
        DatePicker(draft.allDay ? "Through" : "Ends", selection: Binding(
            get: { draft.allDay ? draft.end.addingTimeInterval(-1) : draft.end },
            set: { date in
                if draft.allDay {
                    let day = deviceCalendar.startOfDay(for: date)
                    draft.end = deviceCalendar.date(byAdding: .day, value: 1, to: day) ?? date
                } else { draft.end = date }
            }
        ), displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
        .environment(\.timeZone, zone)
        if draft.end <= draft.start {
            Text("End must be after the start.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var zone: TimeZone { draft.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? deviceZone }

    private func changeAllDay(_ allDay: Bool) {
        draft.allDay = allDay
        if allDay {
            draft.start = deviceCalendar.startOfDay(for: draft.start)
            let endDay = deviceCalendar.startOfDay(for: max(draft.start, draft.end.addingTimeInterval(-1)))
            draft.end = deviceCalendar.date(byAdding: .day, value: 1, to: endDay) ?? draft.end
            draft.timeZoneID = nil
        } else {
            draft.start = deviceCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: draft.start) ?? draft.start
            draft.end = draft.start.addingTimeInterval(3600)
            draft.timeZoneID = deviceZone.identifier
        }
    }
}

struct DestinationPicker: View {
    var title = "Calendar"
    let calendars: [CalendarListItem]
    @Binding var selected: String?
    var emptyLabel = "Choose a calendar"

    var body: some View {
        NavigationLink {
            DestinationOptions(title: title, calendars: calendars, selected: $selected, emptyLabel: emptyLabel)
        } label: {
            LabeledContent {
                if let calendar = calendars.first(where: { $0.id == selected }) {
                    CalendarName(calendar: calendar)
                } else {
                    Text(selected == nil ? emptyLabel : "Calendar unavailable")
                }
            } label: {
                Text(title)
            }
        }
    }
}

private struct DestinationOptions: View {
    let title: String
    let calendars: [CalendarListItem]
    @Binding var selected: String?
    let emptyLabel: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        if calendars.count >= 8 {
            choices.searchable(text: $search, prompt: "Find a calendar")
        } else {
            choices
        }
    }

    private var choices: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? calendars : calendars.filter {
            $0.choice.qualifiedTitle.localizedStandardContains(query)
        }
        return List {
            if query.isEmpty { option(nil) { Text(emptyLabel) } }
            ForEach(matches) { calendar in
                option(calendar.id) { CalendarName(calendar: calendar) }
            }
            if matches.isEmpty && !query.isEmpty {
                Text("No matching calendars").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
    }

    private func option<Label: View>(_ id: String?, @ViewBuilder label: () -> Label) -> some View {
        Button {
            selected = id
            dismiss()
        } label: {
            HStack {
                label()
                Spacer()
                if selected == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == id ? .isSelected : [])
    }
}

private func valid(_ draft: EventDraft?, preservingTitle: String? = nil) -> Bool {
    guard let draft else { return false }
    return draft.end > draft.start
        && (draft.title == preservingTitle || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

private extension View {
    @ViewBuilder
    func submitLabelForCalendar() -> some View {
        #if os(iOS)
        self.submitLabel(.done)
        #else
        self
        #endif
    }
}

struct ActivityFields: View {
    @Binding var draft: EventDraft
    let preferences: Preferences
    var closeEditor: (() -> Void)? = nil

    private var details: Binding<ActivityDetails> {
        Binding(get: { draft.activityDetails }, set: { draft.activityDetails = $0 })
    }

    var body: some View {
        #if os(iOS)
        bufferLink("Before", value: details.before, defaults: preferences.beforeActivity)
        bufferLink("After", value: details.after, defaults: preferences.afterActivity)
        #else
        VStack(alignment: .leading, spacing: 14) {
            macBuffer("Before", value: details.before, defaults: preferences.beforeActivity)
            Divider()
            macBuffer("After", value: details.after, defaults: preferences.afterActivity)
        }
        #endif
    }

    private func bufferLink(_ title: String, value: Binding<ActivityBuffer?>, defaults: ActivityBufferDefaults) -> some View {
        NavigationLink {
            ActivityBufferEditor(title: title, value: value, defaults: defaults, closeEditor: closeEditor)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                if let buffer = value.wrappedValue {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(buffer.minutes) min")
                        Text(buffer.title).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func macBuffer(_ title: String, value: Binding<ActivityBuffer?>, defaults: ActivityBufferDefaults) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Time \(title.lowercased())", isOn: ActivityBufferEditor.enabled(value, defaults: defaults))
            ActivityBufferControls(value: value)
        }
    }
}

struct ActivityBufferEditor: View {
    let title: String
    @Binding var value: ActivityBuffer?
    var defaults: ActivityBufferDefaults = .init()
    var closeEditor: (() -> Void)? = nil

    static func enabled(_ value: Binding<ActivityBuffer?>, defaults: ActivityBufferDefaults = .init()) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { enabled in
            if enabled, value.wrappedValue == nil { value.wrappedValue = defaults.buffer() }
            if !enabled { value.wrappedValue = nil }
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Add time \(title.lowercased())", isOn: Self.enabled($value, defaults: defaults))
            } footer: {
                Text("The event keeps its start and end. This extra time appears \(title.lowercased()) it in your timeline.")
            }
            if value != nil {
                Section("Duration and purpose") { ActivityBufferControls(value: $value) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(title) event")
        .toolbar {
            if let closeEditor {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close event editor", systemImage: "xmark", action: closeEditor)
                        .labelStyle(.iconOnly)
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct ActivityBufferControls: View {
    @Binding var value: ActivityBuffer?

    var body: some View {
        if let current = value {
            let binding = Binding(get: { value ?? current }, set: { value = $0 })
            Stepper(value: binding.minutes, in: 1...1440) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duration")
                    Text("\(current.minutes) min").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            Picker("Purpose", selection: binding.kind) {
                ForEach(ActivityBufferKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            if current.kind == .travel {
                Picker("Travel mode", selection: binding.travelMode) {
                    ForEach(ActivityTravelMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }
            TextField("Label (optional)", text: binding.label)
                .accessibilityLabel("Custom label")
        }
    }
}

private struct ActivityDetailsSummary: View {
    let details: ActivityDetails
    var body: some View {
        if let before = details.before {
            Label("\(before.title) · \(before.minutes) min before", systemImage: before.symbol)
                .font(.caption).foregroundStyle(.secondary)
        }
        if let after = details.after {
            Label("\(after.title) · \(after.minutes) min after", systemImage: after.symbol)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AdditionalCalendarPicker: View {
    let model: CalendarModel
    let primary: String?
    @Binding var selected: Set<String>

    var body: some View {
        NavigationLink {
            AdditionalCalendarOptions(model: model, primary: primary, selected: $selected)
        } label: {
            LabeledContent("Also add to", value: selected.subtracting(primary.map { [$0] } ?? []).isEmpty
                               ? "None" : "\(selected.subtracting(primary.map { [$0] } ?? []).count) calendars")
        }
    }
}

private struct AdditionalCalendarOptions: View {
    let model: CalendarModel
    let primary: String?
    @Binding var selected: Set<String>
    @State private var search = ""

    var body: some View {
        let profileIDs = Set(model.editingCalendars.map(\.id))
        let available = model.editingCalendars + model.snapshot.calendars.filter { !profileIDs.contains($0.id) }
        let calendars = available.filter {
            $0.choice.isWritable && $0.id != primary
                && (search.isEmpty || $0.choice.qualifiedTitle.localizedStandardContains(search))
        }
        List {
            Section {
                ForEach(calendars) { calendar in
                    Toggle(isOn: Binding(get: { selected.contains(calendar.id) }, set: {
                        if $0 { selected.insert(calendar.id) } else { selected.remove(calendar.id) }
                    })) { CalendarName(calendar: calendar) }
                }
            } footer: {
                Text("Creates a linked event in each selected calendar. Updates apply to the linked activity unless you choose to separate a copy.")
            }
        }
        .searchable(text: $search, prompt: "Find a calendar")
        .navigationTitle("Linked Calendars")
    }
}
