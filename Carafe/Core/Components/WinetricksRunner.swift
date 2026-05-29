import Foundation

/// Wraps the winetricks shell script — detection, brew bootstrap,
/// and per-verb install with streaming output.
///
/// ## ⚠️ FRAGILITY — read before changing
///
/// 1. **winetricks invocation environment** — winetricks finds wine
///    via the `WINE` and `WINESERVER` env vars when set, falling
///    back to PATH lookup. We set both explicitly to the GPTK
///    binaries so we never accidentally pick up a system wine.
///
/// 2. **`--unattended`** — disables the GUI nag dialogs winetricks
///    pops by default. Without this the install hangs waiting for a
///    GUI nobody can see. There's no programmatic alternative for
///    "answer Y to every prompt".
///
/// 3. **Verb-level failures are normal** — winetricks downloads real
///    Microsoft installers from real CDNs. Microsoft retires URLs
///    constantly. The expected failure mode is one verb in a batch
///    failing; we surface that per-verb in the UI rather than
///    aborting the whole batch.
///
/// 4. **One verb at a time** — `winetricks vcrun2019 dotnet48` runs
///    them sequentially but coalesces output, making per-verb
///    success/fail attribution impossible. We invoke once per verb
///    so the ComponentsSheet can report each independently.
enum WinetricksRunner {

    /// Canonical Homebrew path after `brew install winetricks`.
    static let winetricksPath = "/opt/homebrew/bin/winetricks"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: winetricksPath)
    }

    /// Try to detect installed version. nil if winetricks isn't on disk.
    static func detectVersion() async -> String? {
        guard isInstalled else { return nil }
        let result = try? await ShellRunner.runToCompletion(
            winetricksPath, arguments: ["--version"]
        )
        return result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - brew install winetricks

    /// Install winetricks via Homebrew. Streams output line-by-line
    /// via `log`. Throws on non-zero exit.
    static func installViaBrew(log: @Sendable @escaping (String) -> Void) async throws {
        guard FileManager.default.isExecutableFile(atPath: HomebrewChecker.brewPath) else {
            throw Failure.prerequisiteMissing("Homebrew")
        }

        log("Running `brew install winetricks`…")

        for try await event in ShellRunner.stream(
            HomebrewChecker.brewPath,
            arguments: ["install", "winetricks"]
        ) {
            switch event {
            case .stdout(let line), .stderr(let line):
                log(line)
            case .exit(let code):
                if code != 0 {
                    throw Failure.brewInstallFailed("brew exited with code \(code).")
                }
            }
        }

        // Verify
        guard isInstalled else {
            throw Failure.brewInstallFailed(
                "brew reported success but \(winetricksPath) still isn't present."
            )
        }
        log("winetricks ready.")
    }

    // MARK: - Verb install

    /// Run winetricks for a single verb in the given bottle. Streams
    /// output as it happens. Returns normally on exit code 0;
    /// throws Failure.verbFailed otherwise.
    ///
    /// Per the fragility note above: callers should NOT batch verbs
    /// into a single call. Loop in the caller, catch each error
    /// independently.
    static func installVerb(
        _ verb: String,
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        guard isInstalled else {
            throw Failure.notInstalled
        }
        guard WineRunner.isWineAvailable(for: bottle.wineBuild) else {
            throw Failure.prerequisiteMissing("Wine \(bottle.wineBuild.shortName)")
        }

        log("→ winetricks --unattended \(verb)  [via \(bottle.wineBuild.shortName)]")

        var env = ProcessInfo.processInfo.environment
        // FRAGILITY: winetricks reads WINE / WINESERVER to find the
        // wine binaries. Resolving per-build means a wine-staging
        // bottle gets the staging wine, a GPTK bottle gets GPTK.
        env["WINEPREFIX"] = bottle.prefixURL.path
        env["WINE"] = WineRunner.wine64Path(for: bottle.wineBuild)
        env["WINESERVER"] = WineRunner.wineserverPath(for: bottle.wineBuild)
        env["PATH"] = ShellRunner.defaultPath
        // Per-bottle DLL overrides + env extend, mirroring RunSession.
        env["WINEDEBUG"] = "fixme-all"
        for (k, v) in bottle.environment { env[k] = v }

        var lastErrorLines: [String] = []
        for try await event in ShellRunner.stream(
            winetricksPath,
            arguments: ["--unattended", verb],
            environment: env
        ) {
            switch event {
            case .stdout(let line):
                log(line)
            case .stderr(let line):
                log(line)
                lastErrorLines.append(line)
                if lastErrorLines.count > 20 { lastErrorLines.removeFirst() }
            case .exit(let code):
                if code != 0 {
                    let tail = lastErrorLines.suffix(6).joined(separator: "\n")
                    throw Failure.verbFailed(
                        verb: verb,
                        exitCode: code,
                        tail: tail
                    )
                }
            }
        }
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case notInstalled
        case prerequisiteMissing(String)
        case brewInstallFailed(String)
        case verbFailed(verb: String, exitCode: Int32, tail: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "winetricks isn't installed. Install it via Homebrew first."
            case .prerequisiteMissing(let name):
                return "Required dependency missing: \(name)."
            case .brewInstallFailed(let detail):
                return "Couldn't install winetricks: \(detail)"
            case .verbFailed(let verb, let code, let tail):
                return "\(verb) failed (exit \(code)).\n\nLast output:\n\(tail)"
            }
        }
    }
}
