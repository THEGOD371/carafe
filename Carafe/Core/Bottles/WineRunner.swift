import Foundation

/// All Wine binary invocations live here. Carafe never shells out to
/// `wine64` from anywhere else — this is the single chokepoint for
/// argument escaping, environment building, and FRAGILITY notes about
/// wine-version differences.
///
/// Per-build resolution: every wine invocation now needs to know
/// which `WineBuild` it's targeting. Callers that have a `Bottle`
/// pass `bottle.wineBuild`; ones that don't (the GPTK dependency
/// checker, the `detectWineVersion` probe) default to `.gptk`.
enum WineRunner {

    // MARK: - Paths

    /// Canonical Apple-Silicon GPTK install location. Set by
    /// `brew install --cask gcenx/wine/game-porting-toolkit`.
    /// Exposed as a constant for the dep checker — most callers
    /// should route through `wine64Path(for:)` instead.
    static let gptkWine64Path = "/opt/homebrew/bin/wine64"
    static let gptkWineserverPath = "/opt/homebrew/bin/wineserver"

    /// Resolve the wine binary path for a given build.
    ///
    /// FRAGILITY: the binary's *name* differs per build. GPTK ships
    /// a separate `wine64` (the old Wine convention pre-8.0). Modern
    /// Wine (and therefore Wine Staging 11.9) ships a single unified
    /// `wine` binary that handles both 32-bit and 64-bit PE files.
    /// The method name `wine64Path(for:)` is preserved for API
    /// compatibility with the wider Carafe codebase — what it
    /// returns is whichever binary actually exists for the build.
    static func wine64Path(for build: WineBuild) -> String {
        switch build {
        case .gptk:        return gptkWine64Path
        case .wineStaging: return WineStagingInstaller.winePath
        }
    }

    /// Resolve the wineserver binary path for a given build.
    static func wineserverPath(for build: WineBuild) -> String {
        switch build {
        case .gptk:        return gptkWineserverPath
        case .wineStaging: return WineStagingInstaller.wineserverPath
        }
    }

    /// True if the wine64 binary for this build is present and
    /// executable. Cheap; used to short-circuit operations before
    /// they shell out.
    static func isWineAvailable(for build: WineBuild) -> Bool {
        FileManager.default.isExecutableFile(atPath: wine64Path(for: build))
    }

    /// Backward-compat for callers that pre-date the wine-build
    /// switcher and just need to know "is GPTK installed?" Same as
    /// `isWineAvailable(for: .gptk)`.
    static var isWineAvailable: Bool { isWineAvailable(for: .gptk) }

    // MARK: - Environment

    /// Build the env dictionary for a wine invocation in a given
    /// prefix. Includes WINEPREFIX, PATH, the wine binary path
    /// hints (so wine64 finds its sibling tools regardless of
    /// build), and the caller's overrides.
    static func environment(
        for prefix: URL,
        build: WineBuild = .gptk,
        dllOverrides: [String: String] = [:],
        bottleEnvironment: [String: String] = [:],
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix.path,
            // Pin WINE / WINESERVER so subprocesses (winetricks,
            // wineboot helpers) pick up the same build we're using.
            // Without these, they'd PATH-search and might find a
            // *different* wine for the same prefix — chaos.
            "WINE": wine64Path(for: build),
            "WINESERVER": wineserverPath(for: build),
            // PATH still needed for tools like /usr/bin/tar and the
            // wine-staging install's sibling binaries which live in
            // a non-standard location.
            "PATH": ShellRunner.defaultPath,
        ]

        if !dllOverrides.isEmpty {
            env["WINEDLLOVERRIDES"] = dllOverridesString(dllOverrides)
        }

        // Bottle-level env, then explicit extras, both override defaults.
        for (k, v) in bottleEnvironment { env[k] = v }
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Serialize a [name: mode] dict into wine's WINEDLLOVERRIDES syntax:
    /// `name1=mode1;name2,name3=mode2`. We don't try to merge entries
    /// with the same mode — clarity beats compactness here.
    static func dllOverridesString(_ overrides: [String: String]) -> String {
        overrides
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    // MARK: - wineboot --init

    /// Initialize a fresh prefix. The prefix folder must already exist
    /// (BottleManager creates it). Streams stderr line-by-line via
    /// `onLine`. Blocks until wineboot finishes, which on a clean
    /// install is 20–60 seconds (longer on Wine Staging because the
    /// upstream build does more bootstrap work).
    ///
    /// FRAGILITY (1): wineboot's stderr is informally formatted and
    /// changes between wine versions. We pass it through unfiltered;
    /// downstream code uses it for log display, not parsing.
    ///
    /// FRAGILITY (2): we set `WINEDLLOVERRIDES=mscoree,mshtml=` for
    /// the init only. This suppresses the Mono / Gecko download
    /// prompts that would otherwise stall wineboot waiting for a GUI
    /// the user can't see.
    ///
    /// FRAGILITY (3): the only signal we get for "wineboot ran to
    /// completion" is exit code 0. There's no structured progress.
    static func wineboot(
        prefix: URL,
        build: WineBuild = .gptk,
        onLine: @Sendable @escaping (String) -> Void
    ) async throws {
        guard isWineAvailable(for: build) else {
            throw BottleError.wineNotInstalled
        }

        var env = environment(for: prefix, build: build)
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="

        onLine("Initializing prefix at \(prefix.path) using \(build.shortName)…")

        var lastStderr: [String] = []
        for try await event in ShellRunner.stream(
            wine64Path(for: build),
            arguments: ["wineboot", "--init"],
            environment: env
        ) {
            switch event {
            case .stdout(let line):
                onLine(line)
            case .stderr(let line):
                onLine(line)
                lastStderr.append(line)
                if lastStderr.count > 40 { lastStderr.removeFirst() }
            case .exit(let code):
                if code != 0 {
                    let tail = lastStderr.suffix(10).joined(separator: "\n")
                    throw BottleError.winebootFailed(
                        stage: "--init",
                        detail: "exit \(code)\n\(tail)"
                    )
                }
            }
        }

        onLine("Prefix initialized.")
    }

    // MARK: - Windows version

    /// Best-effort write of HKCU\Software\Wine\Version. Logged on
    /// failure but not thrown — the bottle still works at whatever
    /// version wine picked by default, and per-game config can retry.
    static func setWindowsVersion(
        prefix: URL,
        version: WindowsVersion,
        build: WineBuild = .gptk,
        onLine: @Sendable @escaping (String) -> Void
    ) async {
        onLine("Setting Windows version to \(version.displayName)…")
        do {
            let result = try await ShellRunner.runToCompletion(
                wine64Path(for: build),
                arguments: [
                    "reg", "add",
                    #"HKCU\Software\Wine"#,
                    "/v", "Version",
                    "/t", "REG_SZ",
                    "/d", version.registryValue,
                    "/f",
                ],
                environment: environment(for: prefix, build: build)
            )
            if !result.didSucceed {
                onLine("Note: setting Windows version exited \(result.exitCode). Bottle will use default; you can retry from per-game config.")
            }
        } catch {
            onLine("Note: couldn't set Windows version: \(error.localizedDescription)")
        }
    }

    // MARK: - winecfg

    /// Launch winecfg as a detached GUI. Doesn't wait for the user
    /// to close it.
    static func launchWinecfg(prefix: URL, build: WineBuild = .gptk) async throws {
        guard isWineAvailable(for: build) else { throw BottleError.wineNotInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [wine64Path(for: build), "winecfg"]

        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment(for: prefix, build: build) { env[k] = v }
        process.environment = env

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
    }

    // MARK: - wineserver shutdown

    /// Gracefully stop the wineserver for a prefix. Useful before
    /// deleting / duplicating a bottle so we're not racing live
    /// file handles. Best-effort — failure is logged, not thrown.
    static func shutdownWineserver(prefix: URL, build: WineBuild = .gptk) async {
        _ = try? await ShellRunner.runToCompletion(
            wineserverPath(for: build),
            arguments: ["-k"],
            environment: environment(for: prefix, build: build)
        )
    }

    /// Stop Steam-specific Wine processes in a prefix, then sweep the
    /// wineserver. Steam can leave detached CEF/service children alive
    /// after the wrapper `Steam.exe` exits; those children hold singleton
    /// locks and make the next launch open to a broken/blank UI. Running
    /// Wine's own `taskkill` keeps this scoped to the target prefix.
    ///
    /// FRAGILITY: Steam process names are stable today
    /// (`Steam.exe`, `steamwebhelper.exe`, `steamservice.exe`), but Valve
    /// can rename helper binaries. If a future log shows new stale Steam
    /// children, add them here before falling back to broad macOS `pkill`.
    static func shutdownSteamProcesses(prefix: URL, build: WineBuild = .gptk) async {
        let targets = ["Steam.exe", "steamwebhelper.exe", "steamservice.exe"]
        for target in targets {
            _ = try? await ShellRunner.runToCompletion(
                wine64Path(for: build),
                arguments: ["taskkill", "/F", "/IM", target],
                environment: environment(for: prefix, build: build)
            )
        }
        await shutdownWineserver(prefix: prefix, build: build)
    }
}
