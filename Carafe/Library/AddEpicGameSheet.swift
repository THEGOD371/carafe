import SwiftUI

/// Adds an Epic Games library entry to Carafe via legendary.
///
/// Five-phase flow (linear, with a single back-step from Library →
/// Auth in case the user wants to re-sign-in):
///
///   .setup    — make sure legendary is installed in Carafe's venv
///   .auth     — show Epic login URL + paste-SID field; verify
///   .library  — list owned games; user picks one
///   .install  — create Wine Staging bottle, run `legendary install`,
///               register Game record
///   .finished — done; offer "Launch now" and "Add another"
///
/// Each phase has a single render block + an action button that
/// advances to the next phase. Errors at any phase set
/// `errorMessage` and let the user retry or cancel.
struct AddEpicGameSheet: View {

    // MARK: - Environment

    @EnvironmentObject private var bottles: BottleManager
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var epicAuth: EpicAuth
    @Environment(\.dismiss) private var dismiss

    // MARK: - Phases

    enum Phase: Equatable {
        case setup
        case auth
        case library
        case install
        case finished
    }

    @State private var phase: Phase = .setup

    // MARK: - Per-phase state

    /// Streaming log for setup + install phases. Capped to keep the
    /// scroll view nimble.
    @State private var logLines: [String] = []
    private let logCap = 1000

    /// Free-text error shown above the action row. nil = no error.
    @State private var errorMessage: String?

    /// True while a long-running task is in flight (setup install,
    /// auth exchange, library fetch, game install). Disables the
    /// action button and shows a progress indicator.
    @State private var isWorking: Bool = false

    /// Sub-state inside the .auth phase:
    /// * `.idle` — primary "Sign in to Epic" button visible.
    /// * `.attemptingImport` — `legendary auth --import` is running.
    /// * `.manualPaste` — `--import` failed or wasn't available; the
    ///   user is in the browser flow with a paste field for the
    ///   authorizationCode from Epic's JSON redirect page.
    private enum AuthStep: Equatable {
        case idle
        case attemptingImport
        case manualPaste
    }
    @State private var authStep: AuthStep = .idle

    /// User's paste of the authorizationCode value from the JSON
    /// page Epic shows after sign-in.
    @State private var codeInput: String = ""

    /// All owned Epic games (populated when phase enters .library).
    @State private var ownedGames: [EpicGame] = []
    @State private var libraryFilter: String = ""
    @State private var selectedGame: EpicGame?

    /// Install progress 0…1. Updated from regex on legendary's
    /// DLManager lines.
    @State private var installProgress: Double = 0
    @State private var installedGame: Game?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
        .task { await onAppear() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add from Epic Games").font(.title3.weight(.semibold))
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        switch phase {
        case .setup:    return "One-time setup — installing the legendary CLI…"
        case .auth:     return "Sign in to your Epic account."
        case .library:  return "Pick a game to install into a new Carafe bottle."
        case .install:  return "Installing — this can take a while for large titles."
        case .finished: return "Done. The game is ready to launch."
        }
    }

    // MARK: - Per-phase content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .setup:    setupView
        case .auth:     authView
        case .library:  libraryView
        case .install:  installView
        case .finished: finishedView
        }
    }

    // MARK: - Setup

    @ViewBuilder
    private var setupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                LegendaryInstaller.isInstalled
                    ? "legendary is already installed at \(LegendaryInstaller.legendaryBinary.path)."
                    : "Carafe will install Homebrew Python 3.12 and the legendary CLI into a private venv at \(LegendaryInstaller.venvDirectory.path). This runs once."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            logView
            if let err = errorMessage {
                errorBanner(err)
            }
        }
        .padding(16)
    }

    private func runSetup() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        appendLog("Setting up legendary…")
        do {
            try await LegendaryInstaller.install { line in
                Task { @MainActor in appendLog(line) }
            }
            phase = .auth
            await epicAuth.refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Auth

    @ViewBuilder
    private var authView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch epicAuth.status {
                case .loggedIn(let name):
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("Signed in as **\(name)**.").font(.callout)
                    }
                    Text("If this isn't the account you want to install from, sign out and sign in again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            try? await epicAuth.logout()
                        }
                    } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    .disabled(isWorking)

                default:
                    authIdleOrFallback
                }

                if let err = errorMessage {
                    errorBanner(err)
                }
            }
            .padding(16)
        }
    }

    /// Auth view body when the user is NOT yet signed in. Renders
    /// one of three states based on `authStep`:
    ///   * `.idle` — single primary "Sign in to Epic" button.
    ///   * `.attemptingImport` — progress message while
    ///     `legendary auth --import` is running.
    ///   * `.manualPaste` — fallback paste field for the
    ///     authorizationCode after `--import` failed.
    @ViewBuilder
    private var authIdleOrFallback: some View {
        switch authStep {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in once with your Epic account to add owned games into Carafe. Carafe tries to import credentials silently from the local Epic Games Launcher first; if that's not installed you'll be prompted to copy a short code from a browser page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await startSignIn() }
                } label: {
                    Label("Sign in to Epic", systemImage: "gamecontroller.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)

                if EpicAuth.isEpicGamesLauncherInstalled {
                    Label("Epic Games Launcher detected — sign-in should be one-click via `legendary --import`.",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Epic Games Launcher not detected at /Applications. Carafe will fall back to a code-paste flow after clicking Sign in.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .attemptingImport:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Importing credentials from Epic Games Launcher…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .manualPaste:
            VStack(alignment: .leading, spacing: 10) {
                Label("Couldn't import — falling back to manual sign-in",
                      systemImage: "arrow.right.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("A browser window opened to Epic's login page. Sign in there if needed, then **copy the `authorizationCode` value** from the resulting JSON page (it looks like `{\"authorizationCode\": \"abc123…\"}`). Paste just that code below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("authorizationCode", text: $codeInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)

                HStack(spacing: 8) {
                    Button {
                        epicAuth.openLoginPage()
                    } label: {
                        Label("Reopen Login Page", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    Spacer()
                    Button("Back") {
                        authStep = .idle
                        codeInput = ""
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                }
            }
        }
    }

    /// Click handler for the primary "Sign in to Epic" button. Tries
    /// `--import` first; on failure, opens the manual login URL and
    /// switches to the code-paste UI.
    private func startSignIn() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        authStep = .attemptingImport
        do {
            try await epicAuth.attemptImport()
            // Success path: refreshStatus inside attemptImport
            // flipped `.status` to .loggedIn. Move to library.
            if case .loggedIn = epicAuth.status {
                phase = .library
                authStep = .idle
                await loadOwnedGames()
                return
            }
            // attemptImport returned success but status didn't update
            // — treat as a no-op failure, fall through to manual.
            authStep = .manualPaste
            epicAuth.openLoginPage()
            errorMessage = "Imported credentials but couldn't confirm login. Please complete the manual flow."
        } catch {
            // --import failed (usually because Epic Games Launcher
            // isn't installed). Quietly switch to manual.
            authStep = .manualPaste
            epicAuth.openLoginPage()
        }
    }

    /// Footer "Continue" handler for the .auth phase.
    private func runAuth() async {
        if case .loggedIn = epicAuth.status {
            phase = .library
            await loadOwnedGames()
            return
        }
        // In .idle the primary button is the trigger, not Continue.
        // In .attemptingImport Continue is disabled. In .manualPaste
        // Continue exchanges the pasted code.
        guard authStep == .manualPaste else { return }
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            errorMessage = "Paste the `authorizationCode` value from the browser page before continuing."
            return
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            try await epicAuth.completeLogin(code: code)
            codeInput = ""
            authStep = .idle
            phase = .library
            await loadOwnedGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Library

    @ViewBuilder
    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search library…", text: $libraryFilter)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await loadOwnedGames() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isWorking)
                .help("Re-fetch your Epic library")
            }

            if isWorking && ownedGames.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fetching library…").font(.callout).foregroundStyle(.secondary)
                }
            } else if filteredOwnedGames.isEmpty {
                Text(ownedGames.isEmpty
                     ? "No games found in your Epic library yet. If you just claimed something, re-sync via the refresh button above."
                     : "No matches for \"\(libraryFilter)\"."
                )
                .font(.callout).foregroundStyle(.secondary)
                .padding(.vertical, 12)
            } else {
                List(filteredOwnedGames, selection: $selectedGame) { game in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title).font(.callout.weight(.medium))
                            if game.isInstalled {
                                Text("Already installed via legendary — Carafe will register it without re-downloading.")
                                    .font(.caption2).foregroundStyle(.orange)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                        }
                        Spacer()
                    }
                    .tag(game)
                    .contentShape(Rectangle())
                }
                .listStyle(.bordered)
                .frame(minHeight: 240, maxHeight: 360)
            }

            if let err = errorMessage {
                errorBanner(err)
            }
        }
        .padding(16)
    }

    private var filteredOwnedGames: [EpicGame] {
        let q = libraryFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ownedGames }
        return ownedGames.filter { $0.title.lowercased().contains(q) }
    }

    private func loadOwnedGames() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            ownedGames = try await EpicLibrary.fetchOwnedGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Install

    @ViewBuilder
    private var installView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let game = selectedGame {
                Text("Installing **\(game.title)**")
                    .font(.title3.weight(.semibold))
                Text("appName: \(game.appName)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            ProgressView(value: installProgress)
                .progressViewStyle(.linear)
            Text("\(Int(installProgress * 100)) %")
                .font(.caption.monospaced()).foregroundStyle(.secondary)

            logView

            if let err = errorMessage {
                errorBanner(err)
            }
        }
        .padding(16)
    }

    /// The main install pipeline. Creates the bottle, runs legendary,
    /// registers the Game.
    private func runInstall() async {
        guard let game = selectedGame else { return }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        installProgress = 0
        appendLog("Creating Wine Staging bottle “\(game.title)”…")

        // 1. Pick a unique bottle name.
        let baseName = game.title
        var bottleName = baseName
        var suffix = 1
        while bottles.entries.contains(where: {
            $0.displayName.localizedCaseInsensitiveCompare(bottleName) == .orderedSame
        }) {
            suffix += 1
            bottleName = "\(baseName) (\(suffix))"
        }

        // 2. Create the bottle. BottleManager.create doesn't return
        //    the new bottle directly — we fish it back out by name
        //    after the await completes.
        await bottles.create(
            name: bottleName,
            windowsVersion: .win10,
            wineVersion: "wine-staging-\(WineStagingInstaller.version)",
            wineBuild: .wineStaging,
            graphicsBackend: .dxmt
        )
        guard let bottle = bottles.entries
            .compactMap(\.validBottle)
            .first(where: { $0.name == bottleName })
        else {
            errorMessage = bottles.lastError ?? "Bottle creation failed silently — check the Bottles view."
            return
        }
        appendLog("Bottle ready at \(bottle.prefixURL.path).")

        // 3. Run `legendary install --base-path <bottle>/drive_c/Games`.
        do {
            try await EpicLibrary.install(
                appName: game.appName,
                intoBottle: bottle,
                onLine: { line in
                    Task { @MainActor in appendLog(line) }
                },
                onProgress: { pct in
                    Task { @MainActor in installProgress = pct }
                }
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // 4. Find the launch exe legendary placed.
        let exePathString: String
        do {
            exePathString = try await EpicLibrary.launchExePath(appName: game.appName)
        } catch {
            errorMessage = "Game installed but Carafe couldn't find the launch exe: \(error.localizedDescription)"
            return
        }
        appendLog("Launch exe: \(exePathString)")

        // 5. Register in Carafe's library.
        let exeURL = URL(fileURLWithPath: exePathString)
        guard let newGame = library.add(
            name: game.title,
            bottle: bottle,
            exeURL: exeURL,
            arguments: []
        ) else {
            errorMessage = library.lastError ?? "Couldn't add to library."
            return
        }
        var withEpic = newGame
        withEpic.epicAppName = game.appName
        library.update(withEpic)
        installedGame = withEpic

        installProgress = 1.0
        appendLog("Registered \(game.title) in your Carafe library.")
        phase = .finished
    }

    // MARK: - Finished

    @ViewBuilder
    private var finishedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            if let game = installedGame {
                Text("\(game.name) is in your library.")
                    .font(.title3.weight(.medium))
            }
            Text("It runs in a fresh Wine Staging bottle with DXMT as the graphics backend — the recommended combo for Epic titles.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(phase == .finished ? "Done" : "Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            switch phase {
            case .setup:
                Button("Continue") { Task { await runSetup() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
            case .auth:
                Button(actionButtonTitle(forAuth: true)) { Task { await runAuth() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(authButtonDisabled)
            case .library:
                Button("Install Game") { phase = .install; Task { await runInstall() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedGame == nil || isWorking)
            case .install:
                EmptyView()  // no manual advance during install
            case .finished:
                if installedGame != nil {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    private func actionButtonTitle(forAuth _: Bool) -> String {
        if case .loggedIn = epicAuth.status { return "Continue" }
        return "Continue"
    }

    private var authButtonDisabled: Bool {
        if isWorking { return true }
        if case .loggedIn = epicAuth.status { return false }
        // Continue is only meaningful in the manual-paste sub-step;
        // the `.idle` and `.attemptingImport` sub-steps drive
        // sign-in from the body (or are mid-action). Continue lights
        // up only once the user has typed something into the code
        // paste field.
        if authStep == .manualPaste {
            return codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    // MARK: - Helpers

    private func onAppear() async {
        if LegendaryInstaller.isInstalled {
            // Skip setup phase entirely.
            phase = .auth
            await epicAuth.refreshStatus()
        } else {
            phase = .setup
        }
    }

    @MainActor
    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > logCap {
            logLines.removeFirst(logLines.count - logCap)
        }
    }

    @ViewBuilder
    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(idx)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 240)
            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: logLines.count) { _, newCount in
                if newCount > 0 {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(8)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .fixedSize(horizontal: false, vertical: true)
    }
}
