import Foundation

/// A library entry — what the user thinks of as "a game I added".
/// A game points at one exe inside one bottle. The bottle ID is the
/// link; if the bottle is deleted, the game becomes orphaned and the
/// UI offers a remap action.
struct Game: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var bottleID: UUID
    var exePath: GameExePath
    var arguments: [String]

    /// Filename (not full path) of the cached cover art under
    /// `~/Library/Application Support/Carafe/CoverArt/`. nil = no
    /// art yet, render a placeholder.
    var coverArtFilename: String?

    /// Reserved for the per-game config milestone. Lets the user
    /// pin a non-cover image (e.g., an exported game icon).
    var customIconFilename: String?

    var lastPlayedAt: Date?
    var totalPlaytime: TimeInterval

    let addedAt: Date

    /// Per-game compat overrides. nil = no overrides, fully inherit
    /// from the bottle's `compatDefaults`. Decoded with
    /// decodeIfPresent so games from before this milestone keep
    /// working with a nil here.
    var compatOverrides: GameCompatOverrides?

    /// Steam app ID when this entry was added via the Add Steam Game
    /// flow. nil for direct-exe entries. Used to render a Steam
    /// badge on the tile and (in future) look up cover art by appid
    /// rather than fuzzy name search. Decoded with decodeIfPresent.
    var steamAppID: Int?
}

/// Where the game's exe lives. We keep this as a sum type so a bottle
/// that gets moved on disk (Settings milestone) re-resolves cleanly
/// when the exe is inside the prefix, while still supporting exes
/// the user picked from elsewhere on their Mac.
enum GameExePath: Hashable, Sendable {
    case insidePrefix(String)
    case absolute(String)

    /// Resolve to an absolute file URL given the current bottle.
    func resolve(bottle: Bottle) -> URL {
        switch self {
        case .insidePrefix(let relative):
            return bottle.prefixURL.appendingPathComponent(relative)
        case .absolute(let path):
            return URL(fileURLWithPath: path)
        }
    }

    /// Human-readable string for display in the Edit sheet etc.
    var displayPath: String {
        switch self {
        case .insidePrefix(let p): return p
        case .absolute(let p): return p
        }
    }

    /// Classify an arbitrary exe URL relative to a bottle's prefix.
    /// FRAGILITY: relies on string-prefix comparison of standardized
    /// paths. Symlinked prefixes could fool us; we don't expect any
    /// in v1 (the bottles directory is plain folders).
    static func from(exeURL: URL, bottle: Bottle) -> GameExePath {
        let prefixPath = bottle.prefixURL.standardized.path
        let exePath = exeURL.standardized.path
        let prefixWithSlash = prefixPath.hasSuffix("/") ? prefixPath : prefixPath + "/"
        if exePath.hasPrefix(prefixWithSlash) {
            let relative = String(exePath.dropFirst(prefixWithSlash.count))
            return .insidePrefix(relative)
        }
        return .absolute(exePath)
    }
}

// MARK: - Codable

extension GameExePath: Codable {
    private enum CodingKeys: String, CodingKey { case kind, path }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .insidePrefix(let p):
            try container.encode("insidePrefix", forKey: .kind)
            try container.encode(p, forKey: .path)
        case .absolute(let p):
            try container.encode("absolute", forKey: .kind)
            try container.encode(p, forKey: .path)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let path = try container.decode(String.self, forKey: .path)
        switch kind {
        case "insidePrefix": self = .insidePrefix(path)
        case "absolute": self = .absolute(path)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "Unknown GameExePath kind: \(kind)"
            )
        }
    }
}

/// On-disk library file. Single library.json under
/// `~/Library/Application Support/Carafe/library.json`. The
/// schemaVersion exists so future migrations have a hook.
struct LibraryFile: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var games: [Game]

    static func empty() -> LibraryFile {
        LibraryFile(schemaVersion: currentSchemaVersion, games: [])
    }
}

/// Health of a library entry. Recomputed on every refresh — never
/// stored. The UI uses this to pick between normal / orphaned tile
/// rendering and to enable/disable Play.
enum GameStatus: Sendable, Equatable {
    case ok
    case bottleMissing
    case exeMissing
}

enum GameError: LocalizedError, Sendable {
    case nameEmpty
    case bottleNotFound
    case exeNotFound(String)
    case persistenceFailed(String)
    case coverArtFailed(String)

    var errorDescription: String? {
        switch self {
        case .nameEmpty:                       return "Game name can't be empty."
        case .bottleNotFound:                  return "Couldn't find the bottle for this game."
        case .exeNotFound(let path):           return "Executable not found: \(path)"
        case .persistenceFailed(let detail):   return "Library save failed: \(detail)"
        case .coverArtFailed(let detail):      return "Cover art failed: \(detail)"
        }
    }
}
