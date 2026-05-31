import Foundation
import AppKit

/// Hands a Heroic-imported game off to Heroic for launch.
///
/// We use Heroic's registered URL scheme rather than its CLI binary
/// because:
///   * The URL handler stays valid across Heroic versions, while the
///     binary's flag names (`--launch=`, `--game=`, etc.) have drifted
///     historically.
///   * `NSWorkspace.open(url)` returns immediately and lets Heroic's
///     own progress UI surface install / launch errors — we don't
///     have to mirror them in Carafe.
///   * No need to know where Heroic is installed (registered
///     handler resolves it via Launch Services).
///
/// FRAGILITY
/// ---------
/// 1. **URL form.** Heroic registers `heroic://launch/<runner>/<appName>`
///    where `runner` is the same identifier Heroic uses internally
///    (`legendary` for Epic, `gog` for GOG). The form has been stable
///    since Heroic 2.0 but isn't formally documented.
/// 2. **Silent failures.** `NSWorkspace.open` returns a Bool but
///    only reports whether the URL handler ran, not whether Heroic
///    actually launched the game. A user can click Play and see
///    nothing happen if (a) Heroic is uninstalled mid-session, or
///    (b) the game's Heroic-side install is corrupted. We log a
///    diagnostic line either way; the user-visible signal is "did
///    Heroic open and start the game?".
/// 3. **App-name encoding.** Epic app_names usually contain only
///    alphanumerics + colons, but some Cloud-Saves entries have
///    spaces or unusual characters. We percent-encode defensively.
enum HeroicLauncher {

    /// Build the launch URL for a Heroic game. Public so the UI
    /// layer can also display it (debugging / context menu).
    static func launchURL(for game: HeroicGame) -> URL? {
        let encoded = game.appName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? game.appName
        return URL(string: "heroic://launch/\(game.source.rawValue)/\(encoded)")
    }

    /// Open `heroic://launch/<runner>/<appName>`. Heroic's URL handler
    /// takes over from there. Returns true if Launch Services accepted
    /// the open (NOT whether the game actually launched — see
    /// fragility point 2 above).
    @MainActor
    @discardableResult
    static func launch(_ game: HeroicGame) -> Bool {
        guard let url = launchURL(for: game) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Open the Heroic app itself (e.g. so the user can manage
    /// installs / settings for the imported game). Falls back to
    /// opening the URL scheme with no path, which Heroic interprets
    /// as "show main window".
    @MainActor
    @discardableResult
    static func openHeroic() -> Bool {
        // Try `/Applications/Heroic.app` first via path-based open —
        // that bypasses the URL handler entirely and is the most
        // direct way to bring Heroic to the front.
        let heroicApp = URL(fileURLWithPath: "/Applications/Heroic.app")
        if FileManager.default.fileExists(atPath: heroicApp.path) {
            NSWorkspace.shared.open(heroicApp)
            return true
        }
        // Fall back to the URL scheme — works even if Heroic was
        // installed somewhere non-standard (Setapp, ~/Applications).
        if let url = URL(string: "heroic://") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}
