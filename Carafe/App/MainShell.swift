import SwiftUI

/// Top-level post-onboarding view. NavigationSplitView with two
/// sidebar items: Library (the friendly default) and Bottles (the
/// technical view). The toolbar gear opens the macOS Settings scene
/// (defined in `CarafeApp`); Cmd+, does the same.
struct MainShell: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    @State private var section: Section = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("Carafe")
            .frame(minWidth: 160, idealWidth: 180)
        } detail: {
            detailView
                // Dot-matrix backdrop, visible behind scrollable
                // content (e.g. the library grid and its empty state).
                // Views with opaque backgrounds simply cover it.
                .background {
                    if settings.appearanceTheme == .nothing {
                        NothingDotGrid().ignoresSafeArea()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Picker("Section", selection: $section) {
                            ForEach(Section.allCases) { item in
                                Label(item.rawValue, systemImage: item.icon)
                                    .tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                        .help("Switch between Library and Bottles")
                    }
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
