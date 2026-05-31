import Foundation
import AppKit
import SwiftUI

/// Owns Epic Games auth state for the Add-from-Epic flow.
///
/// Flow:
///   1. UI calls `refreshStatus()`. We run `legendary status --json`
///      (or fall back to text scrape if --json isn't supported by
///      this legendary version) and set `.loggedOut` /
///      `.loggedIn(name)`.
///   2. If logged out, UI calls `loginURL()` to get the Epic
///      consent URL, opens it in the user's default browser, asks
///      them to paste the resulting `sid` (session id) value.
///   3. UI calls `completeLogin(sid:)`, which shells out to
///      `legendary auth --sid <code>`. On success we refresh status.
///
/// FRAGILITY
/// ---------
/// 1. **The Epic login URL is hardcoded** to the form legendary
///    itself uses internally (production Epic client ID
///    `34a02cf8f4414e29b15921876da36f9a`, redirect to a generic
///    "exchange" page that surfaces the SID). If Epic rotates the
///    client ID or the redirect endpoint, legendary breaks first and
///    we follow. Bump the constant below to match
///    legendary upstream when that happens.
/// 2. **`status` output format.** legendary's text output is human-
///    facing and not stable across versions. We try `--json` first
///    and only fall back to a permissive text scrape ("Logged in
///    as <name>") if the JSON option isn't available. If both fail
///    we treat status as `.loggedOut` rather than `.error` — false
///    negatives are recoverable (user just signs in again).
@MainActor
final class EpicAuth: ObservableObject {

    enum Status: Equatable {
        case notReady              // legendary not yet installed
        case checking
        case loggedOut
        case loggedIn(displayName: String)
        case error(String)
    }

    @Published private(set) var status: Status = .notReady

    /// Epic OAuth login URL using the canonical `responseType=code`
    /// flow that legendary's own docs recommend. After the user
    /// signs in, Epic redirects to a JSON page showing
    /// `{"authorizationCode": "<value>"}` — a stable page that
    /// doesn't auto-close, so the user can copy the code at leisure.
    ///
    /// We hand the copied code to `legendary auth --code <value>`
    /// to complete the exchange.
    nonisolated static let loginURL = URL(string:
        "https://www.epicgames.com/id/login?redirectUrl=" +
        "https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect" +
        "%3FclientId%3D34a02cf8f4414e29b15921876da36f9a" +
        "%26responseType%3Dcode"
    )!

    /// True if Epic Games Launcher is installed at the canonical
    /// `/Applications` location. When true, `attemptImport()` is the
    /// recommended first auth attempt because it's zero-click.
    nonisolated static var isEpicGamesLauncherInstalled: Bool {
        FileManager.default.fileExists(
            atPath: "/Applications/Epic Games Launcher.app"
        )
    }

    /// Pull the current Epic auth status from legendary. Updates
    /// `status` as a side effect; no return value. Cheap when
    /// already-cached; safe to call repeatedly.
    func refreshStatus() async {
        guard LegendaryInstaller.isInstalled else {
            status = .notReady
            return
        }
        status = .checking

        // First attempt: structured JSON.
        if let parsed = try? await LegendaryRunner.decodeJSON(
            ["status", "--json"], as: StatusJSON.self
        ) {
            if let account = parsed.account, !account.isEmpty {
                status = .loggedIn(displayName: account)
            } else {
                status = .loggedOut
            }
            return
        }

        // Fallback: text scrape. legendary's status prints something
        // like "Epic account: SomeUser" or "Not logged in".
        if let raw = try? await LegendaryRunner.capture(["status"]) {
            let lower = raw.lowercased()
            if lower.contains("not logged in") || lower.contains("no account") {
                status = .loggedOut
                return
            }
            // Try to extract the username from a line containing
            // "account:".
            for line in raw.split(separator: "\n") {
                if line.lowercased().contains("account") {
                    let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                    if pieces.count == 2 {
                        let name = pieces[1].trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty && name.lowercased() != "none" {
                            status = .loggedIn(displayName: name)
                            return
                        }
                    }
                }
            }
            // We couldn't parse but legendary returned something — treat
            // as logged out (safe default).
            status = .loggedOut
            return
        }

        // Both probes failed.
        status = .loggedOut
    }

    /// Open Epic's `responseType=code` login URL in the default
    /// browser. After sign-in Epic redirects to a JSON page
    /// containing `{"authorizationCode": "<value>"}` — the user
    /// copies that code into the sheet's paste field, which calls
    /// `completeLogin(code:)`.
    func openLoginPage() {
        NSWorkspace.shared.open(Self.loginURL)
    }

    /// Try `legendary auth --import`. Reads tokens directly from
    /// the Epic Games Launcher's local config. Zero user interaction
    /// when it succeeds — the canonical "easy mode" path.
    ///
    /// FRAGILITY: legendary's `--import` expects to find Epic Games
    /// Launcher's encrypted credentials at a path it knows about.
    /// On macOS the canonical Apple-Silicon-native Launcher (Nov
    /// 2025+) stores config under
    /// `~/Library/Application Support/Epic/EpicGamesLauncher/`.
    /// Older legendary versions only knew the Windows path; if
    /// import succeeds on a fresh PyPI install we know we're good,
    /// but if it fails the manual code-paste fallback is what users
    /// actually rely on.
    func attemptImport() async throws {
        _ = try await LegendaryRunner.capture(["auth", "--import"])
        await refreshStatus()
    }

    /// Exchange an Epic authorizationCode (copied from the JSON
    /// page legendary's loginURL redirects to) for refresh tokens.
    /// legendary stores the tokens; we just call refreshStatus()
    /// after.
    ///
    /// Modern legendary uses `--code` for authorization codes
    /// (the JSON-page value) and reserves `--token` for exchange
    /// tokens. The older `--sid` flag still works in some versions
    /// but `--code` is what's documented as current.
    func completeLogin(code: String) async throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.emptyCode
        }
        do {
            _ = try await LegendaryRunner.capture(["auth", "--code", trimmed])
        } catch let err as LegendaryRunner.Failure {
            switch err {
            case .nonZeroExit(_, let stderr):
                throw Failure.exchangeFailed(stderr.isEmpty ? "Epic rejected the code." : stderr)
            default:
                throw Failure.exchangeFailed(err.localizedDescription)
            }
        }
        await refreshStatus()
    }

    /// Drop the stored tokens. Useful for the "switch account" path
    /// or to force re-auth after a stale-token error.
    func logout() async throws {
        _ = try await LegendaryRunner.capture(["auth", "--delete"])
        await refreshStatus()
    }

    // MARK: - Wire formats

    /// Defensive shape: legendary's `status --json` returns different
    /// keys across versions. We pull `account` (newer) and look at
    /// `username` (older) as fallbacks.
    private struct StatusJSON: Decodable {
        let account: String?
        let username: String?
    }

    enum Failure: LocalizedError {
        case emptyCode
        case exchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyCode:
                return "Paste the SID code from the redirect URL into the field."
            case .exchangeFailed(let detail):
                return "Epic login failed: \(detail)"
            }
        }
    }
}
