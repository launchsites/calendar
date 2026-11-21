import Foundation

public struct CalendarProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var calendarIDs: Set<String>
    public var calendarOrder: [String]?
    public var taskConnectionIDs: Set<String>
    public var accentColor: Preferences.AccentColor?

    public init(name: String, calendarIDs: Set<String> = [], taskConnectionIDs: Set<String> = []) {
        id = UUID()
        self.name = name
        self.calendarIDs = calendarIDs
        self.taskConnectionIDs = taskConnectionIDs
    }
}

public struct GoogleTaskConnection: Codable, Equatable, Identifiable, Sendable {
    public static let primary = Self(id: "primary", name: "Google Tasks")
    public let id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: Self { self }
    }

    public struct AccentColor: Codable, Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public enum WeekStart: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, monday, sunday, saturday
        public var id: Self { self }
        public var firstWeekday: Int? {
            switch self {
            case .system: nil
            case .monday: 2
            case .sunday: 1
            case .saturday: 7
            }
        }
    }

    public enum TimeFormat: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, twelveHour, twentyFourHour
        public var id: Self { self }
        public var label: String {
            switch self {
            case .system: "System"
            case .twelveHour: "12-hour"
            case .twentyFourHour: "24-hour"
            }
        }
    }

    public enum EventDragStep: Int, Codable, CaseIterable, Identifiable, Sendable {
        case one = 1, five = 5, ten = 10, fifteen = 15, thirty = 30, fortyFive = 45, sixty = 60
        public var id: Self { self }
    }

    public enum ActivityBufferBackground: String, Codable, CaseIterable, Identifiable, Sendable {
        case event = "Same as event", lighter = "Lighter"
        public var id: Self { self }
        public var fillOpacity: Double { self == .event ? 0.19 : 0.07 }
    }

    public var appearance: Appearance = .system
    public var accentColor: AccentColor?
    public var timelineLayout: TimelineLayout?
    public var hiddenViews: Set<CalendarViewMode>?
    public var weekStart: WeekStart = .system
    public var timeFormat: TimeFormat = .system
    public var defaultMode: EntryMode = .log
    public var defaultDuration = 60
    public var preferredCalendarID: String?
    public var hiddenCalendars: Set<String> = []
    public var aliases: [String: String] = [:]
    public var rules: [String: String] = [:]
    public var pointsPerHour = 76
    public var minimumEventHeight = 44

    public var highlightOptions: CalendarHighlightOptions?
    public var allDayCalendars: [String: CalendarHighlightOptions.Visibility]?
    public var categoryColours: [String: AccentColor]?
    public var categoryNames: [String: String]?
    public var eventCategoriesEnabled: Bool?
    public var calendarSuggestionsEnabled: Bool?
    public var calendarProfiles: [CalendarProfile]?
    public var activeCalendarProfileID: UUID?
    public var googleTaskConnections: [GoogleTaskConnection]?
    public var importantEventIDs: Set<String>?
    public var monthUsesGrid: Bool?
    public var eventDragStep: EventDragStep?
    public var beforeActivityDefaults: ActivityBufferDefaults?
    public var afterActivityDefaults: ActivityBufferDefaults?
    public var activityBufferBackground: ActivityBufferBackground?
    public var blendActivityBuffers: Bool?

    public var beforeActivity: ActivityBufferDefaults {
        get { beforeActivityDefaults ?? ActivityBufferDefaults() }
        set { beforeActivityDefaults = newValue }
    }
    public var afterActivity: ActivityBufferDefaults {
        get { afterActivityDefaults ?? ActivityBufferDefaults() }
        set { afterActivityDefaults = newValue }
    }
    public var bufferBackground: ActivityBufferBackground {
        get { activityBufferBackground ?? .event }
        set { activityBufferBackground = newValue }
    }

    public init() {}

    public func exportData() throws -> Data {
        // Exports intentionally omit account-specific calendar IDs, aliases and title rules.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PortableSettings(self))
    }

    public mutating func importData(_ data: Data) throws {
        let document = try JSONDecoder().decode(PortableSettings.self, from: data)
        guard document.version == 1,
              (5...240).contains(document.defaultDuration),
              (60...120).contains(document.pointsPerHour),
              (44...64).contains(document.minimumEventHeight) else { throw SettingsImportError.invalid }
        appearance = document.appearance
        accentColor = document.accentColor
        timelineLayout = document.timelineLayout
        hiddenViews = document.hiddenViews.map(Set.init)
        highlightOptions = document.highlightOptions
        weekStart = document.weekStart
        timeFormat = document.timeFormat
        defaultMode = document.defaultMode
        defaultDuration = document.defaultDuration
        pointsPerHour = document.pointsPerHour
        minimumEventHeight = document.minimumEventHeight
        eventDragStep = document.eventDragStep
        beforeActivityDefaults = document.beforeActivityDefaults
        afterActivityDefaults = document.afterActivityDefaults
        activityBufferBackground = document.activityBufferBackground
        blendActivityBuffers = document.blendActivityBuffers
    }

    private struct PortableSettings: Codable {
        var version = 1
        let appearance: Appearance
        let accentColor: AccentColor?
        let timelineLayout: TimelineLayout?
        let hiddenViews: [CalendarViewMode]?
        let highlightOptions: CalendarHighlightOptions?
        let weekStart: WeekStart
        let timeFormat: TimeFormat
        let defaultMode: EntryMode
        let defaultDuration: Int
        let pointsPerHour: Int
        let minimumEventHeight: Int
        let eventDragStep: EventDragStep?
        let beforeActivityDefaults: ActivityBufferDefaults?
        let afterActivityDefaults: ActivityBufferDefaults?
        let activityBufferBackground: ActivityBufferBackground?
        let blendActivityBuffers: Bool?

        init(_ preferences: Preferences) {
            appearance = preferences.appearance
            accentColor = preferences.accentColor
            timelineLayout = preferences.timelineLayout
            hiddenViews = preferences.hiddenViews.map { hidden in CalendarViewMode.allCases.filter(hidden.contains) }
            highlightOptions = preferences.highlightOptions
            weekStart = preferences.weekStart
            timeFormat = preferences.timeFormat
            defaultMode = preferences.defaultMode
            defaultDuration = preferences.defaultDuration
            pointsPerHour = preferences.pointsPerHour
            minimumEventHeight = preferences.minimumEventHeight
            eventDragStep = preferences.eventDragStep
            beforeActivityDefaults = preferences.beforeActivityDefaults
            afterActivityDefaults = preferences.afterActivityDefaults
            activityBufferBackground = preferences.activityBufferBackground
            blendActivityBuffers = preferences.blendActivityBuffers
        }
    }

    private enum SettingsImportError: LocalizedError {
        case invalid
        var errorDescription: String? { "This settings file uses an unsupported version or contains invalid values." }
    }
}
