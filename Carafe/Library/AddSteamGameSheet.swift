import SwiftUI
import AppKit

/// Add Steam games to the Carafe library. Two modes:
///
///   - **Browse Installed**: scan the bottle's Steam library for
///     appmanifest_*.acf files, multi-select discovered games.
///     Requires Steam to have been signed in and games installed.
///
///   - **Add by App ID**: paste a Steam App ID, `steam://run/<id>`
///     URL, or store-page URL. Carafe creates the library entry
///     without needing the Steam client UI to render — useful when
///     the Steam window is black or you want to add a game you
///     haven't downloaded yet (Steam will download on first launch
///     via -applaunch).
///
/// Both modes produce the same kind of Game entry: exePath pointing
/// at Steam.exe and arguments `-applaunch <appid>`.
struct AddSteamGameSheet: View {
    @EnvironmentObject private var bottles: BottleManager
    @EnvironmentObject private var library: GameLibrary
    @Environment(\.dismiss) private var dismiss

    /// Optional pre-selected bottle (passed by the caller). When nil,
    /// we pick the first Steam-bearing bottle automatically.
    let initialBottleID: UUID?

    enum Mode: String, CaseIterable, Identifiable {
        case browse  = "Browse Installed"
        case byAppID = "Add by App ID"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .browse

    @State private var selectedBottleID: UUID?
    @State private var discovered: [DiscoveredSteamGame] = []
    @State private var selectedAppIDs: Set<Int> = []
    @State private var filterText: String = ""
    @State private var isScanning: Bool = false
    @State private var showInstallSheet: Bool = false

    // --- "Add by App ID" form state ---
    @State private var appIDInput: String = ""
    @State private var nameInput: String = ""
    @State private var byAppIDInlineError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 720, height: 600)
        .onAppear { bootstrap() }
        .sheet(isPresented: $showInstallSheet) {
            InstallSteamSheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Steam Games").font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        if steamBottles.isEmpty {
            return "No Steam install detected — install Steam in a bottle first."
        }
        switch mode {
        case .browse:
            return "Pick a bottle, choose games to add to your library."
        case .byAppID:
            return "Paste an App ID or Steam URL — works even when the Steam window won't render."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if steamBottles.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                modePicker
                Divider()
                bottleRow
                Divider()
                Group {
                    switch mode {
                    case .browse:  browseBody
                    case .byAppID: byAppIDBody
                    }
                }
                Divider()
                modalFooter
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "gamecontroller")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("No Steam-bearing bottles found")
                .font(.headline)
            Text("Install Steam in a bottle first — pick a bottle, run the bootstrap installer, sign in to Steam, install some games, then come back here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Install Steam in a bottle…") {
                showInstallSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(16)
        }
        .padding(.top, 20)
    }

    // MARK: - Bottle row (shared between modes)

    private var bottleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bottle").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $selectedBottleID) {
                    ForEach(steamBottles) { b in
                        Text(b.name).tag(Optional(b.id))
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            Spacer()
            // Filter + Rescan are browse-mode only.
            if mode == .browse {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filter").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("name or appid", text: $filterText)
                            .textFieldStyle(.plain)
                            .frame(width: 220)
                        if !filterText.isEmpty {
                            Button { filterText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                }
                if isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { rescan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .onChange(of: selectedBottleID) { _, _ in rescan() }
    }

    // MARK: - Browse mode body

    private var browseBody: some View {
        gameList
    }

    private var gameList: some View {
        Group {
            if isScanning {
                centred {
                    ProgressView()
                    Text("Scanning Steam library…").foregroundStyle(.secondary)
                }
            } else if filteredGames.isEmpty {
                centred {
                    Image(systemName: "tray").font(.title).foregroundStyle(.tertiary)
                    Text(emptyListMessage).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredGames) { game in
                            gameRow(game)
                            if game.appID != filteredGames.last?.appID {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func gameRow(_ game: DiscoveredSteamGame) -> some View {
        let isSelected = selectedAppIDs.contains(game.appID)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    if newValue { selectedAppIDs.insert(game.appID) }
                    else { selectedAppIDs.remove(game.appID) }
                }
            ))
            .labelsHidden().toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(game.name).font(.callout.weight(.medium))
                    Text("(\(game.appID))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if game.sizeOnDisk > 0 {
                        Text("• \(game.sizeOnDiskDisplay)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                Text(game.installDir)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selectedAppIDs.remove(game.appID) }
            else { selectedAppIDs.insert(game.appID) }
        }
    }

    // MARK: - By-AppID mode body

    /// Whatever the parser extracts from `appIDInput`. nil if nothing
    /// in the field looks like an AppID yet.
    private var parsedAppID: Int? {
        SteamAppIDParser.appID(from: appIDInput)
    }

    private var byAppIDBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoBlurb
                appIDField
                nameField
                if let err = byAppIDInlineError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
            }
            .padding(16)
        }
    }

    private var infoBlurb: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steam launches headlessly via `-applaunch`")
                .font(.callout.weight(.medium))
            Text("Carafe registers a tile that runs `Steam.exe -applaunch <id>`. Steam starts in the background, downloads the game if needed, and launches it. No need for the Steam client UI to render — useful when the Steam client window is black on Wine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var appIDField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("App ID or Steam URL").font(.callout.weight(.medium))
            TextField(
                #"1245620   or   steam://run/1245620   or   https://store.steampowered.com/app/1245620/Elden_Ring/"#,
                text: $appIDInput
            )
            .textFieldStyle(.roundedBorder)
            .onChange(of: appIDInput) { _, newValue in
                // Auto-suggest a name when the URL contains a slug,
                // but only if the user hasn't typed a name yet.
                if nameInput.isEmpty,
                   let hint = SteamAppIDParser.nameHint(from: newValue) {
                    nameInput = hint
                }
            }
            HStack(spacing: 6) {
                if let id = parsedAppID {
                    Label("Parsed: AppID \(id)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else if !appIDInput.isEmpty {
                    Label("Couldn't extract an App ID from that input", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).font(.caption)
                }
                Spacer()
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.callout.weight(.medium))
            TextField("e.g. Elden Ring", text: $nameInput)
                .textFieldStyle(.roundedBorder)
            Text("Shown on the tile. Auto-filled from the URL slug when possible; type whatever you like.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var modalFooter: some View {
        switch mode {
        case .browse:  browseFooter
        case .byAppID: byAppIDFooter
        }
    }

    private var browseFooter: some View {
        HStack {
            Text(selectionSummary)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add \(selectedAppIDs.count) game\(selectedAppIDs.count == 1 ? "" : "s")") {
                addSelected()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedAppIDs.isEmpty || selectedBottle == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var byAppIDFooter: some View {
        HStack {
            Text(byAppIDFooterSummary)
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Game") { addByAppID() }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddByAppID)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var byAppIDFooterSummary: String {
        if selectedBottle == nil {
            return "Pick a bottle first."
        }
        if parsedAppID == nil {
            return "Enter an App ID or Steam URL."
        }
        if nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give it a name."
        }
        return "Ready to add."
    }

    private var canAddByAppID: Bool {
        selectedBottle != nil
            && parsedAppID != nil
            && !nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Derived

    private var steamBottles: [Bottle] {
        bottles.entries.compactMap(\.validBottle).filter { SteamLibraryScanner.hasSteam(in: $0) }
    }

    private var selectedBottle: Bottle? {
        steamBottles.first { $0.id == selectedBottleID }
    }

    /// AppIDs already present as Carafe games in the selected bottle.
    /// We hide them from the picker so the user doesn't accidentally
    /// add duplicates.
    private var alreadyInLibrary: Set<Int> {
        guard let bid = selectedBottle?.id else { return [] }
        return Set(library.games
            .filter { $0.bottleID == bid }
            .compactMap(\.steamAppID))
    }

    private var filteredGames: [DiscoveredSteamGame] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return discovered
            .filter { !alreadyInLibrary.contains($0.appID) }
            .filter { game in
                guard !q.isEmpty else { return true }
                return game.name.lowercased().contains(q)
                    || String(game.appID).contains(q)
            }
    }

    private var emptyListMessage: String {
        if alreadyInLibrary.count > 0 && discovered.allSatisfy({ alreadyInLibrary.contains($0.appID) }) {
            return "Every game installed in this bottle's Steam is already in your Carafe library. Install more games in Steam, then click Rescan."
        }
        if !filterText.isEmpty {
            return "No matches for “\(filterText)”."
        }
        return "No games found. Make sure you've signed in to Steam inside this bottle and installed at least one game."
    }

    private var selectionSummary: String {
        if discovered.isEmpty { return "Nothing to add." }
        if selectedAppIDs.isEmpty { return "Tick the games you want in your library." }
        return "\(selectedAppIDs.count) selected."
    }

    // MARK: - Actions

    private func bootstrap() {
        if selectedBottleID == nil {
            selectedBottleID = initialBottleID ?? steamBottles.first?.id
        }
        rescan()
    }

    private func rescan() {
        guard let bottle = selectedBottle else {
            discovered = []
            return
        }
        isScanning = true
        // Detach scan onto a background queue so the UI doesn't lag
        // on libraries with many manifests. Capture the bottle by
        // value (Sendable struct).
        let captured = bottle
        Task.detached(priority: .userInitiated) {
            let games = SteamLibraryScanner.scan(bottle: captured)
            await MainActor.run {
                self.discovered = games
                self.isScanning = false
                // Drop selections that no longer apply.
                self.selectedAppIDs.formIntersection(Set(games.map(\.appID)))
            }
        }
    }

    private func addSelected() {
        guard let bottle = selectedBottle else { return }
        let steamExe = SteamLibraryScanner.steamExeURL(for: bottle)

        let toAdd = discovered.filter { selectedAppIDs.contains($0.appID) }
        var added: [Game] = []
        for game in toAdd {
            // Library.add handles the basic validation, but it
            // constructs a vanilla Game (no steamAppID, no args).
            // We take the freshly-added entry and patch in the
            // Steam-specific fields, then write back via update.
            guard let entry = library.add(
                name: game.name,
                bottle: bottle,
                exeURL: steamExe,
                arguments: ["-applaunch", String(game.appID), "-no-cef-sandbox"]
            ) else { continue }
            var patched = entry
            patched.steamAppID = game.appID
            library.update(patched)
            added.append(patched)
        }
        if !added.isEmpty {
            dismiss()
        }
    }

    /// Headless add path: build a Game entry from typed input.
    /// Mirrors `addSelected` but with one game and no scan dependency.
    /// Game doesn't need to be installed yet — Steam will download
    /// it on first `-applaunch`.
    private func addByAppID() {
        byAppIDInlineError = nil
        guard let bottle = selectedBottle else {
            byAppIDInlineError = "Pick a bottle first."
            return
        }
        guard let appID = parsedAppID else {
            byAppIDInlineError = "App ID couldn't be parsed from the input."
            return
        }
        let trimmedName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            byAppIDInlineError = "Name can't be empty."
            return
        }
        // Dedupe against existing entries in this bottle. The Add
        // button is gated on this too, but a defensive check here
        // means a user pasting an already-added AppID gets a clear
        // error rather than a silent duplicate.
        if alreadyInLibrary.contains(appID) {
            byAppIDInlineError = "AppID \(appID) is already in your library for this bottle."
            return
        }

        let steamExe = SteamLibraryScanner.steamExeURL(for: bottle)
        guard let entry = library.add(
            name: trimmedName,
            bottle: bottle,
            exeURL: steamExe,
            arguments: ["-applaunch", String(appID), "-no-cef-sandbox"]
        ) else {
            byAppIDInlineError = library.lastError ?? "Couldn't add game."
            return
        }
        var patched = entry
        patched.steamAppID = appID
        library.update(patched)
        dismiss()
    }

    // MARK: - Helpers

    @ViewBuilder
    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }
}
