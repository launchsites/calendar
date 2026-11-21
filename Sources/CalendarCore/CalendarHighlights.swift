import Foundation

public struct CalendarHighlightOptions: Codable, Equatable, Sendable {
    public struct Visibility: Codable, Equatable, Sendable {
        public var day = true
        public var month = true

        public init() {}
    }

    public var googleTasks = Visibility()
    public var allDay = Visibility()
    public var showTimedEventsInMonth = true
    private var weekTasksVisible: Bool?
    private var completedTasksVisible: Bool?
    private var taskIconsUseAccent: Bool?
    private var taskBannerAutoScroll: Bool?

    public var autoScrollTaskBanner: Bool {
        get { taskBannerAutoScroll ?? true }
        set { taskBannerAutoScroll = newValue }
    }

    public var showTasksInWeek: Bool {
        get { weekTasksVisible ?? true }
        set { weekTasksVisible = newValue }
    }

    public var showCompletedTasks: Bool {
        get { completedTasksVisible ?? true }
        set { completedTasksVisible = newValue }
    }

    public var useAccentForTaskIcons: Bool {
        get { taskIconsUseAccent ?? true }
        set { taskIconsUseAccent = newValue }
    }

    public init() {}
}

public enum EventCategory {
    /// Categories are standalone bracketed tags on the last non-empty line of the notes.
    public static func name(in notes: String?) -> String? {
        ActivityDetails.description(in: notes).flatMap(tag(in:))?.name
    }

    public static func description(in notes: String?) -> String? {
        guard let notes = ActivityDetails.description(in: notes) else { return nil }
        guard let tag = tag(in: notes) else { return notes }
        var prefix = notes[..<tag.start]
        if prefix.last?.isNewline == true { prefix = prefix.dropLast() }
        return prefix.isEmpty ? nil : String(prefix)
    }

    public static func notes(description: String?, category: String?) -> String? {
        let details = ActivityDetails.read(from: description)
        let content = ActivityDetails.description(in: description).flatMap { $0.isEmpty ? nil : $0 }
        guard let category, let name = validatedName(category) else { return details.notes(description: content) }
        let marker = "[\(name)]"
        let result = content.map { $0 + ($0.last == "\r" ? "\r\n" : "\n") + marker } ?? marker
        return details.notes(description: result)
    }

    public static func validatedName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...48).contains(name.count), !name.contains("["), !name.contains("]"),
              !name.contains(where: \.isNewline) else { return nil }
        return name
    }

    private static func tag(in notes: String) -> (name: String, start: String.Index)? {
        guard let line = notes.split(whereSeparator: \.isNewline).last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        let marker = line.trimmingCharacters(in: .whitespaces)
        guard marker != "[End calendar details]", !marker.hasPrefix("[Calendar details "),
              marker.first == "[", marker.last == "]",
              let name = validatedName(String(marker.dropFirst().dropLast())) else { return nil }
        return (name, line.startIndex)
    }

    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
