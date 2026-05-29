import SwiftUI
import AppKit

struct DependencyInstallerView: View {
    @ObservedObject var deps: DependencyManager
    let onComplete: () -> Void

    @State private var hasRunInitialCheck = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                checklist
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
                logPane
                    .frame(width: 380)
            }
            Divider()
            footer
        }
        .task {
            if !hasRunInitialCheck {
                hasRunInitialCheck = true
                await deps.checkAll()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install dependencies").font(.title2.weight(.semibold))
                Text("Carafe needs Rosetta, Xcode Command Line Tools, Homebrew, and Apple's Game Porting Toolkit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if deps.isWorking { ProgressView().controlSize(.small) }
        }
        .padding(20)
    }

    // MARK: - Checklist

    private var checklist: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(deps.items) { item in
                    DependencyRow(item: item, deps: deps)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Log pane

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy") { copyLogToClipboard() }
                    .disabled(deps.logLines.isEmpty)
                Button("Export…") { exportLog() }
                    .disabled(deps.logLines.isEmpty)
                Button("Clear") { deps.clearLog() }
                    .disabled(deps.logLines.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(deps.logLines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                if let scope = line.scope {
                                    Text(scope)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
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
                .onChange(of: deps.logLines.last?.id) { _, newID in
                    if let newID { proxy.scrollTo(newID, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func color(for stream: DependencyManager.LogLine.Stream) -> Color {
        switch stream {
        case .info:   return .secondary
        case .output: return .primary
        case .error:  return .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if deps.hasSkippedDependencies {
                skippedBanner
                Divider()
            }
            HStack {
                statusLabel
                Spacer()
                Button("Re-check all") {
                    Task { await deps.checkAll() }
                }
                .disabled(deps.isWorking)

                Button("Install missing") {
                    Task { await deps.installAllAuto() }
                }
                .disabled(deps.isWorking || deps.allInstalled)

                Button("Continue") { onComplete() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!deps.allInstalledOrSkipped)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let err = deps.lastError {
            Label(err, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if deps.allInstalled {
            Label("All dependencies are ready.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else if deps.allInstalledOrSkipped {
            Label("Ready to continue in degraded mode.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if deps.allChecked {
            Text("Some dependencies are still missing.")
                .foregroundStyle(.secondary)
        } else {
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    /// Yellow banner that explains the degraded-mode trade-off when one
    /// or more deps have been skipped. Lists which ones, with an
    /// inline Unskip action.
    private var skippedBanner: some View {
        let skippedItems = deps.items.filter { deps.isSkipped(id: $0.id) }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Continuing without: \(skippedItems.map { $0.checker.displayName }.joined(separator: ", "))")
                    .font(.callout.weight(.medium))
                Text("Features that depend on these will be unavailable. You can install them later from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unskip all") {
                for item in skippedItems { deps.unskip(id: item.id) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Clipboard / export

    private func copyLogToClipboard() {
        let text = deps.logLines.map { line in
            let scope = line.scope.map { "[\($0)] " } ?? ""
            return "\(scope)\(line.text)"
        }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func exportLog() {
        guard let url = deps.exportLog() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Row

private struct DependencyRow: View {
    let item: DependencyManager.Item
    @ObservedObject var deps: DependencyManager
    @State private var showManualDetails = false

    private var isSkipped: Bool { deps.isSkipped(id: item.id) }

    /// Compute which instruction block, if any, should render below
    /// the row. Failed auto-installs always show their fallback so
    /// the user can recover; manual-only deps render on user toggle.
    private var instructionsToShow: ManualInstructions? {
        if case .failed = item.status,
           case .automatic = item.checker.installSupport,
           let fallback = item.checker.fallbackInstructions {
            return fallback
        }
        if case .manual(let inst) = item.checker.installSupport, showManualDetails {
            return inst
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.checker.displayName).font(.headline)
                    Text(item.checker.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                Spacer()

                actionButtons
            }
            .padding(12)
            .opacity(isSkipped ? 0.55 : 1.0)

            if let instructions = instructionsToShow {
                Divider()
                ManualInstructionsBlock(instructions: instructions) {
                    Task { await deps.recheck(id: item.id) }
                }
                .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isSkipped {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        } else {
            switch item.status {
            case .unknown:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .checking, .installing:
                ProgressView().controlSize(.small)
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    private var statusText: String {
        if isSkipped {
            return "Skipped — features that depend on this will be unavailable."
        }
        switch item.status {
        case .unknown: return "Not yet checked."
        case .checking: return "Checking…"
        case .installed(let v): return v.map { "Installed (\($0))." } ?? "Installed."
        case .missing: return "Not installed."
        case .installing(let msg): return msg
        case .failed(let reason): return reason
        }
    }

    private var borderColor: Color {
        if isSkipped { return Color(nsColor: .separatorColor) }
        switch item.status {
        case .installed: return .green.opacity(0.4)
        case .failed:    return .red.opacity(0.4)
        case .missing:   return .orange.opacity(0.4)
        default:         return Color(nsColor: .separatorColor)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isSkipped {
            Button("Unskip") { deps.unskip(id: item.id) }
                .controlSize(.small)
        } else {
            switch item.status {
            case .installed:
                Button("Re-check") {
                    Task { await deps.recheck(id: item.id) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

            case .missing, .failed:
                HStack(spacing: 6) {
                    switch item.checker.installSupport {
                    case .automatic:
                        Button(action: { Task { await deps.install(id: item.id) } }) {
                            Text(isFailed ? "Retry" : "Install")
                        }
                        .controlSize(.small)
                        .disabled(deps.isWorking)
                    case .manual:
                        Button(showManualDetails ? "Hide" : "How to install") {
                            showManualDetails.toggle()
                        }
                        .controlSize(.small)
                    }

                    Menu {
                        Button("Skip for now") { deps.skip(id: item.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.small)
                    .help("More actions")
                }

            case .checking, .installing, .unknown:
                EmptyView()
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }
}

private struct ManualInstructionsBlock: View {
    let instructions: ManualInstructions
    let onRecheck: () -> Void

    /// All non-nil commands joined with newlines — for the "Copy all commands" button.
    private var allCommands: String {
        instructions.steps.compactMap(\.command).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(instructions.summary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(instructions.steps.enumerated()), id: \.offset) { index, step in
                    StepView(index: index + 1, step: step)
                }
            }

            HStack {
                Button("Open Terminal") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    )
                }
                .controlSize(.small)

                if !allCommands.isEmpty {
                    Button("Copy all commands") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(allCommands, forType: .string)
                    }
                    .controlSize(.small)
                }

                if let url = instructions.documentationURL {
                    Link("Documentation", destination: url)
                        .font(.caption)
                }

                Spacer()

                Button("I've installed it — re-check", action: onRecheck)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct StepView: View {
    let index: Int
    let step: ManualInstructions.Step

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index).")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = step.command {
                    HStack(alignment: .top, spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Copy") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(command, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
