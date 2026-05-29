import Combine
import Foundation
import Sparkle
import SwiftUI

/// SwiftUI-friendly facade over `SPUStandardUpdaterController`.
///
/// Lifecycle: `CarafeApp` instantiates one `Updater` at launch and
/// holds it as an `@StateObject`. The "Check for Updates…" menu
/// item under the Carafe app menu calls `checkForUpdates()` and
/// observes `canCheckForUpdates` so it disables while a check is
/// in flight.
///
/// Behaviour comes from Info.plist (see `project.yml` info block):
///   - `SUFeedURL` — appcast XML location on GitHub Releases.
///   - `SUEnableAutomaticChecks = true` — schedule background
///     checks on app launch.
///   - `SUScheduledCheckInterval = 86400` — once per 24 h.
///   - `SUAutomaticallyUpdate = false` — notify only; user opts
///     in to each install.
///   - "Skip this version" is built into Sparkle's UpdateAlert
///     UI — no app-side state needed.
///
/// FRAGILITY: Sparkle 2 requires `SUPublicEDKey` in Info.plist for
/// any update to actually install. We deliberately omit that key
/// until the release-engineering workflow in milestone B-2/B-3
/// generates the EdDSA key pair. Pre-release builds will let the
/// user *trigger* a check, but the install path fails at signature
/// validation — which is the right behaviour. See TESTING.md →
/// "Sparkle release engineering" for the one-time setup procedure.
@MainActor
final class Updater: ObservableObject {

    /// Mirrors Sparkle's `canCheckForUpdates` so SwiftUI can bind
    /// the menu item's `.disabled` modifier to it.
    @Published private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` arms the scheduled background
        // checks (governed by SUScheduledCheckInterval). Without it
        // Sparkle stays dormant until the user manually triggers
        // a check, which would defeat the "check once a day on
        // launch" requirement.
        //
        // Delegate slots stay nil for v0.1 — Sparkle's defaults
        // cover everything we want (notify-only UpdateAlert, user
        // opt-in install, version-skip handling). Wire a delegate
        // later if we ever need to override the appcast or change
        // the install behaviour per-user.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Bridge Sparkle's KVO-published `canCheckForUpdates` into
        // our @Published mirror. The publisher is delivered on the
        // main run loop so SwiftUI sees changes synchronously.
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Trigger a user-initiated check. Sparkle handles the UI
    /// (progress sheet, update-available alert, error alerts) on
    /// its own — we just kick it off.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
