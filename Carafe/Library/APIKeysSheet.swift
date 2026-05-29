import SwiftUI

/// Settings sheet for managing the SteamGridDB API key. Reached
/// from the toolbar's gear menu. Stored in the macOS Keychain via
/// CarafeKeychain — never written to disk in plaintext.
struct APIKeysSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var keyInput: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var status: ValidationStatus = .idle
    @State private var showInstructions = false

    enum ValidationStatus: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    private let client = SteamGridDBClient()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    steamGridDBSection
                    instructionsSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .onAppear {
            hasStoredKey = client.hasAPIKey
            if let existing = CarafeKeychain.getString(account: .steamGridDBAPIKey) {
                // Don't expose the full key — show only that something
                // is stored. The keyInput starts blank; user must paste
                // again to replace.
                _ = existing
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("API Keys")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(16)
    }

    // MARK: - SteamGridDB section

    private var steamGridDBSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SteamGridDB").font(.headline)
                if hasStoredKey {
                    Label("Stored", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
            }
            Text("Used to fetch cover art when adding games. Free, but you need a personal key. Stored in the macOS Keychain — Carafe never writes it to disk in plaintext.")
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("Paste your API key", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await test() } }

            HStack(spacing: 8) {
                Button("Test", action: { Task { await test() } })
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || status == .validating)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || status == .validating
                    )
                if hasStoredKey {
                    Button("Clear stored key", role: .destructive) { clearStored() }
                }
                Spacer()
                statusLabel
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Validating…").font(.caption).foregroundStyle(.secondary)
            }
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .invalid(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        DisclosureGroup(isExpanded: $showInstructions) {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open ") + link("https://www.steamgriddb.com", url: URL(string: "https://www.steamgriddb.com")!) + Text(" and sign in (Discord, Google, or Steam login).")
                step(2, "Click your avatar → ") + Text("Preferences").bold() + Text(".")
                step(3, "Open the ") + Text("API").bold() + Text(" tab in the sidebar.")
                step(4, "Click ") + Text("Generate API Key").bold() + Text(" (or copy your existing one).")
                step(5, "Paste it above, hit ") + Text("Test").bold() + Text(", then ") + Text("Save").bold() + Text(".")
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.top, 8)
        } label: {
            Text("How to get a free key")
                .font(.callout.weight(.medium))
        }
    }

    private func step(_ n: Int, _ text: String) -> Text {
        Text("\(n). \(text)")
    }

    private func link(_ text: String, url: URL) -> Text {
        // SwiftUI's Text doesn't directly render hyperlinks — but
        // `.underline().foregroundStyle(.tint)` paired with onTap on
        // the outer view would be heavier. For v1, the visible URL
        // string is enough; users can copy/paste.
        Text(text)
            .foregroundColor(.accentColor)
            .underline()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func test() async {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        status = .validating
        do {
            try await client.validateAPIKey(key)
            status = .valid
        } catch let err as SteamGridDBClient.Failure {
            status = .invalid(err.errorDescription ?? "Failed")
        } catch {
            status = .invalid(error.localizedDescription)
        }
    }

    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try CarafeKeychain.setString(key, account: .steamGridDBAPIKey)
            hasStoredKey = true
            keyInput = ""
            status = .valid
        } catch {
            status = .invalid("Couldn't save to Keychain: \(error.localizedDescription)")
        }
    }

    private func clearStored() {
        do {
            try CarafeKeychain.delete(account: .steamGridDBAPIKey)
            hasStoredKey = false
            status = .idle
            keyInput = ""
        } catch {
            status = .invalid("Couldn't clear key: \(error.localizedDescription)")
        }
    }
}
