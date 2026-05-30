import Foundation
import AppKit

/// Owner of every bottle on disk. Single source of truth for the
/// library UI. All CRUD operations run through a single in-flight
/// `currentOperation` so the UI can show a focused progress sheet
/// and we don't have to reason about overlapping wineboot calls.
@MainActor
final class BottleManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var entries: [BottleEntry] = []
    @Published private(set) var sizes: [UUID: Int64] = [:]
    @Published private(set) var currentOperation: BottleOperationProgress?
    @Published private(set) var lastError: String?

    /// Cached `wine64 --version` for the create-bottle picker.
    /// nil until first `detectWineVersion()` resolves.
    @Published private(set) var detectedWineVersion: String?

    // MARK: - Lifecycle

    init() {
        Task { await refresh() }
        observeDXMTInstalls()
    }

    /// `RunSession` posts `.carafeDidInstallDXMT` after it copies the
    /// DXMT DLLs into a bottle's system32. We listen here so the
    /// bottle's `installedComponents` ledger picks up `"dxmt"` —
    /// short-circuiting the install step on subsequent launches.
    /// Scoped to the manager's lifetime; the observer is cleaned up
    /// automatically when the manager deallocates.
    private func observeDXMTInstalls() {
        NotificationCenter.default.addObserver(
            forName: .carafeDidInstallDXMT,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["bottleID"] as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let bottle = self.entries.compactMap(\.validBottle).first(where: { $0.id == id })
                else { return }
                self.markComponentsInstalled(["dxmt"], in: bottle)
            }
        }
    }

    /// Root of all bottle folders. Today, hardcoded to
    /// `~/Library/Application Support/Carafe/Bottles`. The Settings
    /// milestone will let the user move this — when that lands, the
    /// path needs to thread through here instead of using the static.
    private var bottlesDirectory: URL { AppState.bottlesDirectory }

    // MARK: - Refresh

    /// Re-scan disk, rebuild the entries array. Cheap (folder
    /// enumeration only); kicks off background size calculation
    /// for each valid bottle.
    func refresh() async {
        let fm = FileManager.default
        let dir = bottlesDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            lastError = BottleError.bottlesDirectoryUnavailable(error.localizedDescription)
                .errorDescription
            return
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            lastError = BottleError.bottlesDirectoryUnavailable(error.localizedDescription)
                .errorDescription
            return
        }

        let folders = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var loaded: [BottleEntry] = []
        for folder in folders {
            loaded.append(Self.loadEntry(from: folder))
        }
        loaded.sort { lhs, rhs in
            switch (lhs, rhs) {
            case (.valid(let a), .valid(let b)):
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case (.valid, .corrupted): return true
            case (.corrupted, .valid): return false
            case (.corrupted, .corrupted):
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }

        entries = loaded

        // Drop stale size entries for bottles that disappeared.
        let validIDs = Set(loaded.compactMap { $0.validBottle?.id })
        sizes = sizes.filter { validIDs.contains($0.key) }

        // Kick off background size calculations.
        for entry in loaded {
            if case .valid(let bottle) = entry {
                scheduleSizeRefresh(for: bottle.id, url: bottle.prefixURL)
            }
        }
    }

    /// Static so it can run without an actor hop while iterating folders.
    nonisolated private static func loadEntry(from folder: URL) -> BottleEntry {
        let metadataURL = folder.appendingPathComponent("metadata.json")
        let fallbackID = UUID(uuidString: folder.lastPathComponent) ?? UUID()

        guard let data = try? Data(contentsOf: metadataURL) else {
            return .corrupted(.init(
                id: fallbackID,
                folderURL: folder,
                folderName: folder.lastPathComponent,
                reason: "metadata.json is missing"
            ))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let meta = try decoder.decode(BottleMetadata.self, from: data)
            // FRAGILITY: schemaVersion mismatch policy is "accept, but
            // log". We don't migrate yet (no v2 schema exists). When
            // we add migration, branch on meta.schemaVersion here.
            return .valid(meta.toBottle())
        } catch {
            return .corrupted(.init(
                id: fallbackID,
                folderURL: folder,
                folderName: folder.lastPathComponent,
                reason: "metadata.json failed to parse: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Size cache

    private func scheduleSizeRefresh(for id: UUID, url: URL) {
        Task { [weak self] in
            let bytes = await DirectoryCopier.size(of: url)
            await MainActor.run { [weak self] in
                self?.sizes[id] = bytes
            }
        }
    }

    func size(of bottle: Bottle) -> Int64? { sizes[bottle.id] }

    // MARK: - Wine version detection

    func detectWineVersion() async -> String {
        if let cached = detectedWineVersion { return cached }
        // Detection is GPTK-specific — the picker for the create
        // sheet defaults to GPTK and we report what GPTK ships.
        // Wine Staging gets its own version label from its installer.
        guard WineRunner.isWineAvailable(for: .gptk) else {
            detectedWineVersion = "unknown"
            return "unknown"
        }
        let result = try? await ShellRunner.runToCompletion(
            WineRunner.gptkWine64Path, arguments: ["--version"]
        )
        let raw = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = raw
            .split(separator: "\n").first
            .map(String.init)?
            .split(separator: " ").first
            .map(String.init) ?? "wine"
        detectedWineVersion = first
        return first
    }

    // MARK: - Create

    /// Create a new bottle: optionally bootstrap Wine Staging →
    /// make folder → wineboot --init → apply Windows version → write
    /// metadata.json. Rolls back the folder if any step fails.
    /// Surfaces all progress through `currentOperation`; no error
    /// is thrown to the caller, so the UI is fire-and-forget.
    /// Create a new bottle.
    ///
    /// `graphicsBackend` lets the caller seed the bottle's compat
    /// defaults from `AppSettings.defaultGraphicsBackend` (the
    /// Settings → Defaults preference). nil falls back to the
    /// model-level default (D3DMetal) for callers that don't care.
    func create(
        name: String,
        windowsVersion: WindowsVersion,
        wineVersion: String,
        wineBuild: WineBuild = .gptk,
        graphicsBackend: GraphicsBackend? = nil
    ) async {
        guard currentOperation == nil else {
            lastError = BottleError.operationInProgress.errorDescription
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = BottleError.nameEmpty.errorDescription
            return
        }
        if entries.contains(where: { $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            lastError = BottleError.nameAlreadyExists(trimmed).errorDescription
            return
        }
        // Wine availability depends on which build the user picked.
        // For .wineStaging we may need to install it first — that's
        // a step inside the pipeline rather than a precondition.
        if wineBuild == .gptk, !WineRunner.isWineAvailable(for: .gptk) {
            lastError = BottleError.wineNotInstalled.errorDescription
            return
        }

        let id = UUID()
        let folder = bottlesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)

        let op = BottleOperationProgress(title: "Creating “\(trimmed)”")
        currentOperation = op

        do {
            // --- 0. Bootstrap Wine Staging if needed ---
            if wineBuild == .wineStaging, !WineStagingInstaller.isInstalled {
                op.setStage("Installing Wine Staging \(WineStagingInstaller.version) (~190 MB one-time download)…")
                try await WineStagingInstaller.install { line in
                    Task { @MainActor [weak op] in op?.appendLog(line) }
                }
            }

            op.setStage("Creating folder…")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            op.setStage("Initializing prefix (this may take 30 seconds or more)…")
            try await WineRunner.wineboot(prefix: folder, build: wineBuild) { line in
                Task { @MainActor [weak op] in op?.appendLog(line) }
            }

            op.setStage("Applying Windows version…")
            await WineRunner.setWindowsVersion(
                prefix: folder, version: windowsVersion, build: wineBuild
            ) { line in
                Task { @MainActor [weak op] in op?.appendLog(line) }
            }

            op.setStage("Writing metadata…")
            // Seed compatDefaults from the caller's chosen graphics
            // backend (Settings → Defaults) if provided; otherwise
            // use the model-level default (D3DMetal / msync / hud off
            // / retina off). Only graphicsBackend is plumbed today;
            // other compat fields stay at their `.defaults` values.
            var compatDefaults = BottleCompatDefaults.defaults
            if let gb = graphicsBackend {
                compatDefaults.graphicsBackend = gb
            }
            let bottle = Bottle(
                id: id,
                name: trimmed,
                createdAt: Date(),
                lastUsedAt: nil,
                wineVersion: wineVersion,
                windowsVersion: windowsVersion,
                dllOverrides: [:],
                environment: [:],
                installedComponents: [],
                compatDefaults: compatDefaults,
                wineBuild: wineBuild
            )
            try writeMetadata(bottle, to: folder)

            op.setStage("Done.")
            op.markSucceeded()

            entries.append(.valid(bottle))
            entries.sort { lhs, rhs in
                switch (lhs, rhs) {
                case (.valid(let a), .valid(let b)):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                default: return true
                }
            }
            scheduleSizeRefresh(for: bottle.id, url: folder)
        } catch {
            // Roll back: wineboot may have written half a prefix.
            // Move-to-trash rather than rm so the user can recover
            // if they want to inspect what went wrong.
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            op.markFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Rename

    /// Rename only updates metadata.json — the folder on disk keeps
    /// its UUID name. Wine prefixes contain absolute paths burned
    /// into the registry; renaming the folder would silently break
    /// every install inside.
    func rename(_ bottle: Bottle, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = BottleError.nameEmpty.errorDescription
            return
        }
        if entries.contains(where: {
            guard let other = $0.validBottle, other.id != bottle.id else { return false }
            return other.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            lastError = BottleError.nameAlreadyExists(trimmed).errorDescription
            return
        }

        var updated = bottle
        updated.name = trimmed

        do {
            try writeMetadata(updated, to: updated.prefixURL)
            if let index = entries.firstIndex(where: { $0.id == bottle.id }) {
                entries[index] = .valid(updated)
            }
        } catch {
            lastError = BottleError.metadataWriteFailed(error.localizedDescription).errorDescription
        }
    }

    // MARK: - Duplicate

    func duplicate(_ bottle: Bottle, newName: String) async {
        guard currentOperation == nil else {
            lastError = BottleError.operationInProgress.errorDescription
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = BottleError.nameEmpty.errorDescription
            return
        }
        if entries.contains(where: { $0.displayName.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            lastError = BottleError.nameAlreadyExists(trimmed).errorDescription
            return
        }

        let newID = UUID()
        let destination = bottlesDirectory.appendingPathComponent(newID.uuidString, isDirectory: true)

        let op = BottleOperationProgress(title: "Duplicating “\(bottle.name)” → “\(trimmed)”")
        currentOperation = op

        do {
            op.setStage("Shutting down any running wine processes in the source bottle…")
            await WineRunner.shutdownWineserver(
                prefix: bottle.prefixURL,
                build: bottle.wineBuild
            )

            op.setStage("Copying prefix files…")
            try await DirectoryCopier.copy(
                from: bottle.prefixURL,
                to: destination
            ) { progress in
                Task { @MainActor [weak op] in
                    op?.reportProgress(bytesCopied: progress.bytesCopied, totalBytes: progress.totalBytes)
                    if let path = progress.currentRelativePath {
                        op?.stage = "Copying: \(path)"
                    }
                }
            }

            op.setStage("Writing metadata…")
            let newBottle = Bottle(
                id: newID,
                name: trimmed,
                createdAt: Date(),
                lastUsedAt: nil,
                wineVersion: bottle.wineVersion,
                windowsVersion: bottle.windowsVersion,
                dllOverrides: bottle.dllOverrides,
                environment: bottle.environment,
                // A duplicate is a byte-for-byte copy of the prefix,
                // including everything winetricks wrote. Carry the
                // installed-components ledger across so the badges
                // in ComponentsSheet stay accurate.
                installedComponents: bottle.installedComponents,
                // Compat defaults also carry — the user's tuning of
                // graphics/sync/etc. on the source bottle is part of
                // what they're duplicating.
                compatDefaults: bottle.compatDefaults,
                // Wine build carries too — same wine binary runs the
                // duplicate's prefix. Switching builds in a copy is
                // not safe (prefix has paths burned into the registry).
                wineBuild: bottle.wineBuild
            )
            try writeMetadata(newBottle, to: destination)

            op.setStage("Done.")
            op.markSucceeded()

            entries.append(.valid(newBottle))
            scheduleSizeRefresh(for: newBottle.id, url: destination)
        } catch {
            try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            op.markFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Delete

    /// Moves the bottle folder to the Trash so the user can recover
    /// if they delete by mistake. Confirmation lives in the UI layer.
    func delete(_ entry: BottleEntry) async {
        let url: URL
        switch entry {
        case .valid(let b):
            url = b.prefixURL
            await WineRunner.shutdownWineserver(prefix: url, build: b.wineBuild)
        case .corrupted(let c):
            url = c.folderURL
        }

        do {
            // FileManager.trashItem uses NSFileManager internally;
            // this is the modern equivalent of NSWorkspace's recycle
            // method and the path Apple recommends since 10.8.
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            entries.removeAll { $0.id == entry.id }
            sizes.removeValue(forKey: entry.id)
        } catch {
            lastError = BottleError.trashFailed(error.localizedDescription).errorDescription
        }
    }

    // MARK: - Repair (corrupted → valid)

    /// Regenerate metadata.json from a folder whose original metadata
    /// was missing or unreadable. Uses the folder name as the bottle
    /// name (best guess) and defaults for everything else. The user
    /// can rename + adjust afterward.
    func repair(_ corrupted: CorruptedBottle) async {
        // Try to re-use the folder's UUID if it parses; otherwise
        // generate one (the prefix will still work because wine
        // doesn't care about our folder name, only WINEPREFIX).
        let id = UUID(uuidString: corrupted.folderName) ?? corrupted.id
        let bottle = Bottle(
            id: id,
            name: "Repaired bottle \(corrupted.folderName.prefix(8))",
            createdAt: Date(),
            lastUsedAt: nil,
            wineVersion: detectedWineVersion ?? "unknown",
            windowsVersion: .win10,
            dllOverrides: [:],
            environment: [:],
            // Repair regenerates *fresh* metadata — we don't know
            // what was previously installed via winetricks, so the
            // ledger starts empty. User can re-mark via the
            // components UI if needed.
            installedComponents: [],
            compatDefaults: .defaults,
            // Repair regenerates fresh metadata. We can't recover
            // which build the prefix was originally created against,
            // so default to .gptk — same default we used pre-switcher.
            // If the user knows otherwise they can recreate the bottle.
            wineBuild: .gptk
        )

        do {
            try writeMetadata(bottle, to: corrupted.folderURL)
            await refresh()
        } catch {
            lastError = BottleError.repairFailed(error.localizedDescription).errorDescription
        }
    }

    // MARK: - Reveal in Finder + winecfg

    func showInFinder(_ bottle: Bottle) {
        NSWorkspace.shared.activateFileViewerSelecting([bottle.prefixURL])
    }

    func showInFinder(_ corrupted: CorruptedBottle) {
        NSWorkspace.shared.activateFileViewerSelecting([corrupted.folderURL])
    }

    func openWinecfg(_ bottle: Bottle) async {
        do {
            try await WineRunner.launchWinecfg(
                prefix: bottle.prefixURL,
                build: bottle.wineBuild
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Components ledger

    /// Mark winetricks verbs as successfully installed in this
    /// bottle and persist to metadata.json. Idempotent — installing
    /// the same verb twice is a no-op.
    func markComponentsInstalled(_ verbs: [String], in bottle: Bottle) {
        guard let index = entries.firstIndex(where: { $0.id == bottle.id }),
              case .valid(var updated) = entries[index] else { return }
        let before = updated.installedComponents
        updated.installedComponents.formUnion(verbs)
        guard updated.installedComponents != before else { return }
        do {
            try writeMetadata(updated, to: updated.prefixURL)
            entries[index] = .valid(updated)
        } catch {
            lastError = BottleError.metadataWriteFailed(error.localizedDescription).errorDescription
        }
    }

    /// Remove verbs from the installed ledger. Doesn't actually
    /// *uninstall* anything in the prefix — that's not really
    /// possible without rebuilding the bottle.
    func markComponentsRemoved(_ verbs: [String], in bottle: Bottle) {
        guard let index = entries.firstIndex(where: { $0.id == bottle.id }),
              case .valid(var updated) = entries[index] else { return }
        updated.installedComponents.subtract(verbs)
        do {
            try writeMetadata(updated, to: updated.prefixURL)
            entries[index] = .valid(updated)
        } catch {
            lastError = BottleError.metadataWriteFailed(error.localizedDescription).errorDescription
        }
    }

    // MARK: - Operation lifecycle

    /// UI calls this when the user dismisses the operation sheet.
    func clearCurrentOperation() {
        currentOperation = nil
    }

    func clearError() { lastError = nil }

    // MARK: - Metadata IO

    private func writeMetadata(_ bottle: Bottle, to folder: URL) throws {
        let metadataURL = folder.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(BottleMetadata(from: bottle))
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw BottleError.metadataWriteFailed(error.localizedDescription)
        }
    }
}

// MARK: - Bottle convenience

extension Bottle {
    /// Absolute path to this bottle's prefix on disk. Computed from
    /// the static AppState.bottlesDirectory — will need to thread
    /// through a configured path when the Settings milestone lets
    /// the user relocate bottles.
    var prefixURL: URL {
        AppState.bottlesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    var metadataURL: URL {
        prefixURL.appendingPathComponent("metadata.json")
    }
}
