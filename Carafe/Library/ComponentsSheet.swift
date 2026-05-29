import SwiftUI
import AppKit

/// Per-bottle "Install Components" sheet. Three modes:
///   - `.checking` / `.winetricksMissing` / `.installingWinetricks` —
///     bootstrap phase for users who haven't installed winetricks
///   - `.picker` — list verbs grouped by category, user toggles
///   - `.installing(progress)` — per-verb step list + streaming log
struct ComponentsSheet: View {
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    let bottle: Bottle

    @State private var phase: Phase = .checking
    @State private var winetricksLog: [String] = []
    @State private var selectedVerbs: Set<String> = []
    @State private var filterText: String = ""
    @StateObject private var progress = ComponentsInstallProgress()

    enum Phase: Equatable {
        case checking
        case winetricksMissing
        case installingWinetricks
        case picker
        case installing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 720, height: 600)
        .task { await detectAndAdvance() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install components").font(.title3.weight(.semibold))
                Text("In bottle: \(bottle.name)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            phaseBadge
        }
        .padding(16)
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch phase {
        case .checking:
            Label("Checking…", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
        case .winetricksMissing:
            Label("winetricks missing", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .installingWinetricks:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Installing winetricks").font(.caption).foregroundStyle(.secondary)
            }
        case .picker:
            EmptyView()
        case .installing:
            HStack(spacing: 4) {
                if !progress.isFinished {
                    ProgressView().controlSize(.small)
                }
                Text(progress.isFinished ? progress.summary : "Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Content (switches on phase)

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .checking:
            centred {
                ProgressView()
                Text("Detecting winetricks…").foregroundStyle(.secondary)
            }
        case .winetricksMissing:
            winetricksMissingView
        case .installingWinetricks:
            winetricksInstallingView
        case .picker:
            pickerView
        case .installing:
            installingView
        }
    }

    // MARK: - "winetricks missing" view

    private var winetricksMissingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox").font(.title).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("winetricks isn't installed yet").font(.headline)
                    Text("winetricks is the community tool for installing Windows runtimes (Visual C++, .NET, DirectX shims, etc.) into a Wine prefix. It's distributed via Homebrew.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Install command (in case you'd rather do this in Terminal)") {
                HStack {
                    Text("brew install winetricks")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString("brew install winetricks", forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .font(.callout)

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Install via Homebrew") {
                    Task { await installWinetricks() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - "installing winetricks" view

    private var winetricksInstallingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(winetricksLog.enumerated()), id: \.offset) { _, line in
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
                .onChange(of: winetricksLog.count) { _, _ in
                    if let last = winetricksLog.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .padding(16)
    }

    // MARK: - Picker

    private var pickerView: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if filterText.isEmpty {
                        gamingEssentialsCard
                        extrasHeader
                    }
                    ForEach(WinetricksComponent.Category.allCases) { category in
                        categorySection(category)
                    }
                }
                .padding(16)
            }
            Divider()
            pickerFooter
        }
    }

    // MARK: - Gaming Essentials

    private var gamingEssentialsCard: some View {
        let essentials = WinetricksCatalog.essentialComponents
        let allInstalled = essentials.allSatisfy { bottle.installedComponents.contains($0.verb) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title3).foregroundStyle(.tint)
                Text("Gaming Essentials").font(.headline)
                Spacer()
                if allInstalled {
                    Label("Installed", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Text("One-click install of the three runtimes most games need: VC++ 2015–2019, d3dcompiler_47, and Microsoft Core Fonts. Total ~35 MB, takes about 5 minutes.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(essentials) { c in
                    Text("\(c.verb)\(bottle.installedComponents.contains(c.verb) ? " ✓" : "")")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(
                            bottle.installedComponents.contains(c.verb)
                                ? Color.green.opacity(0.15)
                                : Color.secondary.opacity(0.1)
                        )
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    installEssentials()
                } label: {
                    Label(allInstalled ? "Reinstall Essentials" : "Install Gaming Essentials",
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var extrasHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Extras")
                .font(.title3.weight(.semibold))
            Text("Only install if a specific game needs it. Installing speculatively slows things down and can cause conflicts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func installEssentials() {
        let toInstall = WinetricksCatalog.essentialComponents
        guard !toInstall.isEmpty else { return }
        progress.start(verbs: toInstall)
        phase = .installing
        Task { await runInstall(verbs: toInstall) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter (e.g. vcrun, dotnet, d3d)", text: $filterText)
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func categorySection(_ category: WinetricksComponent.Category) -> some View {
        let items = WinetricksCatalog.components(in: category).filter(matchesFilter)
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: category.systemImage).foregroundStyle(.tint)
                        Text(category.rawValue).font(.headline)
                    }
                    VStack(spacing: 0) {
                        ForEach(items) { component in
                            componentRow(component)
                            if component.id != items.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
    }

    private func componentRow(_ c: WinetricksComponent) -> some View {
        let isInstalled = bottle.installedComponents.contains(c.verb)
        let isSelected = selectedVerbs.contains(c.verb)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    if newValue { selectedVerbs.insert(c.verb) }
                    else { selectedVerbs.remove(c.verb) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.displayName).font(.callout.weight(.medium))
                    Text("(\(c.verb))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let size = c.approximateSize {
                        Text("• \(size)").font(.caption).foregroundStyle(.tertiary)
                    }
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.seal.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    if c.warning != nil {
                        Label("Caution", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                Text(c.summary).font(.caption).foregroundStyle(.secondary)
                if let warning = c.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selectedVerbs.remove(c.verb) } else { selectedVerbs.insert(c.verb) }
        }
    }

    private var pickerFooter: some View {
        HStack {
            Text(selectionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Install \(selectedVerbs.count) component\(selectedVerbs.count == 1 ? "" : "s")") {
                startInstall()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedVerbs.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var selectionSummary: String {
        if selectedVerbs.isEmpty {
            return "Pick one or more components to install."
        }
        let alreadyInstalled = selectedVerbs.intersection(bottle.installedComponents).count
        if alreadyInstalled > 0 {
            return "\(selectedVerbs.count) selected — \(alreadyInstalled) already installed (will be reinstalled)."
        }
        return "\(selectedVerbs.count) selected."
    }

    // MARK: - Installing phase

    private var installingView: some View {
        HStack(spacing: 0) {
            // Left: step list
            VStack(alignment: .leading, spacing: 0) {
                Text("Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(progress.steps) { step in
                            stepRow(step)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .frame(width: 260)
            Divider()
            // Right: streaming log
            VStack(alignment: .leading, spacing: 0) {
                logHeader
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(progress.logLines.enumerated()), id: \.offset) { _, line in
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
                    .onChange(of: progress.logLines.count) { _, _ in
                        if let last = progress.logLines.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                Divider()
                installingFooter
            }
        }
    }

    private func stepRow(_ step: ComponentsInstallProgress.Step) -> some View {
        HStack(alignment: .top, spacing: 6) {
            stepIcon(step.state).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.component.displayName).font(.caption).lineLimit(1)
                if case .failed(let reason) = step.state {
                    Text(reason).font(.caption2).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(step.component.verb)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func stepIcon(_ state: ComponentsInstallProgress.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var logHeader: some View {
        HStack {
            if let verb = progress.currentVerb {
                Text("Installing \(verb)…")
                    .font(.caption.weight(.semibold))
            } else {
                Text("Log").font(.caption.weight(.semibold))
            }
            Spacer()
            Button("Copy log") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(progress.logLines.joined(separator: "\n"), forType: .string)
            }
            .controlSize(.small)
            .disabled(progress.logLines.isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private var installingFooter: some View {
        HStack {
            Spacer()
            if progress.isFinished {
                if !progress.failedComponents.isEmpty {
                    Button("Retry failed (\(progress.failedComponents.count))") {
                        retryFailed()
                    }
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel remaining", role: .destructive) {
                    progress.wasCancelled = true
                }
            }
        }
        .padding(10)
    }

    // MARK: - Actions

    private func detectAndAdvance() async {
        if WinetricksRunner.isInstalled {
            phase = .picker
        } else {
            phase = .winetricksMissing
        }
    }

    private func installWinetricks() async {
        phase = .installingWinetricks
        do {
            try await WinetricksRunner.installViaBrew { line in
                Task { @MainActor in winetricksLog.append(line) }
            }
            phase = .picker
        } catch let err as WinetricksRunner.Failure {
            winetricksLog.append("⛔ \(err.errorDescription ?? "Install failed")")
            phase = .winetricksMissing
        } catch {
            winetricksLog.append("⛔ \(error.localizedDescription)")
            phase = .winetricksMissing
        }
    }

    private func startInstall() {
        let chosen = selectedVerbs
            .compactMap { verb in WinetricksCatalog.components.first(where: { $0.verb == verb }) }
            .sorted(by: { ($0.category.rawValue, $0.displayName) < ($1.category.rawValue, $1.displayName) })
        guard !chosen.isEmpty else { return }
        progress.start(verbs: chosen)
        phase = .installing
        Task { await runInstall(verbs: chosen) }
    }

    private func runInstall(verbs: [WinetricksComponent]) async {
        var installedThisRun: [String] = []
        for (i, component) in verbs.enumerated() {
            if progress.wasCancelled { break }
            progress.setRunning(at: i)
            progress.logLines.append("[\(i+1)/\(verbs.count)] \(component.displayName) — \(component.verb)")
            do {
                try await WinetricksRunner.installVerb(component.verb, in: bottle) { line in
                    Task { @MainActor in progress.logLines.append(line) }
                }
                progress.setSucceeded(at: i)
                installedThisRun.append(component.verb)
            } catch let err as WinetricksRunner.Failure {
                progress.setFailed(at: i, reason: err.errorDescription ?? "failed")
            } catch {
                progress.setFailed(at: i, reason: error.localizedDescription)
            }
        }
        if !installedThisRun.isEmpty {
            bottles.markComponentsInstalled(installedThisRun, in: bottle)
        }
        progress.finish()
    }

    private func retryFailed() {
        let failedVerbs = progress.failedComponents
        guard !failedVerbs.isEmpty else { return }
        progress.start(verbs: failedVerbs)
        Task { await runInstall(verbs: failedVerbs) }
    }

    // MARK: - Helpers

    private func matchesFilter(_ c: WinetricksComponent) -> Bool {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return c.verb.lowercased().contains(q)
            || c.displayName.lowercased().contains(q)
            || c.summary.lowercased().contains(q)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Progress model

@MainActor
final class ComponentsInstallProgress: ObservableObject {
    struct Step: Identifiable {
        let id: String
        let component: WinetricksComponent
        var state: State
    }

    enum State: Equatable {
        case pending
        case running
        case succeeded
        case failed(String)
    }

    @Published var steps: [Step] = []
    @Published var logLines: [String] = []
    @Published var currentVerb: String?
    @Published var isFinished: Bool = false
    @Published var wasCancelled: Bool = false

    private let logCap = 5_000

    func start(verbs: [WinetricksComponent]) {
        steps = verbs.map { Step(id: $0.verb, component: $0, state: .pending) }
        logLines.removeAll()
        currentVerb = nil
        isFinished = false
        wasCancelled = false
    }

    func setRunning(at index: Int) {
        guard index < steps.count else { return }
        steps[index].state = .running
        currentVerb = steps[index].component.verb
    }

    func setSucceeded(at index: Int) {
        guard index < steps.count else { return }
        steps[index].state = .succeeded
    }

    func setFailed(at index: Int, reason: String) {
        guard index < steps.count else { return }
        steps[index].state = .failed(reason)
    }

    func finish() {
        isFinished = true
        currentVerb = nil
    }

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > logCap {
            logLines.removeFirst(logLines.count - logCap)
        }
    }

    var successCount: Int {
        steps.reduce(0) { $0 + ($1.state == .succeeded ? 1 : 0) }
    }

    var failedComponents: [WinetricksComponent] {
        steps.compactMap { step in
            if case .failed = step.state { return step.component }
            return nil
        }
    }

    var summary: String {
        if wasCancelled {
            return "Cancelled. \(successCount) installed."
        }
        if failedComponents.isEmpty {
            return "All \(successCount) component\(successCount == 1 ? "" : "s") installed."
        }
        return "\(successCount) installed, \(failedComponents.count) failed."
    }
}
