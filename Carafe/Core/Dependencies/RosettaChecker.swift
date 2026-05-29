import Foundation

/// Rosetta 2 — required because parts of GPTK's translation pipeline
/// and some Wine helper binaries are still x86_64-only. On a fresh
/// Apple-Silicon Mac it is *not* installed by default; the OS only
/// pulls it in lazily when an x86_64 binary is launched.
final class RosettaChecker: DependencyChecker, @unchecked Sendable {
    let id = "rosetta"
    let displayName = "Rosetta 2"
    let summary = "Apple's x86_64 → arm64 translator. Needed for some Wine helpers."
    let installSupport: InstallSupport = .automatic

    /// Canonical Rosetta marker file. Whisky uses the same probe.
    private let rosettaMarker = "/Library/Apple/usr/share/rosetta/rosetta"

    func check() async -> DependencyStatus {
        if FileManager.default.fileExists(atPath: rosettaMarker) {
            return .installed(version: nil)
        }
        return .missing
    }

    func install(log: @Sendable @escaping (String) -> Void) async throws {
        log("Requesting administrator privileges to install Rosetta…")
        do {
            // `softwareupdate --install-rosetta --agree-to-license` is the
            // official non-interactive install path. It blocks until done
            // (download is ~300 MB on first install) and prints nothing
            // until completion — AppleScript admin runner is fine here.
            let output = try await PrivilegedRunner.run(
                "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
            )
            if !output.isEmpty {
                output.split(separator: "\n").forEach { log(String($0)) }
            }
            log("Rosetta install command finished.")
        } catch PrivilegedRunner.Failure.userCancelled {
            throw DependencyError.userCancelled
        } catch {
            throw DependencyError.installFailed(error.localizedDescription)
        }

        // Verify
        if case .installed = await check() {
            return
        }
        throw DependencyError.installFailed("Rosetta marker file still missing after install.")
    }
}
