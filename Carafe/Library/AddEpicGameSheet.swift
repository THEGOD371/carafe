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

    /// User's paste of the SID code from the Epic login redirect.
    @State private var sidInput: String = ""

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
                    // ---- Step 1: open the SID URL directly ----
                    //
                    // The redirect URL handles BOTH the signed-in
                    // and signed-out cases natively:
                    //   * signed in → Epic immediately appends a
                    //     fresh ?sid=<value> and lands on the store.
                    //   * signed out → Epic shows its login page,
                    //     then completes the redirect once the user
                    //     signs in. Either way, the user ends up on
                    //     a normal page with the SID in the address
                    //     bar. No reason to make this a two-step
                    //     dance for the (much more common) already-
                    //     signed-in path.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Step 1 — Open the SID URL in your browser",
                              systemImage: "1.circle.fill")
                            .font(.callout.weight(.semibold))
                        Text("Click below. If you're already signed in to Epic, your browser lands on the Epic store with `?sid=…` appended to the address bar. If you aren't signed in, Epic prompts you first, then completes the redirect.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button {
                                epicAuth.openSIDRedirect()
                            } label: {
                                Label("Open SID URL", systemImage: "safari")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    EpicAuth.sidRedirectURL.absoluteString,
                                    forType: .string
                                )
                            } label: {
                                Label("Copy URL", systemImage: "doc.on.clipboard")
                            }
                            .disabled(isWorking)
                            .help("Copy the URL if you'd rather paste it into a different browser.")
                        }

                        // Escape hatch: the rare user who wants to
                        // switch accounts before grabbing a SID.
                        // Renders as small secondary text so it
                        // doesn't compete with the primary button.
                        Button {
                            epicAuth.openLoginPage()
                        } label: {
                            Text("Need to switch Epic accounts first? Open the login page →")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.link)
                        .disabled(isWorking)
                        .padding(.top, 4)
                    }

                    Divider()

                    // ---- Step 2: paste the resulting URL back in here ----
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Step 2 — Paste the resulting URL back here",
                              systemImage: "2.circle.fill")
                            .font(.callout.weight(.semibold))
                        Text("Copy the ENTIRE URL from your browser's address bar after Step 1 lands. It will look like `https://www.epicgames.com/store/en-US/?sid=…`. Carafe extracts the SID automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField(
                            "https://www.epicgames.com/store/en-US/?sid=…",
                            text: $sidInput,
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .disabled(isWorking)

                        // Live feedback so the user knows whether
                        // their paste produced a valid SID before
                        // they click Continue.
                        sidExtractionHint
                    }
                }

                if let err = errorMessage {
                    errorBanner(err)
                }
            }
            .padding(16)
        }
    }

    private func runAuth() async {
        if case .loggedIn = epicAuth.status {
            phase = .library
            await loadOwnedGames()
            return
        }
        guard !isWorking else { return }
        // Pull the SID out of whatever the user pasted (full URL or
        // bare token). `authButtonDisabled` already gates this, so
        // extraction normally succeeds — but be defensive in case
        // they tab past the disabled check.
        guard let sid = EpicAuth.extractSID(from: sidInput) else {
            errorMessage = "Couldn't find a SID value in what you pasted. Paste the full URL from your browser's address bar — it should contain `?sid=…`."
            return
        }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            try await epicAuth.completeLogin(sid: sid)
            sidInput = ""
            phase = .library
            await loadOwnedGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Live feedback below the SID paste field. Renders one of:
    ///   * Nothing (empty input)
    ///   * Green "extracted SID: …" when the parser found one
    ///   * Orange "couldn't find a SID" hint otherwise
    @ViewBuilder
    private var sidExtractionHint: some View {
        let trimmed = sidInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else if let extracted = EpicAuth.extractSID(from: trimmed) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("SID found: ")
                    .font(.caption).foregroundStyle(.secondary)
                Text(extracted)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't find `sid=…` in that text. Make sure you copied the URL *after* the step-2 redirect lands on the Epic store page.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        // Require a parseable SID before Continue lights up — the
        // user gets live feedback below the field about whether
        // their paste worked.
        return EpicAuth.extractSID(from: sidInput) == nil
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
