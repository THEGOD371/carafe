import SwiftUI
import AppKit

/// Renders a game's cover. Loads the cached file when one exists,
/// otherwise generates a placeholder from the game's name.
///
/// Used at two sizes:
///   - Tile thumbnail (~200×270 in the library grid)
///   - Small badge (~40×54 in the form sheet preview)
///
/// Loading is synchronous via NSImage(contentsOf:) — cover art files
/// are ≤ a couple MB and live on local disk, so this is fast enough
/// for the grid without an explicit async layer.
struct CoverArtView: View {
    let game: Game
    let coverURL: URL?

    var body: some View {
        ZStack {
            if let coverURL,
               let image = NSImage(contentsOf: coverURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: PlaceholderPalette.colors(for: game.name),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                .minimumScaleFactor(0.3)
                .padding()
        }
    }

    private var initials: String {
        PlaceholderPalette.initials(for: game.name)
    }
}

/// Deterministic palette generator for cover art placeholders.
/// Hashing the name keeps the same game looking the same colour
/// across launches and devices.
enum PlaceholderPalette {
    /// Eight colour pairs that look distinct against white text.
    private static let pairs: [[Color]] = [
        [Color(red: 0.42, green: 0.11, blue: 0.22), Color(red: 0.62, green: 0.18, blue: 0.35)], // wine
        [Color(red: 0.10, green: 0.30, blue: 0.55), Color(red: 0.20, green: 0.50, blue: 0.75)], // ocean
        [Color(red: 0.20, green: 0.45, blue: 0.20), Color(red: 0.35, green: 0.65, blue: 0.35)], // forest
        [Color(red: 0.55, green: 0.30, blue: 0.10), Color(red: 0.80, green: 0.50, blue: 0.20)], // copper
        [Color(red: 0.35, green: 0.15, blue: 0.45), Color(red: 0.55, green: 0.30, blue: 0.65)], // violet
        [Color(red: 0.50, green: 0.10, blue: 0.10), Color(red: 0.75, green: 0.25, blue: 0.20)], // ember
        [Color(red: 0.20, green: 0.40, blue: 0.45), Color(red: 0.35, green: 0.60, blue: 0.65)], // teal
        [Color(red: 0.40, green: 0.40, blue: 0.45), Color(red: 0.60, green: 0.60, blue: 0.65)], // slate
    ]

    static func colors(for name: String) -> [Color] {
        let hash = stableHash(name)
        return pairs[hash % pairs.count]
    }

    static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let chars = words
            .compactMap { $0.first.map(String.init)?.uppercased() }
            .joined()
        return chars.isEmpty ? "?" : chars
    }

    /// `String.hashValue` is randomized per launch (Swift's hash
    /// salting). We need a stable hash for visual consistency, so
    /// roll our own — sum of unicode scalars modulo Int.max.
    private static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV-1a offset basis
        for scalar in s.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
