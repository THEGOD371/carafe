import SwiftUI

/// User-selectable appearance theme, persisted via `AppSettings`.
///
/// `.system` is the stock macOS look Carafe shipped with. `.nothing`
/// reskins the app in the design language of Nothing OS (the Android
/// skin on Nothing Phones): always-dark, monochrome surfaces,
/// dot-matrix-style typography, and the brand's signature red used as
/// the sole accent color.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system
    case nothing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  return "macOS (system)"
        case .nothing: return "Nothing"
        }
    }

    var summary: String {
        switch self {
        case .system:
            return "The standard macOS appearance — follows your system light/dark mode and accent color."
        case .nothing:
            return "Inspired by Nothing OS: always dark, monochrome, dot-matrix typography, red accents."
        }
    }
}

/// Palette and drawing helpers for the Nothing theme.
///
/// The real Nothing OS uses the proprietary NDot / NType faces, which
/// we can't bundle — the system monospaced design (applied app-wide by
/// `AppearanceThemeModifier`) is the closest native stand-in for the
/// dot-matrix look.
enum NothingTheme {
    /// Nothing's signature red (≈ #D71921).
    static let accent = Color(red: 0.84, green: 0.10, blue: 0.13)

    /// Near-black background tone.
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.04)

    /// Faint white used for the decorative dot grid.
    static let dot = Color.white.opacity(0.12)
}

/// A sparse dot grid echoing Nothing's dot-matrix / glyph motif.
/// Purely decorative — used as a backdrop behind scrollable content
/// when the Nothing theme is active. Ignores hit testing so it never
/// swallows clicks.
struct NothingDotGrid: View {
    var spacing: CGFloat = 22
    var dotRadius: CGFloat = 1.1

    var body: some View {
        Canvas { context, size in
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    let rect = CGRect(
                        x: x - dotRadius,
                        y: y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(NothingTheme.dot))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Applies the selected theme to a view subtree. Attached at the root
/// of each scene in `CarafeApp`, so sheets and popovers presented from
/// within inherit it automatically.
private struct AppearanceThemeModifier: ViewModifier {
    let theme: AppearanceTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch theme {
        case .system:
            content
        case .nothing:
            content
                .fontDesign(.monospaced)
                .tint(NothingTheme.accent)
                .preferredColorScheme(.dark)
        }
    }
}

extension View {
    /// Apply the user's chosen `AppearanceTheme` to this subtree.
    func appearanceTheme(_ theme: AppearanceTheme) -> some View {
        modifier(AppearanceThemeModifier(theme: theme))
    }
}
