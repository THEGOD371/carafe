import SwiftUI

/// Two-stage cover art picker: search SteamGridDB by name → pick a
/// game candidate → browse its covers → pick one → cache locally.
///
/// Graceful degradation:
///   - No API key → big CTA pointing at the gear-menu Settings entry.
///   - Network / 401 / 429 → inline error banner, user can retry.
///   - No results → "no results, try a different query".
struct CoverArtPickerSheet: View {
    @EnvironmentObject private var library: GameLibrary
    @Environment(\.dismiss) private var dismiss

    let searchSeed: String

    /// nil during Add flow (game not saved yet) — we still cache
    /// under a fresh UUID and pass the filename back through
    /// `onSelectedFilename` so GameFormSheet can attach it on save.
    let gameID: UUID?

    /// Called when the user picks a cover and the download completes.
    /// The filename is relative to `GameLibrary.coverArtDirectory`.
    let onSelectedFilename: (String) -> Void

    @State private var query: String = ""
    @State private var games: [SteamGridDBGame] = []
    @State private var selectedGameID: Int?
    @State private var grids: [SteamGridDBGrid] = []

    @State private var isSearching = false
    @State private var isLoadingGrids = false
    @State private var isDownloading = false
    @State private var apiError: String?

    private let client = SteamGridDBClient()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !client.hasAPIKey {
                noKeyState
            } else {
                searchAndResults
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .onAppear {
            query = searchSeed
            if client.hasAPIKey, !searchSeed.isEmpty {
                Task { await runSearch() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Choose cover art").font(.title3.weight(.semibold))
            Spacer()
            if isSearching || isLoadingGrids || isDownloading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
    }

    // MARK: - No-key state

    private var noKeyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Set up a SteamGridDB API key to fetch cover art")
                .font(.headline)
            Text("Cover art is sourced from steamgriddb.com. It's free, but you need a personal API key.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Text("Open Settings (gear icon in the toolbar) → API Keys to add one. Carafe still works without a key — you'll just get placeholder covers.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 480)
            Spacer()
        }
        .padding(40)
    }

    // MARK: - Search + results

    private var searchAndResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            if let apiError {
                Label(apiError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 0) {
                gameCandidatesList
                    .frame(width: 240)
                Divider()
                gridsList
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search by game name", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await runSearch() } }
            Button("Search") { Task { await runSearch() } }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var gameCandidatesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Matches")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if games.isEmpty {
                        Text(isSearching ? "Searching…" : "No matches yet — search above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(games) { game in
                        Button {
                            selectedGameID = game.id
                            Task { await loadGrids(for: game.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(game.name).lineLimit(1)
                                Spacer()
                                if game.verified == true {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.tint)
                                        .font(.caption2)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedGameID == game.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var gridsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Covers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            ScrollView {
                if grids.isEmpty {
                    Text(
                        isLoadingGrids
                            ? "Loading covers…"
                            : (selectedGameID == nil
                                ? "Pick a match on the left to see covers."
                                : "No portrait covers available for this match.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(20)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140, maximum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(grids) { grid in
                            Button { Task { await pick(grid) } } label: {
                                AsyncImage(url: grid.thumb ?? grid.url) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.2))
                                        .overlay(ProgressView().controlSize(.small))
                                }
                                .frame(width: 140, height: 210)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isDownloading)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        apiError = nil
        defer { isSearching = false }
        do {
            games = try await client.search(term: trimmed)
            selectedGameID = nil
            grids = []
        } catch let err as SteamGridDBClient.Failure {
            apiError = err.errorDescription
        } catch {
            apiError = error.localizedDescription
        }
    }

    private func loadGrids(for gameID: Int) async {
        isLoadingGrids = true
        apiError = nil
        defer { isLoadingGrids = false }
        do {
            grids = try await client.grids(forGameID: gameID, portraitOnly: true)
        } catch let err as SteamGridDBClient.Failure {
            apiError = err.errorDescription
            grids = []
        } catch {
            apiError = error.localizedDescription
            grids = []
        }
    }

    private func pick(_ grid: SteamGridDBGrid) async {
        isDownloading = true
        apiError = nil
        defer { isDownloading = false }
        do {
            let tempFile = try await client.download(from: grid.url)
            // We mint a synthetic Game just to compute the cache
            // filename — GameLibrary.setCoverArt uses game.id only.
            // For the Add flow (gameID == nil), generate a UUID.
            let id = gameID ?? UUID()
            let stub = Game(
                id: id, name: query, bottleID: UUID(),
                exePath: .absolute(""), arguments: [],
                coverArtFilename: nil, customIconFilename: nil,
                lastPlayedAt: nil, totalPlaytime: 0,
                addedAt: Date()
            )
            // setCoverArt moves the temp file into the cache,
            // updates library state if the stub matches a real game.
            // For the Add flow no library row exists yet — we just
            // move the file ourselves and return the filename.
            if gameID != nil {
                library.setCoverArt(for: stub, fromDownloadedURL: tempFile)
                if let realGame = library.games.first(where: { $0.id == id }) {
                    onSelectedFilename(realGame.coverArtFilename ?? "")
                }
            } else {
                let dir = GameLibrary.coverArtDirectory
                let ext = tempFile.pathExtension.isEmpty ? "jpg" : tempFile.pathExtension
                let filename = "\(id.uuidString).\(ext)"
                let dst = dir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tempFile, to: dst)
                onSelectedFilename(filename)
            }
            dismiss()
        } catch let err as SteamGridDBClient.Failure {
            apiError = err.errorDescription
        } catch {
            apiError = error.localizedDescription
        }
    }
}
