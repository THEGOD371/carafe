import Foundation

/// Library scan + per-game install pipeline for Epic games via
/// legendary. Stateless utility on top of `LegendaryRunner`.
enum EpicLibrary {

    // MARK: - Library scan

    /// Fetch every owned game on the signed-in Epic account. Combines
    /// `legendary list-games --json` (full library) with
    /// `legendary list-installed --json` (installed subset) so each
    /// `EpicGame` reports the right `isInstalled` value without
    /// requiring two separate calls from the UI.
    ///
    /// Sorted alphabetically by title for stable picker ordering.
    static func fetchOwnedGames() async throws -> [EpicGame] {
        // Installed appNames first — cheap, lets us label entries.
        let installedSet: Set<String> = await {
            do {
                let installed = try await LegendaryRunner.decodeJSON(
                    ["list-installed", "--json"],
                    as: [LegendaryListInstalledEntry].self
                )
                return Set(installed.compactMap(\.app_name))
            } catch {
                // Tolerate "no installed games" / probe errors —
                // we'll just label everything as not-installed.
                return []
            }
        }()

        let entries = try await LegendaryRunner.decodeJSON(
            ["list-games", "--json"],
            as: [LegendaryListGamesEntry].self
        )

        var games = entries.compactMap { $0.toEpicGame(installed: installedSet) }
        games.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return games
    }

    // MARK: - Install pipeline

    /// Run `legendary install` for the given app, anchored at
    /// `--base-path <bottle>/drive_c/Games`. Streams progress lines
    /// via `onLine`; calls `onProgress` whenever a parseable DLManager
    /// percentage shows up.
    ///
    /// FRAGILITY: legendary's install prompts interactively on first
    /// run for things like "Install verified launcher? [y/N]". We
    /// pass `--yes` to auto-accept all such prompts; that matches
    /// what users want in 99% of cases (run with the defaults Epic
    /// recommends). If a future legendary adds a prompt that
    /// auto-accept handles dangerously, the user-visible signal will
    /// be a botched install — file an issue.
    static func install(
        appName: String,
        intoBottle bottle: Bottle,
        onLine: @Sendable @escaping (String) -> Void,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let basePath = bottle.prefixURL
            .appendingPathComponent("drive_c/Games", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: basePath, withIntermediateDirectories: true
        )

        let args = [
            "--yes",
            "install",
            "--base-path", basePath,
            // Skip dependency installers — wine handles them via the
            // standard winetricks verbs Carafe already installs into
            // the bottle (vcrun, dotnet, etc.). legendary's bundled
            // installers expect a real Windows environment.
            "--skip-dlcs",
            appName,
        ]

        try await LegendaryRunner.stream(args) { line in
            onLine(line)
            if let pct = LegendaryRunner.parseProgress(line: line) {
                onProgress(pct)
            }
        }
    }

    // MARK: - Post-install metadata

    /// After `install`, ask legendary where the launch exe ended up.
    /// Returns an absolute path string. Throws if legendary's info
    /// doesn't include a launch_executable field.
    static func launchExePath(appName: String) async throws -> String {
        let raw = try await LegendaryRunner.capture(["info", appName, "--json"])
        guard let data = raw.data(using: .utf8) else {
            throw EpicLibraryError.metadataMissing("Couldn't UTF-8 decode info output")
        }
        let info = try JSONDecoder().decode(InfoJSON.self, from: data)
        // The structure has shifted between legendary versions; we
        // probe several plausible paths.
        if let installed = info.installed,
           let exe = installed.executable,
           let dir = installed.install_path
        {
            return URL(fileURLWithPath: dir)
                .appendingPathComponent(exe).path
        }
        if let manifest = info.manifest,
           let exe = manifest.launch_exe,
           let dir = info.install?.install_path
        {
            return URL(fileURLWithPath: dir)
                .appendingPathComponent(exe).path
        }
        throw EpicLibraryError.metadataMissing(
            "legendary info \(appName) didn't include a launch executable path. "
            + "Run `\(LegendaryInstaller.legendaryBinary.path) info \(appName) --json` manually and inspect the JSON shape."
        )
    }

    /// Wire format for `legendary info <app> --json`. Defensive —
    /// every field is optional; we probe for the shape upstream
    /// actually returned and don't fail on extras.
    private struct InfoJSON: Decodable {
        let installed: Installed?
        let install: Install?
        let manifest: Manifest?

        struct Installed: Decodable {
            let executable: String?
            let install_path: String?
        }
        struct Install: Decodable {
            let install_path: String?
        }
        struct Manifest: Decodable {
            let launch_exe: String?
        }
    }
}

enum EpicLibraryError: LocalizedError {
    case metadataMissing(String)

    var errorDescription: String? {
        switch self {
        case .metadataMissing(let d): return "Epic metadata missing: \(d)"
        }
    }
}
