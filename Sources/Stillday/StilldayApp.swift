import CalendarCore
import CalendarData
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct StilldayApp: App {
    @State private var model = CalendarModel(store: EventKitCalendarStore())

    var body: some Scene {
        WindowGroup {
            CalendarScreen(model: model)
                .preferredColorScheme(model.colorScheme)
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 560)
                .focusedSceneValue(\.calendarModel, model)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1_240, height: 790)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CalendarEditCommands()
            CalendarViewCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            DesktopSettings(model: model)
                .preferredColorScheme(model.colorScheme)
        }
        #endif
    }
}

#if os(macOS)
private extension FocusedValues {
    @Entry var calendarModel: CalendarModel?
}

private struct CalendarViewCommands: Commands {
    @FocusedValue(\.calendarModel) private var model

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            modeButton(.day, key: "1")
            modeButton(.week, key: "2")
            modeButton(.month, key: "3")
        }
    }

    private func modeButton(_ mode: CalendarViewMode, key: KeyEquivalent) -> some View {
        Button("Show \(mode.rawValue)") { model?.mode = mode }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(model?.visibleModes.contains(mode) != true)
    }
}

private struct CalendarEditCommands: Commands {
    @FocusedValue(\.calendarModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { replay(redo: false) }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { replay(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private func replay(redo: Bool) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
            if redo { editor.undoManager?.redo() }
            else { editor.undoManager?.undo() }
        } else {
            model?.replayCalendarEdit(redo: redo)
        }
    }
}
#endif
