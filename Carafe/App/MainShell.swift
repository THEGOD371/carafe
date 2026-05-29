import SwiftUI

/// Top-level post-onboarding view. NavigationSplitView with two
/// sidebar items: Library (the friendly default) and Bottles (the
/// technical view). The toolbar gear opens the macOS Settings scene
/// (defined in `CarafeApp`); Cmd+, does the same.
struct MainShell: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    @State private var section: Section = .library

    enum Section: String, CaseIterable, Hashable, Identifiable {
        case library = "Library"
        case bottles = "Bottles"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .library: return "rectangle.stack.fill"
            case .bottles: return "shippingbox.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("Carafe")
            .frame(minWidth: 160, idealWidth: 180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            openSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("Settings (⌘,)")
                        .keyboardShortcut(",", modifiers: .command)
                    }
                }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .library: LibraryGridView()
        case .bottles: BottleLibraryView()
        }
    }
}
