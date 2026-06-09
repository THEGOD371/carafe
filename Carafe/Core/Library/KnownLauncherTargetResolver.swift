import Foundation

/// Resolves a known launcher profile's "real game exe" target.
///
/// Profiles store `skipLauncherTo` as a relative path like:
///
///     Engine/Binaries/Win64r/wwm.exe
///
/// That path is intentionally *not* always relative to the launcher
/// exe's immediate parent. WWM, for example, launches from:
///
///     .../wwm/Win32/deploy/launcher.exe
///
/// while the game lands at:
///
///     .../wwm/Engine/Binaries/Win64r/wwm.exe
///
/// So we walk upward from the launcher directory until the bottle
/// root, trying the relative target at each level.
///
/// FRAGILITY: launchers move files around during updates. This
/// resolver only switches once the target exe already exists. If WWM
/// renames `Win64r` again or ships region-specific folders, add
/// extra fallback paths to the profile/model. As a last resort, the
/// resolver can recursively scan the bottle for profile exe names,
/// but explicit candidates are safer and faster.
enum KnownLauncherTargetResolver {
    static func targetForLauncher(
        exeURL: URL,
        bottle: Bottle,
        profile: LauncherProfile? = nil
    ) -> URL? {
        let launcherProfile = profile ?? KnownLaunchers.match(exeURL: exeURL)
        guard let launcherProfile else { return nil }

        let fm = FileManager.default
        let current = exeURL.standardizedFileURL
        let exeDir = current.deletingLastPathComponent().standardizedFileURL
        let prefixRoot = bottle.prefixURL.standardizedFileURL
        let prefixPath = prefixRoot.path

        var roots: [URL] = []
        var cursor = exeDir
        while true {
            roots.append(cursor)
            if cursor.path == prefixPath { break }

            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            if parent.path == cursor.path { break }

            // Stay inside the bottle when the exe is inside it.
            // Absolute external launchers still get a short upward
            // walk because they may be app folders outside prefix.
            if current.path.hasPrefix(prefixPath), !parent.path.hasPrefix(prefixPath) {
                break
            }
            cursor = parent
        }

        let driveC = prefixRoot.appendingPathComponent("drive_c", isDirectory: true)
        if !roots.contains(where: { $0.standardizedFileURL.path == driveC.standardizedFileURL.path }) {
            roots.append(driveC)
        }

        for targetPath in candidatePaths(from: launcherProfile) {
            for root in roots {
                let candidate = root.appendingPathComponent(targetPath).standardizedFileURL
                guard candidate.path != current.path else { continue }
                if fm.fileExists(atPath: candidate.path), PEValidator.looksLikePE(at: candidate) {
                    return candidate
                }
            }
        }

        return recursiveFallback(in: prefixRoot, current: current, profile: launcherProfile)
    }

    private static func candidatePaths(from profile: LauncherProfile) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        func append(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            paths.append(trimmed)
        }

        append(profile.fix.skipLauncherTo)
        profile.fix.skipLauncherCandidates?.forEach { append($0) }
        return paths
    }

    private static func recursiveFallback(
        in root: URL,
        current: URL,
        profile: LauncherProfile
    ) -> URL? {
        var candidateNames: [String] = []
        if let primaryName = profile.fix.skipLauncherTo?.split(separator: "/").last {
            candidateNames.append(String(primaryName))
        }
        for path in profile.fix.skipLauncherCandidates ?? [] {
            if let name = path.split(separator: "/").last {
                candidateNames.append(String(name))
            }
        }
        candidateNames.append(contentsOf: profile.match.exeNames ?? [])

        let names = Set(candidateNames.map { $0.lowercased() })
        guard !names.isEmpty else { return nil }

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var matches: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let standardized = url.standardizedFileURL
            guard standardized.path != current.path else { continue }
            guard names.contains(standardized.lastPathComponent.lowercased()) else { continue }
            guard PEValidator.looksLikePE(at: standardized) else { continue }
            matches.append(standardized)
        }

        return matches.sorted(by: scoreSort).first
    }

    private static func scoreSort(_ lhs: URL, _ rhs: URL) -> Bool {
        score(lhs) > score(rhs)
    }

    private static func score(_ url: URL) -> Int {
        let path = url.path.lowercased()
        var value = 0
        if path.contains("/engine/binaries/") { value += 100 }
        if path.contains("/win64") { value += 80 }
        if path.contains("/win32") { value -= 80 }
        if path.contains("/deploy/") { value -= 40 }
        if path.contains("/_deploy/") { value -= 80 }
        if url.lastPathComponent.lowercased() == "wwm.exe" { value += 30 }
        return value
    }
}
