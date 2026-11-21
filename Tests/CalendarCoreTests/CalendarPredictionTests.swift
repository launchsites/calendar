import CalendarCore
import Foundation
import Testing

struct CalendarPredictionTests {
    let gaming = CalendarChoice(id: "gaming", title: "Gaming Time", source: "Local", isWritable: true)
    let work = CalendarChoice(id: "work", title: "Work", source: "Local", isWritable: true)
    let duplicate = CalendarChoice(id: "shared", title: "Gaming Time", source: "Shared", isWritable: false)

    @Test func explicitNamesAndAliasesHavePriority() {
        #expect(resolve(requested: "gAMING time") == .selected("gaming", .explicit))
        #expect(resolve(requested: "games", aliases: ["Games": "gaming"]) == .selected("gaming", .explicit))
        #expect(resolve(requested: "unknown").id == nil)
        #expect(resolve(requested: "Games", aliases: ["Games": "removed-calendar"]).id == nil)
    }

    @Test func ambiguousNamesAndAliasCollisionsRequireSelection() {
        #expect(resolve(requested: "Gaming Time", extra: [duplicate]).id == nil)
        #expect(resolve(requested: "Gaming Time · Local", extra: [duplicate]).id == "gaming")
        #expect(resolve(requested: "Gaming Time · Shared", extra: [duplicate]).id == nil)
        #expect(resolve(requested: "Work", aliases: ["work": "gaming"]).id == nil)
    }

    @Test func titleAndKeywordRulesAreUnambiguous() {
        #expect(resolve(title: "G") == .selected("work", .system))
        #expect(resolve(title: "G", rules: ["g": "gaming"]) == .selected("gaming", .rule))
        #expect(resolve(title: "Sketching session", rules: ["sketching": "gaming"]) == .selected("gaming", .rule))
        #expect(resolve(title: "Sketching session", rules: ["sketching": "gaming", "session": "work"]) == .selected("work", .system))
        #expect(resolve(title: "Sketching session", rules: ["sketching session": "gaming", "session": "work"]) == .selected("gaming", .rule))
        #expect(resolve(preferred: "gone").id == nil)
    }

    @Test func frequentDestinationSurvivesAnOccasionalOverride() throws {
        var history = CalendarUsage()
        for _ in 0..<9 { history.record(title: "Court session", calendarID: "gaming") }
        history.record(title: "  COURT SESSION  ", calendarID: "work")
        let encoded = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode(CalendarUsage.self, from: encoded)
        #expect(!String(decoding: encoded, as: UTF8.self).localizedCaseInsensitiveContains("Court session"))
        #expect(resolve(title: "Court session", history: restored) == .selected("gaming", .history))
        #expect(resolve(requested: "Work", title: "Court session", history: restored) == .selected("work", .explicit))
        #expect(resolve(title: "Court session", rules: ["court session": "work"], history: restored) == .selected("work", .rule))
        #expect(resolve(title: "Court session class", history: restored) == .selected("work", .system))

        for _ in 0..<24 { history.record(title: "Court session", calendarID: "work") }
        #expect(resolve(title: "Court session", history: history) == .selected("work", .history))
    }

    @Test func weakEvidenceAndUnavailableCalendarsDoNotSuggest() {
        var history = CalendarUsage()
        history.record(title: "Lunch", calendarID: "gaming")
        history.record(title: "Lunch", calendarID: "gaming")
        #expect(resolve(title: "Lunch", history: history) == .selected("work", .system))
        history.record(title: "Lunch", calendarID: "work")
        history.record(title: "Lunch", calendarID: "gaming")
        #expect(resolve(title: "Lunch", history: history) == .selected("work", .system))
        for _ in 0..<4 { history.record(title: "Travel", calendarID: "removed") }
        #expect(resolve(title: "Travel", history: history) == .selected("work", .system))
    }

    @Test func aChosenDefaultIsUsedOnlyAfterExplicitAndSmartDestinations() {
        #expect(resolve(title: "New activity", preferred: "gaming") == .selected("gaming", .preferred))
        var history = CalendarUsage()
        for _ in 0..<4 { history.record(title: "Lunch", calendarID: "work") }
        #expect(resolve(title: "Lunch", preferred: "gaming", history: history) == .selected("work", .history))
        #expect(resolve(requested: "Work", preferred: "gaming") == .selected("work", .explicit))
        #expect(resolve(title: "Lunch", rules: ["lunch": "work"], preferred: "gaming") == .selected("work", .rule))
    }

    private func resolve(requested: String? = nil, title: String = "Sketching", extra: [CalendarChoice] = [],
                         aliases: [String: String] = [:], rules: [String: String] = [:],
                         preferred: String? = nil, history: CalendarUsage? = nil) -> CalendarResolution {
        CalendarPrediction.resolve(requested: requested, title: title, calendars: [gaming, work] + extra,
                                   aliases: aliases, rules: rules, preferredID: preferred,
                                   systemID: "work", locale: Locale(identifier: "en_GB"), history: history)
    }
}
