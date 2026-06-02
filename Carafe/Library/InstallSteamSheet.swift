import SwiftUI
import AppKit

/// Multi-phase sheet for installing Steam's Windows client into a
/// bottle. Pipeline: vcrun2022 → SteamSetup.exe download → silent
/// install → verification. After success, offers a "Launch Steam"
/// button so the user can sign in immediately.
struct InstallSteamSheet: View {
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .picker
    @State private var selectedBottleID: UUID?
    @StateObject private var progress = SteamInstallProgress()

    /// Non-nil triggers an alert. Used for the "Launch Steam" action
    /// so that silent spawn failures aren't lost in the log.
    @State private var launchError: String?

    /// Drives a sheet that opens CreateBottleSheet pre-seeded with
    /// `.wineStaging` when the user clicks "Create new
    /// Steam-compatible bottle".
    @State private var showingCreateSteamBottle: Bool = false

    enum Phase: Equatable {
        case picker
        case running
        case finished
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 720, height: 600)
        .onAppear {
            if selectedBottleID == nil {
                selectedBottleID = eligibleBottles.first?.id
            }
        }
        .alert(
            "Couldn't launch Steam",
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            ),
            presenting: launchError
        ) { _ in
            Button("OK", role: .cancel) { launchError = nil }
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showingCreateSteamBottle) {
            // Pre-seed wineStaging so the user can't accidentally
            // create another GPTK bottle through this entry point.
            CreateBottleSheet(initialWineBuild: .wineStaging)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install Steam").font(.title3.weight(.semibold))
                Text(headerSubtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        switch phase {
        case .picker: return "Pick a bottle to install Steam's Windows client into."
        case .running: return "Installing — this can take 5–10 minutes."
        case .finished:
            if progress.success {
                return "Steam is installed. Launch it to sign in and download your library."
            }
            return "Install didn't finish cleanly. See the log for details."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .picker:    pickerView
        case .running:   runningView
        case .finished:  runningView
        }
    }

    // MARK: - Picker

    private var eligibleBottles: [Bottle] {
        // Surface every valid bottle, but sort so Wine Staging
        // bottles appear first — they're what the user actually
        // wants. GPTK bottles still show, but with a warning label.
        bottles.entries.compactMap(\.validBottle).sorted { lhs, rhs in
            if lhs.wineBuild != rhs.wineBuild {
                return lhs.wineBuild == .wineStaging
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introCard
                    bottlePicker
                    planCard
                }
                .padding(16)
            }
            Divider()
            pickerFooter
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this does").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                bullet("Installs the Microsoft Visual C++ 2022 runtime (~25 MB).")
                bullet("Downloads SteamSetup.exe (~3 MB) and runs it silently.")
                bullet("Steam itself updates on first launch — that's ~500 MB of network traffic when you sign in.")
            }
            Text("Use the known-good configuration for Steam: Windows 10, MSYNC, D3DMetal. Single-player games (no kernel anti-cheat) generally work; multiplayer games protected by Vanguard / EAC / Battleye will not.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint).font(.caption)
                .padding(.top, 2)
            Text(text).font(.callout)
            Spacer()
        }
    }

    private var bottlePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bottle").font(.callout.weight(.medium))
                Spacer()
                Button {
                    showingCreateSteamBottle = true
                } label: {
                    Label("Create new Steam-compatible bottle…", systemImage: "plus")
                }
                .controlSize(.small)
                .help("Opens the Create Bottle sheet pre-set to Wine Staging 11.9.")
            }
            if eligibleBottles.isEmpty {
                Label("No bottles available. Use the button above to create a Steam-compatible bottle.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Picker("", selection: $selectedBottleID) {
                    ForEach(eligibleBottles) { b in
                        Text(pickerLabel(for: b))
                            .tag(Optional(b.id))
                    }
                }
                .labelsHidden().pickerStyle(.menu)

                // Per-selected-bottle advisory copy.
                bottleAdvisory
            }
        }
    }

    /// "<name> — Wine Staging" / "<name> — GPTK ⚠ Wine 7.7"
    private func pickerLabel(for b: Bottle) -> String {
        var s = "\(b.name) — \(b.wineBuild.shortName)"
        if b.wineBuild == .gptk {
            s += " ⚠ Wine 7.7"
        }
        if SteamLibraryScanner.hasSteam(in: b) {
            s += " · Steam installed"
        }
        return s
    }

    @ViewBuilder
    private var bottleAdvisory: some View {
        if let bottle = selectedBottle {
            VStack(alignment: .leading, spacing: 4) {
                if bottle.wineBuild == .gptk {
                    // Loud warning — this is the case the user
                    // burned three milestones discovering.
                    Label(
                        "GPTK bottles use Wine 7.7, which can't bootstrap current Steam. Steam will install but the CEF helper download (step 6) won't complete — Steam stays unusable. Use the button above to create a Wine Staging bottle instead.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Label(
                        "Wine Staging \(WineStagingInstaller.version) — recommended for Steam.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                }
                if SteamLibraryScanner.hasSteam(in: bottle) {
                    Text("This bottle already has Steam at the canonical path. Re-running is harmless and useful for re-applying Steam UI fixes after a Steam update.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan").font(.headline)
            ForEach(SteamInstallProgress.Step.allCases) { step in
                HStack(spacing: 8) {
                    Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
                    Text(step.rawValue).font(.callout)
                    Spacer()
                    Text(planNote(for: step))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func planNote(for step: SteamInstallProgress.Step) -> String {
        switch step {
        case .vcRuntime:
            if let bottle = selectedBottle {
                if bottle.installedComponents.contains("vcrun2022") {
                    return "vcrun2022 already installed — will skip"
                }
                if bottle.installedComponents.contains("vcrun2019") {
                    return "vcrun2019 already installed — will skip"
                }
            }
            return "~25 MB, ~3 min"
        case .nocrashdialog:
            return "winetricks verb, ~5 s — non-fatal"
        case .download:
            if SteamInstaller.isInstallerCached { return "cached — will skip" }
            return "~3 MB"
        case .runInstaller:
            return "~30 s"
        case .verify:
            return "<1 s"
        case .disableWebHelper:
            if selectedBottle?.wineBuild == .wineStaging {
                return "modern CEF UI fixes"
            }
            return "legacy fallback for GPTK"
        case .firstLaunchBootstrap:
            if selectedBottle?.wineBuild == .wineStaging {
                return "not needed on Wine Staging"
            }
            return "GPTK only: downloads CEF before rename"
        }
    }

    private var pickerFooter: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Install Steam") { startInstall() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBottle == nil
                          || (selectedBottle.map { !WineRunner.isWineAvailable(for: $0.wineBuild) } ?? true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var selectedBottle: Bottle? {
        eligibleBottles.first { $0.id == selectedBottleID }
    }

    // MARK: - Running / Finished

    private var runningView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(SteamInstallProgress.Step.allCases) { step in
                            stepRow(step)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .frame(width: 260)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                logHeader
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(progress.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: progress.logLines.count) { _, _ in
                        if let last = progress.logLines.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                Divider()
                runningFooter
            }
        }
    }

    private func stepRow(_ step: SteamInstallProgress.Step) -> some View {
        HStack(alignment: .top, spacing: 6) {
            stateIcon(progress.states[step] ?? .pending).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.rawValue).font(.caption)
                if case .failed(let reason) = progress.states[step] {
                    Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(3)
                } else if case .warning(let note) = progress.states[step] {
                    Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                } else if case .skipped(let why) = progress.states[step] {
                    Text(why).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: SteamInstallProgress.StepState) -> some View {
        switch state {
        case .pending:   Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:   ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:   Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
        case .warning:   Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var logHeader: some View {
        HStack {
            Text("Log").font(.caption.weight(.semibold))
            Spacer()
            Button("Copy log") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(progress.logLines.joined(separator: "\n"), forType: .string)
            }
            .controlSize(.small)
            .disabled(progress.logLines.isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private var runningFooter: some View {
        HStack {
            Spacer()
            if progress.isFinished {
                if progress.success {
                    Button("Launch Steam to sign in") { launchSteam() }
                        .buttonStyle(.bordered)
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func startInstall() {
        guard let bottle = selectedBottle else { return }
        phase = .running
        Task { await runPipeline(bottle: bottle) }
    }

    private func runPipeline(bottle: Bottle) async {
        let appendLog: @Sendable (String) -> Void = { line in
            Task { @MainActor in progress.appendLog(line) }
        }

        // Step 1: VC runtime (vcrun2022 unless vcrun2019 is already
        // present and equivalent — see SteamInstaller's FRAGILITY note).
        progress.setState(.running, for: .vcRuntime)
        do {
            let didInstall = try await SteamInstaller.ensureVCRuntimeInstalled(
                in: bottle, log: appendLog
            )
            if didInstall {
                bottles.markComponentsInstalled(["vcrun2022"], in: bottle)
                progress.setState(.succeeded, for: .vcRuntime)
            } else if bottle.installedComponents.contains("vcrun2019") {
                progress.setState(.skipped("vcrun2019 already covers this"), for: .vcRuntime)
            } else {
                progress.setState(.skipped("already installed"), for: .vcRuntime)
            }
        } catch {
            progress.setState(.failed(error.localizedDescription), for: .vcRuntime)
            finish(success: false)
            return
        }

        // Step 1.5: nocrashdialog (winetricks verb).
        //
        // Part of the canonical Steam-on-Wine workaround set from
        // Winetricks PR #1975 — disables wine's modal crash dialog
        // because `vulkandriverquery` / `vulkandriverquery64` crash
        // a lot on macOS and the dialog would block any game launch.
        //
        // Non-fatal: if winetricks isn't available or the verb fails,
        // record a warning and continue. Steam itself still works;
        // the user will just see wine crash dialogs occasionally
        // until they install nocrashdialog manually.
        progress.setState(.running, for: .nocrashdialog)
        if !WinetricksRunner.isInstalled {
            progress.setState(
                .warning("winetricks not installed — skipping. Wine crash dialogs may pop up during gameplay; not blocking."),
                for: .nocrashdialog
            )
        } else if bottle.installedComponents.contains("nocrashdialog") {
            progress.setState(.skipped("already applied"), for: .nocrashdialog)
        } else {
            do {
                try await WinetricksRunner.installVerb("nocrashdialog", in: bottle, log: appendLog)
                bottles.markComponentsInstalled(["nocrashdialog"], in: bottle)
                progress.setState(.succeeded, for: .nocrashdialog)
            } catch {
                progress.setState(
                    .warning("nocrashdialog failed: \(error.localizedDescription) — non-fatal, continuing."),
                    for: .nocrashdialog
                )
            }
        }

        // Step 2: download
        progress.setState(.running, for: .download)
        let installerURL: URL
        do {
            installerURL = try await SteamInstaller.ensureInstallerDownloaded(log: appendLog)
            progress.setState(.succeeded, for: .download)
        } catch {
            progress.setState(.failed(error.localizedDescription), for: .download)
            finish(success: false)
            return
        }

        // Step 3: run installer
        progress.setState(.running, for: .runInstaller)
        do {
            try await SteamInstaller.runInstaller(installerURL: installerURL, in: bottle, log: appendLog)
            progress.setState(.succeeded, for: .runInstaller)
        } catch {
            progress.setState(.failed(error.localizedDescription), for: .runInstaller)
            finish(success: false)
            return
        }

        // Step 4: verify
        progress.setState(.running, for: .verify)
        guard SteamLibraryScanner.hasSteam(in: bottle) else {
            progress.setState(.failed("Steam.exe missing at canonical path"), for: .verify)
            finish(success: false)
            return
        }
        progress.setState(.succeeded, for: .verify)

        // Step 5: Steam UI workaround.
        //
        // Wine Staging can run current Steam's CEF UI if we disable
        // the broken GPU / DirectComposition paths. GPTK's Wine 7.7
        // remains too old, so only GPTK keeps the legacy webhelper
        // rename fallback.
        progress.setState(.running, for: .disableWebHelper)
        var needsLegacyBootstrap = false
        if bottle.wineBuild == .wineStaging {
            do {
                try await SteamInstaller.configureModernSteamUIWorkarounds(
                    in: bottle, log: appendLog
                )
                progress.setState(.succeeded, for: .disableWebHelper)
            } catch {
                progress.setState(
                    .warning("Couldn't persist Steam UI workaround: \(error.localizedDescription). Launch will still try runtime flags."),
                    for: .disableWebHelper
                )
            }
        } else {
            let webHelperResult = SteamInstaller.disableSteamWebHelper(
                in: bottle, log: appendLog
            )
            switch webHelperResult {
            case .disabled:
                progress.setState(.succeeded, for: .disableWebHelper)
            case .alreadyDisabled:
                progress.setState(.skipped("already disabled"), for: .disableWebHelper)
            case .notFound:
                needsLegacyBootstrap = true
                progress.setState(
                    .skipped("not present yet — step 6 will trigger Steam to download it"),
                    for: .disableWebHelper
                )
            }
        }

        // Step 6: first-launch CEF bootstrap. Wine Staging no longer
        // needs this because it keeps modern CEF enabled; GPTK still
        // uses it to provoke Steam's lazy download before renaming
        // steamwebhelper.
        progress.setState(.running, for: .firstLaunchBootstrap)
        if bottle.wineBuild == .wineStaging {
            progress.setState(
                .skipped("Wine Staging uses modern Steam UI mode"),
                for: .firstLaunchBootstrap
            )
        } else if !needsLegacyBootstrap {
            progress.setState(
                .skipped("step 5 already handled the legacy UI fallback"),
                for: .firstLaunchBootstrap
            )
        } else {
            let bootstrapResult = await SteamInstaller.performFirstLaunchCEFBootstrap(
                in: bottle, log: appendLog
            )
            switch bootstrapResult {
            case .disabled:
                progress.setState(.succeeded, for: .firstLaunchBootstrap)
            case .alreadyDisabled:
                progress.setState(.skipped("already disabled"), for: .firstLaunchBootstrap)
            case .notFound:
                progress.setState(
                    .warning("Timed out waiting for Steam to download steamwebhelper.exe. Launch Steam manually below and re-run if it crashes."),
                    for: .firstLaunchBootstrap
                )
            }
        }

        finish(success: true)
    }

    private func finish(success: Bool) {
        progress.success = success
        progress.isFinished = true
        phase = .finished
    }

    private func launchSteam() {
        guard let bottle = selectedBottle else {
            launchError = "No bottle selected."
            return
        }
        do {
            try SteamInstaller.launchSteamGUI(in: bottle)
            progress.appendLog(
                "Launched Steam GUI in bottle \(bottle.name). First-launch updates take 5–15 minutes — sign in once Steam stops self-updating."
            )
        } catch {
            let msg = error.localizedDescription
            progress.appendLog("⛔ Launch failed: \(msg)")
            // Surface to the user via alert in addition to the log so
            // the failure isn't lost off-screen.
            launchError = msg
        }
    }
}

// MARK: - Progress model

@MainActor
final class SteamInstallProgress: ObservableObject {
    enum Step: String, CaseIterable, Identifiable {
        case vcRuntime           = "Visual C++ 2022 runtime"
        case nocrashdialog       = "Suppress wine crash dialog"
        case download            = "Download SteamSetup.exe"
        case runInstaller        = "Run installer (silent)"
        case verify              = "Verify Steam.exe"
        case disableWebHelper    = "Configure Steam UI"
        case firstLaunchBootstrap = "Legacy CEF bootstrap"

        var id: String { rawValue }
    }

    enum StepState: Equatable {
        case pending
        case running
        case succeeded
        case skipped(String)
        case warning(String)
        case failed(String)
    }

    @Published var states: [Step: StepState] = Dictionary(
        uniqueKeysWithValues: Step.allCases.map { ($0, .pending) }
    )
    @Published var logLines: [String] = []
    @Published var isFinished: Bool = false
    @Published var success: Bool = false

    private let logCap = 5_000

    func setState(_ state: StepState, for step: Step) {
        states[step] = state
    }

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > logCap {
            logLines.removeFirst(logLines.count - logCap)
        }
    }
}
