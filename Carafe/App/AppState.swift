import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let onboardingComplete = "carafe.onboardingComplete"
    }

    @Published var onboardingComplete: Bool {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }

    /// Shared bottle manager. Created here and pushed into the view
    /// tree as an environmentObject so any view can reach it without
    /// going through AppState.bottles every time.
    let bottles: BottleManager

    /// Shared library of games. Depends on BottleManager for orphan
    /// detection — created after `bottles` and passed a weak ref.
    let library: GameLibrary

    /// Detects + parses a Heroic Games Launcher install (Epic + GOG
    /// libraries). Ephemeral: never persisted into Carafe's
    /// library.json — Heroic is the source of truth.
    let heroicScanner: HeroicScanner

    init() {
        self.onboardingComplete = UserDefaults.standard.bool(forKey: Keys.onboardingComplete)
        let bottleManager = BottleManager()
        self.bottles = bottleManager
        self.library = GameLibrary(bottles: bottleManager)
        self.heroicScanner = HeroicScanner()
    }

    /// Root path for all on-disk state: ~/Library/Application Support/Carafe.
    /// Nonisolated: pure path computation, safe from any context.
    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("Carafe", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Default bottles directory inside Application Support. Used as
    /// the fallback when no override is set or when the override path
    /// is unreachable.
    nonisolated static var defaultBottlesDirectory: URL {
        let url = supportDirectory.appendingPathComponent("Bottles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The active bottles directory. Reads the user's Settings ->
    /// Storage override (if any) directly from `UserDefaults` so this
    /// stays callable from any context, including nonisolated/static
    /// call sites (BottleManager threads through here on every refresh).
    ///
    /// FALLBACK: if the override path doesn't exist on disk (external
    /// drive unplugged, dir deleted), we silently return the default
    /// path so the app stays usable. Settings -> Storage surfaces the
    /// mismatch with a warning row so the user can see what happened.
    nonisolated static var bottlesDirectory: URL {
        let fm = FileManager.default
        if let path = UserDefaults.standard.string(forKey: AppSettings.DefaultsKey.bottlesLocation),
           !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
            // Override is set but unreachable — fall through to default.
        }
        return defaultBottlesDirectory
    }
}
