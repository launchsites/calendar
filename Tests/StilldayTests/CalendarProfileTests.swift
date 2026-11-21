import CalendarCore
import CalendarData
import Foundation
import SwiftUI
@testable import Stillday
import Testing

@MainActor
struct CalendarProfileTests {
    #if os(macOS)
    @Test func desktopWeekRollsOneDayAndKeepsEventsWhileItsBufferReloads() async throws {
        let suite = "Stillday.WeekTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(store: FixtureStore(), defaults: defaults)
        model.mode = .week
        model.preferences.weekStart = .monday
        let calendar = model.calendar
        model.selection = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12)))
        let initial = model.window(for: .week)
        let fetched = model.query
        await model.load(fetched)

        model.rollDesktopWeek(by: 1)
        let shifted = model.window(for: .week)
        #expect(shifted.start == calendar.date(byAdding: .day, value: 1, to: initial.start))
        #expect(shifted.end == calendar.date(byAdding: .day, value: 1, to: initial.end))
        #expect(CalendarWindow.days(in: shifted, calendar: calendar).count == 7)
        #expect(model.query == fetched)

        model.advance(1)
        #expect(model.window(for: .week).start == calendar.date(byAdding: .day, value: 7, to: shifted.start))
        #expect(model.query != fetched)
        #expect(!model.desktopWeekEvents().isEmpty)
        model.setCalendar("first", visible: false)
        #expect(model.desktopWeekEvents().isEmpty)

        model.selection = initial.start
        #expect(model.window(for: .week) == initial)
    }
    #endif

    @Test func appearanceChangesTheActiveProfileAccentOnly() throws {
        let suite = "Stillday.ProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(store: FixtureStore(), defaults: defaults)
        let standard = Preferences.AccentColor(red: 40, green: 120, blue: 200)
        let custom = Preferences.AccentColor(red: 200, green: 40, blue: 60)
        let profile = CalendarProfile(name: "Fixture")
        model.selectedAccentColor = standard
        model.saveProfile(profile)
        model.switchProfile(profile.id)
        #expect(model.selectedAccentColor == nil)
        model.selectedAccentColor = custom
        model.switchProfile(nil)
        #expect(model.selectedAccentColor == standard)
        model.switchProfile(profile.id)
        #expect(model.selectedAccentColor == custom)
        model.selectedAccentColor = nil
        #expect(model.selectedAccentColor == nil)
        #expect(model.preferences.accentColor == standard)
    }

    @Test func eachProfileKeepsItsCalendarPickerOrderAcrossRelaunch() async throws {
        let suite = "Stillday.OrderTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(store: FixtureStore(), defaults: defaults)
        await model.load(model.query)

        var first = CalendarProfile(name: "First", calendarIDs: ["first", "shared"])
        first.calendarOrder = ["missing", "shared", "shared", "first"]
        var second = CalendarProfile(name: "Second", calendarIDs: ["second", "shared"])
        second.calendarOrder = ["second", "shared"]
        model.saveProfile(first)
        model.saveProfile(second)

        model.switchProfile(first.id)
        #expect(model.writableCalendars.map(\.id) == ["shared", "first"])
        model.switchProfile(second.id)
        #expect(model.writableCalendars.map(\.id) == ["second", "shared"])

        model.switchProfile(first.id)
        model.setCalendar("shared", visible: false)
        #expect(model.writableCalendars.map(\.id) == ["first"])
        model.setCalendar("shared", visible: true)
        #expect(model.writableCalendars.map(\.id) == ["shared", "first"])
        model.setCalendar("second", visible: true)
        #expect(model.writableCalendars.map(\.id) == ["shared", "first", "second"])

        let restored = CalendarModel(store: FixtureStore(), defaults: defaults)
        await restored.load(restored.query)
        #expect(restored.writableCalendars.map(\.id) == ["shared", "first", "second"])
        restored.switchProfile(nil)
        #expect(restored.writableCalendars.map(\.id) == ["first", "second", "shared"])
    }

    @Test func activityPreferencesSurviveRelaunchAndManualEnablingPreservesExistingChoices() throws {
        let suite = "Stillday.ActivityDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(store: FixtureStore(), defaults: defaults)
        model.preferences.beforeActivity = .init(kind: .travel, travelMode: .walking)
        model.preferences.afterActivity = .init(kind: .cleanup)
        model.preferences.bufferBackground = .lighter
        let restored = CalendarModel(store: FixtureStore(), defaults: defaults)
        #expect(restored.preferences.beforeActivity == model.preferences.beforeActivity)
        #expect(restored.preferences.afterActivity == model.preferences.afterActivity)
        #expect(restored.preferences.bufferBackground == .lighter)
        var before: ActivityBuffer?
        let binding = Binding(get: { before }, set: { before = $0 })
        let enabled = ActivityBufferEditor.enabled(binding, defaults: restored.preferences.beforeActivity)
        enabled.wrappedValue = true
        #expect(before == ActivityBuffer(minutes: 5, kind: .travel, travelMode: .walking))
        before = ActivityBuffer(minutes: 25, kind: .setup)
        enabled.wrappedValue = true
        #expect(before == ActivityBuffer(minutes: 25, kind: .setup))
        enabled.wrappedValue = false
        #expect(before == nil)
        enabled.wrappedValue = true
        #expect(before?.travelMode == .walking)
    }

    @Test func legacyDisplayMetadataKeepsEventsVisibleAndPreservesNotes() async throws {
        let suite = "Stillday.LegacyDisplay.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        json["backgroundCalendarIDs"] = ["fixture"]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "Stillday.Settings.v1")
        let model = CalendarModel(store: FixtureStore(), defaults: defaults)
        let calendar = CalendarListItem(choice: .init(id: "fixture", title: "Fixture", source: "Test", isWritable: true),
                                        color: .init(red: 0.4, green: 0.2, blue: 0.8))
        var details = ActivityDetails()
        details.display = .background
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CalendarEvent(id: .init(identifier: "fixture", start: start, occurrence: nil, calendarID: calendar.id),
                                  title: "Existing event", end: start + 3600, isAllDay: false, timeZoneID: nil,
                                  modified: nil, isRecurring: false, calendar: calendar,
                                  notes: details.notes(description: "Keep this description."))
        model.selection = start
        await model.load(model.query)
        model.snapshot = CalendarSnapshot(access: .full, calendars: [calendar], events: [event])
        #expect(model.events(in: model.window(for: .day)).map(\.id) == [event.id])
        #if os(macOS)
        #expect(model.desktopWeekEvents().map(\.id) == [event.id])
        #endif
        #expect(ActivityDetails.description(in: event.notes) == "Keep this description.")
        #expect(ActivityDetails.read(from: event.notes).display == .background)
    }

    @Test func switchingProfilesFiltersTheCurrentDayAndPrefetchedDays() async throws {
        let suite = "Stillday.ProfileTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(store: FixtureStore(), defaults: defaults)
        model.selection = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CalendarProfile(name: "First", calendarIDs: ["first", "shared"])
        let second = CalendarProfile(name: "Second", calendarIDs: ["second", "shared"])
        model.saveProfile(first)
        model.saveProfile(second)
        let today = model.window(for: .day)
        let tomorrow = CalendarViewMode.day.window(for: today.end, calendar: model.calendar)

        model.switchProfile(first.id)
        await model.load(model.query)
        #expect(Set(model.events(in: today).map(\.id.calendarID)) == ["first", "shared"])
        #expect(Set(model.events(in: tomorrow).map(\.id.calendarID)) == ["first", "shared"])

        model.switchProfile(second.id)
        #expect(model.events(in: today).isEmpty)
        #expect(model.events(in: tomorrow).isEmpty)
        await model.load(model.query)
        #expect(Set(model.events(in: today).map(\.id.calendarID)) == ["second", "shared"])
        #expect(Set(model.writableCalendars.map(\.id)) == ["second", "shared"])
        #expect(CalendarModel(store: FixtureStore(), defaults: defaults).activeProfile?.id == second.id)

        model.removeProfile(second.id)
        await model.load(model.query)
        #expect(model.activeProfile == nil)
        #expect(Set(model.events(in: today).map(\.id.calendarID)) == ["first", "second", "shared"])
    }
}

private struct FixtureStore: CalendarStore {
    func snapshot(in window: DateInterval, hidden: Set<String>) async throws -> CalendarSnapshot {
        let calendars = ["first", "second", "shared"].map { id in
            CalendarListItem(choice: CalendarChoice(id: id, title: id, source: "Fixture", isWritable: true),
                             color: CalendarColor(red: 0, green: 0, blue: 0))
        }
        let events = calendars.filter { !hidden.contains($0.id) }.map { calendar in
            CalendarEvent(id: EventIdentity(identifier: calendar.id, start: window.start, occurrence: nil, calendarID: calendar.id),
                          title: "Fixture event", end: window.start.addingTimeInterval(3600), isAllDay: false,
                          timeZoneID: nil, modified: nil, isRecurring: false, calendar: calendar)
        }
        return CalendarSnapshot(access: .full, calendars: calendars, events: events)
    }

    func requestAccess() async throws {}
    func calendarUsage(in window: DateInterval) async -> CalendarUsage? { nil }
    func create(_ draft: EventDraft, calendarID: String, requestID: UUID) async throws {}
    func update(_ event: CalendarEvent, with draft: EventDraft, calendarID: String, scope: MutationScope) async throws {}
    func delete(_ event: CalendarEvent, scope: MutationScope) async throws {}
}
