import Foundation
import SwiftUI

/// Detects a Heroic Games Launcher install and parses its library
/// JSONs into `HeroicGame` records. Re-scans on demand (call
/// `scan()`) — typically once at launch + when the user clicks
/// "Refresh library".
///
/// FRAGILITY
/// ---------
/// 1. **Config path drift.** Heroic 2.x lives at
///    `~/Library/Application Support/heroic/`. Earlier macOS builds
///    used `com.heroicgameslauncher.hgl/` (the bundle ID). We probe
///    both and use whichever exists; if Heroic ever moves the dir
///    again (e.g. to `~/Library/Group Containers/`), add the new
///    candidate to `candidatePaths`.
/// 2. **Library JSON schema drift.** Heroic's library files have
///    shifted between major versions:
///      * Some versions store games as an **array** under a `library`
///        or `games` key.
///      * Other versions store games as a **dict** keyed by app_name.
///    Our decoder tries both. We pull a minimal field set
///    (`app_name`, `title`, `art_cover`, `is_installed`, `runner`)
///    and ignore everything else, so schema additions don't break us.
/// 3. **Two stores, two file names.** Epic library lives at
///    `store_cache/legendary_library.json` (current) or
///    `library.json` (older); GOG at `store_cache/gog_library.json`
///    or `gog_store/library.json`. We try multiple candidates per
///    store and accept whichever decodes first.
/// 4. **Cover art URLs.** Heroic stores remote CDN URLs (Epic's
///    cdn1.epicgames.com, GOG's images.gog.com). They're stable
///    enough that we use them directly via AsyncImage. Offline first
///    load → tiles show placeholders. A later milestone can pull
///    Heroic's local icon cache at
///    `~/Library/Application Support/heroic/icons/` instead.
/// 5. **Other Heroic backends.** Heroic also supports Amazon (Nile)
///    and SideloadGames. We only map Epic ("legendary") and GOG
///    ("gog") for Phase A. Entries with unknown runners are silently
///    skipped.
@MainActor
final class HeroicScanner: ObservableObject {

    // MARK: - Published state

    /// All HeroicGames parsed from the most recent successful scan.
    /// Sorted alphabetically by title for stable grid ordering.
    @Published private(set) var games: [HeroicGame] = []

    /// True iff a Heroic config directory was found on disk. UI uses
    /// this to decide whether to show the "From Heroic" section
    /// header or hide it entirely.
    @Published private(set) var isInstalled: Bool = false

    /// Resolved config directory (one of `candidatePaths`). nil when
    /// Heroic isn't installed.
    @Published private(set) var configDirectory: URL?

    /// Human-readable scan error (parse failure, permissions, etc.).
    /// nil on success or when Heroic isn't installed.
    @Published private(set) var lastError: String?

    /// Bumps after each scan completes. Lets views that want to react
    /// to a manual refresh subscribe via `.onChange`.
    @Published private(set) var lastScanAt: Date?

    // MARK: - Lifecycle

    init() {
        Task { await scan() }
    }

    // MARK: - Detection

    /// Filesystem locations Carafe will probe for Heroic's config.
    /// Order matters: newer paths first so a side-by-side install
    /// from an old + new Heroic prefers the new one.
    private static let candidatePaths: [String] = [
        "~/Library/Application Support/heroic",
        "~/Library/Application Support/com.heroicgameslauncher.hgl",
    ]

    /// Returns the first existing candidate config dir, or nil.
    static func detectConfigDirectory() -> URL? {
        let fm = FileManager.default
        for raw in candidatePaths {
            let expanded = NSString(string: raw).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return nil
    }

    // MARK: - Scan

    /// Re-scan Heroic's config dir. Idempotent and cheap (file reads
    /// only, no network). Updates `games`, `isInstalled`,
    /// `configDirectory`, `lastError`, `lastScanAt`.
    func scan() async {
        guard let dir = Self.detectConfigDirectory() else {
            self.isInstalled = false
            self.configDirectory = nil
            self.games = []
            self.lastError = nil
            self.lastScanAt = Date()
            return
        }

        self.isInstalled = true
        self.configDirectory = dir

        var collected: [HeroicGame] = []
        var errors: [String] = []

        // Epic — try newer path first, then older fallback.
        for relative in ["store_cache/legendary_library.json", "library.json"] {
            let url = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let entries = try Self.decodeLibraryFile(at: url)
                    collected.append(contentsOf: entries.compactMap { Self.makeGame(from: $0, fallbackSource: .epic) })
                    break  // first one wins — don't double-import
                } catch {
                    errors.append("Epic library at \(relative): \(error.localizedDescription)")
                }
            }
        }

        // GOG — same pattern.
        for relative in ["store_cache/gog_library.json", "gog_store/library.json"] {
            let url = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let entries = try Self.decodeLibraryFile(at: url)
                    collected.append(contentsOf: entries.compactMap { Self.makeGame(from: $0, fallbackSource: .gog) })
                    break
                } catch {
                    errors.append("GOG library at \(relative): \(error.localizedDescription)")
                }
            }
        }

        // Stable alphabetical ordering — Heroic's source JSON is in
        // arbitrary order (login-recency, mostly).
        collected.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        self.games = collected
        self.lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
        self.lastScanAt = Date()
    }

    // MARK: - Parsing

    /// Decoding entry shape. Snake-case matches Heroic's JSON; every
    /// field is optional so a missing key doesn't fail the whole
    /// entry — we filter at `makeGame(from:)`.
    private struct RawEntry: Decodable {
        let app_name: String?
        let title: String?
        let is_installed: Bool?
        let art_cover: String?
        let art_square: String?
        let runner: String?
    }

    /// Heroic's library files appear in two shapes across versions:
    /// array under a `library` key, or top-level dict keyed by
    /// app_name. We try both.
    private static func decodeLibraryFile(at url: URL) throws -> [RawEntry] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()

        // Shape 1: { "library": [ {...}, {...} ] } — older Epic.
        struct ArrayShapeUnderLibrary: Decodable { let library: [RawEntry]? }
        if let s = try? decoder.decode(ArrayShapeUnderLibrary.self, from: data),
           let arr = s.library {
            return arr
        }

        // Shape 2: { "games": [ {...}, {...} ] } — older GOG.
        struct ArrayShapeUnderGames: Decodable { let games: [RawEntry]? }
        if let s = try? decoder.decode(ArrayShapeUnderGames.self, from: data),
           let arr = s.games {
            return arr
        }

        // Shape 3: top-level array — possible in some builds.
        if let arr = try? decoder.decode([RawEntry].self, from: data) {
            return arr
        }

        // Shape 4: top-level dict keyed by app_name. Current Heroic
        // (2.10+) uses this for store_cache/*.json. Values are the
        // entries we want.
        if let dict = try? decoder.decode([String: RawEntry].self, from: data) {
            // Inject app_name from the key if the value didn't have one
            // (defensive — current Heroic does include both).
            return dict.map { key, value in
                if value.app_name == nil {
                    return RawEntry(
                        app_name: key, title: value.title,
                        is_installed: value.is_installed,
                        art_cover: value.art_cover, art_square: value.art_square,
                        runner: value.runner
                    )
                }
                return value
            }
        }

        throw HeroicScannerError.unrecognizedSchema(url.lastPathComponent)
    }

    /// Translate a raw entry into a HeroicGame. Skips entries
    /// missing required fields or with unrecognized runners.
    private static func makeGame(from raw: RawEntry, fallbackSource: HeroicGameSource) -> HeroicGame? {
        guard let appName = raw.app_name, !appName.isEmpty,
              let title = raw.title, !title.isEmpty
        else { return nil }

        // Prefer explicit `runner`; fall back to the file's
        // store (e.g. parsing gog_library.json defaults to GOG).
        let source: HeroicGameSource
        if let r = raw.runner, let mapped = HeroicGameSource(rawValue: r) {
            source = mapped
        } else if raw.runner == nil {
            source = fallbackSource
        } else {
            // Known unsupported runners (nile = Amazon Games,
            // sideload = manually-added). Quietly skip.
            return nil
        }

        let coverString = raw.art_cover ?? raw.art_square
        let coverURL = coverString.flatMap { URL(string: $0) }

        return HeroicGame(
            appName: appName,
            title: title,
            source: source,
            coverArtURL: coverURL,
            isInstalled: raw.is_installed ?? false
        )
    }

    // MARK: - Errors

    enum HeroicScannerError: LocalizedError {
        case unrecognizedSchema(String)
        var errorDescription: String? {
            switch self {
            case .unrecognizedSchema(let file):
                return "\(file) is in a Heroic library shape we don't recognise (neither array, dict, nor library-keyed). Update HeroicScanner.decodeLibraryFile."
            }
        }
    }
}
