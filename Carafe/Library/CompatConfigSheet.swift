import SwiftUI
import AppKit

/// Per-game compatibility editor. Every setting can either inherit
/// from the bottle's defaults or be overridden game-specifically.
/// Saves on close.
struct CompatConfigSheet: View {
    @EnvironmentObject private var library: GameLibrary
    @EnvironmentObject private var bottles: BottleManager
    @Environment(\.dismiss) private var dismiss

    let game: Game

    // MARK: - Form state mirrors GameCompatOverrides

    @State private var graphicsBackend: GraphicsBackend?
    @State private var sync: SyncMode?
    @State private var windowsVersion: WindowsVersion?
    @State private var metalHUD: Bool?
    @State private var retina: Bool?
    @State private var argumentsText: String

    @State private var dllOverridesEnabled: Bool
    @State private var dllOverridePairs: [KVPair]

    @State private var environmentEnabled: Bool
    @State private var environmentPairs: [KVPair]

    init(game: Game) {
        self.game = game
        let o = game.compatOverrides ?? GameCompatOverrides()
        _graphicsBackend = State(initialValue: o.graphicsBackend)
        _sync = State(initialValue: o.sync)
        _windowsVersion = State(initialValue: o.windowsVersion)
        _metalHUD = State(initialValue: o.metalHUD)
        _retina = State(initialValue: o.retina)
        _argumentsText = State(initialValue: game.arguments.joined(separator: " "))

        if let d = o.dllOverrides {
            _dllOverridesEnabled = State(initialValue: true)
            _dllOverridePairs = State(initialValue: d
                .sorted(by: { $0.key < $1.key })
                .map { KVPair(key: $0.key, value: $0.value) })
        } else {
            _dllOverridesEnabled = State(initialValue: false)
            _dllOverridePairs = State(initialValue: [])
        }

        if let e = o.environment {
            _environmentEnabled = State(initialValue: true)
            _environmentPairs = State(initialValue: e
                .sorted(by: { $0.key < $1.key })
                .map { KVPair(key: $0.key, value: $0.value) })
        } else {
            _environmentEnabled = State(initialValue: false)
            _environmentPairs = State(initialValue: [])
        }
    }

    private var bottle: Bottle? { library.bottle(for: game) }
    private var defaults: BottleCompatDefaults {
        bottle?.compatDefaults ?? .defaults
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    graphicsSection
                    compatibilitySection
                    advancedSection
                    environmentSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 720)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compatibility — \(game.name)")
                    .font(.title3.weight(.semibold))
                if let bottle {
                    Text("Inherits from bottle: \(bottle.name)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Sections

    private var graphicsSection: some View {
        sectionCard(title: "Graphics", icon: "rectangle.3.group") {
            inheritableRow(
                label: "Backend",
                inheritedDescription: defaults.graphicsBackend.displayName,
                isOverridden: graphicsBackend != nil,
                onOverride: { graphicsBackend = defaults.graphicsBackend },
                onInherit: { graphicsBackend = nil }
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(
                        get: { graphicsBackend ?? defaults.graphicsBackend },
                        set: { graphicsBackend = $0 }
                    )) {
                        ForEach(GraphicsBackend.allCases) { b in
                            Text(b.displayName).tag(b)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    Text((graphicsBackend ?? defaults.graphicsBackend).summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if (graphicsBackend ?? defaults.graphicsBackend) == .dxvk {
                        Label("Install the `dxvk` winetricks verb in this bottle first, otherwise DXVK has nothing to load.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Divider().padding(.vertical, 4)
            inheritableToggle(
                label: "Metal HUD",
                summary: "Apple's Metal performance overlay. Useful for benchmarking; usually noisy in actual play.",
                inheritedValue: defaults.metalHUD,
                override: $metalHUD
            )
            Divider().padding(.vertical, 4)
            inheritableToggle(
                label: "Retina (high-DPI)",
                summary: "Renders at native resolution on Retina displays. Sharper but more demanding.",
                inheritedValue: defaults.retina,
                override: $retina
            )
        }
    }

    private var compatibilitySection: some View {
        sectionCard(title: "Compatibility", icon: "shippingbox") {
            inheritableRow(
                label: "Windows version",
                inheritedDescription: (bottle?.windowsVersion ?? .win10).displayName,
                isOverridden: windowsVersion != nil,
                onOverride: { windowsVersion = bottle?.windowsVersion ?? .win10 },
                onInherit: { windowsVersion = nil }
            ) {
                Picker("", selection: Binding(
                    get: { windowsVersion ?? bottle?.windowsVersion ?? .win10 },
                    set: { windowsVersion = $0 }
                )) {
                    ForEach(WindowsVersion.allCases) { v in
                        Text(v.displayName).tag(v)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            Divider().padding(.vertical, 4)
            inheritableRow(
                label: "Sync primitive",
                inheritedDescription: defaults.sync.displayName,
                isOverridden: sync != nil,
                onOverride: { sync = defaults.sync },
                onInherit: { sync = nil }
            ) {
                Picker("", selection: Binding(
                    get: { sync ?? defaults.sync },
                    set: { sync = $0 }
                )) {
                    ForEach(SyncMode.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        }
    }

    private var advancedSection: some View {
        sectionCard(title: "Advanced", icon: "wrench.adjustable") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch arguments").font(.callout.weight(.medium))
                TextField("Optional — passed to the exe at launch", text: $argumentsText)
                    .textFieldStyle(.roundedBorder)
                Text("Whitespace-separated. Wrap arguments containing spaces in double quotes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 4)
            dllOverridesEditor
        }
    }

    private var dllOverridesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DLL overrides").font(.callout.weight(.medium))
                Spacer()
                Toggle("Override bottle's", isOn: $dllOverridesEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
            if dllOverridesEnabled {
                Text("dll name → wine mode (`n` native, `b` builtin, `n,b` native first, `b,n` builtin first, empty disables).")
                    .font(.caption).foregroundStyle(.secondary)
                KVListEditor(
                    pairs: $dllOverridePairs,
                    keyPlaceholder: "dll (e.g. d3d11)",
                    valuePlaceholder: "mode"
                )
            } else {
                Text("Inheriting from bottle: \(bottle?.dllOverrides.isEmpty == false ? "\(bottle?.dllOverrides.count ?? 0) entries" : "none set").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var environmentSection: some View {
        sectionCard(title: "Environment", icon: "terminal") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Environment variables").font(.callout.weight(.medium))
                    Spacer()
                    Toggle("Override bottle's", isOn: $environmentEnabled)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
                if environmentEnabled {
                    Text("Variables set in addition to the GPTK defaults (WINEDEBUG, WINEMSYNC, etc., already managed for you).")
                        .font(.caption).foregroundStyle(.secondary)
                    KVListEditor(
                        pairs: $environmentPairs,
                        keyPlaceholder: "VAR_NAME",
                        valuePlaceholder: "value"
                    )
                } else {
                    Text("Inheriting from bottle: \(bottle?.environment.isEmpty == false ? "\(bottle?.environment.count ?? 0) entries" : "none set").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Reset all to inherit", role: .destructive) {
                graphicsBackend = nil
                sync = nil
                windowsVersion = nil
                metalHUD = nil
                retina = nil
                dllOverridesEnabled = false
                dllOverridePairs = []
                environmentEnabled = false
                environmentPairs = []
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func save() {
        let overrides = GameCompatOverrides(
            graphicsBackend: graphicsBackend,
            sync: sync,
            windowsVersion: windowsVersion,
            metalHUD: metalHUD,
            retina: retina,
            dllOverrides: dllOverridesEnabled ? pairsToDict(dllOverridePairs) : nil,
            environment: environmentEnabled ? pairsToDict(environmentPairs) : nil
        )

        // Persist nothing if all-inherit — keeps metadata.json tidy.
        var updated = game
        updated.compatOverrides = overrides.isAllInherit ? nil : overrides
        updated.arguments = parsedArguments
        library.update(updated)
        dismiss()
    }

    private var parsedArguments: [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for ch in argumentsText {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(ch) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func pairsToDict(_ pairs: [KVPair]) -> [String: String] {
        var d: [String: String] = [:]
        for p in pairs {
            let k = p.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            d[k] = p.value
        }
        return d
    }

    // MARK: - Reusable section helpers

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(title).font(.headline)
            }
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func inheritableRow<Override: View>(
        label: String,
        inheritedDescription: String,
        isOverridden: Bool,
        onOverride: @escaping () -> Void,
        onInherit: @escaping () -> Void,
        @ViewBuilder _ override: () -> Override
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                if isOverridden {
                    Button(action: onInherit) {
                        Label("Inherit from bottle (\(inheritedDescription))", systemImage: "arrow.uturn.backward.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                } else {
                    Text("Inheriting from bottle: \(inheritedDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, alignment: .leading)
            Group {
                if isOverridden {
                    override()
                } else {
                    Button("Override") { onOverride() }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func inheritableToggle(
        label: String,
        summary: String,
        inheritedValue: Bool,
        override: Binding<Bool?>
    ) -> some View {
        let isOverridden = override.wrappedValue != nil
        let effective = override.wrappedValue ?? inheritedValue

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { effective },
                        set: { newValue in
                            if isOverridden {
                                override.wrappedValue = newValue
                            } else {
                                // Auto-override on first toggle change.
                                override.wrappedValue = newValue
                            }
                        }
                    ))
                    .labelsHidden()
                    Text(effective ? "On" : "Off")
                }
                if isOverridden {
                    Button {
                        override.wrappedValue = nil
                    } label: {
                        Label("Inherit from bottle (\(inheritedValue ? "On" : "Off"))",
                              systemImage: "arrow.uturn.backward.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                } else {
                    Text("Inheriting from bottle: \(inheritedValue ? "On" : "Off")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - KV editor

struct KVPair: Identifiable, Hashable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

struct KVListEditor: View {
    @Binding var pairs: [KVPair]
    let keyPlaceholder: String
    let valuePlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pairs.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: Binding(
                        get: { pairs[index].key },
                        set: { pairs[index].key = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    Text("=").foregroundStyle(.secondary)
                    TextField(valuePlaceholder, text: Binding(
                        get: { pairs[index].value },
                        set: { pairs[index].value = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        pairs.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                pairs.append(KVPair(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}
