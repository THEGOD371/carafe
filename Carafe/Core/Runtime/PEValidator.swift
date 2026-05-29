import Foundation

/// PE-format inspection. Two checks:
///   - `looksLikePE(at:)` — cheap "MZ" header probe (the same check
///     we've used since the run-an-exe milestone).
///   - `architecture(of:)` — reads the PE header's Machine field so
///     the launcher can pre-flight block i386 binaries (GPTK only
///     supports x86_64 / arm64; trying to launch a 32-bit PE yields
///     the cryptic ShellExecuteEx error we want to avoid).
///
/// PE format layout we care about:
///   offset 0x00          MZ signature (2 bytes)
///   offset 0x3C          UInt32 LE → file offset of the PE header
///   at that offset       "PE\0\0" (4 bytes)
///   + 4 bytes after that UInt16 LE Machine type
enum PEValidator {

    /// PE Machine field values, per Microsoft's PE/COFF spec. We
    /// only enumerate the ones a Windows app on Apple Silicon could
    /// plausibly be — i386, amd64, arm64 — plus an unknown bucket
    /// for everything else.
    enum Architecture: Sendable, Equatable {
        case i386      // 0x014c — 32-bit x86, NOT supported by GPTK
        case amd64     // 0x8664 — 64-bit x86, the common case
        case arm64     // 0xAA64 — uncommon for games, technically OK
        case unknown(UInt16)

        var displayName: String {
            switch self {
            case .i386:           return "32-bit (x86)"
            case .amd64:          return "64-bit (x86_64)"
            case .arm64:          return "ARM64"
            case .unknown(let v): return String(format: "Unknown PE machine 0x%04X", v)
            }
        }

        /// True if GPTK can run this architecture.
        /// FRAGILITY: arm64 PE binaries do exist (Windows on ARM) but
        /// are vanishingly rare in gaming and GPTK's support is
        /// uncertain. We pass them through optimistically — if they
        /// fail, the error surfaces at wine launch time.
        var isSupported: Bool {
            switch self {
            case .amd64, .arm64: return true
            case .i386, .unknown: return false
            }
        }
    }

    /// Returns true if the file starts with the "MZ" DOS header.
    /// .dll / .sys / .exe / .ocx / .scr all qualify; .msi does not.
    static func looksLikePE(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
        return data[0] == 0x4D && data[1] == 0x5A
    }

    /// Read the PE Machine field. nil if the file isn't a PE, the PE
    /// header offset is malformed, or the "PE\0\0" signature is
    /// missing. Fully synchronous — only reads ~10 bytes from disk.
    static func architecture(of url: URL) -> Architecture? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // --- MZ header ---
        try? handle.seek(toOffset: 0)
        guard let mz = try? handle.read(upToCount: 2), mz.count == 2,
              mz[0] == 0x4D, mz[1] == 0x5A else { return nil }

        // --- PE header offset at 0x3C (LE UInt32) ---
        try? handle.seek(toOffset: 0x3C)
        guard let offBytes = try? handle.read(upToCount: 4), offBytes.count == 4 else { return nil }
        let peOffset =
              UInt32(offBytes[0])
            | UInt32(offBytes[1]) << 8
            | UInt32(offBytes[2]) << 16
            | UInt32(offBytes[3]) << 24

        // Sanity: a sane PE header starts somewhere in the first
        // few KB. Reject offsets that would be larger than the
        // file or absurdly small.
        guard peOffset >= 0x40, peOffset < 1_000_000 else { return nil }

        // --- "PE\0\0" + Machine word ---
        try? handle.seek(toOffset: UInt64(peOffset))
        guard let header = try? handle.read(upToCount: 6), header.count == 6 else { return nil }
        guard header[0] == 0x50, header[1] == 0x45,
              header[2] == 0x00, header[3] == 0x00 else { return nil }

        let machine = UInt16(header[4]) | UInt16(header[5]) << 8
        switch machine {
        case 0x014c: return .i386
        case 0x8664: return .amd64
        case 0xAA64: return .arm64
        default:     return .unknown(machine)
        }
    }

    /// Lower-cased extension without the dot. nil if no extension.
    static func ext(of url: URL) -> String? {
        let value = url.pathExtension.lowercased()
        return value.isEmpty ? nil : value
    }

    // MARK: - Launchability policy

    /// Result of `evaluateLaunchability(at:build:)`. Three buckets:
    ///   - `ok`           Launch is fine; no message to surface.
    ///   - `warning(msg)` Launch is allowed but the user should
    ///                    know there's risk (e.g., 32-bit binary on
    ///                    a Wine Staging bottle's WoW64 path).
    ///   - `block(msg)`   Refuse to launch. UI surfaces the message
    ///                    as a hard error.
    enum LaunchAuthorization: Equatable, Sendable {
        case ok
        case warning(String)
        case block(String)
    }

    /// Filenames whose architecture check we skip entirely. These
    /// are known 32-bit launchers that themselves invoke 64-bit
    /// children once started — refusing to run them on the basis
    /// of their own architecture is a false positive.
    ///
    /// FRAGILITY: filename comparison only — a renamed copy
    /// (`Steam_backup.exe`) won't be bypassed. Acceptable: the user
    /// is being deliberate at that point.
    static let architectureCheckBypassFilenames: Set<String> = [
        "steam.exe",
    ]

    /// True when the executable's filename is on the bypass list
    /// (case-insensitive).
    static func shouldBypassArchitectureCheck(_ url: URL) -> Bool {
        architectureCheckBypassFilenames.contains(url.lastPathComponent.lowercased())
    }

    /// Centralised decision for "is it OK to launch this exe in a
    /// bottle of this build?" Used by:
    ///   - `RunSession.start`              (pre-flight before spawning)
    ///   - `GameFormSheet.pickExecutable`  (block bad picks up front)
    ///   - `LaunchExeSheet.pickExecutable` (same, for the ad-hoc launcher)
    ///   - `GameFormSheet.architectureLabel` (badge under the picked path)
    ///
    /// Rules in order:
    ///   1. `.msi` files are always OK — wine routes them via msiexec.
    ///   2. Non-PE files (no MZ magic) are always blocked.
    ///   3. Whitelisted filenames (Steam.exe) skip the arch check.
    ///   4. Architecture readout decides:
    ///        - amd64 / arm64 → ok
    ///        - i386 / unknown on .gptk → block (no WoW64)
    ///        - i386 / unknown on .wineStaging → warning (WoW64 may work)
    static func evaluateLaunchability(
        at url: URL,
        build: WineBuild
    ) -> LaunchAuthorization {
        // 1. .msi: trust.
        if ext(of: url) == "msi" { return .ok }

        // 2. No PE header → not a Windows executable.
        if !looksLikePE(at: url) {
            return .block(
                "\(url.lastPathComponent) doesn't look like a Windows executable (no MZ header)."
            )
        }

        // 3. Bypass list — Steam.exe and friends.
        if shouldBypassArchitectureCheck(url) { return .ok }

        // 4. Read the machine field.
        guard let arch = architecture(of: url) else {
            // Couldn't read the PE header. Don't block on this —
            // the file passed the MZ check, so it's *probably* a
            // valid PE we just couldn't classify.
            return .ok
        }
        if arch.isSupported { return .ok }

        // Unsupported architecture (i386 or unknown). Decision
        // depends on what the bottle's wine can actually run.
        switch build {
        case .gptk:
            return .block(
                """
                \(url.lastPathComponent) is a \(arch.displayName) executable. \
                Apple's Game Porting Toolkit only supports 64-bit (x86_64) apps — \
                this won't run.

                Look for a 64-bit build of the game or app; many titles ship both. \
                If this is a known 32-bit launcher that invokes 64-bit children, \
                switch the bottle to Wine Staging — its WoW64 layer can handle them.
                """
            )
        case .wineStaging:
            return .warning(
                "\(url.lastPathComponent) is a \(arch.displayName) executable. It may work via Wine Staging's WoW64 support, but isn't guaranteed."
            )
        }
    }
}
