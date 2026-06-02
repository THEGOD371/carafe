import Foundation

/// Shared path/token resolver for launcher profile paths.
enum KnownLauncherPathResolver {
    static func resolve(
        _ raw: String,
        bottle: Bottle,
        exeURL: URL
    ) -> URL {
        let exeDir = exeURL.deletingLastPathComponent().standardizedFileURL
        let prefix = bottle.prefixURL.standardizedFileURL

        if raw.contains("{exeDir}") || raw.contains("{prefix}") {
            let replaced = raw
                .replacingOccurrences(of: "{exeDir}", with: exeDir.path)
                .replacingOccurrences(of: "{prefix}", with: prefix.path)
            return URL(fileURLWithPath: replaced).standardizedFileURL
        }

        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }

        if raw.hasPrefix("drive_c/") || raw.hasPrefix("dosdevices/") {
            return prefix.appendingPathComponent(raw).standardizedFileURL
        }

        return exeDir.appendingPathComponent(raw).standardizedFileURL
    }
}
