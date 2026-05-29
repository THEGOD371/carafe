import Foundation

/// Manages a Carafe-local install of upstream WineHQ's Wine Staging
/// build for macOS, from Gcenx's macOS_Wine_builds GitHub releases.
///
/// Unlike GPTK (which goes through Homebrew Cask), Wine Staging
/// installs into Carafe's own application-support directory:
///
///   ~/Library/Application Support/Carafe/Wine/staging-11.9/
///     └── Wine Staging.app/
///         └── Contents/Resources/wine/bin/
///             ├── wine            ← unified binary (no separate wine64)
///             └── wineserver
///
/// FRAGILITY (the unified-binary convention): modern Wine (8.0+) ships
/// a single `wine` binary that handles both 32-bit and 64-bit Windows
/// executables. The old `wine` / `wine64` split is gone. GPTK predates
/// this change and still has `wine64` at `/opt/homebrew/bin/wine64`,
/// so our `WineRunner.wine64Path(for:)` resolver maps each build to
/// the correct binary name. If a future Wine release adds back the
/// split (unlikely), this constant needs a second binary path.
///
/// This avoids both the brew-tap drift problem (the `wine-crossover`
/// cask was removed at some point — we got bitten once already) and
/// any conflict with GPTK's symlinks at `/opt/homebrew/bin/wine64`.
///
/// ## ⚠️ FRAGILITY
///
/// 1. **Pinned version.** `version` is hardcoded to 11.9. Bumping
///    means downloading + extracting again into a new
///    `staging-<new>/` subdirectory. Old version remains until
///    explicitly cleaned up; no auto-upgrade path in v1.
///
/// 2. **`.app` bundle layout.** Gcenx's tarballs contain a
///    `Wine Staging.app` (or `Wine Devel.app` for the devel flavour)
///    with the binaries under `Contents/Resources/wine/bin/`. If a
///    future release restructures this — moves the `.app` to a
///    different name, or flattens the wine/ subdir — our path
///    resolution returns a stale string and `isInstalled` returns
///    false post-install. Adjust the constants below.
///
/// 3. **xattr quarantine.** `tar` extracts files with the macOS
///    quarantine attribute set (downloaded-via-network bit). The
///    bundled wine binaries refuse to execute under Gatekeeper until
///    quarantine is stripped — we do that at the end of install.
///
/// 4. **Tarball format.** `wine-staging-<v>-osx64.tar.xz` is xz-
///    compressed. macOS's `tar` (BSD tar) supports xz natively since
///    10.12; we shell out to `/usr/bin/tar -xJf …`. No external
///    dependencies.
enum WineStagingInstaller {

    /// Currently-targeted Wine Staging release.
    static let version = "11.9"

    /// Tarball asset URL on Gcenx/macOS_Wine_builds.
    static var downloadURL: URL {
        URL(string:
            "https://github.com/Gcenx/macOS_Wine_builds/releases/download/\(version)/wine-staging-\(version)-osx64.tar.xz"
        )!
    }

    /// Versioned per-Carafe install directory. Living under our own
    /// app-support root means uninstalling Carafe cleanly removes
    /// the wine install too.
    static var installDirectory: URL {
        let dir = AppState.supportDirectory
            .appendingPathComponent("Wine", isDirectory: true)
            .appendingPathComponent("staging-\(version)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `.app` bundle inside the install dir after extraction.
    private static var wineAppBundle: URL {
        installDirectory.appendingPathComponent("Wine Staging.app", isDirectory: true)
    }

    /// Where the Carafe-installed Wine binary lives. Modern Wine
    /// (8.0+) uses a single `wine` binary for both architectures —
    /// no separate `wine64`. See the FRAGILITY block above.
    static var winePath: String {
        wineAppBundle
            .appendingPathComponent("Contents/Resources/wine/bin/wine")
            .path
    }

    static var wineserverPath: String {
        wineAppBundle
            .appendingPathComponent("Contents/Resources/wine/bin/wineserver")
            .path
    }

    /// True iff the extracted wine binary exists and is executable.
    /// Cheap; called from `WineBuild` path resolution on every wine
    /// invocation.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: winePath)
    }

    // MARK: - Install pipeline

    /// Download + extract Wine Staging into the install directory.
    /// Streams progress via `log`. Idempotent — returns immediately
    /// if `isInstalled` is already true.
    static func install(
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        if isInstalled {
            log("Wine Staging \(version) already installed at \(installDirectory.path).")
            return
        }

        // Download to the shared Downloads cache; reuse if a prior
        // run already grabbed the tarball.
        let tarballURL = try await downloadTarball(log: log)
        try extract(tarball: tarballURL, log: log)
        try await stripQuarantine(log: log)
        try verifyInstall()
        log("Wine Staging \(version) ready at \(installDirectory.path).")
    }

    private static func downloadTarball(
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let cachedURL = AppState.supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("wine-staging-\(version)-osx64.tar.xz")
        try? FileManager.default.createDirectory(
            at: cachedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Reuse cache if size looks plausible (≥ 50 MB — Wine
        // tarballs are ~190 MB; anything tiny is a half-failed
        // download we should redo).
        if let size = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size]) as? Int64,
           size >= 50_000_000 {
            log("Using cached Wine Staging tarball (\(formatBytes(size))).")
            return cachedURL
        }

        log("Downloading Wine Staging \(version) from Gcenx releases (~190 MB)…")
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 300

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.downloadFailed("HTTP \(http.statusCode) from Gcenx releases.")
            }
            try? FileManager.default.removeItem(at: cachedURL)
            try FileManager.default.moveItem(at: tempURL, to: cachedURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size]) as? Int64 ?? 0
            log("Downloaded Wine Staging tarball (\(formatBytes(size))).")
            return cachedURL
        } catch let err as Failure {
            throw err
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
    }

    private static func extract(
        tarball: URL,
        log: @Sendable @escaping (String) -> Void
    ) throws {
        // Clean the target dir so the new extraction has no leftovers
        // from a partial prior run.
        try? FileManager.default.removeItem(at: wineAppBundle)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        log("Extracting wine-staging-\(version)-osx64.tar.xz into \(installDirectory.path)…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xJf", tarball.path, "-C", installDirectory.path]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw Failure.extractFailed(error.localizedDescription)
        }

        if proc.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? "<no stderr>"
            throw Failure.extractFailed("tar exited \(proc.terminationStatus): \(stderr)")
        }
        log("Extracted Wine Staging bundle.")
    }

    /// Strip the com.apple.quarantine xattr from the extracted .app
    /// so Gatekeeper doesn't block the wine binaries on first run.
    /// Mirrors the same workaround we apply to GPTK.
    private static func stripQuarantine(
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        log("Stripping quarantine attribute from Wine Staging.app…")
        let result = try? await ShellRunner.runToCompletion(
            "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", wineAppBundle.path]
        )
        if let result, !result.didSucceed {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // "No such xattr" is benign — the attribute was already
            // clean or never set.
            if stderr.contains("no such xattr") || stderr.contains("no such file") {
                log("Quarantine attribute already clean.")
                return
            }
            log("⚠️ xattr returned non-zero: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func verifyInstall() throws {
        guard FileManager.default.isExecutableFile(atPath: winePath) else {
            throw Failure.verifyFailed(
                "wine binary not at expected path after extract: \(winePath). "
                + "(Modern Wine 8.0+ ships a single `wine` binary, not `wine64`. "
                + "If a future Wine release re-introduces the split, the path needs updating.)"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: wineserverPath) else {
            throw Failure.verifyFailed(
                "wineserver not at expected path after extract: \(wineserverPath)"
            )
        }
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case downloadFailed(String)
        case extractFailed(String)
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let d):
                return "Couldn't download Wine Staging tarball: \(d)"
            case .extractFailed(let d):
                return "Couldn't extract Wine Staging tarball: \(d)"
            case .verifyFailed(let d):
                return "Wine Staging extracted but verification failed: \(d)"
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
