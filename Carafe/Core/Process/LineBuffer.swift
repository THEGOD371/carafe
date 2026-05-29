import Foundation

/// Splits incoming `Data` chunks into UTF-8 lines, emitting one
/// callback per complete line. Thread-safe — callers can write from
/// FileHandle.readabilityHandler (background thread) and the callback
/// is invoked synchronously on that same thread; route to the main
/// actor inside the callback if needed.
///
/// Non-UTF-8 bytes are decoded with lossy substitution rather than
/// dropped so noisy stderr from wine never causes data loss.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending.prefix(upTo: newlineIndex)
            pending.removeSubrange(...newlineIndex)
            let line = String(data: lineData, encoding: .utf8)
                ?? String(decoding: lineData, as: UTF8.self)
            onLine(line)
        }
    }

    /// Flush any trailing partial line (no terminating newline).
    /// Call after the process exits to surface short final messages.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        let line = String(data: pending, encoding: .utf8)
            ?? String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        onLine(line)
    }
}
