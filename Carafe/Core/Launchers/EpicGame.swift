import Foundation

/// An owned Epic Games library entry, as `legendary list-games --json`
/// returns it. Used during the Add-from-Epic flow's library picker;
/// once a game is actually installed into a Carafe bottle, it lives
/// in the regular `Game` model with `epicAppName` set.
///
/// We pull a minimal field set so a future legendary schema change is
/// unlikely to break the decode — every optional is `try?`-mapped at
/// parse time.
struct EpicGame: Identifiable, Sendable, Hashable {
    /// legendary's internal app identifier (same string used by
    /// `legendary install <appName>` and `heroic://launch/legendary/<appName>`).
    let appName: String

    /// Display title.
    let title: String

    /// Whether legendary has already downloaded this game on this
    /// machine. (`legendary list-installed` would also tell us, but
    /// `list-games` includes it as a field.)
    let isInstalled: Bool

    /// Best-effort cover URL from Epic's CDN. nil if the metadata
    /// didn't include a key image — tile/list row falls back to a
    /// placeholder.
    let coverArtURL: URL?

    var id: String { appName }
}

// MARK: - Decoding shim

/// Wire format from `legendary list-games --json`. legendary returns
/// an array of game entries; we only consume the fields we use.
/// Field names match legendary's snake_case output.
struct LegendaryListGamesEntry: Decodable {
    let app_name: String?
    let app_title: String?
    let is_dlc: Bool?
    let metadata: Metadata?
    let asset_infos: [String: AssetInfo]?

    struct Metadata: Decodable {
        let keyImages: [KeyImage]?

        struct KeyImage: Decodable {
            let type: String?
            let url: String?
        }
    }

    struct AssetInfo: Decodable {
        let appName: String?
    }

    /// Convert to our internal model. Returns nil for entries that
    /// can't form a usable game (missing identifier/title or DLC).
    func toEpicGame(installed: Set<String>) -> EpicGame? {
        guard let appName = app_name, !appName.isEmpty,
              let title = app_title, !title.isEmpty
        else { return nil }
        // Drop DLC — Epic ships DLC as separate library entries; users
        // never "install" DLC standalone, they own it relative to a
        // base game. Carafe can't represent that in its library model
        // yet, so we hide them here.
        if is_dlc == true { return nil }

        // Pick a cover image. Epic's keyImages have many types; we
        // prefer "DieselGameBoxTall" (the portrait key art used by
        // the Epic Launcher itself), then any "OfferImageTall", then
        // anything else.
        let preferredTypes = ["DieselGameBoxTall", "OfferImageTall", "DieselGameBox", "Thumbnail"]
        var coverURL: URL?
        if let images = metadata?.keyImages, !images.isEmpty {
            for type in preferredTypes {
                if let hit = images.first(where: { $0.type == type }),
                   let str = hit.url, let url = URL(string: str) {
                    coverURL = url
                    break
                }
            }
            if coverURL == nil,
               let any = images.first(where: { $0.url != nil }),
               let str = any.url, let url = URL(string: str) {
                coverURL = url
            }
        }

        return EpicGame(
            appName: appName,
            title: title,
            isInstalled: installed.contains(appName),
            coverArtURL: coverURL
        )
    }
}

/// Wire format from `legendary list-installed --json`. We only need
/// the appName field to build the `installed` set passed to
/// `toEpicGame`.
struct LegendaryListInstalledEntry: Decodable {
    let app_name: String?
}
