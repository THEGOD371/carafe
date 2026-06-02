import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Combined Add / Edit sheet for library entries. Keyed by `mode`:
///   - `.add` → blank form, "Add to Library" button
///   - `.edit(Game)` → fields pre-filled, "Save changes" button
struct GameFormSheet: View {
    enum Mode: Hashable {
        case add
        case edit(Game)

        var isEdit: Bool {
            if case .edit = self { return true }
            return false
        }
    }

    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    // MARK: - Form state

    @State private var name: String = ""
    @State private var selectedBottleID: UUID?
    @State private var exeURL: URL?
    @State private var argumentsText: String = ""
    @State private var coverArtFilename: String?
    @State private var inlineError: String?

    /// Recognised launcher profile, if the picked exe matched an
    /// entry in KnownLaunchers.json. Updated on every change to
    /// `exeURL`.
    @State private var detectedLauncher: LauncherProfile?

    /// Compat overrides queued for application to the game when the
    /// form submits. Non-nil only after the user clicks Apply in
    /// the recognise-card. nil = no auto-apply happened (or the
    /// user chose Dismiss).
    @State private var pendingCompatOverrides: GameCompatOverrides?

    /// True once the user has chosen to dismiss the recognise-card
    /// for the current detection. Prevents the card from re-
    /// appearing on every re-render after dismissal.
    @State private var dismissedDetection: Bool = false

    @State private var showingCoverPicker = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coverArtRow
                    nameRow
                    bottleRow
                    exeRow
                    knownLauncherCard
                    argsRow
                    if let inlineError {
                        Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .onAppear(perform: bootstrapState)
        .sheet(isPresented: $showingCoverPicker) {
            CoverArtPickerSheet(
                searchSeed: name,
                gameID: currentGameID,
                onSelectedFilename: { filename in
                    coverArtFilename = filename
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.isEdit ? "pencil" : "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(mode.isEdit ? "Edit game" : "Add game")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Cover art preview row

    private var coverArtRow: some View {
        HStack(spacing: 14) {
            previewCover
                .frame(width: 70, height: 105)
            VStack(alignment: .leading, spacing: 6) {
                Text("Cover art").font(.callout.weight(.medium))
                Text(
                    coverArtFilename == nil
                        ? "No art yet — a placeholder with the game's initials will be shown."
                        : "Cached locally. Click to choose a different cover."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button(coverArtFilename == nil ? "Search SteamGridDB…" : "Change…") {
                        showingCoverPicker = true
                    }
                    Button("Use local image…", action: pickLocalImage)
                    if coverArtFilename != nil {
                        Button("Remove", role: .destructive) {
                            coverArtFilename = nil
                        }
                        .controlSize(.small)
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var previewCover: some View {
        // Render with a transient Game so CoverArtView can take the
        // local file URL or fall back to the placeholder using the
        // current form name.
        let previewGame = Game(
            id: currentGameID ?? UUID(),
            name: name.isEmpty ? "?" : name,
            bottleID: selectedBottleID ?? UUID(),
            exePath: .absolute(exeURL?.path ?? ""),
            arguments: [],
            coverArtFilename: coverArtFilename,
            customIconFilename: nil,
            lastPlayedAt: nil,
            totalPlaytime: 0,
            addedAt: Date()
        )
        let coverURL: URL? = coverArtFilename.map {
            GameLibrary.coverArtDirectory.appendingPathComponent($0)
        }
        CoverArtView(game: previewGame, coverURL: coverURL)
    }

    // MARK: - Form rows

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.callout.weight(.medium))
            TextField("e.g. Half-Life", text: $name)
                .textFieldStyle(.roundedBorder)
            if mode == .add {
                Text("Auto-filled from the exe filename. Edit anything you like.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var bottleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bottle").font(.callout.weight(.medium))
            Picker("", selection: $selectedBottleID) {
                ForEach(validBottles) { bottle in
                    Text(bottle.name).tag(Optional(bottle.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text("The exe runs inside this bottle's Wine prefix.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Known launcher recognition card

    /// Renders the "we recognise this launcher" card when:
    ///   * the picked exe matched a KnownLaunchers.json profile, AND
    ///   * the user hasn't dismissed the card for the current detection.
    /// Hidden when nothing was detected or when fixes are already
    /// applied (in which case we show a smaller "applied" status).
    @ViewBuilder
    private var knownLauncherCard: some View {
        if let profile = detectedLauncher, !dismissedDetection {
            if pendingCompatOverrides != nil {
                // Compact confirmation row after the user applied.
                Label(
                    "Compatibility fixes for \(profile.displayName) will be saved with the game.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)
                .padding(10)
                .background(Color.green.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                detectionPrompt(profile: profile)
            }
        }
    }

    @ViewBuilder
    private func detectionPrompt(profile: LauncherProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Looks like **\(profile.displayName)**'s launcher.")
                        .font(.callout.weight(.medium))
                    if let publisher = profile.publisher {
                        Text(publisher).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                confidenceBadge(for: profile.fix.confidence)
            }

            if !profile.appliedFixSummary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Carafe can auto-apply:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(profile.appliedFixSummary, id: \.self) { line in
                        Text("• \(line)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            if let verbs = profile.fix.winetricksVerbs, !verbs.isEmpty {
                Text("Recommended winetricks verbs to install via the bottle's Components sheet: **\(verbs.joined(separator: ", "))**.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let skipTo = profile.fix.skipLauncherTo {
                Text("Tip: the launcher is usually only needed for updates/downloads. Once the game files exist, Carafe can switch this entry to `\(skipTo)` and launch the game directly.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                if let target = resolvedKnownLauncherTarget(for: profile) {
                    Button {
                        exeURL = target
                        detectedLauncher = KnownLaunchers.match(exeURL: target)
                        dismissedDetection = true
                    } label: {
                        Label("Use game executable now", systemImage: "arrow.triangle.branch")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(target.path)
                }
            }

            if let notes = profile.fix.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    applyKnownFix(profile)
                } label: {
                    Label("Apply known fixes", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile.asCompatOverrides() == nil)

                Button("Dismiss") {
                    dismissedDetection = true
                }

                Spacer()

                Button {
                    openReportCompatibility(for: profile)
                } label: {
                    Label("Report", systemImage: "bubble.left.and.text.bubble.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open a GitHub issue to share your working config with the community")
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func confidenceBadge(for confidence: LauncherProfile.Confidence?) -> some View {
        switch confidence {
        case .high:
            Label("verified", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
        case .medium:
            Label("partial", systemImage: "minus.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        case .pending, .none:
            Label("unverified", systemImage: "questionmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        }
    }

    private func applyKnownFix(_ profile: LauncherProfile) {
        guard let overrides = profile.asCompatOverrides() else { return }
        pendingCompatOverrides = overrides
    }

    /// Open a GitHub new-issue form with prefilled body for the
    /// user to confirm / refine the fix. Doesn't require any
    /// authentication — GitHub opens the form in the user's browser.
    private func openReportCompatibility(for profile: LauncherProfile) {
        let title = "Launcher compat report: \(profile.displayName)"
        let bottle = selectedBottle?.name ?? "—"
        let wineBuild = selectedBottle?.wineBuild.shortName ?? "—"
        let body = """
        **Game / Launcher:** \(profile.displayName) (`\(profile.id)`)
        **Bottle:** \(bottle)
        **Wine build:** \(wineBuild)
        **Exe path:** `\(exeURL?.path ?? "—")`

        **Worked / didn't work:** [fill in]

        **Notes:**
        - [What you tried, what fixed it, any extra Winetricks verbs you needed]
        """
        var components = URLComponents(string: "https://github.com/THEGOD371/carafe/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "launcher-fix"),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func resolvedKnownLauncherTarget(for profile: LauncherProfile) -> URL? {
        guard let bottle = selectedBottle, let exeURL else { return nil }
        return KnownLauncherTargetResolver.targetForLauncher(
            exeURL: exeURL,
            bottle: bottle,
            profile: profile
        )
    }

    private var exeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Executable").font(.callout.weight(.medium))
            HStack(spacing: 8) {
                Text(exeURL?.path ?? "No file selected")
                    .font(.callout)
                    .foregroundStyle(exeURL == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                Button("Choose…", action: pickExecutable)
            }
            architectureLabel
            Text("The picker opens at the bottle's `drive_c` by default; you can navigate elsewhere too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Inline architecture badge. Three states:
    ///   - green checkmark when the launchability check is `.ok`
    ///     (and we have a real architecture readout — i.e. not .msi)
    ///   - orange triangle on `.warning` (32-bit on Wine Staging)
    ///   - red triangle on `.block` (would have been rejected by
    ///     pickExecutable; only renders here if the user somehow
    ///     bypassed it, e.g., by editing a saved Game in place)
    /// Recomputed per render — only reads ~10 bytes from disk and
    /// only when an exe is picked.
    @ViewBuilder
    private var architectureLabel: some View {
        if let url = exeURL, PEValidator.ext(of: url) != "msi" {
            let build = selectedBottle?.wineBuild ?? .gptk
            let auth = PEValidator.evaluateLaunchability(at: url, build: build)
            switch auth {
            case .ok:
                if let arch = PEValidator.architecture(of: url) {
                    Label(arch.displayName, systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if PEValidator.shouldBypassArchitectureCheck(url) {
                    // e.g. Steam.exe — known launcher, skip arch
                    // check but still mark it positively.
                    Label("Whitelisted launcher", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            case .warning(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .block(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var argsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launch arguments").font(.callout.weight(.medium))
            TextField("Optional — passed to the exe at launch", text: $argumentsText)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode.isEdit ? "Save changes" : "Add to Library", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Derived

    private var validBottles: [Bottle] {
        bottles.entries.compactMap(\.validBottle)
    }

    private var selectedBottle: Bottle? {
        validBottles.first { $0.id == selectedBottleID }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedBottle != nil
            && exeURL != nil
    }

    private var currentGameID: UUID? {
        if case .edit(let g) = mode { return g.id }
        return nil
    }

    private var parsedArguments: [String] {
        // Re-use the same naive shell splitter as LaunchExeSheet.
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in argumentsText {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Actions

    private func bootstrapState() {
        switch mode {
        case .add:
            selectedBottleID = validBottles.first?.id
        case .edit(let game):
            name = game.name
            selectedBottleID = game.bottleID
            argumentsText = game.arguments.joined(separator: " ")
            coverArtFilename = game.coverArtFilename
            if let bottle = library.bottle(for: game) {
                exeURL = game.exePath.resolve(bottle: bottle)
            }
            // If this game already has compat overrides, treat the
            // detection as "already addressed" — we still detect for
            // display info but don't re-prompt to apply.
            if let url = exeURL {
                detectedLauncher = KnownLaunchers.match(exeURL: url)
            }
            if game.compatOverrides != nil {
                dismissedDetection = true
            }
        }
    }

    /// Local-image picker that mirrors the drag-and-drop path on
    /// tiles. We copy the picked file into the cover art cache
    /// directly here (rather than going through GameLibrary) because
    /// the Add flow doesn't have a saved Game row yet — we just need
    /// the cached filename so submit() can attach it on save.
    private func pickLocalImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a cover image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let id = currentGameID ?? UUID()
        let dir = GameLibrary.coverArtDirectory
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let filename = "\(id.uuidString).\(ext)"
        let destination = dir.appendingPathComponent(filename)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            coverArtFilename = filename
        } catch {
            inlineError = "Couldn't copy cover image: \(error.localizedDescription)"
        }
    }

    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows executable"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = []
        if let exeT = UTType(filenameExtension: "exe") { types.append(exeT) }
        if let msiT = UTType(filenameExtension: "msi") { types.append(msiT) }
        if !types.isEmpty { panel.allowedContentTypes = types }

        // Default to drive_c/ inside the bottle if one is selected.
        if let bottle = selectedBottle {
            let driveC = bottle.prefixURL.appendingPathComponent("drive_c", isDirectory: true)
            if FileManager.default.fileExists(atPath: driveC.path) {
                panel.directoryURL = driveC
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Centralised launchability check (MZ + Steam.exe whitelist
        // + per-build 32-bit policy). We only hard-block on .block;
        // .warning is informational and rendered by architectureLabel.
        let build = selectedBottle?.wineBuild ?? .gptk
        if case .block(let message) = PEValidator.evaluateLaunchability(at: url, build: build) {
            inlineError = message
            return
        }
        inlineError = nil
        exeURL = url
        // Auto-fill name in add mode if blank.
        if mode == .add, name.isEmpty {
            name = GameLibrary.suggestedName(for: url)
        }
        // Run the KnownLaunchers matcher on the fresh pick. We reset
        // `dismissedDetection` so a new exe pick gets its own chance
        // to surface even if the user dismissed a previous one.
        detectedLauncher = KnownLaunchers.match(exeURL: url)
        pendingCompatOverrides = nil
        dismissedDetection = false
    }

    private func submit() {
        switch mode {
        case .add:
            guard let bottle = selectedBottle, let exeURL else { return }
            guard let new = library.add(
                name: name,
                bottle: bottle,
                exeURL: exeURL,
                arguments: parsedArguments
            ) else {
                inlineError = library.lastError ?? "Couldn't add game."
                return
            }
            // Persist cover art + any queued KnownLaunchers compat
            // overrides if the user chose them before saving.
            if coverArtFilename != nil || pendingCompatOverrides != nil {
                var updated = new
                if let filename = coverArtFilename { updated.coverArtFilename = filename }
                if let overrides = pendingCompatOverrides { updated.compatOverrides = overrides }
                library.update(updated)
            }
            dismiss()

        case .edit(let original):
            guard let bottle = selectedBottle, let exeURL else { return }
            var updated = original
            updated.name = name
            updated.bottleID = bottle.id
            updated.exePath = .from(exeURL: exeURL, bottle: bottle)
            updated.arguments = parsedArguments
            updated.coverArtFilename = coverArtFilename
            // Auto-apply a fresh KnownLaunchers detection if the user
            // clicked Apply in the card. Doesn't clobber existing
            // overrides set elsewhere (CompatConfigSheet) unless the
            // user explicitly re-applied.
            if let overrides = pendingCompatOverrides {
                updated.compatOverrides = overrides
            }
            library.update(updated)
            dismiss()
        }
    }
}
