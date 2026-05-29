import SwiftUI

/// Top-level onboarding container. Steps through the welcome screen
/// and the dependency installer, then flips `appState.onboardingComplete`.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var deps = DependencyManager.makeDefault()

    private enum Step: Hashable { case welcome, dependencies }
    @State private var step: Step = .welcome

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep(onContinue: { step = .dependencies })
            case .dependencies:
                DependencyInstallerView(deps: deps) {
                    appState.onboardingComplete = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wineglass")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to Carafe")
                .font(.system(size: 32, weight: .semibold))
            Text("Run Windows games on Apple Silicon, natively.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                bullet("Built on Apple's Game Porting Toolkit and Wine.")
                bullet("Per-game bottles keep installs isolated.")
                bullet("Free and open source — MIT licensed.")
                bullet(
                    "Anti-cheat games (Vanguard, EAC, Battleye) won't work — Carafe will flag them up front.",
                    icon: "exclamationmark.triangle"
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)

            Spacer()

            Button(action: onContinue) {
                Text("Get started")
                    .frame(minWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Text("Next: install required system dependencies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
    }

    private func bullet(_ text: String, icon: String = "checkmark.circle.fill") -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(icon.hasPrefix("checkmark") ? .green : .yellow)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.body)
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}
