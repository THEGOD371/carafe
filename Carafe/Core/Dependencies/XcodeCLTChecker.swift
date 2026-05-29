import Foundation

/// Xcode Command Line Tools — required by Homebrew (for its compiler
/// toolchain) and by GPTK (linker, codesign, etc.).
///
/// We don't need the full Xcode IDE — just the CLT package. Triggering
/// `xcode-select --install` pops the standard macOS install dialog;
/// the user clicks "Install" and we poll until the path resolves.
final class XcodeCLTChecker: DependencyChecker, @unchecked Sendable {
    let id = "xcode-clt"
    let displayName = "Xcode Command Line Tools"
    let summary = "Apple's developer toolchain. Required by Homebrew and GPTK."
    let installSupport: InstallSupport = .automatic

    func check() async -> DependencyStatus {
        let result = try? await ShellRunner.runToCompletion(
            "xcode-select", arguments: ["-p"]
        )
        guard let result, result.didSucceed else { return .missing }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // `-p` returns the placeholder receipt path even when the CLT
        // package is missing — verify the install actually exists.
        if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
            return .missing
        }
        return .installed(version: path)
    }

    func install(log: @Sendable @escaping (String) -> Void) async throws {
        log("Triggering the macOS Command Line Tools installer dialog…")
        // FRAGILITY: `xcode-select --install` returns immediately, with
        // the actual install happening in a separate system process the
        // user interacts with via a GUI dialog. There is no programmatic
        // progress, so we poll for completion below.
        let trigger = try await ShellRunner.runToCompletion(
            "xcode-select", arguments: ["--install"]
        )
        // Exit code 1 is what you get when CLT is already installed.
        // We handle that gracefully — `check()` below will confirm.
        if !trigger.didSucceed && !trigger.stderr.lowercased().contains("already installed") {
            log("xcode-select --install: \(trigger.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        log("Waiting for the installer to finish (this can take several minutes)…")

        // Poll for up to 30 minutes — enough for a slow network.
        let deadline = Date().addingTimeInterval(60 * 30)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if case .installed = await check() {
                log("Command Line Tools detected.")
                return
            }
            log("…still waiting for Command Line Tools.")
        }

        throw DependencyError.installFailed(
            "Timed out waiting for Command Line Tools install."
        )
    }
}
