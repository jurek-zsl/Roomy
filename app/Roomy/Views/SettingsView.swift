import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(CleanerStore.self) private var store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            SwiftUI.Section("Cleaning") {
                Toggle("Move everything to the Trash instead of deleting", isOn: $store.trashInstead)
                Text("You can get items back from the Trash. Their space is freed when you empty it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section("Explaining folders") {
                Picker("Ask", selection: $store.advisorID) {
                    ForEach(store.advisors, id: \.id) { a in
                        Text(a.status() == .notInstalled ? "\(a.name) (not installed)" : a.name).tag(a.id)
                    }
                }
                Text(store.advisor.statusMessage(store.advisorStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Apple Intelligence runs on this Mac. Claude and Codex are more capable, but the facts go to Anthropic or OpenAI, so Roomy shows them and asks each time. Either way, Roomy makes the call and nothing is cleaned without you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SwiftUI.Section("Menu bar") {
                Toggle("Open Roomy at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in setLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Tell me when free space drops under \(formatBytes(store.lowSpaceThreshold))", isOn: $store.lowSpaceAlerts)
                    .onChange(of: store.lowSpaceAlerts) { _, on in
                        if on {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
                Text("At most once a day. Roomy also scans again every 6 hours while it runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription) Moving Roomy to Applications may help."
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
