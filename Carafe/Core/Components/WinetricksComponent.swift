import Foundation

/// One installable Windows redistributable / runtime / library that
/// winetricks knows how to fetch and install into a Wine prefix.
struct WinetricksComponent: Identifiable, Hashable, Sendable {
    /// The canonical winetricks verb — what we pass on the command
    /// line. Also the key stored in `Bottle.installedComponents`.
    let verb: String

    let displayName: String
    let summary: String
    let category: Category

    /// Approximate download size, for setting user expectations
    /// (winetricks downloads are real Microsoft installers, not
    /// tiny scripts). nil = unknown.
    let approximateSize: String?

    /// Optional cautionary text shown next to the row. Used for
    /// verbs that frequently cause problems if installed without
    /// the user knowing what they're doing — most notably `dxvk`,
    /// which conflicts with GPTK's default D3DMetal backend.
    let warning: String?

    var id: String { verb }

    init(
        verb: String,
        displayName: String,
        summary: String,
        category: Category,
        approximateSize: String?,
        warning: String? = nil
    ) {
        self.verb = verb
        self.displayName = displayName
        self.summary = summary
        self.category = category
        self.approximateSize = approximateSize
        self.warning = warning
    }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case runtimes  = "Visual C++ runtimes"
        case dotnet    = ".NET Framework"
        case directx   = "DirectX shims"
        case media     = "Media"
        case fonts     = "Fonts"
        case gaming    = "Gaming libraries"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .runtimes: return "shippingbox"
            case .dotnet:   return "circle.hexagongrid"
            case .directx:  return "rectangle.3.group"
            case .media:    return "speaker.wave.2"
            case .fonts:    return "textformat"
            case .gaming:   return "gamecontroller"
            }
        }
    }
}

/// Curated list of winetricks verbs that cover ~95% of single-player
/// Windows game compatibility on Apple Silicon.
///
/// FRAGILITY: winetricks verbs come and go. When Microsoft retires a
/// download URL, the corresponding verb breaks until winetricks ships
/// a fix upstream. Failures here are expected and not Carafe's fault —
/// the ComponentsSheet's per-verb pass/fail reporting makes that
/// visible to the user. To update the catalog, run
/// `winetricks list-all 2>&1 | less` in Terminal.
enum WinetricksCatalog {

    static let components: [WinetricksComponent] = runtimes + dotnet + directx + media + fonts + gaming

    static func components(in category: WinetricksComponent.Category) -> [WinetricksComponent] {
        components.filter { $0.category == category }
    }

    /// The "Gaming Essentials" bundle — three verbs that cover the
    /// vast majority of crashes-on-launch reports. Surfaced as a
    /// one-click install at the top of ComponentsSheet so users
    /// don't have to think about which verbs to pick.
    ///
    /// Why these three:
    ///   - vcrun2019      : Universal CRT + VC++ 2015–2019; covers the
    ///                      majority of modern game runtime requirements.
    ///   - d3dcompiler_47 : Modern DirectX shader compiler; almost
    ///                      every DX11+ game needs it.
    ///   - corefonts      : Microsoft core fonts; fixes the "missing
    ///                      / wrong fonts" look that plagues many games.
    static let essentialVerbs: [String] = ["vcrun2019", "d3dcompiler_47", "corefonts"]

    static var essentialComponents: [WinetricksComponent] {
        essentialVerbs.compactMap { verb in
            components.first(where: { $0.verb == verb })
        }
    }

    // MARK: - Visual C++ runtimes

    private static let runtimes: [WinetricksComponent] = [
        .init(verb: "vcrun6",     displayName: "VC++ 6.0",
              summary: "Microsoft Visual C++ 6.0 runtime. Needed for some very old games.",
              category: .runtimes, approximateSize: "1 MB"),
        .init(verb: "vcrun2005",  displayName: "VC++ 2005",
              summary: "Visual C++ 2005 (8.0) redistributable. Some older games.",
              category: .runtimes, approximateSize: "3 MB"),
        .init(verb: "vcrun2008",  displayName: "VC++ 2008",
              summary: "Visual C++ 2008 (9.0) redistributable.",
              category: .runtimes, approximateSize: "4 MB"),
        .init(verb: "vcrun2010",  displayName: "VC++ 2010",
              summary: "Visual C++ 2010 (10.0). Common Steam-era requirement.",
              category: .runtimes, approximateSize: "5 MB"),
        .init(verb: "vcrun2012",  displayName: "VC++ 2012",
              summary: "Visual C++ 2012 (11.0).",
              category: .runtimes, approximateSize: "6 MB"),
        .init(verb: "vcrun2013",  displayName: "VC++ 2013",
              summary: "Visual C++ 2013 (12.0). Many mid-2010s games.",
              category: .runtimes, approximateSize: "7 MB"),
        .init(verb: "vcrun2019",  displayName: "VC++ 2015–2019",
              summary: "Universal CRT + Visual C++ 2015 / 2017 / 2019 (all 14.x). The single most important runtime for modern games.",
              category: .runtimes, approximateSize: "25 MB"),
        .init(verb: "vcrun2022",  displayName: "VC++ 2022",
              summary: "Latest Visual C++ runtime. Needed by some 2023+ titles.",
              category: .runtimes, approximateSize: "25 MB"),
    ]

    // MARK: - .NET Framework

    private static let dotnet: [WinetricksComponent] = [
        .init(verb: "dotnet35sp1", displayName: ".NET 3.5 SP1",
              summary: ".NET Framework 3.5 SP1. Required by some older games + tools.",
              category: .dotnet, approximateSize: "230 MB"),
        .init(verb: "dotnet40",    displayName: ".NET 4.0",
              summary: ".NET Framework 4.0.",
              category: .dotnet, approximateSize: "50 MB"),
        .init(verb: "dotnet452",   displayName: ".NET 4.5.2",
              summary: ".NET Framework 4.5.2. Common minimum for older Unity games.",
              category: .dotnet, approximateSize: "70 MB"),
        .init(verb: "dotnet48",    displayName: ".NET 4.8",
              summary: ".NET Framework 4.8. Most modern .NET Framework target.",
              category: .dotnet, approximateSize: "100 MB"),
        .init(verb: "dotnet6",     displayName: ".NET 6.0",
              summary: ".NET 6 runtime (modern .NET, not Framework).",
              category: .dotnet, approximateSize: "55 MB"),
        .init(verb: "dotnet7",     displayName: ".NET 7.0",
              summary: ".NET 7 runtime.",
              category: .dotnet, approximateSize: "60 MB"),
    ]

    // MARK: - DirectX

    private static let directx: [WinetricksComponent] = [
        .init(verb: "d3dcompiler_43", displayName: "d3dcompiler_43",
              summary: "DirectX 9-era shader compiler DLL. Common for older games.",
              category: .directx, approximateSize: "2 MB"),
        .init(verb: "d3dcompiler_47", displayName: "d3dcompiler_47",
              summary: "Modern DirectX shader compiler. Required by most DirectX 11+ games.",
              category: .directx, approximateSize: "5 MB"),
        .init(verb: "d3dx9",          displayName: "d3dx9",
              summary: "Full DirectX 9 helper library suite.",
              category: .directx, approximateSize: "5 MB"),
        .init(verb: "d3dx11_43",      displayName: "d3dx11_43",
              summary: "DirectX 11 helper library.",
              category: .directx, approximateSize: "2 MB"),
        .init(verb: "dxvk",           displayName: "DXVK (prefix-wide)",
              summary: "Translates DirectX 9 / 10 / 11 → Vulkan → Metal via MoltenVK. Massive perf boost vs WineD3D for most DX11 games.",
              category: .directx, approximateSize: "5 MB",
              warning: "May conflict with GPTK's D3DMetal default. Only install if a specific game needs DXVK — and then enable it on that game's Compatibility sheet."),
    ]

    // MARK: - Media

    private static let media: [WinetricksComponent] = [
        .init(verb: "mf",      displayName: "Media Foundation",
              summary: "Modern Windows multimedia framework. Required by many UE4 / Unity games for video playback.",
              category: .media, approximateSize: "10 MB"),
        .init(verb: "wmp11",   displayName: "Windows Media Player 11",
              summary: "Media playback runtime. Some older games need this.",
              category: .media, approximateSize: "25 MB"),
        .init(verb: "quartz",  displayName: "quartz (DirectShow)",
              summary: "Legacy DirectShow filter graph. Required by some older games for cutscenes.",
              category: .media, approximateSize: "1 MB"),
        .init(verb: "xact",    displayName: "XACT engine",
              summary: "Cross-Platform Audio Creation Tool runtime. Required by some XNA-era games.",
              category: .media, approximateSize: "5 MB"),
    ]

    // MARK: - Fonts

    private static let fonts: [WinetricksComponent] = [
        .init(verb: "corefonts", displayName: "Microsoft Core Fonts",
              summary: "Arial, Times New Roman, Verdana, etc. Fixes blank/wrong fonts in many games.",
              category: .fonts, approximateSize: "5 MB"),
        .init(verb: "cjkfonts",  displayName: "CJK fonts",
              summary: "Chinese / Japanese / Korean fonts. Needed if you play in these languages.",
              category: .fonts, approximateSize: "100 MB"),
        .init(verb: "tahoma",    displayName: "Tahoma",
              summary: "Tahoma font alone (smaller than corefonts).",
              category: .fonts, approximateSize: "1 MB"),
    ]

    // MARK: - Gaming libraries

    private static let gaming: [WinetricksComponent] = [
        .init(verb: "xna40",   displayName: "XNA 4.0 Refresh",
              summary: "Microsoft XNA Framework 4.0. Required by older indie games (e.g., Terraria pre-1.4, original Stardew Valley).",
              category: .gaming, approximateSize: "7 MB"),
        .init(verb: "faudio",  displayName: "FAudio (XAudio2 alt)",
              summary: "Open-source reimplementation of XAudio2. Better audio compatibility for many games than wine's built-in.",
              category: .gaming, approximateSize: "1 MB"),
        .init(verb: "physx",   displayName: "PhysX",
              summary: "NVIDIA PhysX runtime. Required by some older games (Borderlands 2, Mafia II).",
              category: .gaming, approximateSize: "55 MB"),
    ]
}
