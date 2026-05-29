import SwiftUI
import AppKit

/// Displays a live `RunSession`: status bar (icon + exe name + elapsed
/// timer), streaming log, and Stop / Restart / Close footer.
///
/// Reused by both the technical launch flow (LaunchExeSheet) and the
/// game launch flow (LaunchGameSheet). The host owns the callback
/// trio; this view doesn't know about bottles or games.
struct RunningSessionView: View {
    @ObservedObject var session: RunSession
    let onStop: () -> Void
    let onRestart: () -> Void
    let onClose: () -> Void

    @State private var now: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            logPane
            Divider()
            footer
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(session.exeURL.lastPathComponent).font(.headline)
                Text(statusDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(elapsedString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.state {
        case .idle, .launching:
            ProgressView().controlSize(.small)
        case .running:
            Image(systemName: "circle.fill").foregroundStyle(.green)
        case .exited(let code):
            Image(systemName: code == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(code == 0 ? .green : .orange)
        case .killed:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var statusDescription: String {
        switch session.state {
        case .idle: return "Preparing…"
        case .launching: return "Launching wine…"
        case .running(let pid): return "Running (pid \(pid))"
        case .exited(let code):
            return code == 0 ? "Exited cleanly" : "Exited with code \(code)"
        case .killed: return "Stopped by user"
        case .failed(let reason): return reason
        }
    }

    private var elapsedString: String {
        let elapsed = Int(now.timeIntervalSince(session.startedAt))
        let m = elapsed / 60, s = elapsed % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Log

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(session.logLines) { line in
                        HStack(alignment: .top, spacing: 4) {
                            streamGlyph(line.stream)
                            Text(line.text)
                                .foregroundStyle(color(for: line.stream))
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(line.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: session.logLines.last?.id) { _, newID in
                if let newID { proxy.scrollTo(newID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func streamGlyph(_ stream: RunSession.LogStream) -> some View {
        switch stream {
        case .info:
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.system(size: 9))
        case .stdout:
            Text("  ").font(.system(size: 9))
        case .stderr:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 9))
        }
    }

    private func color(for stream: RunSession.LogStream) -> Color {
        switch stream {
        case .info: return .secondary
        case .stdout: return .primary
        case .stderr: return .orange
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Copy log") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(
                    session.logLines.map { $0.text }.joined(separator: "\n"),
                    forType: .string
                )
            }
            .disabled(session.logLines.isEmpty)

            Spacer()

            if session.state.isLive {
                Button("Stop", role: .destructive, action: onStop)
            }
            if session.state.isTerminal {
                Button("Restart", action: onRestart)
            }
            Button(session.state.isLive ? "Stop & Close" : "Close", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
