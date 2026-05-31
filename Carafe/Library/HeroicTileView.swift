import SwiftUI

/// A library tile for a Heroic-imported game.
///
/// Visually mirrors `GameTileView` (cover-on-top, title-below) so the
/// two render comfortably side-by-side in the LazyVGrid. Differences:
///
///   * The cover is fetched lazily over the network from Heroic's
///     stored remote URL — no SteamGridDB / local-file fallback path.
///   * The corner badge labels the source (Epic / GOG).
///   * A dimmed "Not installed" overlay appears for games Heroic
///     hasn't downloaded yet — launch still works (Heroic will prompt
///     the user to install), but the badge sets expectations.
///   * No Edit / Remap / Compat / Install-components actions. Heroic
///     owns the bottle, Wine config, install state, and uninstall —
///     Carafe is a view, not a manager.
///
/// Click handling:
///   * Double-click — hand off to Heroic via the URL scheme.
///   * Right-click — context menu with "Launch in Heroic" + "Manage
///     in Heroic" (opens the Heroic app itself).
struct HeroicTileView: View {

    let game: HeroicGame

    private let tileWidth: CGFloat = 180
    private let coverAspect: CGFloat = 2.0 / 3.0  // standard "key art" portrait

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !game.isInstalled {
                    Text("Not installed in Heroic")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: tileWidth)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            HeroicLauncher.launch(game)
        }
        .contextMenu {
            Button {
                HeroicLauncher.launch(game)
            } label: {
                Label(game.isInstalled ? "Launch in Heroic" : "Install / Launch via Heroic",
                      systemImage: "play.fill")
            }
            Button {
                HeroicLauncher.openHeroic()
            } label: {
                Label("Manage in Heroic", systemImage: "arrow.up.right.square")
            }
            if let url = HeroicLauncher.launchURL(for: game) {
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    Label("Copy launch URL", systemImage: "doc.on.clipboard")
                }
            }
        }
        .help(game.isInstalled ? "Double-click to launch in Heroic" : "Double-click to install or launch via Heroic")
    }

    // MARK: - Cover artwork

    @ViewBuilder
    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            artworkBase
            badge
        }
        .overlay(alignment: .center) {
            if !game.isInstalled {
                // Subtle dim + cloud-download glyph for un-downloaded
                // games. Distinguishes them at a glance from titles
                // already on disk.
                Rectangle()
                    .fill(.black.opacity(0.35))
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var artworkBase: some View {
        if let url = game.coverArtURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    placeholder.overlay(ProgressView().controlSize(.small))
                @unknown default:
                    placeholder
                }
            }
            .frame(width: tileWidth, height: tileWidth / coverAspect)
            .clipped()
        } else {
            placeholder
                .frame(width: tileWidth, height: tileWidth / coverAspect)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.25), Color.secondary.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: game.source.badgeSystemImage)
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(game.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Source badge

    @ViewBuilder
    private var badge: some View {
        HStack(spacing: 4) {
            Image(systemName: game.source.badgeSystemImage)
                .font(.caption.weight(.semibold))
            Text(game.source.displayName)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(game.source.badgeColor.opacity(0.95))
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .padding(8)
    }
}
