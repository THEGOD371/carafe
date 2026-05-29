import Foundation

/// Which Wine binary a bottle runs against. Carafe v0.x supports two:
///
///   - **GPTK** (Apple Game Porting Toolkit) — Wine **7.7** from
///     2023. Apple-Silicon-optimised, D3DMetal-integrated, great for
///     most single-player games. Too old for current Steam (CEF
///     crashes during bootstrap).
///   - **Wine Staging** — Wine **11.9** from Gcenx's macOS_Wine_builds
///     publishes (upstream WineHQ with the staging patchset). Newer
///     than CrossOver 23.7.1 (Wine 8.0.1); required for Steam and
///     anything else that breaks on Wine 7.7's old Chromium/CEF.
///     ~190 MB one-time download, shared across all .wineStaging
///     bottles.
///
/// FRAGILITY: the original plan called for `gcenx/wine/wine-crossover`
/// (Wine 8.0.1) but Gcenx removed that cask from the tap at some
/// point. The Gcenx macOS_Wine_builds repo publishes WineHQ-upstream
/// builds at much newer versions (currently 11.9), which we use
/// directly via the GitHub release tarball. If Gcenx ever stops
/// publishing, we'd need to fall back to upstream WineHQ packages or
/// reintroduce a brew-cask path.
enum WineBuild: String, Codable, CaseIterable, Identifiable, Sendable {
    case gptk          = "gptk"
    case wineStaging   = "wineStaging"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gptk:        return "GPTK (Apple Game Porting Toolkit)"
        case .wineStaging: return "Wine Staging"
        }
    }

    var shortName: String {
        switch self {
        case .gptk:        return "GPTK"
        case .wineStaging: return "Wine Staging"
        }
    }

    /// User-facing version label. For GPTK we report what Apple
    /// shipped in the cask we install. For Wine Staging we report
    /// the pinned WineStagingInstaller version.
    var versionLabel: String {
        switch self {
        case .gptk:        return "Wine 7.7 (from GPTK cask)"
        case .wineStaging: return "Wine \(WineStagingInstaller.version) (staging)"
        }
    }

    /// One-sentence elevator pitch shown in the bottle creation UI.
    var summary: String {
        switch self {
        case .gptk:
            return "Apple's optimised Wine + D3DMetal. Best graphics performance for single-player games. Wine 7.7."
        case .wineStaging:
            return "Newer upstream Wine — required for current Steam and games that need Wine 8+. Slightly slower than GPTK for graphics but works with everything."
        }
    }

    /// Disk footprint for "you'll need to download X" UX copy.
    var downloadSizeNote: String {
        switch self {
        case .gptk:        return "already installed via the GPTK cask in onboarding"
        case .wineStaging: return "~190 MB one-time download (shared across all Wine Staging bottles)"
        }
    }
}
