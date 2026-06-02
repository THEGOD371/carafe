import Foundation

/// Read-only access to the bundled `KnownLaunchers.json` compatibility
/// database. When a user adds a game and Carafe recognises the picked
/// exe as a known launcher, the matching `LauncherProfile` is offered
/// to the user with an Apply button that fills in the game's
/// `compatOverrides` from `fix`.
///
/// FRAGILITY
/// ---------
/// 1. **Bundled-resource lifecycle.** The JSON ships inside the .app,
///    so updates require a new Carafe release. A future version can
///    layer a remote fetch on top (download a fresher copy at startup,
///    fall back to bundled) — for v0.1.x the static bundle is fine.
/// 2. **First-match wins.** If two profiles match the same exe (rare
///    but possible — Battle.net's `agent.exe` is generic), we return
///    whichever appears first in the JSON. Order matters; put more-
///    specific entries before generic ones when adding profiles.
/// 3. **No path normalisation.** We match on the raw lastPathComponent
///    + path components after lowercasing. Symlinks, case-sensitive
///    filesystems, and trailing slashes are all handled by URL's own
///    normalisation. Edge cases with shellexpansion shouldn't occur
///    because the URL comes from NSOpenPanel which produces canonical
///    file URLs.
/// 4. **Provisioned DLL sources.** `requiredDLLs` may point at
///    third-party archives whose layout can change. The provisioner
///    verifies that the requested DLL exists after extract and fails
///    loudly before launch instead of leaving the user with a Wine
///    "module not found" dialog.
enum KnownLaunchers {

    // MARK: - Public surface

    /// All profiles loaded at first access. Lazy-loaded singleton so
    /// the JSON parse cost is paid at most once per app run.
    static let all: [LauncherProfile] = loadBundled()

    /// Match a picked exe URL against every profile. First hit wins.
    /// Returns nil if nothing matched.
    static func match(exeURL: URL) -> LauncherProfile? {
        let exeName = exeURL.lastPathComponent.lowercased()
        let pathParts = exeURL.standardizedFileURL.pathComponents.map { $0.lowercased() }

        for profile in all {
            // Match by exact exe filename.
            if let exeNames = profile.match.exeNames {
                let lowered = exeNames.map { $0.lowercased() }
                if lowered.contains(exeName) {
                    return profile
                }
            }
            // Match by folder hint — checks every ancestor folder
            // for `contains(hint)`. Hints should be specific enough
            // not to collide with unrelated games.
            if let hints = profile.match.folderHints {
                for hint in hints {
                    let lowerHint = hint.lowercased()
                    if pathParts.contains(where: { $0.contains(lowerHint) }) {
                        return profile
                    }
                }
            }
        }
        return nil
    }

    // MARK: - JSON loader

    private static func loadBundled() -> [LauncherProfile] {
        guard let url = Bundle.main.url(forResource: "KnownLaunchers", withExtension: "json")
        else {
            // Resource missing — non-fatal, app continues without
            // the auto-detect feature. Log once on first access.
            print("Carafe: KnownLaunchers.json not found in bundle — auto-detect disabled.")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(KnownLaunchersFile.self, from: data)
            return file.launchers
        } catch {
            print("Carafe: KnownLaunchers.json parse failure: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Models

struct KnownLaunchersFile: Decodable, Sendable {
    let schemaVersion: Int
    let lastUpdated: String?
    let launchers: [LauncherProfile]
}

struct LauncherProfile: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let publisher: String?
    let match: MatchRules
    let fix: LauncherFix

    struct MatchRules: Decodable, Hashable, Sendable {
        let exeNames: [String]?
        let folderHints: [String]?
    }

    /// Confidence we have that this profile actually works. Drives
    /// the UI badge colour on the recognise-card.
    enum Confidence: String, Decodable, Sendable {
        case high, medium, pending

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw.lowercased() {
            case "high": self = .high
            case "medium", "partial": self = .medium
            case "pending": self = .pending
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown launcher confidence: \(raw)"
                    )
                )
            }
        }
    }

    struct LauncherFix: Decodable, Hashable, Sendable {
        /// Optional path relative to the launcher's parent folder
        /// pointing at the real game exe. UI shows this as a "use the
        /// real game exe instead" tip; we don't auto-rewrite the
        /// user's exe pick because they may have a reason for picking
        /// the launcher specifically.
        let skipLauncherTo: String?

        /// Extra candidate paths for the real game exe. Same
        /// resolution semantics as `skipLauncherTo`: each path is
        /// tried relative to the launcher folder and each ancestor
        /// inside the bottle. Useful for regional or Steam builds
        /// where a launcher writes multiple Win64 folders.
        let skipLauncherCandidates: [String]?

        /// Raw values matching `WindowsVersion`'s rawValue / `GraphicsBackend`'s
        /// rawValue. nil = inherit from bottle.
        let windowsVersion: String?
        let graphicsBackend: String?

        /// Verbs the user should install into the bottle via the
        /// Components sheet. We don't auto-install (winetricks is a
        /// separate flow); we surface them as a recommendation.
        let winetricksVerbs: [String]?

        /// dll → override value (e.g. "n", "n,b", "disabled"). Maps
        /// onto Game.dllOverrides at apply time.
        let dllOverrides: [String: String]?

        /// Extra env vars. Maps onto Game.environment at apply time.
        let environment: [String: String]?

        /// DLLs Carafe can fetch and place before launching this
        /// profile. Unlike `dllOverrides`, these are actual files
        /// copied beside the launcher/game exe or into the prefix.
        let requiredDLLs: [RequiredDLL]?

        /// Log/file signatures that indicate a known failure mode.
        /// Carafe surfaces these in the live run log so users don't
        /// have to inspect launcher-specific logs by hand.
        let failureSignals: [FailureSignal]?

        /// Some launchers intentionally exit after spawning an
        /// updater/downloader process in the same Wine prefix. The
        /// default RunSession cleanup kills wineserver after a
        /// natural exit to avoid zombies; this flag opts a profile
        /// out so the child updater can keep running.
        let preserveWineserverOnExit: Bool?

        /// Optional executable to run after the launcher exits, if a
        /// log contains `triggerLogContains`. This covers launchers
        /// that log a handoff like "StartUpdateExe success" but Wine
        /// fails to keep the child updater alive.
        let postExitHandoff: PostExitHandoff?

        /// Human-readable explanation shown in the card. Should
        /// include any caveats / known limitations.
        let notes: String?

        let confidence: Confidence?
        let lastVerified: String?
    }

    struct RequiredDLL: Decodable, Hashable, Sendable {
        /// Human-readable name and final filename, e.g. `Qt5Svg.dll`.
        let name: String

        /// Direct downloadable source archive. Supported today:
        /// `.7z`, `.zip`, and raw `.dll`.
        let sourceURL: String

        /// Optional exact path inside the archive. If omitted,
        /// Carafe recursively searches the extracted archive for
        /// `name`.
        let archivePath: String?

        /// Destination. Relative paths are resolved beside the exe.
        /// Supported tokens:
        ///   `{exeDir}/Qt5Svg.dll`
        ///   `{prefix}/drive_c/windows/system32/Qt5Svg.dll`
        /// A bare `Qt5Svg.dll` means "next to the picked exe".
        let destinationPath: String?

        /// Optional SHA-256 for the downloaded archive/raw DLL.
        /// nil means "trust TLS + source host".
        let sha256: String?
    }

    struct FailureSignal: Decodable, Hashable, Sendable {
        /// Path to inspect. Relative paths are resolved beside the
        /// launcher exe. Supports `{exeDir}` and `{prefix}` tokens.
        let logPath: String

        /// Case-insensitive substring that signals the failure.
        let contains: String

        /// Human-readable explanation to show in Carafe logs.
        let message: String
    }

    struct PostExitHandoff: Decodable, Hashable, Sendable {
        /// Relative to exe dir unless using {exeDir}/{prefix}.
        let executablePath: String
        let triggerLogPath: String
        let triggerLogContains: String
        let arguments: [String]?
    }

    // MARK: - Apply

    /// Convert this profile's `fix` block into a `GameCompatOverrides`
    /// that the form can drop straight onto the game record. Returns
    /// nil if the fix doesn't have anything overrideable (all fields
    /// were null) — that's a profile shape with notes-only.
    func asCompatOverrides() -> GameCompatOverrides? {
        let wv: WindowsVersion? = fix.windowsVersion.flatMap { WindowsVersion(rawValue: $0) }
        let gb: GraphicsBackend? = fix.graphicsBackend.flatMap { GraphicsBackend(rawValue: $0) }
        let dlls = fix.dllOverrides
        let env = fix.environment

        if wv == nil && gb == nil && (dlls?.isEmpty ?? true) && (env?.isEmpty ?? true) {
            return nil
        }
        return GameCompatOverrides(
            graphicsBackend: gb,
            sync: nil,
            windowsVersion: wv,
            metalHUD: nil,
            retina: nil,
            dllOverrides: dlls,
            environment: env
        )
    }

    /// Pretty bullet list of what auto-apply will actually change.
    /// Rendered in the recognise-card so users see exactly what
    /// they're agreeing to before clicking Apply.
    var appliedFixSummary: [String] {
        var lines: [String] = []
        if let wv = fix.windowsVersion, let parsed = WindowsVersion(rawValue: wv) {
            lines.append("Windows version → \(parsed.displayName)")
        }
        if let gb = fix.graphicsBackend, let parsed = GraphicsBackend(rawValue: gb) {
            lines.append("Graphics backend → \(parsed.displayName)")
        }
        if let dlls = fix.dllOverrides, !dlls.isEmpty {
            let formatted = dlls.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            lines.append("DLL overrides → \(formatted)")
        }
        if let env = fix.environment, !env.isEmpty {
            let formatted = env.keys.sorted().joined(separator: ", ")
            lines.append("Env vars → \(formatted)")
        }
        if let dlls = fix.requiredDLLs, !dlls.isEmpty {
            let formatted = dlls.map(\.name).sorted().joined(separator: ", ")
            lines.append("Provision DLLs → \(formatted)")
        }
        return lines
    }
}
