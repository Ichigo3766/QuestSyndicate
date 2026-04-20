import SwiftUI

struct AppCommands: Commands {
    @FocusedValue(\.appState) private var appState

    var body: some Commands {
        // File menu additions
        CommandGroup(after: .newItem) {
            Button("Sync Game Library") {
                Task {
                    do {
                        try await appState?.gameLibrary.forceSync()
                    } catch {
                        appState?.showError("Library sync failed: \(error.localizedDescription)")
                    }
                    // Forward refreshed VRP config into the download pipeline
                    appState?.configurePipeline()
                    appState?.refreshInstalledStatus()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(appState == nil)
        }

        // View menu
        CommandMenu("Device") {
            Button("Refresh Devices") {
                appState?.startDeviceTracking()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(appState == nil)

            Divider()

            Button("Connect via Wi-Fi…") {
                // Post notification to open sheet
                NotificationCenter.default.post(name: .showWiFiConnect, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // Library menu
        CommandMenu("Library") {
            Button("Search Games") {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(appState?.selectedTab != .library)

            Divider()

            Button("Show Library") {
                appState?.selectedTab = .library
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Downloads") {
                appState?.selectedTab = .downloads
            }
            .keyboardShortcut("2", modifiers: .command)
        }
    }
}

// MARK: - FocusedValue key for AppState
struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
}

// MARK: - Notification names
// All app-wide notification names live here as the single canonical source of truth.
extension Notification.Name {
    static let showWiFiConnect    = Notification.Name("showWiFiConnect")
    static let focusSearch        = Notification.Name("focusSearch")
    /// Posted (with `object: [URL]`) to trigger a manual APK/folder install.
    static let installManualFiles = Notification.Name("installManualFiles")
    /// Posted to switch the library filter to "On Device Only".
    static let showOnDeviceOnly   = Notification.Name("showOnDeviceOnly")
}
