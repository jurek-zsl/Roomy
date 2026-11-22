import SwiftUI
import UserNotifications

@main
struct RoomyApp: App {
    @State private var store: CleanerStore

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
                .frame(minWidth: 680, minHeight: 500)
        }
        .defaultSize(width: 860, height: 700)

        Settings {
            SettingsView()
                .environment(store)
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
