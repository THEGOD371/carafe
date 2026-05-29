import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.onboardingComplete {
            // MainShell hosts the NavigationSplitView with Library /
            // Bottles sections and the gear menu (API Keys + debug).
            MainShell()
        } else {
            OnboardingView()
        }
    }
}
