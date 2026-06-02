import Foundation

/// Reads launcher-specific logs for profile-declared failure signals.
///
/// This is deliberately data-driven through `KnownLaunchers.json`.
/// WWM's current useful signal is `not support avx` inside
/// `launcher.log`; the same mechanism can later explain missing
/// WebView runtimes, blocked CDN updates, or launcher-specific error
/// codes without hardcoding those strings in `RunSession`.
///
/// FRAGILITY: launchers rotate or truncate logs however they like.
/// We only read the tail of each file, and diagnostics are advisory:
/// no launch is blocked solely because a signal is present.
enum KnownLauncherDiagnostics {
    static func messages(
        for profile: LauncherProfile,
        bottle: Bottle,
        exeURL: URL
    ) -> [String] {
        guard let signals = profile.fix.failureSignals,
              !signals.isEmpty
        else { return [] }

        return signals.compactMap { signal in
            guard let text = tailOfLog(for: signal, bottle: bottle, exeURL: exeURL)
            else { return nil }
            if text.localizedCaseInsensitiveContains(signal.contains) {
                return signal.message
            }
            return nil
        }
    }

    private static func tailOfLog(
        for signal: LauncherProfile.FailureSignal,
        bottle: Bottle,
        exeURL: URL
    ) -> String? {
        let url = KnownLauncherPathResolver.resolve(signal.logPath, bottle: bottle, exeURL: exeURL)
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let tailBytes: UInt64 = 16 * 1024
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
    }

    static func logContains(
        _ needle: String,
        logPath: String,
        bottle: Bottle,
        exeURL: URL
    ) -> Bool {
        let signal = LauncherProfile.FailureSignal(
            logPath: logPath,
            contains: needle,
            message: ""
        )
        return tailOfLog(for: signal, bottle: bottle, exeURL: exeURL)?
            .localizedCaseInsensitiveContains(needle) == true
    }
}
