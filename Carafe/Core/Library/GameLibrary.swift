import Foundation
import AppKit

/// Persists and surfaces the user's library of games. Lives alongside
/// BottleManager — depends on it for orphan detection and bottle
/// lookups, but doesn't own bottle CRUD.
@MainActor
final class GameLibrary: ObservableObject {

    // MARK: - Published state

    @Published private(set) var games: [Game] = []
    @Published private(set) var lastError: String?

    // MARK: - Dependencies

    private weak var bottles: BottleManager?

    init(bottles: BottleManager) {
        self.bottles = bottles
        load()
    }

    // MARK: - Paths

    private var libraryFileURL: URL {
        AppState.supportDirectory.appendingPathComponent("library.json")
    }

    /// Directory holding cached cover art files. Created on demand.
    static var coverArtDirectory: URL {
        let url = AppState.supportDirectory.appendingPathComponent("CoverArt", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Disk IO

    private func load() {
        let url = libraryFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First run — no library.json yet. Treat as empty.
            games = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(LibraryFile.self, from: data)
            // FRAGILITY: schemaVersion mismatch handling is "accept
            // and log" today. When v2 lands, branch here for
            // migration. We never throw on mismatch — losing the
            // library to a bad migration is worse than running with
            // a slightly stale shape.
            if file.schemaVersion != LibraryFile.currentSchemaVersion {
                NSLog("Carafe: library.json schemaVersion %d ≠ current %d", file.schemaVersion, LibraryFile.currentSchemaVersion)
            }
            games = file.games
        } catch {
            lastError = "Couldn't load library: \(error.localizedDescription)"
            games = []
        }
    }

    private func save() {
        let url = libraryFileURL
        let file = LibraryFile(schemaVersion: LibraryFile.currentSchemaVersion, games: games)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = GameError.persistenceFailed(error.localizedDescription).errorDescription
        }
    }

    func clearError() { lastError = nil }

    // MARK: - Status

    /// Recompute health for a game. UI calls this per tile on render.
    func status(of game: Game) -> GameStatus {
        guard let bottles else { return .bottleMissing }
        guard let bottle = bottles.entries.compactMap(\.validBottle)
            .first(where: { $0.id == game.bottleID }) else {
            return .bottleMissing
        }
        let exeURL = game.exePath.resolve(bottle: bottle)
        if !FileManager.default.fileExists(atPath: exeURL.path) {
            return .exeMissing
        }
        return .ok
    }

    /// Look up the bottle for a game. nil = orphaned bottle.
    func bottle(for game: Game) -> Bottle? {
        bottles?.entries.compactMap(\.validBottle).first(where: { $0.id == game.bottleID })
    }

    // MARK: - CRUD

    /// Create a new library entry. Validates the bottle exists and
    /// the exe is on disk; persists immediately.
    @discardableResult
    func add(name: String, bottle: Bottle, exeURL: URL, arguments: [String]) -> Game? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = GameError.nameEmpty.errorDescription
            return nil
        }
        guard FileManager.default.fileExists(atPath: exeURL.path) else {
            lastError = GameError.exeNotFound(exeURL.path).errorDescription
            return nil
        }
        let exePath = GameExePath.from(exeURL: exeURL, bottle: bottle)
        let game = Game(
            id: UUID(),
            name: trimmed,
            bottleID: bottle.id,
            exePath: exePath,
            arguments: arguments,
            coverArtFilename: nil,
            customIconFilename: nil,
            lastPlayedAt: nil,
            totalPlaytime: 0,
            addedAt: Date()
        )
        games.append(game)
        save()
        return game
    }

    /// Update an existing entry (rename, change args, swap cover, ...).
    func update(_ game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index] = game
        save()
    }

    /// Remove the library entry. Does NOT touch the bottle, the exe,
    /// or any cached cover art file (the cache is cleared lazily on
    /// the next cover art sweep — see `pruneCoverArtCache()` below).
    func remove(_ game: Game) {
        // Clean up its cover art file proactively so the cache
        // doesn't bloat. Errors here are best-effort.
        if let filename = game.coverArtFilename {
            let url = Self.coverArtDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        games.removeAll { $0.id == game.id }
        save()
    }

    /// Update exePath in place after the user picks a new file.
    /// Used by the "Relocate exe…" action on missing-exe tiles.
    func relocate(_ game: Game, to newExeURL: URL) {
        guard FileManager.default.fileExists(atPath: newExeURL.path) else {
            lastError = GameError.exeNotFound(newExeURL.path).errorDescription
            return
        }
        guard let bottle = bottle(for: game) else {
            lastError = GameError.bottleNotFound.errorDescription
            return
        }
        var updated = game
        updated.exePath = .from(exeURL: newExeURL, bottle: bottle)
        update(updated)
    }

    /// Remap to a different bottle (used for orphaned-bottle tiles).
    func remap(_ game: Game, toBottleID bottleID: UUID) {
        var updated = game
        updated.bottleID = bottleID
        update(updated)
    }

    // MARK: - Play time

    /// Called by LaunchGameSheet on every terminal RunSession state.
    /// `duration` is wall-clock time the session ran in seconds.
    func recordPlay(_ game: Game, duration: TimeInterval) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        // FRAGILITY: we use wall-clock elapsed, NOT actual CPU time
        // playing. Time spent at "press any key" splash screens is
        // counted; time when wine sat at 0% because the game alt-
        // tabbed is also counted. Steam does the same — fine for v1.
        games[index].totalPlaytime += max(0, duration)
        games[index].lastPlayedAt = Date()
        save()
    }

    // MARK: - Cover art

    /// Absolute URL of this game's cached cover art file, if any.
    /// Returns nil when the entry has no art OR the file is missing
    /// (transparently triggers placeholder rendering).
    func coverArtURL(for game: Game) -> URL? {
        guard let filename = game.coverArtFilename else { return nil }
        let url = Self.coverArtDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Move a downloaded file into the cover art cache and update
    /// the game's metadata. Extension is taken from the source URL
    /// so the filename has the right type.
    func setCoverArt(for game: Game, fromDownloadedURL local: URL) {
        let dir = Self.coverArtDirectory
        let ext = local.pathExtension.isEmpty ? "jpg" : local.pathExtension
        let filename = "\(game.id.uuidString).\(ext)"
        let destination = dir.appendingPathComponent(filename)

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: local, to: destination)
        } catch {
            lastError = GameError.coverArtFailed(error.localizedDescription).errorDescription
            return
        }

        var updated = game
        updated.coverArtFilename = filename
        update(updated)
    }

    /// Copy a user-provided image file into the cover art cache.
    /// Unlike setCoverArt(fromDownloadedURL:), this *copies* — the
    /// user's source file is left untouched on disk. Used by the
    /// "Use local image…" picker and drag-and-drop onto game tiles.
    func setCoverArt(for game: Game, fromLocalFile source: URL) {
        let dir = Self.coverArtDirectory
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let filename = "\(game.id.uuidString).\(ext)"
        let destination = dir.appendingPathComponent(filename)

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            lastError = GameError.coverArtFailed(error.localizedDescription).errorDescription
            return
        }

        var updated = game
        updated.coverArtFilename = filename
        update(updated)
    }

    func clearCoverArt(for game: Game) {
        if let filename = game.coverArtFilename {
            let url = Self.coverArtDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        var updated = game
        updated.coverArtFilename = nil
        update(updated)
    }

    // MARK: - Helpers

    /// Helpful default name for a freshly-picked exe.
    /// "BlackMesa.exe" → "Black Mesa"; "rocket-league.exe" → "Rocket League".
    static func suggestedName(for exeURL: URL) -> String {
        let base = exeURL.deletingPathExtension().lastPathComponent
        // Insert space before each uppercase that follows a lowercase
        // (CamelCase → "Camel Case"), then replace separators.
        var spaced = ""
        for (i, ch) in base.enumerated() {
            if i > 0, ch.isUppercase,
               let prev = base[base.index(base.startIndex, offsetBy: i - 1)].unicodeScalars.first,
               CharacterSet.lowercaseLetters.contains(prev) {
                spaced.append(" ")
            }
            spaced.append(ch)
        }
        spaced = spaced
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return spaced.isEmpty ? base : spaced
    }
}
