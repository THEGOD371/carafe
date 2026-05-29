import Foundation
import SwiftUI

/// Coordinates the four dependency checkers and exposes their state
/// to SwiftUI as a single observable object. The live log pane in
/// `DependencyInstallerView` reads `logLines` directly.
@MainActor
final class DependencyManager: ObservableObject {

    struct Item: Identifiable {
        let checker: any DependencyChecker
        var status: DependencyStatus

        var id: String { checker.id }
    }

    struct LogLine: Identifiable, Equatable {
        enum Stream: Equatable { case info, output, error }

        let id = UUID()
        let timestamp: Date
        let scope: String?
        let stream: Stream
        let text: String
    }

    @Published private(set) var items: [Item]
    @Published private(set) var logLines: [LogLine] = []
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?

    /// IDs the user has explicitly chosen to skip during onboarding so they
    /// can develop / test the rest of the app without a blocking dependency.
    /// Persisted across launches; future code can ask `isSkipped(id:)` to
    /// decide whether to gracefully degrade.
    @Published private(set) var skippedIDs: Set<String> = []

    /// Cap to keep memory bounded if a download chatters for a long time.
    private let logLineCap = 5_000

    private enum Keys {
        static let skippedIDs = "carafe.skippedDependencies"
    }

    static func makeDefault() -> DependencyManager {
        DependencyManager(checkers: [
            RosettaChecker(),
            XcodeCLTChecker(),
            HomebrewChecker(),
            GPTKChecker(),
        ])
    }

    init(checkers: [any DependencyChecker]) {
        self.items = checkers.map { Item(checker: $0, status: .unknown) }
        let raw = UserDefaults.standard.stringArray(forKey: Keys.skippedIDs) ?? []
        self.skippedIDs = Set(raw)
    }

    // MARK: - Derived state

    var allInstalled: Bool {
        items.allSatisfy { $0.status.isInstalled }
    }

    /// Gate for the "Continue" button: every dep is either installed
    /// or the user has explicitly skipped it.
    var allInstalledOrSkipped: Bool {
        items.allSatisfy { $0.status.isInstalled || skippedIDs.contains($0.id) }
    }

    var allChecked: Bool {
        items.allSatisfy { $0.status.isTerminal }
    }

    var hasManualWork: Bool {
        items.contains { item in
            if case .missing = item.status, case .manual = item.checker.installSupport { return true }
            return false
        }
    }

    /// True if any required dep is being skipped — downstream code
    /// (game launcher) should branch on this and degrade gracefully.
    var hasSkippedDependencies: Bool { !skippedIDs.isEmpty }

    func isSkipped(id: String) -> Bool { skippedIDs.contains(id) }

    func skip(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        skippedIDs.insert(id)
        persistSkipped()
        append(
            scope: item.checker.displayName,
            stream: .info,
            text: "Skipped. Features that depend on this will be unavailable."
        )
    }

    func unskip(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        skippedIDs.remove(id)
        persistSkipped()
        append(
            scope: item.checker.displayName,
            stream: .info,
            text: "Skip removed."
        )
    }

    private func persistSkipped() {
        UserDefaults.standard.set(Array(skippedIDs), forKey: Keys.skippedIDs)
    }

    // MARK: - Operations

    /// Check every dependency in parallel.
    func checkAll() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        lastError = nil
        append(scope: nil, stream: .info, text: "Checking dependencies…")
        for index in items.indices { items[index].status = .checking }

        // Concurrent checks via a TaskGroup.
        await withTaskGroup(of: (String, DependencyStatus).self) { group in
            for item in items {
                group.addTask { [checker = item.checker] in
                    (checker.id, await checker.check())
                }
            }
            for await (id, status) in group {
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items[index].status = status
                    append(
                        scope: items[index].checker.displayName,
                        stream: .info,
                        text: describe(status)
                    )
                }
            }
        }
    }

    /// Re-check a single dependency. Useful after the user finishes a
    /// manual install (e.g., pasted the Homebrew command in Terminal).
    func recheck(id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .checking
        let status = await items[index].checker.check()
        items[index].status = status
        append(
            scope: items[index].checker.displayName,
            stream: .info,
            text: describe(status)
        )
    }

    /// Install one specific dependency. The UI uses this for the
    /// per-row "Install" / "Retry" buttons.
    func install(id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]

        guard case .automatic = item.checker.installSupport else {
            append(
                scope: item.checker.displayName,
                stream: .error,
                text: "This dependency requires a manual install."
            )
            return
        }

        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        lastError = nil
        items[index].status = .installing(message: "Starting…")
        append(scope: item.checker.displayName, stream: .info, text: "Installing…")

        do {
            try await item.checker.install { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.append(scope: item.checker.displayName, stream: .output, text: line)
                }
            }
            // Re-verify post-install.
            let postStatus = await item.checker.check()
            items[index].status = postStatus
            append(
                scope: item.checker.displayName,
                stream: .info,
                text: "Done. \(describe(postStatus))"
            )
        } catch DependencyError.userCancelled {
            items[index].status = .missing
            append(scope: item.checker.displayName, stream: .info, text: "Cancelled.")
        } catch {
            let message = error.localizedDescription
            items[index].status = .failed(reason: message)
            lastError = "\(item.checker.displayName): \(message)"
            append(scope: item.checker.displayName, stream: .error, text: message)
        }
    }

    /// Walk the items in declared order; for each `.missing` automatic
    /// dependency, install it. Stops on first failure so the user can
    /// see what went wrong.
    func installAllAuto() async {
        for item in items {
            if case .missing = item.status,
               case .automatic = item.checker.installSupport {
                await install(id: item.id)
                if case .failed = items.first(where: { $0.id == item.id })?.status {
                    return
                }
            }
        }
    }

    // MARK: - Logging

    func clearLog() { logLines.removeAll() }

    /// Write the current log to a file under ~/Library/Application Support/Carafe/logs.
    func exportLog() -> URL? {
        let logsDir = AppState.supportDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let file = logsDir.appendingPathComponent("onboarding-\(stamp).log")

        let text = logLines.map { line in
            let scope = line.scope.map { "[\($0)]" } ?? ""
            return "\(line.timestamp) \(scope) \(line.text)"
        }.joined(separator: "\n")

        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    private func append(scope: String?, stream: LogLine.Stream, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(.init(timestamp: Date(), scope: scope, stream: stream, text: trimmed))
        if logLines.count > logLineCap {
            logLines.removeFirst(logLines.count - logLineCap)
        }
    }

    private func describe(_ status: DependencyStatus) -> String {
        switch status {
        case .unknown: return "Not yet checked."
        case .checking: return "Checking…"
        case .installed(let version):
            return version.map { "Installed (\($0))." } ?? "Installed."
        case .missing: return "Not installed."
        case .installing(let msg): return msg
        case .failed(let reason): return "Failed — \(reason)"
        }
    }
}
