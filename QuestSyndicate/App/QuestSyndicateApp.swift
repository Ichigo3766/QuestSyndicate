import SwiftUI

@main
struct QuestSyndicateApp: App {
    @State private var appState = AppState()
    @AppStorage("colorScheme") private var colorSchemeRaw: String = "system"

    /// Drives the update-prompt sheet from the app level.
    @State private var showUpdateSheet = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .focusedValue(\.appState, appState)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 900, minHeight: 600)
                // ── Update check: on launch ───────────────────────────────────
                .task {
                    // Delay slightly so the window is fully rendered before network activity
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    // Always force-check on launch so the prompt appears every time an update exists
                    await appState.updater.checkForUpdate()
                    // Directly set the flag — .onChange on @Observable can miss the first transition
                    if appState.updater.availableUpdate != nil {
                        showUpdateSheet = true
                    }
                }
                // ── Update check: on foreground resume ────────────────────────
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    Task {
                        await appState.updater.checkIfNeeded()
                        if appState.updater.availableUpdate != nil {
                            showUpdateSheet = true
                        }
                    }
                }
                // ── Show update sheet when triggered by other code paths ───────
                .onChange(of: appState.updater.availableUpdate != nil) { _, hasUpdate in
                    if hasUpdate { showUpdateSheet = true }
                }
                .sheet(isPresented: $showUpdateSheet) {
                    UpdatePromptView(updateService: appState.updater)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppCommands()

            // ── Check for Updates menu item (App menu) ────────────────────────
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await appState.updater.checkForUpdate() }
                    showUpdateSheet = true
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsContainerView()
                .environment(appState)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }
}
