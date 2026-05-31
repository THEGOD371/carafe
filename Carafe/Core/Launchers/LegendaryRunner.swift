import Foundation

/// Calls the `legendary` Epic CLI installed by `LegendaryInstaller`.
/// Three usage patterns:
///
///   - `capture(_:)` — run-to-completion, return combined stdout. For
///     "give me a string" commands (`status`, `--version`, etc.).
///   - `decodeJSON(_:as:)` — capture + JSONDecoder. For commands that
///     return structured data (`list-games --json`,
///     `list-installed --json`, `info --json`).
///   - `stream(_:onLine:)` — line-by-line streaming for long-running
///     operations like `install` (which prints
///     `[DLManager] INFO: = Progress: 12.34%` lines we want to parse
///     for the UI progress bar).
///
/// All three implicitly use the venv's `legendary` binary at
/// `LegendaryInstaller.legendaryBinary.path`.
///
/// FRAGILITY
/// ---------
/// 1. **legendary stdout vs stderr.** Most progress info lands on
///    stderr; legendary uses stdout for "the answer" (game lists,
///    info dumps). We merge both into the line stream for `stream`
///    but only return stdout for `capture` / `decodeJSON`. If a
///    future legendary changes that split, JSON decoding may fail
///    because the answer ended up on stderr instead.
/// 2. **Non-zero exit on "no games installed" etc.** legendary
///    sometimes exits 1 when there's nothing to list. We treat any
///    non-zero exit as an error and surface the stderr — callers
///    that need to tolerate "empty" should catch
///    `Failure.nonZeroExit` and inspect.
enum LegendaryRunner {

    // MARK: - One-shot commands

    /// Run `legendary <args>`, return its stdout. Throws if the
    /// binary isn't installed or the process exits non-zero.
    static func capture(_ args: [String]) async throws -> String {
        guard LegendaryInstaller.isInstalled else {
            throw Failure.notInstalled
        }
        let result = try await ShellRunner.runToCompletion(
            LegendaryInstaller.legendaryBinary.path,
            arguments: args
        )
        if !result.didSucceed {
            throw Failure.nonZeroExit(
                code: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    /// Run `legendary <args>` and JSON-decode the stdout. Caller picks
    /// the type. For lists, pass `[T].self` etc.
    static func decodeJSON<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        let raw = try await capture(args)
        guard let data = raw.data(using: .utf8) else {
            throw Failure.decodeFailed("Couldn't UTF-8 decode legendary stdout")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.decodeFailed(
                "JSON decode failed: \(error.localizedDescription)\n"
                + "Stdout head: \(raw.prefix(500))"
            )
        }
    }

    // MARK: - Streaming for installs

    /// Stream `legendary <args>` line-by-line. Each stdout AND stderr
    /// line is delivered to `onLine`. Throws on non-zero exit.
    static func stream(
        _ args: [String],
        onLine: @Sendable @escaping (String) -> Void
    ) async throws {
        guard LegendaryInstaller.isInstalled else {
            throw Failure.notInstalled
        }
        var collectedStderr = ""
        for try await event in ShellRunner.stream(
            LegendaryInstaller.legendaryBinary.path,
            arguments: args
        ) {
            switch event {
            case .stdout(let line), .stderr(let line):
                onLine(line)
                // Also retain stderr for the exit-code error path.
                if case .stderr = event { collectedStderr += line + "\n" }
            case .exit(let code):
                if code != 0 {
                    throw Failure.nonZeroExit(
                        code: code,
                        stderr: collectedStderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
        }
    }

    // MARK: - Progress parsing

    /// Regex over legendary's standard DLManager progress lines:
    ///
    ///     [DLManager] INFO: = Progress: 12.34% (1234/9876), Running for 00:01:23
    ///
    /// Returns the percentage as a value in 0…1, or nil for lines
    /// that don't match.
    static func parseProgress(line: String) -> Double? {
        guard let match = progressRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let percentRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[percentRange])
        else {
            return nil
        }
        return percent / 100.0
    }

    private static let progressRegex: NSRegularExpression = {
        // `^.*Progress: <number>%` — tolerates variations in the
        // surrounding prefix (different legendary versions tag the
        // DL manager line differently).
        try! NSRegularExpression(pattern: #"Progress:\s+([0-9]+(?:\.[0-9]+)?)\s*%"#)
    }()

    // MARK: - Errors

    enum Failure: LocalizedError {
        case notInstalled
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "legendary isn't installed yet — Carafe will install it on first use."
            case .nonZeroExit(let code, let stderr):
                if stderr.isEmpty { return "legendary exited with code \(code)." }
                return "legendary exited with code \(code): \(stderr)"
            case .decodeFailed(let d):
                return "Couldn't read legendary's response: \(d)"
            }
        }
    }
}
