import Foundation

/// Manages a Carafe-local install of DXMT (3Shain/DXMT), the native
/// D3D11/12 → Metal translation layer for Wine on Apple Silicon.
///
/// Why DXMT alongside D3DMetal and DXVK:
///   - **D3DMetal** ships with GPTK and targets the Wine 7.7 branch
///     in that toolkit. Works well on GPTK bottles but the API shim
///     it expects from wine is older than what Wine Staging 11.x
///     exposes — Steam-class games under Staging often render
///     glitches or run slow.
///   - **DXVK** translates DX9-11 → Vulkan → Metal via MoltenVK.
///     Adds an extra layer of translation; works but slower.
///   - **DXMT** goes DX11 → Metal directly. Built against modern
///     Wine API surfaces so it pairs naturally with Wine Staging.
///     Faster than DXVK and more reliable than D3DMetal on Staging.
///
/// Disk layout:
///
///     ~/Library/Application Support/Carafe/DXMT/dxmt-0.60/
///       ├── x64/
///       │   ├── d3d11.dll
///       │   ├── dxgi.dll
///       │   └── d3d10core.dll  (when shipped)
///       └── x32/                (when shipped — 32-bit Windows DLLs)
///           └── …
///
/// Per-bottle deployment: when a game launches with
/// `graphicsBackend == .dxmt` and the bottle's `installedComponents`
/// ledger doesn't already contain `"dxmt"`, the launcher calls
/// `installInto(bottle:)`, which:
///   1. Ensures the global cache is downloaded (`ensureDownloaded`)
///   2. Copies the 64-bit DLLs into the bottle's
///      `drive_c/windows/system32/`
///   3. Copies any 32-bit DLLs into `drive_c/windows/syswow64/`
///   4. Caller (the launcher) records `"dxmt"` in the bottle's
///      ledger via `BottleManager.markComponentsInstalled`.
///
/// FRAGILITY
/// ---------
/// 1. **Pinned version.** `version` is hardcoded below. To bump it,
///    look at https://github.com/3Shain/DXMT/releases for the
///    current release tag, edit `version`, and verify by running a
///    fresh launch with `.dxmt`. The downloader will redownload and
///    extract into a new versioned subdirectory; the old install
///    remains on disk until manually cleaned up.
///
/// 2. **Asset name convention.** We assume the release archive is
///    named `dxmt-v<version>.zip` and contains `x64/` (always) and
///    `x32/` (optionally) subdirectories with the Windows DLLs. If
///    3Shain restructures the archive — flattens the dirs, renames
///    them — `installInto(bottle:)` will throw
///    `Failure.verifyFailed("No DXMT DLLs found …")` rather than
///    silently no-op. Inspect the extracted directory and adjust
///    `dllSource64` / `dllSource32` to match.
///
/// 3. **DLL coverage.** Stock DXMT ships `d3d11.dll` + `dxgi.dll`
///    plus sometimes `d3d10core.dll`. The DLL-override side is in
///    `ResolvedConfig.effectiveDLLOverrides`. If a future DXMT
///    release adds `d3d12.dll` or `d3d9.dll`, expand BOTH `dllNames`
///    below AND the override set in CompatibilityConfig.swift so
///    wine picks the native DLL up.
enum DXMTInstaller {

    /// Currently-targeted DXMT release. Update when 3Shain ships a
    /// newer version; rerun a `.dxmt` launch to refresh per-bottle
    /// installs.
    static let version = "0.60"

    /// Asset URL on 3Shain/DXMT. Built from `version`.
    static var downloadURL: URL {
        URL(string:
            "https://github.com/3Shain/DXMT/releases/download/v\(version)/dxmt-v\(version).zip"
        )!
    }

    /// Versioned per-Carafe install directory. Lives under our own
    /// app-support root so uninstalling Carafe cleanly removes DXMT.
    static var installDirectory: URL {
        let dir = AppState.supportDirectory
            .appendingPathComponent("DXMT", isDirectory: true)
            .appendingPathComponent("dxmt-\(version)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Names of DLLs DXMT may ship. Lookup is opportunistic — if a
    /// DLL isn't present in the extracted archive, it's skipped
    /// without error. Order matters only for log clarity.
    static let dllNames = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]

    /// True iff the canonical 64-bit `d3d11.dll` exists in the
    /// extracted bundle. Cheap; safe from any context.
    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: dllSource64(named: "d3d11.dll").path)
    }

    private static func dllSource64(named name: String) -> URL {
        installDirectory
            .appendingPathComponent("x64", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func dllSource32(named name: String) -> URL {
        installDirectory
            .appendingPathComponent("x32", isDirectory: true)
            .appendingPathComponent(name)
    }

    // MARK: - Public pipeline

    /// Ensure DXMT is downloaded + extracted into the global cache.
    /// Idempotent; cheap when already installed.
    static func ensureDownloaded(
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        if isDownloaded {
            log("DXMT \(version) already cached at \(installDirectory.path).")
            return
        }
        let zipURL = try await downloadZip(log: log)
        try extract(zip: zipURL, log: log)
        try await stripQuarantine(log: log)
        try verifyDownload()
        log("DXMT \(version) ready at \(installDirectory.path).")
    }

    /// Install DXMT into a specific bottle. Copies DLLs from the
    /// global cache into the bottle's `system32/` and `syswow64/`.
    /// Calls `ensureDownloaded` first.
    ///
    /// Caller responsibility: record `"dxmt"` in the bottle's
    /// `installedComponents` ledger via
    /// `BottleManager.markComponentsInstalled` so subsequent
    /// launches short-circuit the install step.
    static func installInto(
        bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        try await ensureDownloaded(log: log)

        let system32 = bottle.prefixURL
            .appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        let syswow64 = bottle.prefixURL
            .appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)

        let fm = FileManager.default
        // Ensure both target dirs exist — the prefix has them by
        // default after wineboot but be defensive.
        try? fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try? fm.createDirectory(at: syswow64, withIntermediateDirectories: true)

        var copied = 0

        for name in dllNames {
            let src64 = dllSource64(named: name)
            if fm.fileExists(atPath: src64.path) {
                let dest = system32.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: src64, to: dest)
                log("→ DXMT/\(name) (64-bit) → drive_c/windows/system32/")
                copied += 1
            }
            let src32 = dllSource32(named: name)
            if fm.fileExists(atPath: src32.path) {
                let dest = syswow64.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: src32, to: dest)
                log("→ DXMT/\(name) (32-bit) → drive_c/windows/syswow64/")
                copied += 1
            }
        }

        if copied == 0 {
            // The cache exists (ensureDownloaded passed) but the
            // expected DLL paths inside it are empty. Almost
            // certainly a DXMT release-archive restructure — see
            // FRAGILITY point 2 in the type doc.
            throw Failure.verifyFailed(
                "No DXMT DLLs found in \(installDirectory.path). "
                + "The release archive layout may have changed; see "
                + "the FRAGILITY notes in DXMTInstaller.swift."
            )
        }
        log("Installed DXMT \(version) into bottle “\(bottle.name)” (\(copied) DLL file(s)).")
    }

    // MARK: - Download + extract

    private static func downloadZip(
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let cachedURL = AppState.supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("dxmt-v\(version).zip")
        try? FileManager.default.createDirectory(
            at: cachedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // DXMT archives are small (~5 MB). A previously-cached file
        // larger than 100 KB is plausibly intact; anything smaller
        // is a truncated download we should retry.
        if let size = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size]) as? Int64,
           size >= 100_000 {
            log("Using cached DXMT zip (\(formatBytes(size))).")
            return cachedURL
        }

        log("Downloading DXMT \(version) from 3Shain/DXMT…")
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 120

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.downloadFailed(
                    "HTTP \(http.statusCode) from 3Shain/DXMT releases. "
                    + "Check https://github.com/3Shain/DXMT/releases to verify "
                    + "v\(version) exists and that the asset is named "
                    + "dxmt-v\(version).zip; bump DXMTInstaller.version otherwise."
                )
            }
            try? FileManager.default.removeItem(at: cachedURL)
            try FileManager.default.moveItem(at: tempURL, to: cachedURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size]) as? Int64 ?? 0
            log("Downloaded DXMT zip (\(formatBytes(size))).")
            return cachedURL
        } catch let err as Failure {
            throw err
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
    }

    private static func extract(
        zip: URL,
        log: @Sendable @escaping (String) -> Void
    ) throws {
        // Wipe and recreate the extraction target so a partial prior
        // run can't leave stale DLLs behind.
        try? FileManager.default.removeItem(at: installDirectory)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        log("Extracting dxmt-v\(version).zip into \(installDirectory.path)…")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // `-q` keeps the log focused. `-d` sets the output dir.
        proc.arguments = ["-q", zip.path, "-d", installDirectory.path]
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
            throw Failure.extractFailed("unzip exited \(proc.terminationStatus): \(stderr)")
        }
        log("Extracted DXMT bundle.")
    }

    /// Strip the `com.apple.quarantine` xattr that downloaded
    /// archives carry. Wine doesn't itself care, but the DLLs will
    /// occasionally trip Gatekeeper-style heuristics when loaded.
    /// Mirrors the same workaround we apply to Wine Staging + GPTK.
    private static func stripQuarantine(
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        let result = try? await ShellRunner.runToCompletion(
            "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", installDirectory.path]
        )
        if let result, !result.didSucceed {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if stderr.contains("no such xattr") || stderr.contains("no such file") {
                return
            }
            log("⚠️ xattr returned non-zero stripping DXMT quarantine: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    private static func verifyDownload() throws {
        // Must have at least d3d11.dll under x64/.
        guard isDownloaded else {
            throw Failure.verifyFailed(
                "Expected \(dllSource64(named: "d3d11.dll").path) after extract — "
                + "DXMT archive layout may have changed. See FRAGILITY notes."
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
            case .downloadFailed(let d): return "Couldn't download DXMT: \(d)"
            case .extractFailed(let d):  return "Couldn't extract DXMT zip: \(d)"
            case .verifyFailed(let d):   return "DXMT extracted but verification failed: \(d)"
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
