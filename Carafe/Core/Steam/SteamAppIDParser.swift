import Foundation

/// Parses Steam App IDs (and optional name hints) from the strings
/// users typically have on hand:
///
///   - raw integer:    `1245620`
///   - protocol URL:   `steam://run/1245620`
///   - store URL:      `https://store.steampowered.com/app/1245620/Elden_Ring/`
///   - bare-host URL:  `https://steamcommunity.com/app/1245620/`
///
/// Used by the "Add Steam Game by AppID" path so the user can paste
/// whatever they copied from a browser tab and Carafe figures out
/// the AppID and a sensible default game name.
///
/// FRAGILITY: regex-based path matching. Steam URLs have been stable
/// for ~15 years (the `/app/<id>/<slug>` shape predates the
/// store-revamp era). If Valve restructures their URLs, the parser
/// returns nil and the user falls back to typing the AppID by hand —
/// not catastrophic.
enum SteamAppIDParser {

    /// Extract a positive AppID from any of the accepted formats.
    /// Returns nil if no plausible ID is found.
    static func appID(from rawInput: String) -> Int? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Fast path: input is just a positive integer.
        if let id = Int(trimmed), id > 0 {
            return id
        }

        // Slow path: scan the string for /app/<digits> or /run/<digits>.
        // Covers steam://, store.steampowered.com/app/, and
        // steamcommunity.com/app/ in one go.
        let pattern = #"/(?:app|run)/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let captureRange = Range(match.range(at: 1), in: trimmed),
              let id = Int(trimmed[captureRange]),
              id > 0
        else {
            return nil
        }
        return id
    }

    /// Try to recover a display name from a store URL.
    /// `…/app/1245620/Elden_Ring/` → "Elden Ring".
    /// Returns nil when the input has no slug (raw AppID, protocol
    /// URL, store URL without the trailing name segment).
    static func nameHint(from rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Capture the path segment immediately after /app/<digits>/.
        // Tolerant of trailing slashes, query strings, and fragments.
        let pattern = #"/app/\d+/([^/?#\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..., in: trimmed)
              ),
              let captureRange = Range(match.range(at: 1), in: trimmed)
        else {
            return nil
        }
        let slug = String(trimmed[captureRange])
        // URL-decode (in case of `%20` etc.) then swap _ → space.
        let decoded = slug.removingPercentEncoding ?? slug
        let humanized = decoded.replacingOccurrences(of: "_", with: " ")
        let cleaned = humanized.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
