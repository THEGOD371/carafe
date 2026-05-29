import SwiftUI
import AppKit

/// Top-level library shell. Shown after onboarding completes; replaces
/// the old `MainAppShell` placeholder. Owns the local UI state for
/// sort order, selection, and the various modal flows (create, rename,
/// duplicate, delete confirmation, operation progress).
struct BottleLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var bottles: BottleManager

    // MARK: - Local UI state

    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<BottleRow>] = [
        KeyPathComparator(\BottleRow.name, order: .forward)
    ]

    @State private var showingCreate = false

    /// When non-nil, present the LaunchExeSheet for this bottle.
    /// We use a dedicated Identifiable wrapper so `.sheet(item:)`
    /// re-fires reliably for the same bottle ID across launches.
    @State private var launchTarget: LaunchTarget?

    struct LaunchTarget: Identifiable {
        let id = UUID()
        let bottleID: UUID?
    }

    /// Rename / Duplicate use a single shared text-prompt sheet, keyed
    /// by which intent is active.
    @State private var promptIntent: PromptIntent?
    @State private var promptText: String = ""

    @State private var deleteTarget: BottleEntry?

    /// Sheet binding for "Install Components…". Identifiable via the
    /// bottle's UUID.
    @State private var componentsTarget: Bottle?

    enum PromptIntent: Identifiable, Equatable {
        case rename(UUID)
        case duplicate(UUID)

        var id: String {
            switch self {
            case .rename(let id): return "rename-\(id.uuidString)"
            case .duplicate(let id): return "duplicate-\(id.uuidString)"
            }
        }
    }

    // MARK: - Derived rows

    private var rows: [BottleRow] {
        bottles.entries.map { entry in
            // Sizes are populated lazily by BottleManager; nil means
            // "still computing" and the row UI renders "…".
            BottleRow(entry: entry, size: bottles.sizes[entry.id])
        }.sorted(using: sortOrder)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if bottles.entries.isEmpty {
                BottleEmptyState(onCreate: { showingCreate = true })
            } else {
                table
            }
        }
        .toolbar { toolbar }
        // Sheets / dialogs
        .sheet(isPresented: $showingCreate) {
            CreateBottleSheet()
        }
        .sheet(item: Binding(
            get: { bottles.currentOperation },
            set: { _ in /* read-only — manager owns this */ }
        )) { op in
            BottleOperationSheet(operation: op) {
                bottles.clearCurrentOperation()
            }
        }
        .sheet(item: $launchTarget) { target in
            LaunchExeSheet(initialBottleID: target.bottleID)
        }
        .sheet(item: $componentsTarget) { bottle in
            ComponentsSheet(bottle: bottle)
        }
        .alert("Rename bottle", isPresented: bindingForIntent(.rename)) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) { promptIntent = nil }
            Button("Rename") { submitPrompt() }
                .keyboardShortcut(.defaultAction)
        }
        .alert("Duplicate bottle", isPresented: bindingForIntent(.duplicate)) {
            TextField("Name for the copy", text: $promptText)
            Button("Cancel", role: .cancel) { promptIntent = nil }
            Button("Duplicate") { submitPrompt() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Carafe will copy the entire prefix folder. This can take a while for large bottles.")
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("Move to Trash", role: .destructive) {
                Task { await bottles.delete(target); deleteTarget = nil }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("The bottle will be moved to the Trash so you can recover it later.")
        }
        .alert(
            "Bottle error",
            isPresented: Binding(
                get: { bottles.lastError != nil },
                set: { if !$0 { bottles.clearError() } }
            ),
            presenting: bottles.lastError
        ) { _ in
            Button("OK", role: .cancel) { bottles.clearError() }
        } message: { message in
            Text(message)
        }
        .navigationTitle("Carafe")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await bottles.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-scan the bottles folder")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                // Use the currently selected bottle, falling back to
                // the first valid bottle, falling back to nil (the
                // sheet's picker still works).
                let bottleID = selection.first
                    ?? bottles.entries.compactMap(\.validBottle).first?.id
                launchTarget = LaunchTarget(bottleID: bottleID)
            } label: {
                Label("Run Executable", systemImage: "play.fill")
            }
            .help("Launch a Windows .exe or .msi in a bottle")
            .disabled(
                !WineRunner.isWineAvailable
                || bottles.entries.compactMap(\.validBottle).isEmpty
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingCreate = true
            } label: {
                Label("New Bottle", systemImage: "plus")
            }
            .help("Create a new bottle")
            .disabled(!WineRunner.isWineAvailable)
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    if row.isCorrupted {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(row.corruptionReason ?? "Corrupted bottle")
                    } else {
                        Image(systemName: "wineglass")
                            .foregroundStyle(.tint)
                    }
                    Text(row.name)
                        .foregroundStyle(row.isCorrupted ? .secondary : .primary)
                }
            }
            TableColumn("Wine", value: \.wineVersion)
                .width(min: 90, ideal: 110)
            TableColumn("Windows", value: \.windowsVersion)
                .width(min: 90, ideal: 110)
            TableColumn("Last used", value: \.lastUsedSortKey) { row in
                Text(row.lastUsedDisplay).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Size", value: \.sizeSortKey) { row in
                Text(row.sizeDisplay)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        // Single-row menus only for now; multi-select operations
        // arrive in a later milestone.
        if let id = ids.first, ids.count == 1,
           let entry = bottles.entries.first(where: { $0.id == id }) {
            switch entry {
            case .valid(let bottle):
                Button("Run Executable…") {
                    launchTarget = LaunchTarget(bottleID: bottle.id)
                }
                .disabled(bottles.currentOperation?.state == .running)
                Button("Install Components…") {
                    componentsTarget = bottle
                }
                .disabled(bottles.currentOperation?.state == .running)
                Divider()
                Button("Rename…") { startPrompt(.rename(bottle.id), seed: bottle.name) }
                Button("Duplicate…") { startPrompt(.duplicate(bottle.id), seed: "\(bottle.name) Copy") }
                Divider()
                Button("Show in Finder") { bottles.showInFinder(bottle) }
                Button("Open Wine Configuration") {
                    Task { await bottles.openWinecfg(bottle) }
                }
                Divider()
                Button("Move to Trash…", role: .destructive) { deleteTarget = entry }
            case .corrupted(let corrupted):
                Button("Repair") {
                    Task { await bottles.repair(corrupted) }
                }
                Button("Show in Finder") { bottles.showInFinder(corrupted) }
                Divider()
                Button("Move to Trash…", role: .destructive) { deleteTarget = entry }
            }
        }
    }

    // MARK: - Prompt helpers

    private func startPrompt(_ intent: PromptIntent, seed: String) {
        promptText = seed
        promptIntent = intent
    }

    private func bindingForIntent(_ kind: PromptIntentKind) -> Binding<Bool> {
        Binding(
            get: {
                switch (promptIntent, kind) {
                case (.rename, .rename), (.duplicate, .duplicate): return true
                default: return false
                }
            },
            set: { newValue in
                if !newValue { promptIntent = nil }
            }
        )
    }

    private enum PromptIntentKind { case rename, duplicate }

    private func submitPrompt() {
        guard let intent = promptIntent else { return }
        let value = promptText
        promptIntent = nil
        Task {
            switch intent {
            case .rename(let id):
                if let bottle = bottles.entries.compactMap(\.validBottle).first(where: { $0.id == id }) {
                    await bottles.rename(bottle, to: value)
                }
            case .duplicate(let id):
                if let bottle = bottles.entries.compactMap(\.validBottle).first(where: { $0.id == id }) {
                    await bottles.duplicate(bottle, newName: value)
                }
            }
        }
    }

    private var deleteConfirmationTitle: String {
        guard let target = deleteTarget else { return "Move bottle to Trash?" }
        return "Move \"\(target.displayName)\" to Trash?"
    }
}

// MARK: - Row VM

struct BottleRow: Identifiable, Hashable {
    let entry: BottleEntry
    let size: Int64?

    var id: UUID { entry.id }

    var name: String { entry.displayName }

    var wineVersion: String {
        entry.validBottle?.wineVersion ?? "—"
    }

    var windowsVersion: String {
        entry.validBottle?.windowsVersion.displayName ?? "—"
    }

    var lastUsedSortKey: Date { entry.validBottle?.lastUsedAt ?? .distantPast }
    var sizeSortKey: Int64 { size ?? 0 }

    var isCorrupted: Bool { entry.isCorrupted }

    var corruptionReason: String? {
        if case .corrupted(let c) = entry { return c.reason }
        return nil
    }

    var lastUsedDisplay: String {
        guard let date = entry.validBottle?.lastUsedAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var sizeDisplay: String {
        guard !isCorrupted else { return "—" }
        guard let size else { return "…" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// BottleOperationProgress is already Identifiable via its `id`
// property, which is all `.sheet(item:)` needs.
