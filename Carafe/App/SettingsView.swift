import SwiftUI
import AppKit

/// The macOS-native Settings window. Lives inside the
/// `Settings { ... }` scene defined in `CarafeApp` — Cmd+, opens it,
/// and the toolbar gear in `MainShell` triggers it via the
/// `openSettings` environment value.
///
/// Four tabs:
///   - General   — appearance theme, telemetry opt-in + SteamGridDB
///                 API key shortcut
///   - Defaults  — Wine build, Windows version, Graphics backend
///                 (used to pre-seed new bottles)
///   - Storage   — bottles directory override + migrate flow
///   - About     — version, GitHub, acknowledgements, debug-reset
struct SettingsView: View {
    private enum Tab: Hashable {
        case general, defaults, storage, about
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(Tab.general)

            DefaultsTab()
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
                .tag(Tab.defaults)

            StorageTab()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(Tab.storage)

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showingAPIKeys = false

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $settings.appearanceTheme) {
                    ForEach(AppearanceTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                Text(settings.appearanceTheme.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Appearance")
            }

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SteamGridDB API key")
                            .font(.callout.weight(.medium))
                        Text("Used to fetch game cover art. Free; stored in your Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage…") {
                        showingAPIKeys = true
                    }
                }
            } header: {
                Text("Integrations")
            }

            Section {
                Toggle(isOn: $settings.telemetryEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send anonymous crash reports and usage stats")
                            .font(.callout)
                        Text("Off by default. No personally identifying information is sent. You can change this at any time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                // FRAGILITY note (UI-side mirror of AppSettings):
                // the flag is wired but no telemetry pipe exists yet.
                // The toggle's effect is "store the preference" only.
                Text("Carafe doesn't currently send any telemetry — this preference will gate the future crash-reporting integration.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAPIKeys) {
            APIKeysSheet()
        }
    }
}

// MARK: - Defaults tab

private struct DefaultsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Wine build", selection: $settings.defaultWineBuild) {
                    ForEach(WineBuild.allCases) { build in
                        Text(build.displayName).tag(build)
                    }
                }
                Text(settings.defaultWineBuild.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Default Wine build for new bottles")
            } footer: {
                Text("Used to pre-fill the picker when you create a bottle. Existing bottles are not affected — Wine build is fixed at bottle creation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Windows version", selection: $settings.defaultWindowsVersion) {
                    ForEach(WindowsVersion.allCases) { v in
                        Text(v.displayName).tag(v)
                    }
                }
            } header: {
                Text("Default Windows version")
            } footer: {
                Text("What new bottles report to Windows apps. Most modern games expect Windows 10 or 11.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Graphics backend", selection: $settings.defaultGraphicsBackend) {
                    ForEach(GraphicsBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(settings.defaultGraphicsBackend.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Default graphics backend")
            } footer: {
                Text("Per-bottle and per-game overrides take precedence. DXVK requires the `dxvk` winetricks verb in the bottle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage tab

private struct StorageTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bottles: BottleManager

    /// State for the migrate-bottles flow. `.idle` is the resting
    /// state. `.confirming` shows the alert. `.running` shows a
    /// progress UI. `.done` shows a success row. `.failed` shows the
    /// error inline; user can retry or dismiss.
    @State private var migrate: MigrateState = .idle

    private enum MigrateState: Equatable {
        case idle
        case confirming(source: URL, destination: URL, count: Int)
        case running
        case done(moved: Int, destination: URL)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if settings.isBottlesLocationDefault {
                            Text("Default location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if settings.isBottlesLocationMissing {
                            Label("Override path is unreachable — Carafe is falling back to the default", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Custom location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button("Choose…", action: chooseLocation)
                    if !settings.isBottlesLocationDefault {
                        Button("Reset to default") {
                            settings.bottlesLocationOverride = nil
                            Task { await bottles.refresh() }
                        }
                    }
                    Button("Open in Finder", action: openInFinder)
                    Spacer()
                }
            } header: {
                Text("Bottles location")
            } footer: {
                Text("Where Carafe stores its Wine prefixes. Each bottle can be tens of GB once games are installed — moving to an external drive is a common reason to change this.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Migrate section only shown when the user has set a
            // custom location AND the default location still has
            // bottles in it — i.e. there's something to move.
            if shouldOfferMigrate {
                Section {
                    migrateRow
                } header: {
                    Text("Move existing bottles")
                } footer: {
                    Text("Moves bottle folders from the default location to your chosen location. Carafe will refresh the bottle list afterward. **Quit any running games first.**")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    NSWorkspace.shared.open(AppState.supportDirectory)
                } label: {
                    Label("Open Carafe data folder", systemImage: "folder")
                }
            } header: {
                Text("Application data")
            } footer: {
                Text("\(AppState.supportDirectory.path) — contains bottles, downloaded Wine builds, cover art cache, and logs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .alert("Move existing bottles?", isPresented: confirmingBinding, presenting: confirmingPayload) { payload in
            Button("Cancel", role: .cancel) { migrate = .idle }
            Button("Move \(payload.count) bottle\(payload.count == 1 ? "" : "s")") {
                runMigrate(source: payload.source, destination: payload.destination)
            }
        } message: { payload in
            Text("Carafe will move \(payload.count) bottle folder\(payload.count == 1 ? "" : "s") from\n\(payload.source.path)\nto\n\(payload.destination.path)\n\nMake sure no games are running. If a game complains about a missing path after the move, open winecfg for that bottle once to refresh its registry.")
        }
    }

    private var currentPath: String {
        if let override = settings.bottlesLocationOverride {
            return override.path
        }
        return AppState.defaultBottlesDirectory.path
    }

    private var shouldOfferMigrate: Bool {
        guard let override = settings.bottlesLocationOverride else { return false }
        // Skip the migrate row when the override IS the default (e.g.
        // user picked the same folder) or when no bottles exist at
        // the default location.
        guard override != AppState.defaultBottlesDirectory else { return false }
        return countBottles(in: AppState.defaultBottlesDirectory) > 0
    }

    @ViewBuilder
    private var migrateRow: some View {
        switch migrate {
        case .idle, .confirming:
            HStack {
                Text("\(countBottles(in: AppState.defaultBottlesDirectory)) bottle folder(s) still in the default location.")
                    .font(.callout)
                Spacer()
                Button("Move now…") {
                    let src = AppState.defaultBottlesDirectory
                    let dst = settings.bottlesLocationOverride ?? AppState.defaultBottlesDirectory
                    let n = countBottles(in: src)
                    migrate = .confirming(source: src, destination: dst, count: n)
                }
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Moving bottles…").font(.callout)
            }
        case .done(let n, let dest):
            Label("Moved \(n) bottle\(n == 1 ? "" : "s") to \(dest.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let detail):
            VStack(alignment: .leading, spacing: 4) {
                Label("Move failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { migrate = .idle }
            }
        }
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirming = migrate { return true }
                return false
            },
            set: { newValue in
                if !newValue { migrate = .idle }
            }
        )
    }

    /// Payload type for the alert's `presenting:` parameter — pulling
    /// the associated values out of the enum case in one place keeps
    /// the alert closure tidy.
    private struct ConfirmPayload {
        let source: URL
        let destination: URL
        let count: Int
    }

    private var confirmingPayload: ConfirmPayload? {
        if case let .confirming(source, destination, count) = migrate {
            return ConfirmPayload(source: source, destination: destination, count: count)
        }
        return nil
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder where Carafe should store bottle prefixes."
        if panel.runModal() == .OK, let url = panel.url {
            settings.bottlesLocationOverride = url
            Task { await bottles.refresh() }
        }
    }

    private func openInFinder() {
        let url: URL
        if settings.isBottlesLocationDefault || settings.isBottlesLocationMissing {
            url = AppState.defaultBottlesDirectory
        } else {
            url = settings.bottlesLocationOverride ?? AppState.defaultBottlesDirectory
        }
        NSWorkspace.shared.open(url)
    }

    /// Sequential, main-actor move. The migration itself runs on a
    /// background thread (Task.detached) so the UI stays responsive
    /// for the progress spinner; once it returns we refresh the
    /// bottle list and surface the result.
    private func runMigrate(source: URL, destination: URL) {
        migrate = .running
        Task {
            do {
                let moved = countBottles(in: source)
                try await Task.detached {
                    try AppSettings.migrateBottles(from: source, to: destination)
                }.value
                await bottles.refresh()
                migrate = .done(moved: moved, destination: destination)
            } catch {
                migrate = .failed(error.localizedDescription)
            }
        }
    }

    private func countBottles(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.count
    }
}

// MARK: - About tab

private struct AboutTab: View {
    @EnvironmentObject private var appState: AppState

    private static let githubURL = URL(string: "https://github.com/THEGOD371/carafe")!

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "wineglass.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Carafe").font(.title.weight(.semibold))
                        Text(versionLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Run Windows games on Apple Silicon with Wine + GPTK.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                Link(destination: Self.githubURL) {
                    Label("github.com/THEGOD371/carafe", systemImage: "link")
                }
                .font(.callout)
            }

            Section {
                ack("Wine", subtitle: "winehq.org", url: URL(string: "https://www.winehq.org")!)
                ack("Apple Game Porting Toolkit", subtitle: "Apple — the Wine + D3DMetal build that makes most of this possible.", url: nil)
                ack("Gcenx — macOS_Wine_builds", subtitle: "Pre-built Wine Staging packages for Apple Silicon.", url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!)
                ack("Winetricks", subtitle: "The component installer that fills in vcrun, dotnet, dxvk, fonts, and the Steam workaround set.", url: URL(string: "https://github.com/Winetricks/winetricks")!)
                ack("SteamGridDB", subtitle: "Cover art for the game library.", url: URL(string: "https://www.steamgriddb.com")!)
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("Carafe is MIT-licensed. It is not affiliated with or endorsed by Apple, Valve, CodeWeavers, Wine, or any other project listed above.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    appState.onboardingComplete = false
                } label: {
                    Label("Re-run onboarding", systemImage: "arrow.uturn.backward")
                }
                Text("Useful if a dependency check went wrong and you want to step through Rosetta / Xcode CLT / GPTK installation again. Your bottles and games are not affected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Troubleshooting")
            }
        }
        .formStyle(.grouped)
    }

    /// Reads `CFBundleShortVersionString` (the marketing version, e.g.
    /// "0.1.0") and `CFBundleVersion` (the build number, e.g. "1")
    /// from Info.plist. Falls back to "dev" labels when launched
    /// from a debug build that hasn't been versioned.
    private var versionLine: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (build \(build))"
    }

    @ViewBuilder
    private func ack(_ title: String, subtitle: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                if let url {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .help(url.absoluteString)
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
