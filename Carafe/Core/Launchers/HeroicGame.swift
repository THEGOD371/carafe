import Foundation
import SwiftUI

/// A game imported from a running Heroic Games Launcher install.
///
/// Heroic-imported games are EPHEMERAL — Carafe never persists them in
/// its own `library.json`. They live only in `HeroicScanner.games` and
/// re-appear on each scan. If the user uninstalls Heroic, these tiles
/// disappear from Carafe's library on the next refresh. This is
/// intentional: Heroic owns the source of truth (auth, downloads,
/// installed-state); Carafe is a *view* over Heroic's library, not a
/// second copy of it.
///
/// The `appName` is Heroic's internal app identifier (Epic's
/// "namespace/asset_id" or GOG's numeric ID). It's what we feed to the
/// `heroic://launch/<runner>/<appName>` URL scheme.
struct HeroicGame: Identifiable, Hashable, Sendable {

    /// Heroic's internal app identifier. For Epic this is usually a
    /// GUID-ish slug ("Fortnite", "Carbon" + GUID, etc.); for GOG
    /// it's the numeric product ID as a string ("1207659049").
    let appName: String

    /// Display name as Heroic stores it.
    let title: String

    /// Which Heroic backend manages this game.
    let source: HeroicGameSource

    /// Remote URL of the cover art Heroic associates with this title
    /// (CDN-hosted by Epic / GOG). nil = no art known; tile shows a
    /// placeholder.
    let coverArtURL: URL?

    /// Whether Heroic considers the game currently installed on disk.
    /// We surface this in the UI ("Install in Heroic" vs "Launch")
    /// but launch attempts on uninstalled games still work — Heroic's
    /// launch handler prompts the user to install if needed.
    let isInstalled: Bool

    /// Stable identity for SwiftUI ForEach. Two games can share an
    /// app_name across stores (rare but possible) — namespace by source.
    var id: String { "\(source.rawValue)/\(appName)" }
}

/// Which Heroic backend a game came from. The raw value is the same
/// string Heroic uses internally for the `runner` field in its
/// library JSON and the path component in the `heroic://launch/<runner>/<id>`
/// URL scheme.
enum HeroicGameSource: String, Hashable, Sendable, CaseIterable {
    /// Epic Games Store — Heroic delegates to its bundled `legendary`
    /// binary, hence the "legendary" string everywhere in Heroic's
    /// internals. We surface it to users as "Epic".
    case epic = "legendary"

    /// GOG.com — Heroic delegates to its `heroic-gogdl` fork. The
    /// runner string is plain "gog".
    case gog = "gog"

    /// User-facing label for the tile badge + acknowledgements.
    var displayName: String {
        switch self {
        case .epic: return "Epic"
        case .gog:  return "GOG"
        }
    }

    /// SF Symbol for the corner badge on the tile.
    var badgeSystemImage: String {
        switch self {
        case .epic: return "gamecontroller.fill"
        case .gog:  return "g.circle.fill"
        }
    }

    /// Accent color for the badge. Epic's brand is dark grey/black;
    /// GOG's is purple. We pick muted near-brand colours that still
    /// read on Carafe's dark library background.
    var badgeColor: Color {
        switch self {
        case .epic: return Color(red: 0.12, green: 0.12, blue: 0.14)   // near-black, Epic brand
        case .gog:  return Color(red: 0.50, green: 0.20, blue: 0.65)   // purple, GOG brand
        }
    }
}
