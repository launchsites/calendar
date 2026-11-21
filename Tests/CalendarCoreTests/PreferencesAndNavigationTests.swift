import CalendarCore
import Foundation
import Testing

struct PreferencesAndNavigationTests {
    @Test func dayPagingCancelsShortDragsAndAcceptsDeliberateFlicks() {
        #expect(DayPaging.horizontalDirection(translation: -45, projected: -70, width: 400) == nil)
        #expect(DayPaging.horizontalDirection(translation: -45, projected: -180, width: 400) == 1)
        #expect(DayPaging.horizontalDirection(translation: 110, projected: 110, width: 400) == -1)
        #expect(DayPaging.horizontalDirection(translation: 45, projected: -180, width: 400) == nil)
        #expect(DayPaging.horizontalDirection(translation: 12, projected: 200, width: 400) == nil)
    }

    @Test func midnightPullRequiresOverscrollAndClampsAtFullProgress() {
        #expect(DayPaging.pullProgress(overscroll: 0) == 0)
        #expect(DayPaging.pullProgress(overscroll: 34) == 0.5)
        #expect(DayPaging.pullProgress(overscroll: 59) < 1)
        #expect(DayPaging.pullProgress(overscroll: 60) == 1)
        #expect(DayPaging.pullProgress(overscroll: 95) == 1)
    }

    @Test func midnightPullUsesFingerTravelRelativeToTheViewport() {
        #expect(DayPaging.pullProgress(travel: 72, viewportHeight: 800) == 0.5)
        #expect(DayPaging.pullProgress(travel: 144, viewportHeight: 800) == 1)
        #expect(DayPaging.pullProgress(travel: 72, viewportHeight: 400) == 1)
        #expect(DayPaging.pullProgress(travel: -10, viewportHeight: 800) == 0)
    }

    @Test func preferencesTransferWithoutCalendarMetadata() throws {
        var source = Preferences()
        source.defaultMode = .schedule
        source.defaultDuration = 45
        source.timeFormat = .twentyFourHour
        source.accentColor = .init(red: 154, green: 54, blue: 208)
        source.timelineLayout = .columns
        source.preferredCalendarID = "private-account-id"
        source.rules = ["private-title": "private-account-id"]
        let data = try source.exportData()
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("private"))
        var destination = Preferences()
        destination.aliases["alias"] = "local-id"
        try destination.importData(data)
        #expect(destination.defaultMode == .schedule)
        #expect(destination.defaultDuration == 45)
        #expect(destination.timeFormat == .twentyFourHour)
        #expect(destination.accentColor == source.accentColor)
        #expect(destination.timelineLayout == .columns)
        #expect(destination.aliases == ["alias": "local-id"])
        #expect(throws: (any Error).self) { try destination.importData(Data(json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 99").utf8)) }
    }

    @Test func preferencesWithoutAnAccentKeepExistingSettings() throws {
        var legacy = Preferences()
        legacy.defaultDuration = 90
        legacy.hiddenCalendars = ["fixture-calendar"]
        let localData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(Preferences.self, from: localData)
        #expect(decoded.defaultDuration == 90)
        #expect(decoded.hiddenCalendars == ["fixture-calendar"])
        #expect(decoded.accentColor == nil)
        #expect(decoded.timelineLayout == nil)

        var imported = Preferences()
        imported.accentColor = .init(red: 128, green: 20, blue: 40)
        try imported.importData(legacy.exportData())
        #expect(imported.defaultDuration == 90)
        #expect(imported.accentColor == nil)
    }

    @Test func existingProfilesDecodeWithoutACalendarOrder() throws {
        let original = CalendarProfile(name: "Existing", calendarIDs: ["one", "two"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalendarProfile.self, from: data)
        #expect(decoded == original)
        #expect(decoded.calendarOrder == nil)

        var ordered = original
        ordered.calendarOrder = ["two", "one"]
        let encoded = try JSONEncoder().encode(ordered)
        #expect(try JSONDecoder().decode(CalendarProfile.self, from: encoded) == ordered)
    }

    @Test func activityDefaultsPersistAndTransferWithBackwardCompatibleFallbacks() throws {
        let legacyData = try JSONEncoder().encode(Preferences())
        let legacy = try JSONDecoder().decode(Preferences.self, from: legacyData)
        #expect(legacy.beforeActivity == ActivityBufferDefaults())
        #expect(legacy.afterActivity == ActivityBufferDefaults())
        #expect(legacy.bufferBackground == .event)
        #expect(legacy.bufferBackground.fillOpacity == 0.19)

        var configured = legacy
        configured.beforeActivity = .init(kind: .travel, travelMode: .walking)
        configured.afterActivity = .init(kind: .travel, travelMode: .train)
        configured.bufferBackground = .lighter
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(configured))
        #expect(restored.beforeActivity == configured.beforeActivity)
        #expect(restored.afterActivity == configured.afterActivity)
        #expect(restored.bufferBackground == .lighter)
        var imported = Preferences()
        try imported.importData(configured.exportData())
        #expect(imported.beforeActivity == configured.beforeActivity)
        #expect(imported.afterActivity == configured.afterActivity)
        #expect(imported.bufferBackground == .lighter)
        try imported.importData(legacy.exportData())
        #expect(imported.bufferBackground == .event)
        #expect(imported.beforeActivity == ActivityBufferDefaults())
    }

    @Test func overlapBlendingIsOptionalAndTransfersWithSettings() throws {
        var preferences = Preferences()
        #expect(preferences.blendActivityBuffers == nil)
        preferences.blendActivityBuffers = true
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(restored.blendActivityBuffers == true)
        var imported = Preferences()
        try imported.importData(preferences.exportData())
        #expect(imported.blendActivityBuffers == true)
        try imported.importData(Preferences().exportData())
        #expect(imported.blendActivityBuffers == nil)
    }

    @Test func windowsRespectMondayStartAndDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        calendar.firstWeekday = 2
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        #expect(CalendarViewMode.day.window(for: date, calendar: calendar).duration == 23 * 3600)
        let week = CalendarViewMode.week.window(for: date, calendar: calendar)
        #expect(calendar.component(.weekday, from: week.start) == 2)
        #expect(CalendarWindow.days(in: week, calendar: calendar).count == 7)
        let month = CalendarViewMode.month.window(for: date, calendar: calendar)
        #expect(CalendarWindow.days(in: month, calendar: calendar).count == 42)
        let next = CalendarViewMode.day.advance(date, by: 1, calendar: calendar)
        #expect(calendar.component(.day, from: next) == 30)
        #expect(next.timeIntervalSince(date) == 23 * 3600)
    }
}
