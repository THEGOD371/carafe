import Foundation

/// A game we discovered inside a bottle's Steam install. This is a
/// pre-Carafe-library entity — the user picks some of these to add
/// to the Carafe library as proper Games.
struct DiscoveredSteamGame: Identifiable, Hashable, Sendable {
    let appID: Int
    let name: String
    let installDir: String
    /// Host path to the *library folder* containing this game
    /// (e.g. `<prefix>/drive_c/Program Files (x86)/Steam`). The
    /// game's files live under `<libraryPath>/steamapps/common/<installDir>`.
    let libraryPath: URL
    let sizeOnDisk: Int64

    var id: Int { appID }

    var installPath: URL {
        libraryPath
            .appendingPathComponent("steamapps")
            .appendingPathComponent("common")
            .appendingPathComponent(installDir)
    }

    var sizeOnDiskDisplay: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: sizeOnDisk)
    }
}

/// Detection + enumeration of Steam content inside a Carafe bottle.
/// Stateless; everything is computed from disk on demand.
///
/// FRAGILITY: this code assumes Steam was installed at its canonical
/// location (`drive_c/Program Files (x86)/Steam`). The Steam
/// installer respects user-chosen directories too; v1 doesn't.
/// If the user picked elsewhere during install, scanning will miss
/// it. Future fix: also probe `drive_c/Program Files/Steam` and
/// any path the user manually configures.
enum SteamLibraryScanner {

    /// Path under the prefix where Steam normally installs itself.
    static let steamInstallSubpath = "drive_c/Program Files (x86)/Steam"

    /// Relative path (under the prefix) of the canonical Steam.exe.
    static let steamExeSubpath = "drive_c/Program Files (x86)/Steam/Steam.exe"

    /// True if Steam.exe is present at the canonical location.
    static func hasSteam(in bottle: Bottle) -> Bool {
        let exe = bottle.prefixURL.appendingPathComponent(steamExeSubpath)
        return FileManager.default.fileExists(atPath: exe.path)
    }

    /// Absolute host URL of the Steam install dir for this bottle.
    static func steamInstallURL(for bottle: Bottle) -> URL {
        bottle.prefixURL.appendingPathComponent(steamInstallSubpath)
    }

    /// Absolute host URL of Steam.exe inside this bottle.
    static func steamExeURL(for bottle: Bottle) -> URL {
        bottle.prefixURL.appendingPathComponent(steamExeSubpath)
    }

    /// All bottles in the library that currently have Steam installed.
    /// Used by AddSteamGameSheet to populate the bottle picker.
    /// Main-actor isolated because BottleManager.entries is.
    @MainActor
    static func bottlesWithSteam(in manager: BottleManager) -> [Bottle] {
        manager.entries.compactMap(\.validBottle).filter { hasSteam(in: $0) }
    }

    // MARK: - Scanning

    /// Enumerate installed Steam games in this bottle. Order: by
    /// name, case-insensitive. Returns an empty array when Steam
    /// isn't installed, when libraryfolders.vdf is missing, or when
    /// the bottle simply has no games yet.
    static func scan(bottle: Bottle) -> [DiscoveredSteamGame] {
        guard hasSteam(in: bottle) else { return [] }

        let steam = steamInstallURL(for: bottle)
        let libraryPaths = discoverLibraryFolders(steamInstall: steam, prefix: bottle.prefixURL)

        var seenAppIDs = Set<Int>()
        var games: [DiscoveredSteamGame] = []

        for libraryURL in libraryPaths {
            let steamapps = libraryURL.appendingPathComponent("steamapps")
            // skipsHiddenFiles avoids the macOS .DS_Store and
            // Steam's own .crash files cluttering results.
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: steamapps,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("appmanifest_"),
                      file.pathExtension.lowercased() == "acf" else { continue }
                guard let parsed = parseAppManifest(at: file, libraryPath: libraryURL) else {
                    continue
                }
                // Dedupe in case the same appid appears in two
                // libraries (shouldn't happen in normal use, but
                // protects against weird half-moved installs).
                guard !seenAppIDs.contains(parsed.appID) else { continue }
                seenAppIDs.insert(parsed.appID)
                games.append(parsed)
            }
        }

        return games.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Internals

    /// Returns every library folder (host URLs) including the default
    /// Steam install. Reads libraryfolders.vdf when present;
    /// falls back to "just the Steam install dir" if missing or
    /// unparseable.
    private static func discoverLibraryFolders(steamInstall: URL, prefix: URL) -> [URL] {
        let vdfURL = steamInstall
            .appendingPathComponent("steamapps")
            .appendingPathComponent("libraryfolders.vdf")

        var paths: [URL] = [steamInstall]

        if let root = SteamVDFParser.parseFile(at: vdfURL),
           let libraryFolders = root.object("libraryfolders") {
            // Each child is keyed "0", "1", ... and contains a "path"
            // pointing at a library root (Windows-format path).
            for (_, child) in libraryFolders.objectEntries {
                guard let winPath = child.string("path") else { continue }
                guard let host = translateWindowsPath(winPath, prefix: prefix) else { continue }
                // Skip the default — it's already first.
                if host.standardized.path == steamInstall.standardized.path { continue }
                paths.append(host)
            }
        }

        return paths.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Parse a single appmanifest_*.acf file. Returns nil if the
    /// manifest is malformed or missing required fields. Steam
    /// occasionally writes partial manifests during download
    /// (StateFlags=2/4); we still surface those — the user may
    /// want to know about an in-progress install.
    private static func parseAppManifest(at url: URL, libraryPath: URL) -> DiscoveredSteamGame? {
        guard let root = SteamVDFParser.parseFile(at: url) else { return nil }
        // Most appmanifest files wrap their contents in an outer
        // "AppState" node. Be liberal in what we accept.
        let app = root.object("AppState") ?? root
        guard let appID = app.integer("appid"),
              let name = app.string("name"),
              let installDir = app.string("installdir"),
              !name.isEmpty else {
            return nil
        }
        let size = Int64(app.string("SizeOnDisk") ?? "") ?? 0
        return DiscoveredSteamGame(
            appID: appID,
            name: name,
            installDir: installDir,
            libraryPath: libraryPath,
            sizeOnDisk: size
        )
    }

    /// Translate a Windows-style path (`C:\foo\bar`) into the
    /// equivalent host URL under this bottle's prefix. Only the C
    /// drive is supported — additional drives configured via wine's
    /// dosdevices would need per-bottle resolution which we don't do
    /// in v1.
    ///
    /// FRAGILITY: relies on `drive_c` being the literal name of the C
    /// drive symlink in wine prefixes. That's been true since wine
    /// 1.0, and GPTK follows the same layout.
    private static func translateWindowsPath(_ windows: String, prefix: URL) -> URL? {
        let normalized = windows.replacingOccurrences(of: "\\", with: "/")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        let lower = trimmed.lowercased()
        guard lower.hasPrefix("c:") else { return nil }

        var after = String(trimmed.dropFirst(2))
        if after.hasPrefix("/") { after.removeFirst() }
        if after.isEmpty {
            return prefix.appendingPathComponent("drive_c", isDirectory: true)
        }
        return prefix
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent(after)
    }
}
