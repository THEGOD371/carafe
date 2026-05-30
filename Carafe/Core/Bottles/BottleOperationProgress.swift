import Foundation

/// State container for a single in-flight bottle operation (create,
/// duplicate, delete, repair). Bound to the operation-progress sheet
/// in the library UI. Lives only as long as the operation; the
/// manager nils its `currentOperation` reference when the user
/// dismisses the sheet.
@MainActor
final class BottleOperationProgress: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    nonisolated let id = UUID()
    nonisolated let title: String
    nonisolated let startedAt: Date

    @Published var state: State = .running
    @Published var stage: String = ""
    @Published var logLines: [String] = []

    /// Set during copy operations. nil if the op doesn't have byte
    /// progress (e.g., wineboot, which is unparsable).
    @Published var bytesCopied: Int64? = nil
    @Published var totalBytes: Int64? = nil

    /// Cap to bound memory if a noisy wineboot session emits
    /// thousands of debug lines.
    private let logCap = 2_000

    init(title: String) {
        self.title = title
        self.startedAt = Date()
    }

    func setStage(_ stage: String) {
        self.stage = stage
        appendLog(stage)
    }

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > logCap {
            logLines.removeFirst(logLines.count - logCap)
        }
    }

    func reportProgress(bytesCopied: Int64, totalBytes: Int64) {
        self.bytesCopied = bytesCopied
        self.totalBytes = totalBytes
    }

    func markSucceeded() {
        state = .succeeded
    }

    func markFailed(_ message: String) {
        state = .failed(message)
        appendLog("⛔ \(message)")
    }

    var byteFraction: Double? {
        guard let copied = bytesCopied,
              let total = totalBytes,
              total > 0
        else { return nil }
        return min(1.0, Double(copied) / Double(total))
    }

    var isFinished: Bool {
        if case .running = state { return false }
        return true
    }
}
