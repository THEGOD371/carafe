import Foundation

// MARK: - Enum types

/// Which DirectX → Metal path wine uses for this launch.
///
/// FRAGILITY: switching graphics backends mid-bottle is risky.
/// D3DMetal and DXVK both want to provide d3d11.dll / dxgi.dll —
/// installing the DXVK winetricks verb in a bottle and then leaving
/// the backend on D3DMetal leaves stale .dll files lying around the
/// prefix. The Compat UI warns about this.
enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dMetal = "d3dMetal"   // GPTK's built-in D3D → Metal translator. Default.
    case dxvk     = "dxvk"        // DXVK (DirectX → Vulkan → Metal). Advanced, conflict-prone.

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .d3dMetal: return "D3DMetal (recommended)"
        case .dxvk:     return "DXVK (advanced)"
        }
    }

    var summary: String {
        switch self {
        case .d3dMetal:
            return "Apple's DirectX-to-Metal translator built into GPTK. Best compatibility and performance for most games."
        case .dxvk:
            return "DXVK translates DirectX 9/10/11 → Vulkan → Metal via MoltenVK. Sometimes faster, but the prefix needs the `dxvk` winetricks verb installed, and it conflicts with D3DMetal."
        }
    }
}

/// Wine sync primitive. msync is GPTK's improved Apple-Silicon-specific
/// implementation; esync is the older Linux-derived path.
enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case msync   = "msync"
    case esync   = "esync"
    case off     = "off"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .msync: return "MSYNC (GPTK recommended)"
        case .esync: return "ESYNC (older)"
        case .off:   return "Off (wine default)"
        }
    }

    /// Env vars to set. msync and esync are mutually exclusive —
    /// setting both is undefined behaviour.
    var envContributions: [String: String] {
        switch self {
        case .msync: return ["WINEMSYNC": "1"]
        case .esync: return ["WINEESYNC": "1"]
        case .off:   return [:]
        }
    }
}

// MARK: - Bottle-level defaults

/// Per-bottle defaults for the compat-toggle settings. Carried inside
/// `Bottle.compatDefaults`. Every field has a value — these are the
/// fallbacks when a game doesn't override.
struct BottleCompatDefaults: Codable, Hashable, Sendable {
    var graphicsBackend: GraphicsBackend
    var sync: SyncMode
    var metalHUD: Bool
    var retina: Bool

    static var defaults: BottleCompatDefaults {
        BottleCompatDefaults(
            graphicsBackend: .d3dMetal,
            sync: .msync,
            metalHUD: false,
            retina: false
        )
    }
}

// MARK: - Per-game overrides

/// Per-game overrides for the compat settings. Every field is
/// optional: nil = inherit from the bottle's defaults. Non-nil = use
/// this value for this game only.
///
/// `dllOverrides` and `environment` are full-dict overrides, not
/// merges — nil means "use the bottle's dict verbatim", non-nil means
/// "ignore the bottle's dict entirely and use this one." Simpler
/// mental model than per-key merging; the UI surfaces the dict's
/// current state and a "Reset to bottle default" action.
struct GameCompatOverrides: Codable, Hashable, Sendable {
    var graphicsBackend: GraphicsBackend?
    var sync: SyncMode?
    var windowsVersion: WindowsVersion?
    var metalHUD: Bool?
    var retina: Bool?
    var dllOverrides: [String: String]?
    var environment: [String: String]?

    init(
        graphicsBackend: GraphicsBackend? = nil,
        sync: SyncMode? = nil,
        windowsVersion: WindowsVersion? = nil,
        metalHUD: Bool? = nil,
        retina: Bool? = nil,
        dllOverrides: [String: String]? = nil,
        environment: [String: String]? = nil
    ) {
        self.graphicsBackend = graphicsBackend
        self.sync = sync
        self.windowsVersion = windowsVersion
        self.metalHUD = metalHUD
        self.retina = retina
        self.dllOverrides = dllOverrides
        self.environment = environment
    }

    /// True when every field is nil — pure inheritance, no overrides.
    var isAllInherit: Bool {
        graphicsBackend == nil
            && sync == nil
            && windowsVersion == nil
            && metalHUD == nil
            && retina == nil
            && dllOverrides == nil
            && environment == nil
    }
}

// MARK: - Resolved (launch-time) view

/// What the launcher actually uses. Built by `ResolvedConfig.resolve`
/// from a bottle + optional game overrides. Every field is non-optional
/// — no inheritance remaining.
struct ResolvedConfig: Sendable, Equatable {
    var graphicsBackend: GraphicsBackend
    var sync: SyncMode
    var windowsVersion: WindowsVersion
    var metalHUD: Bool
    var retina: Bool
    var dllOverrides: [String: String]
    var environment: [String: String]
    var arguments: [String]

    /// Build from a bottle only (no game involved). Used by the
    /// run-arbitrary-exe path where there is no library entry.
    static func fromBottle(_ bottle: Bottle, arguments: [String] = []) -> ResolvedConfig {
        ResolvedConfig(
            graphicsBackend: bottle.compatDefaults.graphicsBackend,
            sync: bottle.compatDefaults.sync,
            windowsVersion: bottle.windowsVersion,
            metalHUD: bottle.compatDefaults.metalHUD,
            retina: bottle.compatDefaults.retina,
            dllOverrides: bottle.dllOverrides,
            environment: bottle.environment,
            arguments: arguments
        )
    }

    /// Resolve game overrides on top of bottle defaults. Each
    /// optional field on the game falls through to the corresponding
    /// bottle value when nil.
    static func resolve(game: Game, bottle: Bottle) -> ResolvedConfig {
        let o = game.compatOverrides ?? GameCompatOverrides()
        return ResolvedConfig(
            graphicsBackend: o.graphicsBackend ?? bottle.compatDefaults.graphicsBackend,
            sync:            o.sync            ?? bottle.compatDefaults.sync,
            windowsVersion:  o.windowsVersion  ?? bottle.windowsVersion,
            metalHUD:        o.metalHUD        ?? bottle.compatDefaults.metalHUD,
            retina:          o.retina          ?? bottle.compatDefaults.retina,
            dllOverrides:    o.dllOverrides    ?? bottle.dllOverrides,
            environment:     o.environment     ?? bottle.environment,
            arguments:       game.arguments
        )
    }

    // MARK: - Derived env

    /// DLL overrides actually passed to wine, including the
    /// graphics-backend-driven additions for DXVK.
    var effectiveDLLOverrides: [String: String] {
        var d = dllOverrides
        if graphicsBackend == .dxvk {
            // DXVK ships d3d9/d3d10core/d3d11/dxgi as native DLLs in
            // the prefix (winetricks dxvk verb installs them). Setting
            // these to "n" (native first) makes wine pick DXVK's DLLs
            // instead of its built-in implementations.
            //
            // FRAGILITY: these key names are the wine-canonical
            // ones. If a future DXVK version adds new translator
            // DLLs (e.g., d3d12.dll) this list needs to grow.
            d["d3d11"] = "n"
            d["dxgi"] = "n"
            d["d3d10core"] = "n"
            d["d3d9"] = "n"
        }
        return d
    }

    /// Env vars contributed by the toggles, before merging the
    /// user's bottle/game environment dict.
    var derivedEnvironment: [String: String] {
        var env: [String: String] = [
            "WINEDEBUG": "fixme-all",
        ]
        for (k, v) in sync.envContributions { env[k] = v }
        env["MTL_HUD_ENABLED"] = metalHUD ? "1" : "0"
        if retina {
            // FRAGILITY: MACDRV_RETINA_MODE is GPTK / Apple-specific
            // and the value "on" is what we've observed working —
            // not strictly documented. If a future wine breaks
            // retina support, this is the first place to look.
            env["MACDRV_RETINA_MODE"] = "on"
        }
        return env
    }
}
