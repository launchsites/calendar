import AppIntents
import Observation

@MainActor @Observable
final class QuickEntryLaunch {
    static let shared = QuickEntryLaunch()
    var pending = false
}

struct OpenQuickEntry: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Entry"
    static let description = IntentDescription("Open Calendar with the event entry field ready to type.")
    static var openAppWhenRun: Bool { true }

    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickEntryLaunch.shared.pending = true
        return .result()
    }
}

struct StilldayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenQuickEntry(),
                    phrases: ["Add an event in \(.applicationName)"],
                    shortTitle: "Quick Entry", systemImageName: "plus")
    }
}
