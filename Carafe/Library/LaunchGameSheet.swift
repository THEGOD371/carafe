import SwiftUI

/// One-click launch sheet for clicking a tile in the library grid.
/// Resolves the game's bottle + exe, creates a RunSession, starts it
/// immediately, and reports total wall-clock time back to
/// GameLibrary on the terminal state transition.
///
/// No exe-picker, no bottle picker — that's the LaunchExeSheet's
/// job. If the bottle is missing or the exe path is broken, this
/// sheet shows a recovery view rather than crashing.
struct LaunchGameSheet: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    let game: Game

    @State private var session: RunSession?
    @State private var preflightError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 560)
        .task { await launchOnce() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.title3.weight(.semibold))
                if let bottle = library.bottle(for: game) {
                    Text("Bottle: \(bottle.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let session {
            RunningSessionView(
                session: session,
                onStop:    { Task { await session.stop() } },
                onRestart: { restart() },
                onClose:   { closeAndCleanup() }
            )
        } else if let preflightError {
            errorState(preflightError)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing launch…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Launch lifecycle

    /// Single-shot launcher. Called from `.task` on first appear.
    /// If preflight fails, we set `preflightError` and don't spin
    /// a RunSession — the user sees an error state with a Close button.
    private func launchOnce() async {
        guard let bottle = library.bottle(for: game) else {
            preflightError = "The bottle for this game no longer exists. From the library, right-click → Remap to a different bottle, or remove the entry."
            return
        }
        let exeURL = game.exePath.resolve(bottle: bottle)
        guard FileManager.default.fileExists(atPath: exeURL.path) else {
            preflightError = "The exe is missing: \(exeURL.path). From the library, right-click → Relocate exe, or remove the entry."
            return
        }
        let launchURL = switchToRealGameIfAvailable(game: game, bottle: bottle, exeURL: exeURL)
        if launchURL == exeURL,
           let profile = KnownLaunchers.match(exeURL: exeURL),
           profile.fix.skipLauncherTo != nil
        {
            // The launcher is still needed until it has downloaded
            // the real game exe. Do NOT block here: first-run users
            // need the launcher to create the files we later switch
            // to. Once `KnownLauncherTargetResolver` sees the real
            // exe, the next launch rewrites the library entry.
            NSLog(
                "Carafe: %@ launcher target not found yet; running launcher so it can install files.",
                profile.displayName
            )
        }
        startNewSession(bottle: bottle, exeURL: launchURL)
    }

    /// Known launcher profiles can identify the real game exe that
    /// appears after a launcher finishes downloading files. If that
    /// target now exists, update the library entry and launch it
    /// instead of making the user browse the prefix by hand.
    private func switchToRealGameIfAvailable(game: Game, bottle: Bottle, exeURL: URL) -> URL {
        guard let target = KnownLauncherTargetResolver.targetForLauncher(
            exeURL: exeURL,
            bottle: bottle
        ) else {
            return exeURL
        }

        var updated = game
        updated.exePath = .from(exeURL: target, bottle: bottle)
        library.update(updated)
        return target
    }

    private func startNewSession(bottle: Bottle, exeURL: URL) {
        // Resolve the game's compat overrides on top of bottle
        // defaults — this is the configuration RunSession will apply
        // (graphics backend, sync, Windows version, dll overrides,
        // env, retina, Metal HUD).
        let resolved = ResolvedConfig.resolve(game: game, bottle: bottle)
        let newSession = RunSession(
            bottle: bottle,
            exeURL: exeURL,
            config: resolved
        )
        // Hook play-time recording before start() so the callback
        // is wired by the time terminationHandler fires.
        let gameID = game.id
        newSession.onSessionEnded = { [weak library] duration in
            guard let library,
                  let current = library.games.first(where: { $0.id == gameID })
            else { return }
            library.recordPlay(current, duration: duration)
        }
        session = newSession
        Task { await newSession.start() }
    }

    private func restart() {
        guard let bottle = library.bottle(for: game) else {
            preflightError = "Bottle has disappeared since launch."
            session = nil
            return
        }
        let exeURL = game.exePath.resolve(bottle: bottle)
        guard FileManager.default.fileExists(atPath: exeURL.path) else {
            preflightError = "Exe disappeared between sessions."
            session = nil
            return
        }
        let launchURL = switchToRealGameIfAvailable(game: game, bottle: bottle, exeURL: exeURL)
        let old = session
        Task {
            if let old, old.state.isLive { await old.stop() }
            await old?.cleanup()
            await MainActor.run {
                startNewSession(bottle: bottle, exeURL: launchURL)
            }
        }
    }

    private func closeAndCleanup() {
        let s = session
        Task {
            if let s, s.state.isLive { await s.stop() }
            await s?.cleanup()
            await MainActor.run { dismiss() }
        }
    }

    // MARK: - Error state

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Can't launch this game")
                .font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Spacer()
            HStack {
                Spacer()
                Button("Close", action: { dismiss() })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }
}
