import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Steam-style grid of game tiles. Default view after onboarding.
struct LibraryGridView: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var bottles: BottleManager
    @EnvironmentObject private var heroicScanner: HeroicScanner

    @State private var showingAdd = false
    @State private var editingGame: Game?
    @State private var launchingGame: Game?
    @State private var deleteCandidate: Game?
    @State private var remapCandidate: Game?

    /// Sheet binding for "Install Components in this game's bottle…"
    /// from the tile context menu.
    @State private var componentsTarget: Bottle?

    /// Sheet binding for the per-game Compatibility… editor.
    @State private var compatTarget: Game?

    /// Steam install / add-game sheets.
    @State private var showingInstallSteam = false
    @State private var addSteamGameTarget: SteamMenuTarget?

    // Native Epic integration via legendary CLI (AddEpicGameSheet,
    // EpicAuth, LegendaryInstaller) is dormant: Epic's 2FA + redirect-
    // page transience made every auth flow we tried unreliable. Users
    // who want Epic games install Heroic Games Launcher; HeroicScanner
    // picks up their library automatically (see the "From Heroic"
    // section in the grid + the Connect Heroic prompt in the empty
    // state). The Swift core stays in tree for a possible future
    // revival once legendary upstream's auth story improves.

    /// Identifiable wrapper so .sheet(item:) re-presents reliably even
    /// when the underlying bottleID stays the same across opens.
    struct SteamMenuTarget: Identifiable {
        let id = UUID()
        let bottleID: UUID?
    }

    private let tileWidth: CGFloat = 180
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth + 40), spacing: 18)]
    }

    var body: some View {
        Group {
            // Empty-state only when BOTH Carafe-managed AND Heroic-
            // imported sections are empty. If the user has zero
            // Carafe games but Heroic detected, we show the grid (so
            // their Heroic library is reachable on day-one).
            if library.games.isEmpty && heroicScanner.games.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showingAdd) {
            GameFormSheet(mode: .add)
        }
        .sheet(item: $editingGame) { game in
            GameFormSheet(mode: .edit(game))
        }
        .sheet(item: $launchingGame) { game in
            LaunchGameSheet(game: game)
        }
        .sheet(item: $remapCandidate) { game in
            RemapBottleSheet(game: game)
        }
        .sheet(item: $componentsTarget) { bottle in
            ComponentsSheet(bottle: bottle)
        }
        .sheet(item: $compatTarget) { game in
            CompatConfigSheet(game: game)
        }
        .sheet(isPresented: $showingInstallSteam) {
            InstallSteamSheet()
        }
        .sheet(item: $addSteamGameTarget) { target in
            AddSteamGameSheet(initialBottleID: target.bottleID)
        }
        .confirmationDialog(
            "Remove “\(deleteCandidate?.name ?? "")” from your library?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            ),
            presenting: deleteCandidate
        ) { game in
            Button("Remove from Library", role: .destructive) {
                library.remove(game)
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { _ in
            Text("This only removes the library entry. The bottle and the exe stay on disk.")
        }
        .alert(
            "Library error",
            isPresented: Binding(
                get: { library.lastError != nil },
                set: { if !$0 { library.clearError() } }
            ),
            presenting: library.lastError
        ) { _ in
            Button("OK", role: .cancel) { library.clearError() }
        } message: { msg in Text(msg) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    addSteamGameTarget = SteamMenuTarget(bottleID: nil)
                } label: {
                    Label("Add Steam Game…", systemImage: "tray.and.arrow.down")
                }
                .disabled(!hasAnySteamBottle)
                Button {
                    showingInstallSteam = true
                } label: {
                    Label("Install Steam in Bottle…", systemImage: "arrow.down.app")
                }
                .disabled(bottles.entries.compactMap(\.validBottle).isEmpty)
                if !hasAnySteamBottle && bottles.entries.compactMap(\.validBottle).isEmpty == false {
                    Divider()
                    Text("No bottle has Steam yet — start with Install Steam.")
                        .font(.caption)
                }
            } label: {
                Label("Steam", systemImage: "gamecontroller.fill")
            }
            .help("Steam install + add games")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Label("Add Game", systemImage: "plus")
            }
            .help("Add a game to the library")
            .disabled(bottles.entries.compactMap(\.validBottle).isEmpty || !WineRunner.isWineAvailable)
        }
    }

    private var hasAnySteamBottle: Bool {
        bottles.entries.compactMap(\.validBottle).contains { SteamLibraryScanner.hasSteam(in: $0) }
    }

    // MARK: - Empty state

    /// Suggestion card shown beneath the empty state's primary CTA
    /// when no Heroic install was detected. Carafe's Epic + GOG
    /// story currently goes through Heroic (whose own auth +
    /// download flow is much more reliable than what we could build
    /// directly atop legendary), so pointing users at it
    /// pre-emptively shortens the "where do I get Epic games from"
    /// path for the dominant use case.
    @ViewBuilder
    private var connectHeroicPrompt: some View {
        VStack(spacing: 8) {
            Divider()
                .padding(.horizontal, 60)
                .padding(.vertical, 6)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Want Epic or GOG games?")
                        .font(.callout.weight(.semibold))
                    Text("Install Heroic Games Launcher and sign into your Epic / GOG account there. Carafe will detect Heroic and show your library here automatically.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let url = URL(string: "https://heroicgameslauncher.com") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Download Heroic", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.regular)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(.top, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(.tertiary)
                .overlay {
                    Image(systemName: "wineglass")
                        .resizable().scaledToFit()
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.tint)
                }
            Text("No games yet").font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                Text("Add a game to give it a name, cover art, and a one-click launch.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
                if bottles.entries.compactMap(\.validBottle).isEmpty {
                    Text("You'll need at least one bottle first — switch to the Bottles tab in the sidebar.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 460)
                        .padding(.top, 6)
                }
            }
            Button {
                showingAdd = true
            } label: {
                Label("Add your first game", systemImage: "plus")
                    .frame(minWidth: 220)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 12)
            .disabled(bottles.entries.compactMap(\.validBottle).isEmpty || !WineRunner.isWineAvailable)

            // Suggest Heroic when it isn't installed. Hidden once the
            // scanner detects a Heroic config — at that point the
            // "From Heroic" section in the grid is the discoverable
            // path and this prompt would be redundant noise.
            if !heroicScanner.isInstalled {
                connectHeroicPrompt
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Carafe-managed games (the canonical library). Only
                // rendered when there are any — keeps the layout clean
                // for users with a Heroic-only library.
                if !library.games.isEmpty {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(library.games) { game in
                            GameTileView(
                                game: game,
                                status: library.status(of: game),
                                coverURL: library.coverArtURL(for: game),
                                onPlay: { launchingGame = game },
                                onEdit: { editingGame = game },
                                onShowInFinder: { showInFinder(game) },
                                onRemove: { deleteCandidate = game },
                                onRelocateExe: { relocateExe(for: game) },
                                onRemap: { remapCandidate = game },
                                onInstallComponents: {
                                    if let bottle = library.bottle(for: game) {
                                        componentsTarget = bottle
                                    }
                                },
                                onEditCompatibility: { compatTarget = game },
                                onPickLocalCover: { pickLocalCover(for: game) },
                                onDropLocalCover: { url in
                                    library.setCoverArt(for: game, fromLocalFile: url)
                                }
                            )
                        }
                    }
                }

                // Heroic-imported games. Rendered after the Carafe
                // games with a section header that doubles as a
                // refresh control. Hidden entirely when no Heroic
                // games were detected.
                if !heroicScanner.games.isEmpty {
                    heroicSection
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var heroicSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .foregroundStyle(.tint)
                Text("From Heroic")
                    .font(.title3.weight(.semibold))
                Text("(\(heroicScanner.games.count))")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await heroicScanner.scan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-read Heroic's library files")
            }
            .padding(.top, library.games.isEmpty ? 0 : 8)

            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(heroicScanner.games) { game in
                    HeroicTileView(game: game)
                }
            }
        }
    }

    // MARK: - Actions

    private func showInFinder(_ game: Game) {
        guard let bottle = library.bottle(for: game) else {
            library.clearError()
            return
        }
        let exeURL = game.exePath.resolve(bottle: bottle)
        if FileManager.default.fileExists(atPath: exeURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([exeURL])
        } else {
            // Exe gone — reveal the bottle folder instead.
            NSWorkspace.shared.activateFileViewerSelecting([bottle.prefixURL])
        }
    }

    private func relocateExe(for game: Game) {
        let panel = NSOpenPanel()
        panel.title = "Locate the executable for \(game.name)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = []
        if let t = UTType(filenameExtension: "exe") { types.append(t) }
        if let t = UTType(filenameExtension: "msi") { types.append(t) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if let bottle = library.bottle(for: game) {
            panel.directoryURL = bottle.prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if PEValidator.ext(of: url) != "msi", !PEValidator.looksLikePE(at: url) {
            // Surface via library error
            return
        }
        library.relocate(game, to: url)
    }

    /// Open NSOpenPanel filtered to image types, set the picked file
    /// as the game's cover art (copied into the cache).
    private func pickLocalCover(for game: Game) {
        let panel = NSOpenPanel()
        panel.title = "Choose a cover image for \(game.name)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Use the standard `.image` UTType so subtypes (jpeg, png,
        // heic, gif, webp) all light up in the panel.
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setCoverArt(for: game, fromLocalFile: url)
    }
}

// MARK: - Tile

struct GameTileView: View {
    let game: Game
    let status: GameStatus
    let coverURL: URL?
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onShowInFinder: () -> Void
    let onRemove: () -> Void
    let onRelocateExe: () -> Void
    let onRemap: () -> Void
    let onInstallComponents: () -> Void
    let onEditCompatibility: () -> Void
    let onPickLocalCover: () -> Void
    let onDropLocalCover: (URL) -> Void

    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 180)
        .contentShape(Rectangle())
        .onTapGesture { if status == .ok { onPlay() } }
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .onDrop(
            of: [.fileURL, .image],
            isTargeted: $isDropTargeted,
            perform: handleDrop
        )
    }

    /// Accept dropped image files. Tries `URL` payload first
    /// (Finder drag), then falls back to `NSImage` data wrapped into
    /// a temp file (drag from a browser / Preview's saved-to-clipboard
    /// image). Single-file only.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // FRAGILITY: `loadObject(ofClass: URL.self)` is async and runs
        // on a background queue. We hop to MainActor before calling
        // the callback because GameLibrary.setCoverArt is main-actor.
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    onDropLocalCover(url)
                }
            }
            return true
        }
        return false
    }

    private var cover: some View {
        ZStack(alignment: .center) {
            CoverArtView(game: game, coverURL: coverURL)
            // Hover overlay with Play button
            if isHovering && status == .ok {
                Color.black.opacity(0.4)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            // Drop target highlight: blue ring + "Drop image here"
            // overlay while a drag is hovering.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [6]))
                Label("Drop image to set cover", systemImage: "arrow.down.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.85))
                    .clipShape(Capsule())
            }
            // Orphan badge
            if status != .ok {
                VStack {
                    HStack {
                        statusBadge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
            // Steam badge — bottom-right corner when this game was
            // added via the Add Steam Game flow (game.steamAppID set).
            // Epic badge sits in the same spot when epicAppName is
            // set; the two are mutually exclusive in practice (a Game
            // entry comes from exactly one launcher source).
            if game.steamAppID != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "gamecontroller.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.85))
                            .clipShape(Capsule())
                    }
                }
                .padding(8)
            } else if game.epicAppName != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: "gamecontroller")
                                .font(.caption2.weight(.semibold))
                            Text("Epic")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.95))
                        .clipShape(Capsule())
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 180, height: 270)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .ok: EmptyView()
        case .bottleMissing:
            Label("Bottle missing", systemImage: "shippingbox.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.red.opacity(0.85))
                .clipShape(Capsule())
        case .exeMissing:
            Label("Exe missing", systemImage: "questionmark.folder.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.orange.opacity(0.9))
                .clipShape(Capsule())
        }
    }

    private var subline: String {
        if status != .ok {
            switch status {
            case .bottleMissing: return "Bottle no longer exists"
            case .exeMissing:    return "Exe not found"
            case .ok:            return ""
            }
        }
        if let last = game.lastPlayedAt {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            return "Played \(fmt.localizedString(for: last, relativeTo: Date()))"
        }
        return "Never played"
    }

    @ViewBuilder
    private var contextMenu: some View {
        if status == .ok {
            Button("Play", action: onPlay)
            Divider()
        }
        Button("Edit…", action: onEdit)
        Button("Compatibility…", action: onEditCompatibility)
        Menu("Set cover art") {
            Button("Use local image…", action: onPickLocalCover)
        }
        Button("Show in Finder", action: onShowInFinder)
        if status == .ok || status == .exeMissing {
            Button("Install Components in bottle…", action: onInstallComponents)
        }
        Divider()
        if status == .exeMissing {
            Button("Relocate exe…", action: onRelocateExe)
        }
        if status == .bottleMissing {
            Button("Remap to another bottle…", action: onRemap)
        }
        if status != .ok {
            Divider()
        }
        Button("Remove from Library", role: .destructive, action: onRemove)
    }
}

// MARK: - Remap sheet

private struct RemapBottleSheet: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    let game: Game
    @State private var selectedBottleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Remap “\(game.name)” to another bottle")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("The original bottle is no longer in the library. Pick a replacement — the exe path is preserved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Bottle", selection: $selectedBottleID) {
                    ForEach(bottles.entries.compactMap(\.validBottle)) { b in
                        Text(b.name).tag(Optional(b.id))
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(16)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remap") {
                    if let id = selectedBottleID {
                        library.remap(game, toBottleID: id)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBottleID == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440)
        .onAppear { selectedBottleID = bottles.entries.compactMap(\.validBottle).first?.id }
    }
}
