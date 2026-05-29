import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Top-level sheet for launching a Windows executable inside a
/// bottle. Owns the active RunSession (nil = pre-launch form mode).
struct LaunchExeSheet: View {
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    /// Bottle pre-selected by the caller (right-click "Run executable…").
    /// User can still pick a different one from the dropdown.
    let initialBottleID: UUID?

    // MARK: - Form state

    @State private var selectedBottleID: UUID?
    @State private var exeURL: URL?
    @State private var argumentsText: String = ""
    @State private var showEnvironment: Bool = false
    @State private var formError: String?

    // MARK: - Session state

    @State private var session: RunSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                RunningSessionView(
                    session: session,
                    onStop: { Task { await session.stop() } },
                    onRestart: { restart() },
                    onClose: { closeAndCleanup() }
                )
            } else {
                ConfigForm(
                    bottles: validBottles,
                    selectedBottleID: $selectedBottleID,
                    exeURL: $exeURL,
                    argumentsText: $argumentsText,
                    showEnvironment: $showEnvironment,
                    formError: $formError,
                    resolvedEnvironment: resolvedEnvironment,
                    canLaunch: canLaunch,
                    blockedReason: blockedReason,
                    onPickExe: pickExecutable,
                    onCancel: { dismiss() },
                    onLaunch: launch
                )
            }
        }
        .frame(width: 640, height: session == nil ? 480 : 560)
        .onAppear {
            if selectedBottleID == nil {
                selectedBottleID = initialBottleID ?? validBottles.first?.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run an executable").font(.title3.weight(.semibold))
                if let bottle = selectedBottle {
                    Text("In bottle: \(bottle.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let session, case .running = session.state {
                Label("Running", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    // MARK: - Derived

    private var validBottles: [Bottle] {
        bottles.entries.compactMap(\.validBottle)
    }

    private var selectedBottle: Bottle? {
        validBottles.first { $0.id == selectedBottleID }
    }

    private var parsedArguments: [String] {
        // Simple shell-style splitting on whitespace, respecting
        // double-quoted segments. Good enough for v1; the per-game
        // config milestone will get a structured args editor.
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in argumentsText {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private var resolvedEnvironment: [(String, String)] {
        guard let bottle = selectedBottle else { return [] }
        let env = WineRunner.environment(
            for: bottle.prefixURL,
            build: bottle.wineBuild,
            dllOverrides: bottle.dllOverrides,
            bottleEnvironment: bottle.environment,
            extra: [
                "WINEMSYNC": "1",
                "WINEDEBUG": "fixme-all",
                "MTL_HUD_ENABLED": "0",
            ]
        )
        return env.sorted(by: { $0.key < $1.key })
            .map { ($0.key, $0.value) }
    }

    /// nil if launch is OK, otherwise the reason the Run button is
    /// disabled. Returned as user-facing copy so the UI can show it
    /// next to the disabled button.
    private var blockedReason: String? {
        if bottles.currentOperation?.state == .running {
            return "A bottle operation is in progress. Wait for it to finish."
        }
        if selectedBottle == nil {
            return "Pick a bottle first."
        }
        if exeURL == nil {
            return "Pick an executable first."
        }
        if let bottle = selectedBottle,
           !WineRunner.isWineAvailable(for: bottle.wineBuild) {
            return "\(bottle.wineBuild.shortName) isn't installed for this bottle."
        }
        return nil
    }

    private var canLaunch: Bool { blockedReason == nil }

    // MARK: - Actions

    private func pickExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows executable"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Pick an .exe or .msi file. The file can live anywhere on disk — wine maps your Mac filesystem as the Z: drive."

        var allowedTypes: [UTType] = []
        if let exeType = UTType(filenameExtension: "exe") { allowedTypes.append(exeType) }
        if let msiType = UTType(filenameExtension: "msi") { allowedTypes.append(msiType) }
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Centralised launchability check (MZ + Steam.exe whitelist
        // + per-build 32-bit policy). Hard-block on .block; .warning
        // and .ok both accept the pick — RunSession will log the
        // warning at launch time.
        let build = selectedBottle?.wineBuild ?? .gptk
        if case .block(let message) = PEValidator.evaluateLaunchability(at: url, build: build) {
            formError = message
            return
        }
        formError = nil
        exeURL = url
    }

    private func launch() {
        guard let bottle = selectedBottle, let exeURL else { return }
        let newSession = RunSession(
            bottle: bottle,
            exeURL: exeURL,
            arguments: parsedArguments
        )
        session = newSession
        Task { await newSession.start() }
    }

    private func restart() {
        guard let oldSession = session else { return }
        Task {
            // Ensure the previous process is fully done before
            // spinning a new one in the same prefix.
            if oldSession.state.isLive { await oldSession.stop() }
            await oldSession.cleanup()
            await MainActor.run {
                let newSession = RunSession(
                    bottle: oldSession.bottle,
                    exeURL: oldSession.exeURL,
                    arguments: oldSession.arguments
                )
                session = newSession
                Task { await newSession.start() }
            }
        }
    }

    private func closeAndCleanup() {
        guard let session else { dismiss(); return }
        Task {
            if session.state.isLive { await session.stop() }
            await session.cleanup()
            await MainActor.run { dismiss() }
        }
    }
}

// MARK: - Config form

private struct ConfigForm: View {
    let bottles: [Bottle]
    @Binding var selectedBottleID: UUID?
    @Binding var exeURL: URL?
    @Binding var argumentsText: String
    @Binding var showEnvironment: Bool
    @Binding var formError: String?

    let resolvedEnvironment: [(String, String)]
    let canLaunch: Bool
    let blockedReason: String?
    let onPickExe: () -> Void
    let onCancel: () -> Void
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bottlePickerSection
                    exePickerSection
                    argumentsSection
                    environmentSection
                    if let formError {
                        Label(formError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    private var bottlePickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bottle").font(.callout.weight(.medium))
            Picker("", selection: $selectedBottleID) {
                ForEach(bottles) { bottle in
                    Text("\(bottle.name) — \(bottle.windowsVersion.displayName)")
                        .tag(Optional(bottle.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var exePickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Executable").font(.callout.weight(.medium))
            HStack(spacing: 8) {
                Text(exeURL?.path ?? "No file selected")
                    .font(.callout)
                    .foregroundStyle(exeURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                Button("Choose…", action: onPickExe)
            }
            Text("Wine maps `/` to the `Z:` drive. The exe can live anywhere — its containing folder becomes the working directory at launch time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var argumentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launch arguments").font(.callout.weight(.medium))
            TextField("Optional — e.g.  --windowed  -savedir \"My Saves\"", text: $argumentsText)
                .textFieldStyle(.roundedBorder)
            Text("Whitespace-separated. Wrap arguments containing spaces in double quotes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var environmentSection: some View {
        DisclosureGroup(isExpanded: $showEnvironment) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(resolvedEnvironment, id: \.0) { key, value in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("=").font(.caption).foregroundStyle(.tertiary)
                        Text(value)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if resolvedEnvironment.isEmpty {
                    Text("No environment computed (no bottle selected).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Resolved environment")
                .font(.callout.weight(.medium))
        }
    }

    private var footer: some View {
        HStack {
            if let blockedReason {
                Text(blockedReason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Run", action: onLaunch)
                .buttonStyle(.borderedProminent)
                .disabled(!canLaunch)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

// RunningSessionView moved to Carafe/Library/RunningSessionView.swift
// so LaunchGameSheet can reuse it.
