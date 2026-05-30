import SwiftUI

struct CreateBottleSheet: View {
    @EnvironmentObject private var bottles: BottleManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// Caller-supplied default wine build. The Steam install flow
    /// pre-fills this to `.wineStaging`. When the caller doesn't
    /// pass anything we use `AppSettings.defaultWineBuild` (Settings
    /// → Defaults). The "did the caller override the AppSettings
    /// preference?" distinction is preserved with `Optional`: nil =
    /// "use AppSettings", non-nil = "use this verbatim".
    let initialWineBuild: WineBuild?

    init(initialWineBuild: WineBuild? = nil) {
        self.initialWineBuild = initialWineBuild
    }

    @State private var name: String = ""
    @State private var windowsVersion: WindowsVersion = .win10
    @State private var wineBuild: WineBuild = .gptk
    @State private var detectedGPTKVersion: String = "…"

    /// Set when an existing name collision is detected at submit time.
    @State private var inlineError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { form }
            Divider()
            footer
        }
        .frame(width: 520, height: 540)
        .task {
            detectedGPTKVersion = await bottles.detectWineVersion()
        }
        .onAppear {
            // Caller's explicit override wins; otherwise pull both
            // wine build and Windows version from AppSettings so the
            // form opens with the user's saved defaults pre-selected.
            wineBuild = initialWineBuild ?? settings.defaultWineBuild
            windowsVersion = settings.defaultWindowsVersion
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wineglass")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("New bottle").font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(16)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            nameSection
            wineBuildSection
            windowsVersionSection
            if let inlineError {
                Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(16)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.callout.weight(.medium))
            TextField("My Game", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Text("Used in the library list. You can change it later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var wineBuildSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wine build").font(.callout.weight(.medium))
            Picker("", selection: $wineBuild) {
                ForEach(WineBuild.allCases) { build in
                    Text(label(for: build)).tag(build)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // Per-build summary — different between GPTK and Wine Staging.
            Text(wineBuild.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Per-build install-status note (one-time download warning
            // for Wine Staging, plain "ready" for GPTK).
            HStack(spacing: 6) {
                Image(systemName: installedIconName)
                    .foregroundStyle(installedIconColor)
                Text(installedNote)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            // Spell out the canonical use cases.
            if wineBuild == .wineStaging {
                Text("Recommended for current Steam and any game that needs Wine 8+. Slightly slower graphics than GPTK.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func label(for build: WineBuild) -> String {
        switch build {
        case .gptk:        return "Standard (GPTK, Wine 7.7)"
        case .wineStaging: return "Steam-compatible (Wine Staging 11.9)"
        }
    }

    private var installedIconName: String {
        switch wineBuild {
        case .gptk:
            return WineRunner.isWineAvailable(for: .gptk)
                ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        case .wineStaging:
            return WineStagingInstaller.isInstalled
                ? "checkmark.seal.fill" : "arrow.down.circle"
        }
    }

    private var installedIconColor: Color {
        switch wineBuild {
        case .gptk:
            return WineRunner.isWineAvailable(for: .gptk) ? .green : .orange
        case .wineStaging:
            return WineStagingInstaller.isInstalled ? .green : .accentColor
        }
    }

    private var installedNote: String {
        switch wineBuild {
        case .gptk:
            return WineRunner.isWineAvailable(for: .gptk)
                ? "GPTK installed (\(detectedGPTKVersion))"
                : "GPTK not detected — re-run onboarding"
        case .wineStaging:
            return WineStagingInstaller.isInstalled
                ? "Wine Staging \(WineStagingInstaller.version) installed at \(WineStagingInstaller.installDirectory.path)"
                : "\(wineBuild.downloadSizeNote) — will install when you create this bottle"
        }
    }

    private var windowsVersionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Windows version").font(.callout.weight(.medium))
            Picker("", selection: $windowsVersion) {
                ForEach(WindowsVersion.allCases) { v in
                    Text(v.displayName).tag(v)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text("What this prefix reports to Windows apps. Most modern games expect Windows 10 or 11.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var footerNote: String {
        switch wineBuild {
        case .gptk:
            return "Initialization takes about 30 seconds."
        case .wineStaging:
            return WineStagingInstaller.isInstalled
                ? "Initialization takes about 30 seconds."
                : "First-time setup: ~5 minutes (download + extract Wine Staging, then init the prefix)."
        }
    }

    /// Wine version label saved on the bottle for display purposes.
    private var wineVersionLabel: String {
        switch wineBuild {
        case .gptk:        return detectedGPTKVersion
        case .wineStaging: return "wine-staging-\(WineStagingInstaller.version)"
        }
    }

    /// Pick the graphics backend the new bottle should start with.
    ///
    /// Rules, in order:
    ///   1. If the bottle is Wine Staging AND the user hasn't moved
    ///      the AppSettings default away from D3DMetal, use DXMT —
    ///      it's empirically the best fit for Wine Staging (Metal-
    ///      native, no Vulkan hop, modern Wine API surface).
    ///   2. Otherwise use whatever the user set in
    ///      Settings → Defaults.
    ///
    /// Trade-off (rule 1's heuristic): "user explicitly picked
    /// D3DMetal in Settings" is indistinguishable from "user never
    /// touched Settings". That collision matters very little —
    /// picking D3DMetal as the global default while creating
    /// wine-staging bottles is an unusual combination, and the per-
    /// bottle/per-game compat config can still override per-launch.
    private var effectiveGraphicsBackend: GraphicsBackend {
        if wineBuild == .wineStaging && settings.defaultGraphicsBackend == .d3dMetal {
            return .dxmt
        }
        return settings.defaultGraphicsBackend
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inlineError = "Name can't be empty."
            return
        }
        Task {
            await bottles.create(
                name: trimmed,
                windowsVersion: windowsVersion,
                wineVersion: wineVersionLabel,
                wineBuild: wineBuild,
                graphicsBackend: effectiveGraphicsBackend
            )
        }
        dismiss()
    }
}
