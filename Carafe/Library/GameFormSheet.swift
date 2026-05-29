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
            // Persist cover art selection if the user chose one
            // before saving.
            if let filename = coverArtFilename {
                var updated = new
                updated.coverArtFilename = filename
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
            library.update(updated)
            dismiss()
        }
    }
}
