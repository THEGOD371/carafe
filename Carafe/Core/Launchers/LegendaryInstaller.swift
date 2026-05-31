import Foundation

/// Bootstraps the `legendary` Epic Games CLI inside a Carafe-managed
/// virtualenv. Pipeline:
///
///   1. Verify Homebrew is present (Carafe's onboarding step
///      installs brew already, so this is a sanity check).
///   2. If `python@3.12` isn't installed, run `brew install python@3.12`.
///   3. Create a venv at
///      `~/Library/Application Support/Carafe/legendary-venv/` using
///      that Python.
///   4. `pip install --upgrade legendary-gl` inside the venv (pinned
///      version below — bump deliberately).
///
/// We isolate legendary in its own venv rather than touching the
/// user's system or Homebrew Python site-packages. The venv path is
/// known + stable, so subsequent Carafe launches just shell out to
/// `<venv>/bin/legendary` directly without re-running the install.
///
/// FRAGILITY
/// ---------
/// 1. **legendary-gl maintenance state.** Upstream PyPI hasn't shipped
///    a release in 12+ months as of 2026. If the current pinned
///    version stops working with Epic's API (Epic rotates endpoints
///    every few quarters), the workaround is to point pip at the
///    `Heroic-Games-Launcher/legendary` fork, which is the one Heroic
///    actually ships and tracks. Bump `pipPackageSpec` to
///    `"legendary @ git+https://github.com/Heroic-Games-Launcher/legendary"`
///    if/when this matters.
/// 2. **Homebrew Python tap stability.** `python@3.12` has been in the
///    core formulae since 2023 and is the Apple-recommended Python
///    for Apple Silicon as of 2026. If brew ever bumps to a newer
///    series and 3.12 ages out, `pythonFormula` needs updating —
///    legendary supports 3.9+ in practice so any 3.x in the 3.9–3.13
///    range works.
/// 3. **venv path.** Lives under `AppState.supportDirectory`, so
///    uninstalling Carafe cleans up the venv. If a user wipes the
///    support dir manually, the next "Add from Epic" click does a
///    fresh install (idempotent).
/// 4. **`pip install` and "externally-managed environment".** Newer
///    brew Pythons mark themselves as externally-managed (PEP 668),
///    which is exactly why we use a venv instead of pip-installing
///    into the brew Python directly. The venv carries its own pip.
enum LegendaryInstaller {

    // MARK: - Tunables

    /// Homebrew formula name. Carafe targets one specific Python
    /// series to keep the dependency footprint deterministic.
    static let pythonFormula = "python@3.12"

    /// The version of Python's binary inside the formula.
    static let pythonBinaryName = "python3.12"

    /// What we pip-install into the venv. Pinning by name only —
    /// pip will fetch the latest matching version. Bump or change
    /// (e.g. to a git+ URL for Heroic's fork) when needed.
    static let pipPackageSpec = "legendary-gl"

    // MARK: - Paths

    /// Root of Carafe's managed legendary install.
    static var venvDirectory: URL {
        AppState.supportDirectory
            .appendingPathComponent("legendary-venv", isDirectory: true)
    }

    /// `<venv>/bin/legendary`.
    static var legendaryBinary: URL {
        venvDirectory.appendingPathComponent("bin/legendary")
    }

    /// `<venv>/bin/pip`.
    static var pipBinary: URL {
        venvDirectory.appendingPathComponent("bin/pip")
    }

    /// True iff the venv has a working `legendary` binary. Cheap and
    /// nonisolated so any caller can branch on it.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: legendaryBinary.path)
    }

    // MARK: - Probing Homebrew Python

    /// Hunt for a Homebrew-installed Python 3.12 binary across the
    /// usual locations. Returns the absolute path or nil.
    static func locateBrewPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(pythonBinaryName)",
            "/opt/homebrew/opt/\(pythonFormula)/bin/\(pythonBinaryName)",
            "/opt/homebrew/opt/\(pythonFormula)/libexec/bin/python",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Install pipeline

    /// Idempotent install. Streams progress lines via `log`. Safe to
    /// call repeatedly; returns immediately when `isInstalled` is
    /// already true.
    static func install(
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        if isInstalled {
            log("legendary already installed at \(legendaryBinary.path).")
            return
        }

        // Step 1: ensure brew python 3.12 is present.
        var pythonPath = locateBrewPython()
        if pythonPath == nil {
            log("Homebrew Python \(pythonFormula) not found — running `brew install`…")
            try await runStreaming(
                "brew", ["install", pythonFormula],
                log: log,
                failure: { "brew install \(pythonFormula) failed: \($0)" }
            )
            pythonPath = locateBrewPython()
            guard pythonPath != nil else {
                throw Failure.pythonMissing(
                    "brew install \(pythonFormula) succeeded but Python isn't at any of the expected paths. "
                    + "Run `brew --prefix \(pythonFormula)` manually and update LegendaryInstaller.locateBrewPython."
                )
            }
        }
        let python = pythonPath!
        log("Using Python at \(python).")

        // Step 2: create the venv (idempotent — `-m venv` overwrites
        // a stale venv if asked to). Skip if the venv dir already
        // has a Python in it.
        let venvPython = venvDirectory.appendingPathComponent("bin/python").path
        if !FileManager.default.isExecutableFile(atPath: venvPython) {
            log("Creating venv at \(venvDirectory.path)…")
            try? FileManager.default.removeItem(at: venvDirectory)
            try await runStreaming(
                python, ["-m", "venv", venvDirectory.path],
                log: log,
                failure: { "Couldn't create venv: \($0)" }
            )
        } else {
            log("Reusing existing venv at \(venvDirectory.path).")
        }

        // Step 3: pip install legendary-gl. `--upgrade` covers the
        // case where we've previously installed an older version.
        log("Installing \(pipPackageSpec) via pip…")
        try await runStreaming(
            pipBinary.path, ["install", "--upgrade", pipPackageSpec],
            log: log,
            failure: { "pip install \(pipPackageSpec) failed: \($0)" }
        )

        // Step 4: verify.
        guard isInstalled else {
            throw Failure.verifyFailed(
                "pip reported success but \(legendaryBinary.path) is missing. "
                + "Try `\(pipBinary.path) install --upgrade \(pipPackageSpec)` manually."
            )
        }
        log("legendary ready at \(legendaryBinary.path).")
    }

    /// Quick `legendary --version` to surface in About / Settings.
    /// Returns nil if legendary isn't installed.
    static func detectVersion() async -> String? {
        guard isInstalled else { return nil }
        do {
            let result = try await ShellRunner.runToCompletion(
                legendaryBinary.path, arguments: ["--version"]
            )
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Streams a single Process's stdout/stderr lines via `log`,
    /// throws Failure.nonZeroExit on bad exit code. Used for brew
    /// install, venv creation, pip install — they all behave well
    /// when wrapped this way.
    private static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        log: @Sendable @escaping (String) -> Void,
        failure: @Sendable @escaping (String) -> String
    ) async throws {
        var lastStderr = ""
        for try await event in ShellRunner.stream(executable, arguments: arguments) {
            switch event {
            case .stdout(let line):
                log(line)
            case .stderr(let line):
                log(line)
                lastStderr += line + "\n"
            case .exit(let code):
                if code != 0 {
                    throw Failure.subprocessFailed(failure(lastStderr.isEmpty ? "exit \(code)" : lastStderr))
                }
            }
        }
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case pythonMissing(String)
        case subprocessFailed(String)
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let d): return "Homebrew Python is missing: \(d)"
            case .subprocessFailed(let d): return d
            case .verifyFailed(let d): return "legendary install verification failed: \(d)"
            }
        }
    }
}
