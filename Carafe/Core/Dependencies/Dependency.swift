import Foundation

/// Status of a single dependency as observed by its checker.
enum DependencyStatus: Sendable, Equatable {
    case unknown
    case checking
    case installed(version: String?)
    case missing
    case installing(message: String)
    case failed(reason: String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .installed, .failed, .missing: return true
        default: return false
        }
    }
}

/// Copy-paste instructions for dependencies that need (or have fallen
/// back to) manual install. Multi-step so we can render numbered lists
/// with per-step copy buttons (GPTK is the motivating case — tap then
/// install).
struct ManualInstructions: Sendable, Equatable {
    struct Step: Sendable, Equatable {
        let description: String
        /// Shell command to copy. nil for description-only steps
        /// (e.g., "Open Terminal").
        let command: String?
    }

    let summary: String
    let steps: [Step]
    let documentationURL: URL?

    /// Convenience for single-command installs (Homebrew).
    init(summary: String, command: String, documentationURL: URL? = nil) {
        self.summary = summary
        self.steps = [Step(description: summary, command: command)]
        self.documentationURL = documentationURL
    }

    init(summary: String, steps: [Step], documentationURL: URL? = nil) {
        self.summary = summary
        self.steps = steps
        self.documentationURL = documentationURL
    }
}

enum InstallSupport: Sendable, Equatable {
    case automatic
    case manual(ManualInstructions)
}

/// One checker per system dependency. Implementations are reference
/// types so the DependencyManager can hold them in a list and let
/// SwiftUI observe state via a single @Published.
protocol DependencyChecker: AnyObject, Sendable {
    /// Stable identifier used as the SwiftUI list key.
    var id: String { get }
    var displayName: String { get }
    var summary: String { get }
    var installSupport: InstallSupport { get }

    /// Optional fallback instructions to show if the automatic install
    /// path fails. Renders in the same UI as `.manual` instructions.
    var fallbackInstructions: ManualInstructions? { get }

    /// Return whether the dependency is present on the system.
    /// Must not mutate anything; safe to call repeatedly.
    func check() async -> DependencyStatus

    /// Auto-install the dependency, streaming log lines via `log`.
    /// Only invoked when `installSupport == .automatic`.
    /// Throws on failure; success is implied by normal return.
    func install(log: @Sendable @escaping (String) -> Void) async throws
}

extension DependencyChecker {
    var fallbackInstructions: ManualInstructions? { nil }
}

enum DependencyError: LocalizedError {
    case notAutoInstallable
    case prerequisiteMissing(String)
    case userCancelled
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAutoInstallable:
            return "This dependency must be installed manually."
        case .prerequisiteMissing(let name):
            return "Cannot install: \(name) must be installed first."
        case .userCancelled:
            return "Cancelled by user."
        case .installFailed(let detail):
            return "Install failed: \(detail)"
        }
    }
}
