import CryptoKit
import Foundation

/// Fetches profile-declared runtime DLLs before a known launcher runs.
///
/// `KnownLaunchers.json` stays declarative:
///
///     requiredDLLs: [
///       {
///         "name": "Qt5Svg.dll",
///         "sourceURL": "https://download.qt.io/.../qtsvg....7z",
///         "archivePath": "5.15.2/msvc2019_64/bin/Qt5Svg.dll",
///         "destinationPath": "Qt5Svg.dll"
///       }
///     ]
///
/// The provisioner handles Homebrew `sevenzip`, download caching,
/// archive extraction, and copy-to-destination.
///
/// FRAGILITY
/// ---------
/// 1. **Qt packaging moves.** WWM needs `Qt5Svg.dll`. Qt no longer
///    presents a simple old-style "minimal offline installer" for
///    Qt 5.15.2; the stable official source is the Qt online
///    repository component archive:
///    `qt.qt5.5152.win64_msvc2019_64/...qtsvg...7z`.
///    If Qt removes that old component repository, update the WWM
///    profile's `sourceURL`/`archivePath`, not launch code.
///
/// 2. **7zip binary name drift.** Homebrew's formula is `sevenzip`,
///    but installs have used both `7zz` and `7z` depending on era.
///    We resolve both before and after `brew install sevenzip`.
///
/// 3. **DLL provenance.** Carafe deliberately does not scrape DLL
///    mirror sites. Profiles should point at an official vendor
///    archive or a trusted upstream release. Add `sha256` when the
///    upstream URL is version-pinned and stable.
enum LauncherDLLProvisioner {

    private static let minimumCachedBytes: Int64 = 1_024

    static func provision(
        for profile: LauncherProfile,
        bottle: Bottle,
        exeURL: URL,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        guard let requiredDLLs = profile.fix.requiredDLLs,
              !requiredDLLs.isEmpty
        else { return }

        log("Known launcher profile “\(profile.displayName)” requires \(requiredDLLs.count) DLL check(s).")

        for dll in requiredDLLs {
            try await provision(dll, bottle: bottle, exeURL: exeURL, log: log)
        }
    }

    private static func provision(
        _ dll: LauncherProfile.RequiredDLL,
        bottle: Bottle,
        exeURL: URL,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        let destination = try destinationURL(for: dll, bottle: bottle, exeURL: exeURL)
        if fileLooksPresent(destination) {
            log("✓ \(dll.name) already present at \(displayPath(destination, bottle: bottle, exeURL: exeURL)).")
            return
        }

        log("Provisioning \(dll.name)…")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let source = try await download(dll, log: log)
        try verifySHA256IfNeeded(dll, fileURL: source)

        let stagedDLL: URL
        if source.pathExtension.lowercased() == "dll" {
            stagedDLL = source
        } else {
            stagedDLL = try await extract(dll, archive: source, log: log)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: stagedDLL, to: destination)
        _ = try? await ShellRunner.runToCompletion(
            "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", destination.path]
        )

        guard fileLooksPresent(destination) else {
            throw Failure.installFailed(
                "\(dll.name) copy completed but the destination is missing: \(destination.path)"
            )
        }

        log("✓ Installed \(dll.name) → \(displayPath(destination, bottle: bottle, exeURL: exeURL)).")
    }

    // MARK: - Destination

    private static func destinationURL(
        for dll: LauncherProfile.RequiredDLL,
        bottle: Bottle,
        exeURL: URL
    ) throws -> URL {
        let raw = (dll.destinationPath?.isEmpty == false)
            ? dll.destinationPath!
            : dll.name

        let exeDir = exeURL.deletingLastPathComponent().standardizedFileURL
        let prefix = bottle.prefixURL.standardizedFileURL

        if raw.contains("{exeDir}") || raw.contains("{prefix}") {
            let replaced = raw
                .replacingOccurrences(of: "{exeDir}", with: exeDir.path)
                .replacingOccurrences(of: "{prefix}", with: prefix.path)
            return URL(fileURLWithPath: replaced).standardizedFileURL
        }

        guard !raw.hasPrefix("/") else {
            throw Failure.invalidProfile(
                "\(dll.name) uses an absolute destination path. Use {exeDir} or {prefix} tokens instead."
            )
        }

        if raw.hasPrefix("drive_c/") || raw.hasPrefix("dosdevices/") {
            return prefix.appendingPathComponent(raw).standardizedFileURL
        }
        return exeDir.appendingPathComponent(raw).standardizedFileURL
    }

    private static func displayPath(_ url: URL, bottle: Bottle, exeURL: URL) -> String {
        let path = url.standardizedFileURL.path
        let exeDir = exeURL.deletingLastPathComponent().standardizedFileURL.path
        let prefix = bottle.prefixURL.standardizedFileURL.path

        let exePrefix = exeDir.hasSuffix("/") ? exeDir : exeDir + "/"
        if path.hasPrefix(exePrefix) {
            return "exe folder/\(String(path.dropFirst(exePrefix.count)))"
        }

        let bottlePrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        if path.hasPrefix(bottlePrefix) {
            return "prefix/\(String(path.dropFirst(bottlePrefix.count)))"
        }

        return path
    }

    private static func fileLooksPresent(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        else { return false }
        return size > 0
    }

    // MARK: - Download

    private static func download(
        _ dll: LauncherProfile.RequiredDLL,
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        guard let url = URL(string: dll.sourceURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https"
        else {
            throw Failure.invalidProfile("\(dll.name) has an invalid or non-HTTPS source URL.")
        }

        let cacheURL = downloadsDirectory
            .appendingPathComponent(cacheFilename(for: url), isDirectory: false)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size]) as? Int64,
           size >= minimumCachedBytes {
            log("Using cached \(dll.name) source (\(formatBytes(size))).")
            return cacheURL
        }

        log("Downloading \(dll.name) source from \(url.host ?? "vendor")…")
        var request = URLRequest(url: url)
        request.timeoutInterval = 180

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw Failure.downloadFailed("\(dll.name): HTTP \(http.statusCode).")
            }

            try? FileManager.default.removeItem(at: cacheURL)
            try FileManager.default.moveItem(at: tempURL, to: cacheURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size]) as? Int64 ?? 0
            log("Downloaded \(dll.name) source (\(formatBytes(size))).")
            return cacheURL
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.downloadFailed("\(dll.name): \(error.localizedDescription)")
        }
    }

    private static var downloadsDirectory: URL {
        let dir = AppState.supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("DLLProvisioning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFilename(for url: URL) -> String {
        let basename = url.lastPathComponent.isEmpty ? "download.bin" : url.lastPathComponent
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest)-\(sanitizeFilename(basename))"
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private static func verifySHA256IfNeeded(
        _ dll: LauncherProfile.RequiredDLL,
        fileURL: URL
    ) throws {
        guard let expected = dll.sha256?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty
        else { return }

        let data = try Data(contentsOf: fileURL)
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actual.lowercased() == expected.lowercased() else {
            throw Failure.downloadFailed(
                "\(dll.name) SHA-256 mismatch. Expected \(expected), got \(actual)."
            )
        }
    }

    // MARK: - Extract

    private static func extract(
        _ dll: LauncherProfile.RequiredDLL,
        archive: URL,
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let tool = try await ensureSevenZip(log: log)

        let extractionRoot = extractionDirectory(for: archive)
        try? FileManager.default.removeItem(at: extractionRoot)
        try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

        log("Extracting \(dll.name) with 7zip…")

        var args = ["x", archive.path, "-y", "-o\(extractionRoot.path)"]
        if let archivePath = dll.archivePath, !archivePath.isEmpty {
            args.append(archivePath)
        }

        let result = try await ShellRunner.runToCompletion(
            tool,
            arguments: args,
            throwOnFailure: false
        )
        guard result.didSucceed else {
            throw Failure.extractFailed(
                "\(dll.name): 7zip exited \(result.exitCode).\n\(result.stderr)"
            )
        }

        if let archivePath = dll.archivePath, !archivePath.isEmpty {
            let exact = extractionRoot.appendingPathComponent(archivePath)
            if fileLooksPresent(exact) { return exact }
        }

        if let found = findFile(named: dll.name, under: extractionRoot) {
            return found
        }

        throw Failure.extractFailed(
            "\(dll.name) was not found after extraction. "
            + "The source archive layout may have changed; update KnownLaunchers.json."
        )
    }

    private static func extractionDirectory(for archive: URL) -> URL {
        let stem = archive.deletingPathExtension().lastPathComponent
        return AppState.supportDirectory
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("DLLProvisioning", isDirectory: true)
            .appendingPathComponent(stem, isDirectory: true)
    }

    private static func findFile(named name: String, under root: URL) -> URL? {
        let target = name.lowercased()
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent.lowercased() == target else { continue }
            if fileLooksPresent(url) { return url }
        }
        return nil
    }

    // MARK: - sevenzip

    private static func ensureSevenZip(
        log: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        if let path = sevenZipPath() { return path }

        guard FileManager.default.isExecutableFile(atPath: HomebrewChecker.brewPath) else {
            throw Failure.prerequisiteMissing(
                "Homebrew is required to install sevenzip for DLL provisioning."
            )
        }

        log("Installing sevenzip via Homebrew so Carafe can extract DLL archives…")
        let result = try await ShellRunner.runToCompletion(
            HomebrewChecker.brewPath,
            arguments: ["install", "sevenzip"],
            throwOnFailure: false
        )
        guard result.didSucceed else {
            throw Failure.prerequisiteMissing(
                "Couldn't install sevenzip: brew exited \(result.exitCode).\n\(result.stderr)"
            )
        }

        if let path = sevenZipPath() { return path }
        throw Failure.prerequisiteMissing(
            "Homebrew reported sevenzip installed, but Carafe couldn't find 7zz or 7z."
        )
    }

    private static func sevenZipPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/7zz",
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7zz",
            "/usr/local/bin/7z"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case invalidProfile(String)
        case prerequisiteMissing(String)
        case downloadFailed(String)
        case extractFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let detail):
                return "Launcher DLL profile is invalid: \(detail)"
            case .prerequisiteMissing(let detail):
                return detail
            case .downloadFailed(let detail):
                return "Couldn't download required launcher DLL: \(detail)"
            case .extractFailed(let detail):
                return "Couldn't extract required launcher DLL: \(detail)"
            case .installFailed(let detail):
                return "Couldn't install required launcher DLL: \(detail)"
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
