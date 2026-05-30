import Foundation

/// Windows version a bottle reports to Windows applications.
/// Stored in metadata, applied to the prefix via `wine reg add HKCU\Software\Wine`.
enum WindowsVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case win7
    case win8
    case win81
    case win10
    case win11

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .win7:  return "Windows 7"
        case .win8:  return "Windows 8"
        case .win81: return "Windows 8.1"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }

    /// Value to write into HKCU\Software\Wine\Version.
    /// FRAGILITY: wine forks (CrossOver, GPTK, vanilla wine) sometimes
    /// disagree on which key actually drives the reported version.
    /// We write the canonical one; per-game config can layer on top.
    var registryValue: String { rawValue }
}

/// A Wine prefix managed by Carafe. `id` doubles as the on-disk
/// folder name — never change it after creation.
struct Bottle: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date?

    /// Human-readable wine version label, e.g. "gptk-3.0-2".
    /// Stored for display; the actual binary is resolved by WineRunner.
    var wineVersion: String

    var windowsVersion: WindowsVersion

    /// dll-name → wine override value ("n", "b", "n,b", "b,n", "")
    var dllOverrides: [String: String]

    /// Extra environment passed to every wine invocation in this bottle.
    var environment: [String: String]

    /// Winetricks verbs we've successfully installed into this
    /// prefix. Used to show "Installed" badges in ComponentsSheet
    /// and to skip already-installed verbs by default. Not the
    /// authoritative source — winetricks itself maintains a ledger
    /// at `<prefix>/winetricks.log` — but ours drives the UI.
    var installedComponents: Set<String>

    /// Bottle-level defaults for the compat toggles. Games can
    /// override individual fields via their own `compatOverrides`.
    var compatDefaults: BottleCompatDefaults

    /// Which Wine binary this bottle runs against — GPTK or
    /// Wine Staging. Set at creation and *not* changeable later in
    /// v1: prefixes contain absolute paths to wine internals and
    /// switching builds in place corrupts them.
    var wineBuild: WineBuild
}

/// On-disk JSON shape. Kept separate from the in-memory `Bottle` so we
/// can evolve the runtime model without breaking the JSON contract,
/// and so we can carry a `schemaVersion` for migrations.
struct BottleMetadata: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var wineVersion: String
    var windowsVersion: WindowsVersion
    var dllOverrides: [String: String]
    var environment: [String: String]

    /// Optional for backward-compat: bottles created before the
    /// components installer landed have no `installedComponents`
    /// key in their metadata.json. `toBottle()` substitutes an
    /// empty set in that case.
    var installedComponents: [String]?

    /// Optional for backward-compat: bottles created before the
    /// per-game compat config milestone have no `compatDefaults`
    /// key. `toBottle()` substitutes `BottleCompatDefaults.defaults`
    /// (D3DMetal / msync / hud off / retina off) in that case.
    var compatDefaults: BottleCompatDefaults?

    /// Optional for backward-compat: bottles created before the
    /// Wine version switcher milestone have no `wineBuild` key.
    /// `toBottle()` substitutes `.gptk` (the only build they could
    /// have been created against).
    var wineBuild: WineBuild?

    init(from bottle: Bottle) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = bottle.id
        self.name = bottle.name
        self.createdAt = bottle.createdAt
        self.lastUsedAt = bottle.lastUsedAt
        self.wineVersion = bottle.wineVersion
        self.windowsVersion = bottle.windowsVersion
        self.dllOverrides = bottle.dllOverrides
        self.environment = bottle.environment
        self.installedComponents = Array(bottle.installedComponents).sorted()
        self.compatDefaults = bottle.compatDefaults
        self.wineBuild = bottle.wineBuild
    }

    func toBottle() -> Bottle {
        Bottle(
            id: id,
            name: name,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            wineVersion: wineVersion,
            windowsVersion: windowsVersion,
            dllOverrides: dllOverrides,
            environment: environment,
            installedComponents: Set(installedComponents ?? []),
            compatDefaults: compatDefaults ?? .defaults,
            wineBuild: wineBuild ?? .gptk
        )
    }
}

/// One entry in the library list. A folder on disk is either a valid
/// parseable bottle or a corrupted one the user can repair / delete.
enum BottleEntry: Identifiable, Hashable {
    case valid(Bottle)
    case corrupted(CorruptedBottle)

    var id: UUID {
        switch self {
        case .valid(let b): return b.id
        case .corrupted(let c): return c.id
        }
    }

    var displayName: String {
        switch self {
        case .valid(let b): return b.name
        case .corrupted(let c): return c.folderName
        }
    }

    var isCorrupted: Bool {
        if case .corrupted = self { return true }
        return false
    }

    var validBottle: Bottle? {
        if case .valid(let b) = self { return b }
        return nil
    }
}

/// A bottle folder we couldn't parse — metadata.json missing,
/// unreadable, schema-mismatched, or the folder name doesn't look
/// like one of ours. We still surface it so the user can repair or
/// delete it, rather than having "orphaned" folders silently take up
/// disk space.
struct CorruptedBottle: Identifiable, Hashable {
    let id: UUID
    let folderURL: URL
    let folderName: String
    let reason: String
}

/// Errors thrown by BottleManager / WineRunner. Each has a userFacing
/// message — UI shows .localizedDescription verbatim.
enum BottleError: LocalizedError, Sendable {
    case bottlesDirectoryUnavailable(String)
    case nameEmpty
    case nameAlreadyExists(String)
    case wineNotInstalled
    case winebootFailed(stage: String, detail: String)
    case copyFailed(String)
    case trashFailed(String)
    case metadataReadFailed(String)
    case metadataWriteFailed(String)
    case repairFailed(String)
    case operationInProgress
    case bottleNoLongerExists

    var errorDescription: String? {
        switch self {
        case .bottlesDirectoryUnavailable(let detail):
            return "Couldn't access the bottles directory: \(detail)"
        case .nameEmpty:
            return "Bottle name can't be empty."
        case .nameAlreadyExists(let name):
            return "A bottle named \"\(name)\" already exists."
        case .wineNotInstalled:
            return "Wine isn't installed. Install Game Porting Toolkit first."
        case .winebootFailed(let stage, let detail):
            return "wineboot \(stage) failed: \(detail)"
        case .copyFailed(let detail):
            return "Copy failed: \(detail)"
        case .trashFailed(let detail):
            return "Couldn't move bottle to Trash: \(detail)"
        case .metadataReadFailed(let detail):
            return "Couldn't read bottle metadata: \(detail)"
        case .metadataWriteFailed(let detail):
            return "Couldn't write bottle metadata: \(detail)"
        case .repairFailed(let detail):
            return "Repair failed: \(detail)"
        case .operationInProgress:
            return "Another bottle operation is already running. Wait for it to finish."
        case .bottleNoLongerExists:
            return "That bottle no longer exists on disk."
        }
    }
}
