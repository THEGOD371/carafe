import SwiftUI

@main
struct CarafeApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var settings = AppSettings()

    // Sparkle updater. Created once at launch — instantiating
    // SPUStandardUpdaterController arms the scheduled background
    // check that runs once per 24 h (configured in Info.plist).
    // See `Updater.swift` for the wrapper, and TESTING.md →
    // "Sparkle release engineering" for the one-time key setup.
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup("Carafe") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.bottles)
                .environmentObject(appState.library)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            // Drop the "New" menu item — Carafe has no document model.
            CommandGroup(replacing: .newItem) { }

            // "Check for Updates…" lives in the Carafe app menu,
            // directly after the "About Carafe" item. This is the
            // standard macOS placement that Sparkle's docs recommend.
            // The button observes `canCheckForUpdates` so it greys
            // out while a check is already in flight.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        // macOS-native Settings scene. Cmd+, opens it from anywhere
        // in the app; the toolbar gear button also calls into it via
        // the `openSettings` environment value.
        //
        // The Settings scene needs its own copy of environment objects
        // — they don't inherit across scenes — so we re-inject the
        // same instances here.
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.bottles)
                .environmentObject(settings)
        }
    }
}
