import Foundation
import SwiftUI

/// App-wide user preferences. Created once in `CarafeApp` and pushed
/// into the SwiftUI environment as an environmentObject. Backed by
/// `UserDefaults` — every published property writes through on
/// `didSet`.
///
/// Why UserDefaults and not a JSON file: every setting here is a
/// single primitive (enum raw value, bool, string path). UserDefaults
/// gives us free Plist persistence, KVO, automatic atomic writes, and
/// — critically — readability from nonisolated contexts (see
/// `AppState.bottlesDirectory`, which has to compute a URL without
/// hopping to the main actor).
///
/// Telemetry note: `telemetryEnabled` is plumbed but there is no
/// telemetry pipe wired in v0.1. It exists so the eventual Sentry /
/// analytics integration in the Stability milestone has an explicit
/// opt-in flag to gate against. Default is OFF.
@MainActor
final class AppSettings: ObservableObject {

    /// Public so other modules (notably `AppState.bottlesDirectory`)
    /// can read the same keys without a parallel constant.
    enum DefaultsKey {
        static let defaultWineBuild       = "carafe.settings.defaultWineBuild"
        static let defaultWindowsVersion  = "carafe.settings.defaultWindowsVersion"
        static let defaultGraphicsBackend = "carafe.settings.defaultGraphicsBackend"
        static let bottlesLocation        = "carafe.settings.bottlesLocation"
        static let telemetryEnabled       = "carafe.settings.telemetryEnabled"
        static let appearanceTheme        = "carafe.settings.appearanceTheme"
    }

    // MARK: - Published settings

    /// Used to pre-seed `CreateBottleSheet.wineBuild` for the regular
    /// "New bottle" flow. The Steam install flow continues to override
    /// this with `.wineStaging` explicitly — see `InstallSteamSheet`.
    @Published var defaultWineBuild: WineBuild {
        didSet { UserDefaults.standard.set(defaultWineBuild.rawValue, forKey: DefaultsKey.defaultWineBuild) }
    }

    /// Pre-seeds `CreateBottleSheet.windowsVersion`.
    @Published var defaultWindowsVersion: WindowsVersion {
        didSet { UserDefaults.standard.set(defaultWindowsVersion.rawValue, forKey: DefaultsKey.defaultWindowsVersion) }
    }

    /// Used by `BottleManager.create` as the initial
    /// `compatDefaults.graphicsBackend` for new bottles. Existing
    /// bottles are not touched.
    @Published var defaultGraphicsBackend: GraphicsBackend {
        didSet { UserDefaults.standard.set(defaultGraphicsBackend.rawValue, forKey: DefaultsKey.defaultGraphicsBackend) }
    }

    /// User-chosen on-disk location for the bottles folder. nil = use
    /// the default at `~/Library/Application Support/Carafe/Bottles`.
    ///
    /// Stored as a plain absolute path string. Carafe is not sandboxed
    /// so security-scoped bookmarks aren't needed. If the path becomes
    /// unreachable (external drive unplugged), `AppState.bottlesDirectory`
    /// silently falls back to the default — the UI surfaces the
    /// mismatch in Settings → Storage.
    @Published var bottlesLocationOverride: URL? {
        didSet {
            if let url = bottlesLocationOverride {
                UserDefaults.standard.set(url.path, forKey: DefaultsKey.bottlesLocation)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.bottlesLocation)
            }
        }
    }

    /// App-wide visual theme. `.nothing` is the default — the always-
    /// dark, monochrome, red-accent look modeled on Nothing OS. Users
    /// who prefer the stock macOS appearance can switch back in
    /// Settings → General → Appearance.
    @Published var appearanceTheme: AppearanceTheme {
        didSet { UserDefaults.standard.set(appearanceTheme.rawValue, forKey: DefaultsKey.appearanceTheme) }
    }

    /// Opt-in crash reporting + analytics. Default OFF.
    ///
    /// TODO(stability-milestone): wire this to a Sentry SDK init that
    /// only runs when this flag is true. Until then, this flag is
    /// stored but has no consumers.
    @Published var telemetryEnabled: Bool {
        didSet { UserDefaults.standard.set(telemetryEnabled, forKey: DefaultsKey.telemetryEnabled) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        let wineBuildRaw = defaults.string(forKey: DefaultsKey.defaultWineBuild) ?? ""
        self.defaultWineBuild = WineBuild(rawValue: wineBuildRaw) ?? .gptk

        let winVerRaw = defaults.string(forKey: DefaultsKey.defaultWindowsVersion) ?? ""
        self.defaultWindowsVersion = WindowsVersion(rawValue: winVerRaw) ?? .win10

        let gfxRaw = defaults.string(forKey: DefaultsKey.defaultGraphicsBackend) ?? ""
        self.defaultGraphicsBackend = GraphicsBackend(rawValue: gfxRaw) ?? .d3dMetal

        if let path = defaults.string(forKey: DefaultsKey.bottlesLocation), !path.isEmpty {
            self.bottlesLocationOverride = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.bottlesLocationOverride = nil
        }

        let themeRaw = defaults.string(forKey: DefaultsKey.appearanceTheme) ?? ""
        self.appearanceTheme = AppearanceTheme(rawValue: themeRaw) ?? .nothing

        self.telemetryEnabled = defaults.bool(forKey: DefaultsKey.telemetryEnabled)
    }

    // MARK: - Derived values

    /// True when the configured bottles location is the built-in default.
    var isBottlesLocationDefault: Bool { bottlesLocationOverride == nil }

    /// True when an override is configured but the path no longer exists
    /// on disk — e.g. the user unplugged the external drive. UI surfaces
    /// this with a warning row in Settings → Storage.
    var isBottlesLocationMissing: Bool {
        guard let url = bottlesLocationOverride else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return !(exists && isDir.boolValue)
    }

    // MARK: - Migration

    /// Move every bottle folder from `source` into `destination`.
    /// Sequential; first error aborts (partial state is left in place
    /// — we don't roll back). Caller should then trigger
    /// `BottleManager.refresh()` so the in-memory list re-points.
    ///
    /// FRAGILITY: wine prefixes contain absolute paths to themselves
    /// in `system.reg`, `userdef.reg`, and a handful of `.lnk`
    /// shortcuts inside `drive_c/users/<u>/`. Most of those get
    /// resolved at launch from `WINEPREFIX`, so moving the prefix
    /// directory works for the common case — but games that bake the
    /// install path into their own config files (Steam included, in
    /// `loginusers.vdf` paths) may need a one-time `wineboot -u`
    /// after the move. The Settings UI warns about this.
    nonisolated static func migrateBottles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            // Only move directories — stray files at the bottles-dir
            // root are left in place. A defensive check; in practice
            // the bottles dir only contains UUID folders.
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let dest = destination.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            try fm.moveItem(at: entry, to: dest)
        }
    }
}
