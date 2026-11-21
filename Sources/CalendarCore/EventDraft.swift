#if os(Linux)
import CLinuxCrypto
#else
import CryptoKit
#endif
import Foundation

public enum EntryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case log, schedule
    public var id: Self { self }
    public var label: String { self == .log ? "Log activity" : "Schedule ahead" }
}

public enum RepeatRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, weekly
    public var id: Self { self }
    public var label: String { self == .none ? "Never" : "Weekly" }
}

public struct EventDraft: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var timeZoneID: String?
    public var repetition: RepeatRule
    public var notes: String?

    public init(title: String, start: Date, end: Date, allDay: Bool = false,
                timeZoneID: String? = nil, repetition: RepeatRule = .none, notes: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.timeZoneID = timeZoneID
        self.repetition = repetition
        self.notes = notes
    }
}

public struct CalendarChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let isWritable: Bool

    public init(id: String, title: String, source: String, isWritable: Bool) {
        self.id = id
        self.title = title
        self.source = source
        self.isWritable = isWritable
    }

    public var qualifiedTitle: String { "\(title) · \(source)" }
}

public enum DestinationReason: Equatable, Sendable {
    case explicit, rule, history, preferred, system, onlyCalendar
}

public enum CalendarResolution: Equatable, Sendable {
    case selected(String, DestinationReason)
    case choose(String)

    public var id: String? {
        if case let .selected(id, _) = self { return id }
        return nil
    }
}

public struct CalendarPrediction {
    public static func normalize(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func resolve(
        requested: String?, title: String, calendars: [CalendarChoice], aliases: [String: String],
        rules: [String: String], preferredID: String?, systemID: String?, locale: Locale,
        history: CalendarUsage? = nil
    ) -> CalendarResolution {
        let writable = calendars.filter(\.isWritable)
        let writableIDs = Set(writable.map(\.id))
        func normalized(_ text: String) -> String { normalize(text, locale: locale) }

        if let requested {
            let key = normalized(requested)
            let matchingNames = calendars.filter {
                normalized($0.title) == key || normalized($0.qualifiedTitle) == key
            }.map(\.id)
            let matchingAliases = aliases.filter { normalized($0.key) == key }.map(\.value)
            let matches = Set(matchingNames + matchingAliases)
            guard matches.count <= 1 else {
                return .choose("More than one calendar matches /\(requested). Choose one below.")
            }
            guard let id = matches.first else {
                return .choose("No calendar matches /\(requested). Choose one below.")
            }
            guard writableIDs.contains(id) else {
                return .choose("/\(requested) is unavailable or read-only. Choose a writable calendar.")
            }
            return .selected(id, .explicit)
        }

        let key = normalized(title)
        let words = " " + key + " "
        let exact = rules.filter { normalized($0.key) == key && writableIDs.contains($0.value) }
        let candidates = exact.isEmpty ? rules.filter {
            let keyword = normalized($0.key)
            return !keyword.isEmpty && words.contains(" " + keyword + " ") && writableIDs.contains($0.value)
        } : exact
        let predictions = Set(candidates.values)
        if predictions.count == 1, let id = predictions.first { return .selected(id, .rule) }
        if predictions.isEmpty, writable.count > 1,
           let id = history?.suggestion(for: title), writableIDs.contains(id) {
            return .selected(id, .history)
        }
        if let preferredID {
            guard writableIDs.contains(preferredID) else {
                return .choose("Your default calendar is unavailable. Choose a writable calendar.")
            }
            return .selected(preferredID, .preferred)
        }
        if let systemID, writableIDs.contains(systemID) { return .selected(systemID, .system) }
        if writable.count == 1, let calendar = writable.first { return .selected(calendar.id, .onlyCalendar) }
        return .choose(writable.isEmpty ? "No writable calendars are available." : "Choose a calendar.")
    }
}

/// Recent choices, keyed by a digest of the normalized title. Stored separately from portable settings.
public struct CalendarUsage: Codable, Sendable {
    private struct Choices: Codable, Sendable {
        var ids: [String]
        var lastUsed: Int
    }

    private var byTitle: [String: Choices] = [:]
    private var sequence = 0

    public init() {}

    public mutating func record(title: String, calendarID: String) {
        guard let key = Self.key(title) else { return }
        sequence += 1
        var ids = byTitle[key]?.ids ?? []
        ids.append(calendarID)
        byTitle[key] = Choices(ids: Array(ids.suffix(24)), lastUsed: sequence)
        if byTitle.count > 1_024,
           let oldest = byTitle.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            byTitle.removeValue(forKey: oldest)
        }
    }

    public func suggestion(for title: String) -> String? {
        guard let key = Self.key(title), let ids = byTitle[key]?.ids, ids.count >= 3 else { return nil }
        var counts: [String: Int] = [:]
        for id in ids { counts[id, default: 0] += 1 }
        return counts.first(where: { $0.value * 5 >= ids.count * 4 })?.key
    }

    private static func key(_ title: String) -> String? {
        let normalized = CalendarPrediction.normalize(title, locale: Locale(identifier: "en_US_POSIX"))
        guard !normalized.isEmpty else { return nil }
        let bytes = Data(normalized.utf8)
#if os(Linux)
        var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { buffer in
            _ = SHA256(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &digest)
        }
        return Data(digest).base64EncodedString()
#else
        return Data(SHA256.hash(data: bytes)).base64EncodedString()
#endif
    }
}
