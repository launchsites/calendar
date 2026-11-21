import Foundation

// Retained solely to round-trip display metadata written by older builds.
// All timed events now use ordinary event cards.
public enum ActivityDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Calendar default"
    case activity = "Activity"
    case background = "Background period"
    public var id: Self { self }
}

public enum ActivityBufferKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case travel = "Travel"
    case preparation = "Preparation"
    case setup = "Setup"
    case cleanup = "Cleanup"
    case recovery = "Recovery"
    case custom = "Custom"
    public var id: Self { self }
    public var symbol: String {
        switch self {
        case .travel: "figure.walk"
        case .preparation: "checklist"
        case .setup: "wrench.and.screwdriver"
        case .cleanup: "sparkles"
        case .recovery: "leaf"
        case .custom: "clock"
        }
    }
}

public enum ActivityTravelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case unspecified = "Unspecified"
    case walking = "Walking"
    case driving = "Driving"
    case train = "Train"
    case bus = "Bus"
    case cycling = "Cycling"
    case flight = "Flight"
    public var id: Self { self }
    public var symbol: String {
        switch self {
        case .unspecified: "map"
        case .walking: "figure.walk"
        case .driving: "car"
        case .train: "tram"
        case .bus: "bus"
        case .cycling: "bicycle"
        case .flight: "airplane"
        }
    }
}

public struct ActivityBuffer: Codable, Equatable, Sendable {
    public var minutes: Int
    public var kind: ActivityBufferKind
    public var label: String
    public var travelMode: ActivityTravelMode
    public init(minutes: Int = 10, kind: ActivityBufferKind = .preparation, label: String = "",
                travelMode: ActivityTravelMode = .unspecified) {
        self.minutes = minutes
        self.kind = kind
        self.label = label
        self.travelMode = travelMode
    }
    public var symbol: String { kind == .travel ? travelMode.symbol : kind.symbol }
    public var title: String { label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.rawValue : label }
}

public struct ActivityBufferDefaults: Codable, Equatable, Sendable {
    public var minutes: Int
    public var kind: ActivityBufferKind
    public var travelMode: ActivityTravelMode

    public init(minutes: Int = 5, kind: ActivityBufferKind = .travel, travelMode: ActivityTravelMode = .walking) {
        self.minutes = minutes
        self.kind = kind
        self.travelMode = travelMode
    }

    public func buffer(minutes: Int? = nil) -> ActivityBuffer {
        ActivityBuffer(minutes: minutes ?? self.minutes, kind: kind, travelMode: travelMode)
    }

    private enum CodingKeys: String, CodingKey { case minutes, kind, travelMode }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minutes = try values.decodeIfPresent(Int.self, forKey: .minutes) ?? 5
        guard (1...1440).contains(minutes) else {
            throw DecodingError.dataCorruptedError(forKey: .minutes, in: values, debugDescription: "Duration must be from 1 to 1440 minutes.")
        }
        kind = try values.decode(ActivityBufferKind.self, forKey: .kind)
        travelMode = try values.decode(ActivityTravelMode.self, forKey: .travelMode)
    }
}

public struct ActivityLink: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var calendars: [String]
    public var copyCount: Int
    public init(id: UUID, title: String, calendars: [String]) {
        self.id = id
        self.title = title
        self.calendars = calendars
        copyCount = calendars.count
    }
}

/// A readable, explicitly delimited footer. Other bracketed notes remain ordinary text.
public struct ActivityDetails: Codable, Equatable, Sendable {
    public var before: ActivityBuffer?
    public var after: ActivityBuffer?
    public var display: ActivityDisplay = .automatic
    public var link: ActivityLink?
    public var unknownLines: [String] = []
    public init() {}
    private static let opening = "[Calendar details v1]"
    private static let closing = "[End calendar details]"

    public static func read(from notes: String?) -> ActivityDetails { split(notes).details }
    public static func description(in notes: String?) -> String? { split(notes).description }

    public func notes(description: String?) -> String? {
        var lines: [String] = []
        if let before { lines += Self.bufferLines(before, key: "Before") }
        if let after { lines += Self.bufferLines(after, key: "After") }
        if display != .automatic { lines.append("[Display: \(display.rawValue)]") }
        if let link {
            lines.append("[Linked activity: \(Self.clean(link.title))]")
            lines += link.calendars.enumerated().map { "[Calendar \($0.offset + 1): \(Self.clean($0.element))]" }
            lines += ["[Linked copies: \(link.copyCount)]", "[Link ID: \(link.id.uuidString)]"]
        }
        lines += unknownLines
        guard !lines.isEmpty else { return description.flatMap { $0.isEmpty ? nil : $0 } }
        let block = ([Self.opening] + lines + [Self.closing]).joined(separator: "\n")
        guard let description, !description.isEmpty else { return block }
        return description + "\n\n" + block
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private static func bufferLines(_ buffer: ActivityBuffer, key: String) -> [String] {
        var lines = ["[\(key): \(buffer.minutes) minutes]", "[\(key) purpose: \(buffer.kind.rawValue)]"]
        if buffer.kind == .travel && buffer.travelMode != .unspecified {
            lines.append("[\(key) travel: \(buffer.travelMode.rawValue)]")
        }
        if !buffer.label.isEmpty { lines.append("[\(key) label: \(clean(buffer.label))]") }
        return lines
    }

    private static func buffer(_ key: String, values: inout [String: String]) -> ActivityBuffer? {
        guard let value = values.removeValue(forKey: key),
              let first = value.split(separator: " ").first,
              let minutes = Int(first), (1...1440).contains(minutes),
              let kind = ActivityBufferKind(rawValue: values.removeValue(forKey: key + " purpose") ?? ActivityBufferKind.preparation.rawValue),
              let mode = ActivityTravelMode(rawValue: values.removeValue(forKey: key + " travel") ?? ActivityTravelMode.unspecified.rawValue)
        else { return nil }
        return ActivityBuffer(minutes: minutes, kind: kind,
                              label: values.removeValue(forKey: key + " label") ?? "", travelMode: mode)
    }

    private static func split(_ notes: String?) -> (description: String?, details: ActivityDetails) {
        guard let notes else { return (nil, ActivityDetails()) }
        let trimmed = notes.trimmingCharacters(in: .newlines)
        guard trimmed.hasSuffix(closing), let start = trimmed.range(of: opening, options: .backwards),
              start.lowerBound == trimmed.startIndex || trimmed[trimmed.index(before: start.lowerBound)].isNewline
        else { return (notes, ActivityDetails()) }
        let end = trimmed.index(trimmed.endIndex, offsetBy: -closing.count)
        let lines = trimmed[start.upperBound..<end].split(whereSeparator: \.isNewline).map(String.init)
        var details = ActivityDetails()
        var values: [String: String] = [:]
        for line in lines {
            guard line.first == "[", line.last == "]", let separator = line.firstIndex(of: ":") else {
                return (notes, ActivityDetails())
            }
            let key = String(line[line.index(after: line.startIndex)..<separator])
            let value = String(line[line.index(after: separator)..<line.index(before: line.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            guard values[key] == nil else { return (notes, ActivityDetails()) }
            values[key] = value
        }
        if values["Before"] != nil {
            guard let buffer = buffer("Before", values: &values) else { return (notes, ActivityDetails()) }
            details.before = buffer
        }
        if values["After"] != nil {
            guard let buffer = buffer("After", values: &values) else { return (notes, ActivityDetails()) }
            details.after = buffer
        }
        if let value = values.removeValue(forKey: "Display") {
            guard let display = ActivityDisplay(rawValue: value) else { return (notes, ActivityDetails()) }
            details.display = display
        }
        if let rawID = values["Link ID"] {
            guard let id = UUID(uuidString: rawID), let title = values["Linked activity"],
                  let count = values["Linked copies"].flatMap(Int.init), count >= 2,
                  count <= values.count else { return (notes, ActivityDetails()) }
            let calendars = (1...count).compactMap { values.removeValue(forKey: "Calendar \($0)") }
            guard calendars.count == count else { return (notes, ActivityDetails()) }
            details.link = ActivityLink(id: id, title: title, calendars: calendars)
            for key in ["Link ID", "Linked activity", "Linked copies"] { values.removeValue(forKey: key) }
        }
        details.unknownLines = lines.filter { line in
            values.keys.contains { line.hasPrefix("[\($0):") }
        }
        var content = String(trimmed[..<start.lowerBound])
        // The serializer adds exactly two newlines, preserving the user's own trailing whitespace.
        if content.hasSuffix("\n\n") { content.removeLast(2) }
        return (content.isEmpty ? nil : content, details)
    }
}

public extension EventDraft {
    var activityDetails: ActivityDetails {
        get { ActivityDetails.read(from: notes) }
        set { notes = newValue.notes(description: ActivityDetails.description(in: notes)) }
    }
}
