import CalendarCore
import Foundation
import Testing

struct CalendarHighlightsTests {
    @Test func onlyTheLastStandaloneBracketedLineSetsACategory() {
        #expect(EventCategory.name(in: "Bring a notebook\n\n[School]\n\n") == "School")
        #expect(EventCategory.name(in: "[School]\nBring a notebook") == nil)
        #expect(EventCategory.name(in: "Bring a [School] notebook") == nil)
        #expect(EventCategory.name(in: "[School] [Work]") == nil)
        #expect(EventCategory.key(" ÉCOLE ") == EventCategory.key("école"))
    }

    @Test func portableTagCanBeSetReplacedAndClearedWithoutChangingDescription() {
        let original = "Bring a notebook [optional]\r\n\r\n[Topic]\r\nMore details\r"
        let notes = EventCategory.notes(description: original, category: "School")
        #expect(notes?.hasSuffix("[School]") == true)
        #expect(EventCategory.name(in: notes) == "School")
        #expect(EventCategory.description(in: notes) == original)
        let replaced = EventCategory.notes(description: EventCategory.description(in: notes), category: "Social")
        #expect(EventCategory.name(in: replaced) == "Social")
        #expect(EventCategory.notes(description: EventCategory.description(in: replaced), category: nil) == original)
        #expect(EventCategory.description(in: "[School]") == nil)
        #expect(EventCategory.description(in: "Bring a [School] notebook") == "Bring a [School] notebook")
        #expect(EventCategory.validatedName("School\nExtra") == nil)
    }

    @Test func existingHighlightSettingsKeepTaskAutoScrollOnByDefault() throws {
        let data = Data("""
            {
              "googleTasks": {"day": false, "month": true},
              "allDay": {"day": true, "month": false},
              "showTimedEventsInMonth": false
            }
            """.utf8)
        let options = try JSONDecoder().decode(CalendarHighlightOptions.self, from: data)
        #expect(options.autoScrollTaskBanner)
        #expect(!options.googleTasks.day)
        #expect(!options.showTimedEventsInMonth)
    }

    @Test func portableDisplaySettingsOmitPrivateCalendarAndCategoryNames() throws {
        var options = CalendarHighlightOptions()
        options.googleTasks.day = false
        options.allDay.month = false
        options.showTimedEventsInMonth = false
        options.autoScrollTaskBanner = false
        var preferences = Preferences()
        preferences.highlightOptions = options
        preferences.allDayCalendars = ["private calendar ID": .init()]
        preferences.categoryColours = ["private category name": .init(red: 1, green: 2, blue: 3)]
        let data = try preferences.exportData()
        #expect(!String(decoding: data, as: UTF8.self).contains("private"))
        var restored = Preferences()
        try restored.importData(data)
        #expect(restored.highlightOptions == options)
    }
}
