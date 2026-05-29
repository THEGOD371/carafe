import Foundation

/// Homebrew — used to install GPTK (and later DXVK / utilities).
///
/// We deliberately do **not** auto-install Homebrew. The official
/// installer script needs an interactive sudo session, fails when run
/// as root (Homebrew explicitly refuses), and depends on a confirmation
/// prompt that NONINTERACTIVE=1 only partly papers over. The pragmatic
/// path is to show the user the canonical one-liner and a "Re-check"
/// button — that matches what every other Mac dev tool does.
final class HomebrewChecker: DependencyChecker, @unchecked Sendable {
    let id = "homebrew"
    let displayName = "Homebrew"
    let summary = "Package manager for macOS. Used to install Game Porting Toolkit."

    /// Canonical Apple-Silicon Homebrew install location.
    static let brewPath = "/opt/homebrew/bin/brew"

    let installSupport: InstallSupport = .manual(
        ManualInstructions(
            summary:
                "Open Terminal and paste the command below. Homebrew will prompt for your password.",
            command:
                #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
            documentationURL: URL(string: "https://brew.sh")
        )
    )

    func check() async -> DependencyStatus {
        // Fast path: canonical file check.
        if FileManager.default.isExecutableFile(atPath: Self.brewPath) {
            let result = try? await ShellRunner.runToCompletion(
                Self.brewPath, arguments: ["--version"]
            )
            if let result, result.didSucceed {
                let version = result.stdout
                    .split(separator: "\n").first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                return .installed(version: version)
            }
        }
        // Fallback: ask the shell — handles the (unusual) case where
        // brew lives in /usr/local on a migrated Mac.
        let fallback = try? await ShellRunner.runToCompletion(
            "brew", arguments: ["--version"]
        )
        if let fallback, fallback.didSucceed {
            return .installed(version:
                fallback.stdout.split(separator: "\n").first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
            )
        }
        return .missing
    }

    func install(log: @Sendable @escaping (String) -> Void) async throws {
        // installSupport is .manual; the manager won't call this.
        throw DependencyError.notAutoInstallable
    }
}
