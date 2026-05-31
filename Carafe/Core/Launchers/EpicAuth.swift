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

    /// Plain Epic login page — no auto-redirect. We open this first
    /// so the user signs into their Epic account; after sign-in
    /// they're on whatever Epic dashboard their account lands on,
    /// and the page stays open long enough to read.
    ///
    /// The user then manually navigates to `sidRedirectURL` (we
    /// give them a Copy URL button) to get the SID appended to
    /// their address bar.
    nonisolated static let loginURL = URL(string:
        "https://www.epicgames.com/id/login"
    )!

    /// SID-extraction URL. The user pastes this into the SAME
    /// browser after signing in via `loginURL`. Epic's redirect API
    /// observes that the user is authenticated, generates a fresh
    /// SID for legendary's client ID, and redirects to the
    /// `redirectUrl` query parameter (the Epic store — a normal
    /// page that does NOT auto-close) with the SID appended as
    /// `?sid=<value>`.
    ///
    /// The user then copies the FULL final URL from their address
    /// bar and pastes it into Carafe. `extractSID(from:)` parses
    /// out the SID.
    ///
    /// FRAGILITY: the `clientId` matches legendary's hardcoded
    /// value. If Epic ever rotates it, legendary's upstream breaks
    /// first and we follow — bump this constant to match.
    nonisolated static let sidRedirectURL = URL(string:
        "https://www.epicgames.com/id/api/redirect" +
        "?clientId=34a02cf8f4414e29b15921876da36f9a" +
        "&redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fstore%2Fen-US%2F"
    )!

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

    /// Open the Epic login page in the user's default browser. The
    /// page does not auto-redirect; after sign-in the user
    /// separately visits `sidRedirectURL` to obtain the SID.
    func openLoginPage() {
        NSWorkspace.shared.open(Self.loginURL)
    }

    /// Open `sidRedirectURL` directly. The auth sheet's primary path
    /// gives the user a Copy URL button (so they paste it manually
    /// into the same browser session as their login) — this helper
    /// exists for the convenience case where they want one-click
    /// access from inside Carafe.
    func openSIDRedirect() {
        NSWorkspace.shared.open(Self.sidRedirectURL)
    }

    /// Pull a SID value out of whatever the user pasted into the
    /// auth field. Three shapes handled:
    ///   1. Full URL with `?sid=<value>` query param — what they get
    ///      from the address bar after `sidRedirectURL` resolves.
    ///      Extracted via `URLComponents`.
    ///   2. Bare alphanumeric SID (Epic's tokens are hex-like,
    ///      32+ chars). Accepted as-is if the input looks like one.
    ///   3. Anything else → nil. The UI surfaces a "couldn't find
    ///      a SID" hint and the Continue button stays disabled.
    ///
    /// Nonisolated so the sheet's `.disabled(authButtonDisabled)`
    /// binding can evaluate it on the SwiftUI rendering thread
    /// without bouncing through the actor.
    nonisolated static func extractSID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Shape 1 — URL with sid query param.
        if let url = URL(string: trimmed),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let sid = components.queryItems?
                .first(where: { $0.name.lowercased() == "sid" })?.value,
           !sid.isEmpty
        {
            return sid
        }

        // Shape 2 — bare SID. Epic's tokens are alphanumeric and
        // long enough that we can heuristically distinguish them
        // from typed gibberish.
        if trimmed.count >= 16,
           trimmed.allSatisfy({ $0.isLetter || $0.isNumber })
        {
            return trimmed
        }

        return nil
    }

    /// Hand a SID code from the redirect URL to legendary, which
    /// exchanges it for refresh tokens and stores them. Throws if
    /// legendary rejects the code (bad/expired/wrong format).
    func completeLogin(sid: String) async throws {
        let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Failure.emptyCode
        }
        // legendary auth --sid <code> exchanges and stores tokens.
        do {
            _ = try await LegendaryRunner.capture(["auth", "--sid", trimmed])
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
