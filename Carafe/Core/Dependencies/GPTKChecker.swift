import Foundation

/// Apple Game Porting Toolkit — the translation layer that lets
/// Windows games run on Apple Silicon (D3DMetal + a patched Wine).
///
/// ## Install strategy (revised 2026-05)
///
/// Apple's official Homebrew formula `apple/apple/game-porting-toolkit`
/// is currently **broken**: it depends on `openssl@1.1`, which Homebrew
/// disabled on 2024-10-24. Trying to install it produces:
///
///     Error: No available formula with the name "openssl@1.1"
///     (dependency of apple/apple/game-porting-toolkit).
///
/// The community has converged on **Gcenx's cask** as the working
/// install path:
///
///     brew install --cask gcenx/wine/game-porting-toolkit
///
/// The cask ships pre-built binaries via GitHub releases, so it
/// sidesteps both the openssl@1.1 build dependency AND the multi-hour
/// x86_64 compile. The cask also handles ad-hoc codesigning and
/// quarantine removal in its postflight. As of v3.0-2 it installs
/// `/Applications/Game Porting Toolkit.app` and symlinks `wine64`,
/// `wine64-preloader`, `wineserver` into `/opt/homebrew/bin`.
///
/// ## ⚠️ FRAGILITY — read before changing this checker
///
/// 1. **Cask tap path**: `gcenx/wine` is the canonical tap as of 2026.
///    If Gcenx ever moves the cask, the install command will silently
///    fail. Surface, don't suppress.
///
/// 2. **Apple formula recovery**: if Apple ever fixes their formula
///    (bumps to openssl@3, ships a cask of their own), we should
///    prefer the Apple path. Until then it's a trap — leave it as a
///    *detection* fallback only, never as an install target.
///
/// 3. **Cask vs formula collision**: a user who hit the broken Apple
///    formula path may have a half-installed mess. The cask install
///    will refuse if a conflicting wine is present (`conflicts_with`
///    in the cask). Surface the error message.
///
/// 4. **sudo prompt**: the cask installs to /Applications, which on
///    standard admin accounts works without sudo, but on some setups
///    (managed Macs, non-admin users) brew will prompt. We can't
///    stream that prompt; it goes through TTY. If install hangs with
///    no output, that's the cause — fall back to manual instructions.
///
/// 5. **Gatekeeper / quarantine handling** (added 2026-05): Homebrew
///    5.1.14 removed the `--no-quarantine` flag — passing it is now a
///    hard error. We rely on the cask's own postflight (which calls
///    `xattr -drs com.apple.quarantine ...` plus ad-hoc codesign),
///    *and* run `xattr -dr` ourselves after install as a safety net.
///    If Apple ever locks down user-mode quarantine removal (they've
///    been tightening Gatekeeper steadily), both paths fail and the
///    user has to right-click → Open the .app the first time. The
///    fallback instructions below document that escape hatch.
final class GPTKChecker: DependencyChecker, @unchecked Sendable {
    let id = "gptk"
    let displayName = "Apple Game Porting Toolkit"
    let summary = "Apple's DirectX → Metal translation layer + a patched Wine."
    let installSupport: InstallSupport = .automatic

    /// Pre-built binary cask maintained by the GPTK community.
    private let caskTap = "gcenx/wine"
    private let caskName = "gcenx/wine/game-porting-toolkit"
    private let bareCaskName = "game-porting-toolkit"

    /// Canonical install location after the cask runs.
    private let appBundlePath = "/Applications/Game Porting Toolkit.app"

    var fallbackInstructions: ManualInstructions? {
        ManualInstructions(
            summary:
                """
                If automatic install failed, run these commands in Terminal. \
                They use Gcenx's pre-built cask, which avoids the broken \
                openssl@1.1 dependency in Apple's official formula.
                """,
            steps: [
                .init(
                    description: "Add the Gcenx tap (one-time):",
                    command: "brew tap gcenx/wine"
                ),
                .init(
                    description: "Install the pre-built GPTK cask:",
                    command: "brew install --cask gcenx/wine/game-porting-toolkit"
                ),
                .init(
                    description:
                        "Strip the quarantine attribute so Gatekeeper doesn't block the bundled wine binaries:",
                    command:
                        #"xattr -dr com.apple.quarantine "/Applications/Game Porting Toolkit.app""#
                ),
                .init(
                    description:
                        "If the xattr step fails (managed Macs sometimes block it), launch the app once from /Applications by right-click → Open and click \"Open\" in the Gatekeeper dialog. After that, click re-check below.",
                    command: nil
                ),
            ],
            documentationURL: URL(string: "https://github.com/Gcenx/homebrew-wine")
        )
    }

    func check() async -> DependencyStatus {
        guard FileManager.default.isExecutableFile(atPath: HomebrewChecker.brewPath) else {
            return .missing
        }

        // Preferred: the Gcenx cask. `brew list --cask --versions` prints
        // `<name> <version>` on hit, nothing on miss.
        if let caskResult = try? await ShellRunner.runToCompletion(
            HomebrewChecker.brewPath,
            arguments: ["list", "--cask", "--versions", bareCaskName]
        ), caskResult.didSucceed {
            let line = caskResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                let version = line.split(separator: " ").dropFirst().first.map(String.init)
                return .installed(version: version.map { "cask \($0)" } ?? "cask")
            }
        }

        // Fallback detection only: Apple's broken formula. If it *did*
        // somehow install on this machine (older brew, downgraded
        // openssl) we still count it as working.
        if let formulaResult = try? await ShellRunner.runToCompletion(
            HomebrewChecker.brewPath,
            arguments: ["list", "--formula", "--versions", bareCaskName]
        ), formulaResult.didSucceed {
            let line = formulaResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                let version = line.split(separator: " ").dropFirst().first.map(String.init)
                return .installed(version: version.map { "formula \($0)" } ?? "formula")
            }
        }

        // Last resort: someone installed the .app by hand outside brew.
        if FileManager.default.fileExists(atPath: appBundlePath) {
            return .installed(version: "app-bundle")
        }

        return .missing
    }

    func install(log: @Sendable @escaping (String) -> Void) async throws {
        guard FileManager.default.isExecutableFile(atPath: HomebrewChecker.brewPath) else {
            throw DependencyError.prerequisiteMissing("Homebrew")
        }

        // --- 1. Tap ---
        log("Tapping \(caskTap)…")
        try await runStreaming(
            arguments: ["tap", caskTap],
            log: log,
            // `brew tap` returns 0 normally; some versions return 1 if
            // already tapped. Either is fine.
            acceptableExitCodes: [0, 1],
            stage: "tap"
        )

        // --- 2. Install (no flags — Homebrew 5.1.14 removed --no-quarantine) ---
        log("Installing \(caskName) from the Gcenx cask (pre-built — no openssl@1.1 needed)…")
        log("The download is ~1 GB; the .app installs to /Applications.")

        var lastErrorLines: [String] = []
        var sawOpenSSLError = false
        var sawNoQuarantineError = false

        for try await event in ShellRunner.stream(
            HomebrewChecker.brewPath,
            arguments: ["install", "--cask", caskName]
        ) {
            switch event {
            case .stdout(let line):
                log(line)
            case .stderr(let line):
                log(line)
                lastErrorLines.append(line)
                if lastErrorLines.count > 30 { lastErrorLines.removeFirst() }
                let lower = line.lowercased()
                if lower.contains("openssl@1.1") {
                    sawOpenSSLError = true
                }
                // FRAGILITY: if this code path is ever hit it means a
                // future edit reintroduced --no-quarantine. The flag
                // was removed in Homebrew 5.1.14 with "There is no
                // replacement" — we now run xattr ourselves below.
                if lower.contains("no-quarantine") && lower.contains("disabled") {
                    sawNoQuarantineError = true
                }
            case .exit(let code):
                if code != 0 {
                    if sawOpenSSLError {
                        throw DependencyError.installFailed(
                            """
                            Hit the openssl@1.1 dependency error — that's the broken \
                            Apple formula, not the Gcenx cask. Make sure the install \
                            command above is `brew install --cask gcenx/wine/...`, \
                            not `brew install apple/apple/...`.
                            """
                        )
                    }
                    if sawNoQuarantineError {
                        throw DependencyError.installFailed(
                            """
                            Homebrew rejected the `--no-quarantine` switch (removed in \
                            5.1.14). The current code shouldn't be passing it — check \
                            GPTKChecker.swift for a regression.
                            """
                        )
                    }
                    let tail = lastErrorLines.suffix(8).joined(separator: "\n")
                    throw DependencyError.installFailed(
                        "brew install --cask exited \(code).\n\nLast output:\n\(tail)"
                    )
                }
            }
        }

        // --- 3. Strip quarantine (defense in depth) ---
        //
        // The Gcenx cask's postflight *already* runs
        //     xattr -drs com.apple.quarantine "${appdir}/Game Porting Toolkit.app"
        //     codesign --force --deep -s - "${appdir}/Game Porting Toolkit.app"
        // (verified in Casks/game-porting-toolkit.rb on 2026-05-27).
        // We run xattr again as a safety net: it's idempotent on an
        // already-clean attribute, costs ~1 ms, and protects us if the
        // cask postflight ever regresses or silently fails. Crucially
        // it runs as the current user — quarantine attrs on user-owned
        // /Applications writes don't need root.
        log("Stripping quarantine attribute from \(appBundlePath)…")
        let quarantineWarning = await stripQuarantine(log: log)

        // --- 4. Verify ---
        //
        // Two probes:
        //   (a) /Applications/Game Porting Toolkit.app exists.
        //   (b) /opt/homebrew/bin/wine64 exists & is executable (the
        //       cask's binary stanza creates this symlink into the
        //       app bundle; without it, downstream bottle code can't
        //       find wine).
        // If (a) is true but (b) is false, something is structurally
        // wrong — we surface that as a hard failure. If both are true
        // but xattr warned, we still report success (with the warning
        // visible in the log).
        guard FileManager.default.fileExists(atPath: appBundlePath) else {
            throw DependencyError.installFailed(
                "Cask install finished but \(appBundlePath) is missing. Try the manual steps below."
            )
        }

        let wine64Path = "/opt/homebrew/bin/wine64"
        guard FileManager.default.isExecutableFile(atPath: wine64Path) else {
            throw DependencyError.installFailed(
                """
                The .app installed but \(wine64Path) is missing — brew didn't \
                create the wine symlinks. Try `brew reinstall --cask \
                \(caskName)` from Terminal.
                """
            )
        }

        if let warning = quarantineWarning {
            // FRAGILITY: xattr can fail on managed Macs that have
            // tightened the quarantine attribute via MDM. The cask's
            // postflight may also have already cleared it (typical
            // case — our xattr then warns "no such xattr"). Either
            // way, we land on installed-with-warning rather than
            // failed; the user can manually approve the .app on first
            // launch if Gatekeeper actually blocks anything.
            log("⚠️ xattr post-step warning: \(warning)")
            log("If the wine binaries get blocked on first launch, right-click → Open the .app in Finder.")
        } else {
            log("Quarantine attribute cleared.")
        }

        log("GPTK install verified.")
    }

    /// Runs `xattr -dr com.apple.quarantine "<app bundle>"` as the
    /// current user. Returns nil on success, or a short warning string
    /// describing why it didn't fully succeed. Never throws — quarantine
    /// stripping is best-effort, not load-bearing.
    private func stripQuarantine(log: @Sendable @escaping (String) -> Void) async -> String? {
        do {
            let result = try await ShellRunner.runToCompletion(
                "/usr/bin/xattr",
                arguments: ["-dr", "com.apple.quarantine", appBundlePath]
            )
            // xattr is quietly successful when the attribute is
            // already gone (the cask's postflight typically beats us
            // to it). Non-zero exits are usually "no such xattr",
            // which we treat as success.
            if result.didSucceed { return nil }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            log(stderr)
            // "No such xattr" / "No such file or directory" indicate
            // the attribute is already absent — that's the desired
            // end state.
            let benign = ["no such xattr", "no such file or directory"]
            let lower = stderr.lowercased()
            if benign.contains(where: { lower.contains($0) }) { return nil }
            return "xattr exited \(result.exitCode): \(stderr)"
        } catch {
            return "could not run xattr: \(error.localizedDescription)"
        }
    }

    /// Helper for the tap step — wraps `ShellRunner.stream` with an
    /// acceptable-exit-code allowlist.
    private func runStreaming(
        arguments: [String],
        log: @Sendable @escaping (String) -> Void,
        acceptableExitCodes: Set<Int32>,
        stage: String
    ) async throws {
        for try await event in ShellRunner.stream(
            HomebrewChecker.brewPath,
            arguments: arguments
        ) {
            switch event {
            case .stdout(let line), .stderr(let line):
                log(line)
            case .exit(let code):
                if !acceptableExitCodes.contains(code) {
                    throw DependencyError.installFailed(
                        "brew \(stage) failed with exit code \(code)."
                    )
                }
            }
        }
    }
}
