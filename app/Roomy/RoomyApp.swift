import SwiftUI
import UserNotifications

@main
struct RoomyApp: App {
    @State private var store: CleanerStore
    private let updater = Updater()

    init() {
        let store = CleanerStore(engine: Engine.bundled(), notify: { text in
            let content = UNMutableNotificationContent()
            content.title = "Your Mac is running low on space"
            content.body = text
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        })
        store.startFreeSpaceUpdates()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        Window("Roomy", id: "main") {
            ContentView()
                .environment(store)
                .environment(updater.updates)
                .frame(minWidth: 680, minHeight: 500)
        }
        .defaultSize(width: 860, height: 700)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesCommand(updates: updater.updates) }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(updater.updates)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(store)
        } label: {
            MenuBarLabel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
