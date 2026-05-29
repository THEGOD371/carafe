import SwiftUI
import AppKit

struct BottleOperationSheet: View {
    @ObservedObject var operation: BottleOperationProgress
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .frame(width: 540, height: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            stateIcon
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title).font(.headline)
                Text(operation.stage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch operation.state {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    // MARK: - Body

    private var body_: some View {
        VStack(alignment: .leading, spacing: 12) {
            progressBar
            logPane
        }
        .padding(16)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = operation.byteFraction,
           let copied = operation.bytesCopied,
           let total = operation.totalBytes {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                HStack {
                    Text("\(formatBytes(copied)) of \(formatBytes(total))")
                    Spacer()
                    Text(String(format: "%.0f%%", fraction * 100))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else if case .running = operation.state {
            // No byte progress (wineboot / metadata write) — indeterminate.
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(operation.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .onChange(of: operation.logLines.count) { _, _ in
                if let last = operation.logLines.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if case .failed(let message) = operation.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Copy log") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(operation.logLines.joined(separator: "\n"), forType: .string)
            }
            .disabled(operation.logLines.isEmpty)

            Button(operation.isFinished ? "Close" : "Hide") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
