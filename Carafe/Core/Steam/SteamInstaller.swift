import Foundation

/// Service for installing Steam's Windows client into a Carafe bottle.
///
/// Pipeline:
///   1. Ensure vcrun2022 (or 2019) is present.
///   2. Download SteamSetup.exe to the shared cache.
///   3. Run SteamSetup.exe /S inside the bottle (silent NSIS install).
///   4. Verify Steam.exe at the canonical path.
///   5. Configure Steam UI workarounds.
///
/// All steps are independent async methods so the UI can run them in
/// sequence and surface per-step success/failure independently.
///
/// ## ⚠️ The Wine 7.7 ceiling
///
/// Apple's Game Porting Toolkit (the Gcenx cask we install in
/// onboarding) is based on **Wine 7.7** from 2023. Current Steam's
/// CEF/Chromium-based UI components (steamwebhelper.exe and the
/// React-based login) require Wine 8+ to render reliably. On
/// Wine 7.7 you see the classic "steamwebhelper is not responding"
/// dialog within a minute or two of launch; Steam's own
/// "Restart with Browser Sandboxing disabled" recovery option
/// doesn't permanently fix it.
///
/// Carafe's mitigation is now split by Wine build:
///
///   - GPTK / Wine 7.7: legacy fallback. Rename steamwebhelper.exe
///     after bootstrap because modern CEF does not survive here.
///   - Wine Staging: modern Steam UI mode. Keep steamwebhelper.exe
///     and disable CEF GPU / problematic Wine DLLs instead.
///
/// The practical fix is a newer wine. Carafe's Steam bottle path now
/// uses Wine Staging and keeps modern CEF enabled instead of trying
/// to force Steam's removed legacy UI.
///
/// ## ⚠️ Auto-update can undo UI setup
///
/// Steam's self-update runs often and can replace both Steam.exe and
/// steamwebhelper.exe. For Wine Staging we keep webhelper enabled and
/// re-apply the CEF GPU/DLL overrides whenever the user reruns
/// "Install Steam in Bottle…". For GPTK's older Wine 7.7 fallback we
/// still rename webhelper after bootstrap, but that mode is only kept
/// as a degraded fallback.
///
/// ## ⚠️ Canonical Steam-on-Wine workaround
///
/// Applied uniformly across `launchSteamGUI` (env + flags) and the
/// install pipeline (nocrashdialog winetricks verb). Source of
/// truth: [Winetricks PR #1975](https://github.com/Winetricks/winetricks/pull/1975),
/// which is the upstream-community-blessed reference for Wine bugs
/// 44985 (Store/Library/login black screen) and 49839
/// (steamwebhelper.exe crashes on macOS).
///
/// Pieces:
///   - Env: `WINEDLLOVERRIDES="libglesv2=disabled;dcomp=disabled"`
///   - Env: `METAL_DEVICE_WRAPPER_TYPE=1`
///   - Wine Staging flags: `-no-cef-sandbox -cef-disable-gpu
///            -cef-disable-gpu-compositing -cef-in-process-gpu
///            -windowed -allosarches`
///   - GPTK legacy flags: `-no-cef-sandbox -noreactlogin
///            -nofriendsui -skipinitialbootstrap -windowed
///            -allosarches -cef-force-32bit -cef-in-process-gpu`
///   - Winetricks: `nocrashdialog` (suppresses wine's modal crash
///     dialog when `vulkandriverquery` / `vulkandriverquery64`
///     misbehave on macOS).
///
/// All inline-documented at the call sites — search for "PR #1975"
/// to find them. Pieces of this fix were rolled out across multiple
/// debugging milestones; this is the consolidation that applies
/// them all together as upstream intends.
///
/// ## ⚠️ Original FRAGILITY (still applies)
///
/// 1. **Installer URL stability.** `cdn.cloudflare.steamstatic.com`
///    has hosted SteamSetup.exe for years but it's not Valve's
///    official documented endpoint. If Valve moves the file, this
///    URL goes 404 silently. If we see download failures across
///    multiple bottles, this is the first thing to check.
///
/// 2. **`/S` silent flag.** Steam's installer is NSIS. NSIS accepts
///    `/S` (uppercase, case-sensitive) for silent install. Lowercase
///    `/s` is ignored. If a future Steam installer switches packaging
///    (MSIX, MSIX-App-Installer, etc.) the flag stops working.
///
/// 3. **Default install location.** Steam's installer respects user
///    choice of install path, but `/S` always picks the default
///    (`C:\Program Files (x86)\Steam`). We pin our verification to
///    that path. Manual / GUI installs to elsewhere won't be
///    detected by SteamLibraryScanner without code changes.
///
/// 4. **steamwebhelper.exe location.** Steam moves CEF between
///    subdirectories over time (cef.win7, cef.win7x64, cef.win64,
///    etc.). The legacy GPTK fallback uses a recursive search rather
///    than hardcoded paths. For Wine Staging, seeing webhelper present
///    is good: current Steam needs it to draw login/library UI.
///
/// 5. **Removed Steam flags.** `-noreactlogin` (and `-no-browser`)
///    were deprecated by Valve in the 2023 Steam Client Beta and
///    are silently ignored in current clients. We pass them anyway
///    — Steam tolerates unknown flags gracefully, and on older
///    Steam clients (e.g. inside a long-running bottle that hasn't
///    updated yet) they still help.
enum SteamInstaller {

    /// Canonical Cloudflare-hosted Steam installer stub. ~3 MB; the
    /// real Steam client (~500 MB) downloads on first launch of
    /// Steam.exe itself, not at install time.
    static let installerDownloadURL = URL(
        string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
    )!

    /// Steam's current Windows client can still spawn the old
    /// `bin/gldriverquery.exe` helper, which imports SDL2.dll.
    /// Current Steam packages may only ship SDL3.dll, leaving Wine
    /// to fail with:
    ///
    ///     Library SDL2.dll (needed by ...\Steam\bin\gldriverquery.exe) not found
    ///
    /// Use SDL's official VC development archive instead of DLL
    /// mirror sites. We install the 32-bit DLL into Steam/bin
    /// because the failing helper is `gldriverquery.exe` (not
    /// `gldriverquery64.exe`).
    ///
    /// FRAGILITY: this is pinned to an SDL2 release URL. If SDL
    /// removes old GitHub release assets, bump `sdl2Version` and
    /// keep `sdl2ArchivePath` in sync with the archive layout.
    private static let sdl2Version = "2.32.10"
    private static let sdl2ArchivePath = "SDL2-\(sdl2Version)/lib/x86/SDL2.dll"
    private static var sdl2DownloadURL: URL {
        URL(
            string: "https://github.com/libsdl-org/SDL/releases/download/release-\(sdl2Version)/SDL2-devel-\(sdl2Version)-VC.zip"
        )!
    }

    /// Shared installer cache so a single download serves every
    /// bottle the user creates.
    static var cachedInstallerURL: URL {
        let dir = AppState.supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SteamSetup.exe")
    }

    /// True if the cached installer exists and is bigger than a
    /// plausible "real installer" floor — guards against half-
    /// downloaded files left over from an aborted prior run.
    static var isInstallerCached: Bool {
        let url = cachedInstallerURL
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > 1_000_000 // > 1 MB sanity floor
        else {
            return false
        }
        return true
    }

    // MARK: - Pipeline steps

    /// Step 1. Ensure a working Visual C++ 2015–2022 runtime is
    /// present in the bottle. Returns `true` if we actually installed
    /// vcrun2022 (so the caller can mark it in the ledger); `false`
    /// if an equivalent runtime was already present and we skipped.
    ///
    /// FRAGILITY: vcrun2019 and vcrun2022 both ship the Universal CRT
    /// + Visual C++ 2015–2019 (14.2x) runtime DLLs. Winetricks does
    /// NOT refuse the second install, but layering them produces
    /// mixed DLL versions in the prefix that can confuse Steam +
    /// some games. Skipping when either is present avoids that.
    /// If we ever need to *upgrade* a bottle from 2019 → 2022 (e.g.
    /// for a game that needs the newer 14.3x DLLs) we'll add an
    /// explicit "force reinstall" hook then.
    @discardableResult
    static func ensureVCRuntimeInstalled(
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) async throws -> Bool {
        if bottle.installedComponents.contains("vcrun2022") {
            log("vcrun2022 already installed in this bottle — skipping.")
            return false
        }
        if bottle.installedComponents.contains("vcrun2019") {
            log("vcrun2019 already installed and covers the same Universal CRT + Visual C++ 2015–2019 DLLs as vcrun2022 — skipping the install to avoid mixed-version conflicts.")
            return false
        }
        guard WinetricksRunner.isInstalled else {
            throw Failure.winetricksMissing
        }
        log("Installing vcrun2022 (~25 MB, takes a few minutes)…")
        try await WinetricksRunner.installVerb("vcrun2022", in: bottle, log: log)
        return true
    }

    /// Step 2. Download SteamSetup.exe to the shared cache. Reuses
    /// the cached file if present + non-truncated. Returns the local
    /// file URL.
    static func ensureInstallerDownloaded(
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let dest = cachedInstallerURL
        if isInstallerCached {
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            log("Using cached installer (\(formatBytes(size))).")
            return dest
        }

        log("Downloading SteamSetup.exe from \(installerDownloadURL.host ?? "Valve CDN")…")
        var request = URLRequest(url: installerDownloadURL)
        request.timeoutInterval = 120

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.downloadFailed("HTTP \(http.statusCode) from Valve CDN.")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            log("Downloaded SteamSetup.exe (\(formatBytes(size))).")
            return dest
        } catch let err as Failure {
            throw err
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
    }

    /// Step 3. Run SteamSetup.exe /S inside the bottle. Streams wine
    /// output. Verifies Steam.exe lands at the canonical path before
    /// returning success.
    static func runInstaller(
        installerURL: URL,
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        guard WineRunner.isWineAvailable(for: bottle.wineBuild) else { throw Failure.wineMissing }

        log("Launching SteamSetup.exe inside the bottle (silent /S install) using \(bottle.wineBuild.shortName)…")

        // Build env mirroring RunSession's approach but pared down —
        // we're not running a game, just an installer.
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixURL.path
        env["WINE"] = WineRunner.wine64Path(for: bottle.wineBuild)
        env["WINESERVER"] = WineRunner.wineserverPath(for: bottle.wineBuild)
        env["PATH"] = ShellRunner.defaultPath
        env["WINEDEBUG"] = "fixme-all"
        // Steam's NSIS installer respects msync just like Steam
        // itself, and msync is what we'd use anyway for the bottle.
        env["WINEMSYNC"] = "1"

        var lastErrorLines: [String] = []
        for try await event in ShellRunner.stream(
            WineRunner.wine64Path(for: bottle.wineBuild),
            arguments: [installerURL.path, "/S"],
            environment: env
        ) {
            switch event {
            case .stdout(let line):
                log(line)
            case .stderr(let line):
                log(line)
                lastErrorLines.append(line)
                if lastErrorLines.count > 30 { lastErrorLines.removeFirst() }
            case .exit(let code):
                if code != 0 {
                    let tail = lastErrorLines.suffix(8).joined(separator: "\n")
                    throw Failure.installerFailed(
                        "SteamSetup.exe exited \(code).\n\nLast output:\n\(tail)"
                    )
                }
            }
        }

        guard SteamLibraryScanner.hasSteam(in: bottle) else {
            throw Failure.installerFailed(
                "Installer reported success but Steam.exe isn't at the canonical path (\(SteamLibraryScanner.steamExeSubpath)). Steam may have installed elsewhere — try re-running with the default install location."
            )
        }
        log("Steam.exe verified at the canonical path.")
    }

    /// Repair runtime helper DLLs Steam's self-update sometimes
    /// omits. Called both by generic RunSession Steam launches and
    /// safe to call after the install pipeline; no-op if the files
    /// already exist.
    static func ensureSteamSupportDLLs(
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        guard SteamLibraryScanner.hasSteam(in: bottle) else { throw Failure.steamNotInstalled }

        let steamBin = SteamLibraryScanner.steamInstallURL(for: bottle)
            .appendingPathComponent("bin", isDirectory: true)
        let glDriverQuery = steamBin.appendingPathComponent("gldriverquery.exe")
        let sdl2Destination = steamBin.appendingPathComponent("SDL2.dll")

        guard FileManager.default.fileExists(atPath: glDriverQuery.path) else {
            log("Steam helper gldriverquery.exe is not present — SDL2 repair not needed.")
            return
        }

        if fileSize(sdl2Destination) > 0 {
            log("✓ Steam SDL2.dll already present in Steam/bin.")
            return
        }

        log("Steam helper gldriverquery.exe needs SDL2.dll; installing official SDL2 \(sdl2Version) runtime into Steam/bin…")
        let zip = try await ensureSDL2ArchiveDownloaded(log: log)
        let staged = try await extractSDL2DLL(from: zip, log: log)

        try FileManager.default.createDirectory(
            at: sdl2Destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: sdl2Destination)
        try FileManager.default.copyItem(at: staged, to: sdl2Destination)
        _ = try? await ShellRunner.runToCompletion(
            "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", sdl2Destination.path]
        )

        guard fileSize(sdl2Destination) > 0 else {
            throw Failure.installerFailed("SDL2.dll copy completed but Steam/bin/SDL2.dll is still missing.")
        }

        log("✓ Installed SDL2.dll for Steam's gldriverquery.exe helper.")
    }

    private static func ensureSDL2ArchiveDownloaded(
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let dir = AppState.supportDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("SteamSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent("SDL2-devel-\(sdl2Version)-VC.zip")
        if fileSize(dest) > 1_000_000 {
            log("Using cached SDL2 \(sdl2Version) archive (\(formatBytes(fileSize(dest)))).")
            return dest
        }

        log("Downloading SDL2 \(sdl2Version) from libsdl-org…")
        var request = URLRequest(url: sdl2DownloadURL)
        request.timeoutInterval = 180

        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw Failure.downloadFailed("SDL2 \(sdl2Version): HTTP \(http.statusCode).")
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            log("Downloaded SDL2 archive (\(formatBytes(fileSize(dest)))).")
            return dest
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.downloadFailed("SDL2 \(sdl2Version): \(error.localizedDescription)")
        }
    }

    private static func extractSDL2DLL(
        from zip: URL,
        log: @Sendable @escaping (String) -> Void
    ) async throws -> URL {
        let extractDir = AppState.supportDirectory
            .appendingPathComponent("SteamSupport", isDirectory: true)
            .appendingPathComponent("SDL2-\(sdl2Version)", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        log("Extracting SDL2.dll from SDL2-devel-\(sdl2Version)-VC.zip…")
        let result = try await ShellRunner.runToCompletion(
            "/usr/bin/unzip",
            arguments: ["-q", zip.path, sdl2ArchivePath, "-d", extractDir.path]
        )
        guard result.exitCode == 0 else {
            throw Failure.installerFailed(
                "Couldn't extract SDL2.dll from SDL archive (unzip exited \(result.exitCode)). \(result.stderr)"
            )
        }

        let staged = extractDir.appendingPathComponent(sdl2ArchivePath)
        guard fileSize(staged) > 0 else {
            throw Failure.installerFailed("SDL2 archive extracted but \(sdl2ArchivePath) was not found.")
        }
        return staged
    }

    /// Steam launch flags for the GPTK / Wine 7.7 legacy fallback.
    /// The set below is the **canonical Wine + Steam macOS workaround**
    /// from [Winetricks PR #1975](https://github.com/Winetricks/winetricks/pull/1975),
    /// which is the upstream-community-blessed reference. Apply ALL
    /// of them together — partial application is what kept biting
    /// us across the steamwebhelper / steamui.dll / black-window
    /// debugging milestones.
    ///
    ///   - `-no-cef-sandbox`        Chromium sandbox can't init on wine.
    ///   - `-noreactlogin`          Skip React/Chromium login UI;
    ///                              deprecated in 2023+ clients but
    ///                              still honoured by older Steam
    ///                              and harmless on newer ones.
    ///   - `-nofriendsui`           Don't initialize the Chromium-
    ///                              based friends panel.
    ///   - `-skipinitialbootstrap`  Skip Steam's bootstrap UI
    ///                              animation which uses CEF.
    ///   - `-windowed`              Force Steam into a regular window
    ///                              (not borderless / chromeless).
    ///   - `-allosarches`           **macOS workaround for wine bug
    ///                              49839** — allow all architecture
    ///                              variants for CEF.
    ///   - `-cef-force-32bit`       **macOS workaround for wine bug
    ///                              49839** — force 32-bit CEF child
    ///                              process; wine on macOS handles
    ///                              the 32-bit CEF better than the
    ///                              64-bit one (matches Steam.exe's
    ///                              own 32-bit launcher).
    ///   - `-cef-in-process-gpu`    **macOS workaround for wine bug
    ///                              49839** — run CEF's GPU process
    ///                              in-process rather than spawning
    ///                              a separate one (the separate
    ///                              spawn crashes hard on Mac).
    static let legacySteamLaunchFlags = [
        "-no-cef-sandbox",
        "-noreactlogin",
        "-nofriendsui",
        "-skipinitialbootstrap",
        "-windowed",
        "-allosarches",
        "-cef-force-32bit",
        "-cef-in-process-gpu",
    ]

    /// Steam launch flags for Wine Staging's modern CEF UI.
    ///
    /// The old `-noreactlogin`, `-nofriendsui`, and
    /// `-skipinitialbootstrap` flags are deliberately absent here:
    /// current Steam is CEF-first, so trying to suppress CEF tends to
    /// produce the exact "nothing useful appears" behavior users see.
    ///
    /// Sources checked during the 2026 refresh:
    ///   - Steam's own steamwebhelper help recommends restarting with
    ///     GPU acceleration disabled for rendering failures.
    ///   - ValveSoftware/steam-for-linux#10561 documents black UI
    ///     recovering with `-cef-disable-gpu`.
    ///   - Wine bug 44985 / WineHQ forum guidance still points at
    ///     disabling `libglesv2` for CEF black windows.
    static let modernSteamLaunchFlags = [
        "-no-cef-sandbox",
        "-cef-disable-gpu",
        "-cef-disable-gpu-compositing",
        "-cef-in-process-gpu",
        "-windowed",
        "-allosarches",
    ]

    static func steamLaunchFlags(for build: WineBuild) -> [String] {
        switch build {
        case .gptk: return legacySteamLaunchFlags
        case .wineStaging: return modernSteamLaunchFlags
        }
    }

    static func isSteamExecutable(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare("steam.exe") == .orderedSame
    }

    /// Add Steam's Wine/macOS compatibility flags without duplicating
    /// flags the library entry already stores, e.g. `-applaunch 1245620`.
    static func augmentedLaunchArguments(
        _ existing: [String],
        for build: WineBuild
    ) -> [String] {
        var result = existing
        let present = Set(existing.map { $0.lowercased() })
        for flag in steamLaunchFlags(for: build) where !present.contains(flag.lowercased()) {
            result.append(flag)
        }
        return result
    }

    /// Runtime Steam environment shared by both the dedicated
    /// "Launch Steam" button and generic library `RunSession`s that
    /// point at Steam.exe. This keeps Steam tiles and `-applaunch`
    /// entries from accidentally bypassing the CEF black-window fixes.
    static func applySteamLaunchEnvironment(to env: inout [String: String], bottle: Bottle) {
        env["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
        env["WINEDLLOVERRIDES"] = "libglesv2=disabled;dcomp=disabled"
        env["METAL_DEVICE_WRAPPER_TYPE"] = "1"

        if bottle.wineBuild == .gptk {
            // Legacy fallback only. On Wine Staging this breaks the
            // current Steam client because the modern UI is CEF.
            env["STEAM_DISABLE_BROWSER"] = "1"
        } else {
            // Clean up stale env from older Carafe builds or user
            // experiments. Wine Staging needs Steam's browser UI.
            env.removeValue(forKey: "STEAM_DISABLE_BROWSER")
        }
    }

    /// Convenience: launch Steam GUI inside a bottle (non-blocking).
    /// Used by the post-install "Launch Steam to sign in" button.
    /// We don't track this as a RunSession because Steam's lifetime
    /// is typically much longer than a single game session.
    ///
    /// FRAGILITY (the dealloc trap): a `Process` instance owns the
    /// lifecycle of its child via Foundation's pipe + termination
    /// tracking. When a local `Process` goes out of scope, ARC
    /// deallocates it — and for long-running GUI children like
    /// Steam.exe (where wine64 stays alive as the loader for the
    /// whole session) that dealloc kills the child before its GUI
    /// even pops. winecfg and similar short-lived helpers don't hit
    /// this because wine64 exits fast and the GUI is reparented to
    /// wineserver before we'd dealloc. We hold the Process in
    /// `launchTracker` until terminationHandler fires.
    static func launchSteamGUI(in bottle: Bottle) throws {
        guard SteamLibraryScanner.hasSteam(in: bottle) else {
            throw Failure.steamNotInstalled
        }
        let steamExe = SteamLibraryScanner.steamExeURL(for: bottle)
        // Defensive double-check — the file might have been moved
        // since the post-install verification.
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw Failure.installerFailed(
                "Steam.exe is no longer at \(steamExe.path). Re-run the installer."
            )
        }

        let process = Process()
        // Mirror the winecfg launch pattern (`/usr/bin/env wine64 …`).
        // The env intermediary is slightly more robust against
        // quoting weirdness in the executable path.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            [WineRunner.wine64Path(for: bottle.wineBuild), steamExe.path] + steamLaunchFlags(for: bottle.wineBuild)

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixURL.path
        env["WINE"] = WineRunner.wine64Path(for: bottle.wineBuild)
        env["WINESERVER"] = WineRunner.wineserverPath(for: bottle.wineBuild)
        env["PATH"] = ShellRunner.defaultPath
        env["WINEDEBUG"] = "fixme-all"
        env["WINEMSYNC"] = "1"
        env["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"

        // --- Black-window / steamwebhelper workarounds ---
        //
        // The DLL override set is the canonical Wine + Steam fix
        // from Winetricks PR #1975. Two DLLs disabled:
        //
        //   libglesv2 — Wine's stubbed GLES2 implementation.
        //     Steam's UI tries to use it for hardware-accelerated
        //     rendering and renders **completely black** under
        //     winemac.drv. Disabling forces a GDI/Direct2D fallback
        //     that paints correctly. This is the *actual* fix for
        //     the "black Steam window" symptom — see Wine bug 44985.
        //
        //   dcomp — DirectComposition. Same shape of problem,
        //     same fix; was the prior round's partial patch.
        //
        // METAL_DEVICE_WRAPPER_TYPE=1 is an Apple Metal env var.
        // Value 1 routes through a wrapper that empirically helps
        // black-window cases; the exact mechanism isn't publicly
        // documented. Kept as belt-and-braces in case libglesv2
        // disabling alone isn't enough on a given combo of macOS
        // + Wine + Steam client version.
        //
        // Apply bottle.environment first, then force the Steam
        // overrides. Older Carafe builds and manual experiments may
        // have left STEAM_DISABLE_BROWSER=1 in the bottle; Wine
        // Staging must clear that or Steam's modern UI cannot draw.
        for (k, v) in bottle.environment { env[k] = v }
        applySteamLaunchEnvironment(to: &env, bottle: bottle)
        process.environment = env

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Strong-reference the process until its child actually
        // terminates — see the FRAGILITY block above for why this
        // matters. The terminationHandler removes the entry once the
        // OS reaps the process so we don't leak after Steam quits.
        process.terminationHandler = { proc in
            launchTracker.untrack(proc)
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
        launchTracker.track(process)
    }

    // MARK: - Modern Steam UI workaround

    /// Configure Wine Staging bottles to run current Steam's CEF UI
    /// instead of trying to force the removed/fragile legacy UI.
    ///
    /// We set the `libglesv2` / `dcomp` overrides both at launch time
    /// (WINEDLLOVERRIDES in `launchSteamGUI`) and persistently for
    /// `steamwebhelper.exe` via Wine's AppDefaults registry. The
    /// registry piece matters because Steam launches webhelper as a
    /// child process; depending on Steam's self-update path, the
    /// child does not always behave like the original Steam.exe
    /// process.
    ///
    /// FRAGILITY: Wine's disabled DLL override is represented in the
    /// registry as an empty string (`""`), matching WineHQ forum
    /// guidance for bug 44985. If Wine changes that representation,
    /// this helper will still be harmless but the black-window fix
    /// may stop applying.
    static func configureModernSteamUIWorkarounds(
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) async throws {
        guard bottle.wineBuild == .wineStaging else {
            log("GPTK bottle detected — modern Steam UI mode is unavailable on Wine 7.7.")
            return
        }
        guard WineRunner.isWineAvailable(for: bottle.wineBuild) else { throw Failure.wineMissing }

        log("Configuring Wine Staging for modern Steam UI mode…")
        restoreSteamWebHelperIfNeeded(in: bottle, log: log)

        let key = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\steamwebhelper.exe\DllOverrides"#

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixURL.path
        env["WINE"] = WineRunner.wine64Path(for: bottle.wineBuild)
        env["WINESERVER"] = WineRunner.wineserverPath(for: bottle.wineBuild)
        env["PATH"] = ShellRunner.defaultPath
        env["WINEDEBUG"] = "fixme-all"
        env["WINEMSYNC"] = "1"

        let overrides = ["libglesv2", "dcomp"]
        for dll in overrides {
            var lastError = ""
            for try await event in ShellRunner.stream(
                WineRunner.wine64Path(for: bottle.wineBuild),
                arguments: ["reg", "add", key, "/v", dll, "/t", "REG_SZ", "/d", "", "/f"],
                environment: env
            ) {
                switch event {
                case .stdout(let line):
                    log(line)
                case .stderr(let line):
                    lastError = line
                    log(line)
                case .exit(let code):
                    if code != 0 {
                        throw Failure.installerFailed(
                            "Couldn't configure Steam UI DLL override for \(dll) (reg exited \(code)). \(lastError)"
                        )
                    }
                }
            }
        }
        log("Steam UI mode configured: steamwebhelper stays enabled, CEF GPU rendering is disabled, and libglesv2/dcomp are disabled for steamwebhelper.exe.")
    }

    /// Undo Carafe's older legacy-UI workaround for Wine Staging.
    /// Current Steam needs steamwebhelper for login/library rendering;
    /// leaving only `.disabled-by-carafe` in place guarantees a dead
    /// or empty UI.
    private static func restoreSteamWebHelperIfNeeded(
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) {
        let scan = findSteamWebHelperFiles(in: bottle)
        guard scan.real.isEmpty, let disabled = scan.renamed.first else {
            if !scan.real.isEmpty {
                log("steamwebhelper.exe is present — keeping modern Steam UI enabled.")
            }
            return
        }

        let restored = disabled.deletingLastPathComponent()
            .appendingPathComponent("steamwebhelper.exe")
        do {
            try FileManager.default.moveItem(at: disabled, to: restored)
            let steamRoot = SteamLibraryScanner.steamInstallURL(for: bottle)
            log("Restored steamwebhelper.exe from \(relativePath(disabled, from: steamRoot)) for modern Steam UI mode.")
        } catch {
            log("⚠️ Couldn't restore steamwebhelper.exe: \(error.localizedDescription). Steam may repair it during self-update; if the UI still does not appear, re-run Install Steam.")
        }
    }

    // MARK: - steamwebhelper legacy-UI workaround

    /// Disable steamwebhelper.exe inside the bottle so Steam falls
    /// back to its legacy WinAPI UI. Required for Steam to be usable
    /// on Wine 7.7 (what GPTK ships).
    ///
    /// We *rename* rather than delete so a future user (or future
    /// version of Carafe with a newer wine) can put it back. Rename
    /// target ends with `.disabled-by-carafe` so it's findable.
    ///
    /// FRAGILITY (the path drift problem): earlier revisions of this
    /// function hardcoded `bin/cef/cef.win7x64/steamwebhelper.exe`
    /// and `bin/cef/cef.win7/steamwebhelper.exe`. Steam's CEF
    /// layout has moved at least once since (recent client builds
    /// land it in a versioned subdirectory like
    /// `bin/cef/cef.winxp64-…` or directly under `bin/`). Hardcoded
    /// paths missed the new location and the workaround silently
    /// no-op'd. We now **recursively search** under `<steam>/bin/`
    /// for any file literally named `steamwebhelper.exe`, regardless
    /// of nesting — so a single rename keeps working across Steam
    /// CEF version bumps.
    ///
    /// Search is scoped to `bin/` (not the full Steam root) because
    /// `steamapps/common/` contains every installed game and walking
    /// that for one file is gratuitously slow.
    ///
    /// Returns `.disabled` if we just renamed at least one match,
    /// `.alreadyDisabled` if only `.disabled-by-carafe` files exist
    /// (a prior run already did the work), or `.notFound` if no
    /// match anywhere — which the UI surfaces as a *warning*, not a
    /// failure, because some Steam launches succeed without the
    /// rename and we don't want to scare users away.
    static func disableSteamWebHelper(
        in bottle: Bottle,
        log: @Sendable @escaping (String) -> Void
    ) -> WebHelperResult {
        let steamRoot = SteamLibraryScanner.steamInstallURL(for: bottle)
        let scan = findSteamWebHelperFiles(in: bottle)

        if scan.real.isEmpty && scan.renamed.isEmpty {
            // The lazy-download chicken-and-egg case: Steam hasn't
            // run yet so its bootstrapper hasn't fetched CEF. The
            // next pipeline step (performFirstLaunchCEFBootstrap)
            // takes care of provoking that download.
            log("steamwebhelper.exe not present yet — Steam's bootstrapper downloads it on first launch.")
            log("The next step will launch Steam to trigger that download and rename the file once it lands.")
            return .notFound
        }

        if scan.real.isEmpty {
            for url in scan.renamed {
                log("steamwebhelper.exe already renamed at \(relativePath(url, from: steamRoot)).")
            }
            return .alreadyDisabled
        }

        // Rename every real match in place. Steam has historically
        // shipped only one steamwebhelper.exe at a time, but if a
        // future version ships variants for different Windows
        // targets we'll catch them all in one pass.
        var anyRenamed = false
        for exeURL in scan.real {
            if renameSteamWebHelperToDisabled(at: exeURL, steamRoot: steamRoot, log: log) {
                anyRenamed = true
            }
        }
        if anyRenamed {
            log("Steam will fall back to the legacy WinAPI UI. Note: Steam's self-update will restore this file; re-run the installer afterward if Steam starts crashing again.")
            return .disabled
        }
        // Permission / IO failure on every match — surface as
        // notFound so the UI shows a warning rather than a hard fail.
        return .notFound
    }

    // MARK: - First-launch CEF bootstrap

    /// Launch Steam, wait for its bootstrapper to download CEF (which
    /// includes `steamwebhelper.exe`), rename the file the instant it
    /// appears, then kill wineserver so Steam exits cleanly.
    ///
    /// This exists because Steam's CEF / Chromium component is
    /// fetched lazily on first launch, not by the installer. The
    /// `.disableWebHelper` step finds nothing on a fresh install; we
    /// have to *provoke* the download to get the file we want to
    /// rename. Chicken-and-egg, automated.
    ///
    /// The poll loop is intentionally coarse (2 s default) — we're
    /// watching for a network download to finish, not a fast event.
    /// 3-minute default timeout is enough for ~30 MB on a typical
    /// home connection.
    ///
    /// FRAGILITY:
    ///   - If Steam's bootstrap UI crashes hard enough that the
    ///     download never starts, we'll time out with nothing
    ///     renamed. The user can re-run the installer or launch
    ///     Steam manually.
    ///   - If Steam's bootstrap moves CEF to a path outside
    ///     `<steam>/bin/`, our scan misses it. Same fallback path:
    ///     we widen the search in `findSteamWebHelperFiles`.
    static func performFirstLaunchCEFBootstrap(
        in bottle: Bottle,
        pollInterval: TimeInterval = 2.0,
        timeout: TimeInterval = 180,
        log: @Sendable @escaping (String) -> Void
    ) async -> WebHelperResult {
        let steamRoot = SteamLibraryScanner.steamInstallURL(for: bottle)

        // Short-circuit: maybe the file is already there (a prior
        // launch downloaded CEF and we're now re-running the
        // pipeline). Rename and skip the Steam-launch dance.
        let preScan = findSteamWebHelperFiles(in: bottle)
        if !preScan.real.isEmpty {
            log("steamwebhelper.exe already present — renaming directly without launching Steam.")
            var anyRenamed = false
            for url in preScan.real {
                if renameSteamWebHelperToDisabled(at: url, steamRoot: steamRoot, log: log) {
                    anyRenamed = true
                }
            }
            return anyRenamed ? .disabled : .notFound
        }
        if !preScan.renamed.isEmpty {
            log("steamwebhelper.exe already renamed by a previous run — skipping Steam launch.")
            return .alreadyDisabled
        }

        // Provoke the bootstrap download.
        //
        // We're waiting for *two* files now, not just steamwebhelper.exe:
        //
        //   1. `steamwebhelper.exe` — CEF helper (the file we rename).
        //   2. `steamui.dll`        — Steam's main UI library.
        //
        // The original implementation only watched for steamwebhelper
        // and killed Steam the moment it appeared. That declared
        // "done" while Steam was still mid-update — steamui.dll
        // wasn't downloaded yet — and the next launch crashed with
        // "Failed to load steamui.dll" before sign-in.
        //
        // The two files arrive in undefined order; we wait for both,
        // then a ~5 s settle delay to let any final writes (registry,
        // version manifest) flush, then rename + kill.
        //
        // FRAGILITY: if Steam ever changes WHICH files it downloads
        // at bootstrap, this still picks up steamwebhelper + steamui
        // because the names are stable. But if Valve renames either,
        // we go back to the original "killed too early" failure mode.
        log("Launching Steam to download CEF + UI components (~50 MB total). Carafe will close Steam automatically once steamwebhelper.exe AND steamui.dll have both landed…")
        do {
            try launchSteamGUI(in: bottle)
        } catch {
            log("⚠️ Couldn't launch Steam to trigger the CEF download: \(error.localizedDescription)")
            return .notFound
        }

        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var lastProgressLog = start
        let progressInterval: TimeInterval = 15

        // Track first-seen times for progress UX — so the log can
        // say things like "steamwebhelper landed at 22 s, still
        // waiting for steamui.dll".
        var webhelperFirstSeen: Date?
        var steamuiFirstSeen: Date?

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            let scan = findSteamWebHelperFiles(in: bottle)
            let hasWebhelper = !scan.real.isEmpty
            let hasRenamedAlready = !scan.renamed.isEmpty
            let steamUI = findSteamUIDLL(in: bottle)

            // Note first-seen transitions for the log.
            if hasWebhelper && webhelperFirstSeen == nil {
                webhelperFirstSeen = Date()
                let elapsed = Int(Date().timeIntervalSince(start))
                log("✓ steamwebhelper.exe landed after \(elapsed)s.")
            }
            if steamUI != nil && steamuiFirstSeen == nil {
                steamuiFirstSeen = Date()
                let elapsed = Int(Date().timeIntervalSince(start))
                log("✓ steamui.dll landed after \(elapsed)s.")
            }

            // Edge case: someone already disabled steamwebhelper on a
            // previous run. If steamui.dll also exists we're fully
            // set up — short-circuit.
            if hasRenamedAlready && steamUI != nil {
                let elapsed = Int(Date().timeIntervalSince(start))
                log("steamwebhelper already disabled and steamui.dll present after \(elapsed)s — stopping Steam.")
                await WineRunner.shutdownWineserver(prefix: bottle.prefixURL)
                return .alreadyDisabled
            }

            if hasWebhelper && steamUI != nil {
                let elapsed = Int(Date().timeIntervalSince(start))
                log("Both files present after \(elapsed)s. Waiting 5 s for Steam to finish any final writes before renaming…")
                // Settle delay. 5 s is empirical: gives Steam time
                // to flush manifests and version files without
                // dragging out the bootstrap noticeably.
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                // Re-scan after the settle in case Steam restored or
                // moved things in those 5 seconds.
                let postScan = findSteamWebHelperFiles(in: bottle)
                guard !postScan.real.isEmpty else {
                    // Steam may have renamed/moved its own helper
                    // during the settle window. Treat as already-
                    // disabled if we now see the renamed sidecar.
                    if !postScan.renamed.isEmpty {
                        await WineRunner.shutdownWineserver(prefix: bottle.prefixURL)
                        return .alreadyDisabled
                    }
                    log("⚠️ steamwebhelper.exe vanished during the settle wait — stopping Steam without renaming.")
                    await WineRunner.shutdownWineserver(prefix: bottle.prefixURL)
                    return .notFound
                }

                log("Renaming steamwebhelper.exe and stopping Steam…")
                var anyRenamed = false
                for url in postScan.real {
                    if renameSteamWebHelperToDisabled(at: url, steamRoot: steamRoot, log: log) {
                        anyRenamed = true
                    }
                }
                await WineRunner.shutdownWineserver(prefix: bottle.prefixURL)
                if anyRenamed {
                    log("First-launch bootstrap complete. Steam is set up for legacy UI mode with steamui.dll on disk.")
                    return .disabled
                }
                return .notFound
            }

            // Throttled progress note every `progressInterval` seconds.
            if Date().timeIntervalSince(lastProgressLog) >= progressInterval {
                let elapsed = Int(Date().timeIntervalSince(start))
                let remaining = Int(timeout) - elapsed
                let webhelperState = hasWebhelper ? "✓" : "…"
                let steamuiState   = steamUI != nil ? "✓" : "…"
                log("Still waiting (\(elapsed)s elapsed, ~\(remaining)s remaining) — webhelper \(webhelperState)  steamui \(steamuiState).")
                lastProgressLog = Date()
            }
        }

        // Timeout: figure out what we got and report something useful.
        let finalScan = findSteamWebHelperFiles(in: bottle)
        let finalSteamUI = findSteamUIDLL(in: bottle) != nil
        let missing: String
        switch (finalScan.real.isEmpty && finalScan.renamed.isEmpty, !finalSteamUI) {
        case (true, true):   missing = "neither steamwebhelper.exe nor steamui.dll"
        case (true, false):  missing = "steamwebhelper.exe"
        case (false, true):  missing = "steamui.dll (Steam UI library — needed to render the client)"
        case (false, false): missing = "(both present but something else stalled)"
        }
        log("Timed out after \(Int(timeout))s. Still missing: \(missing). Stopping Steam — try Launch Steam manually and let it finish updating, then re-run Install Steam.")
        await WineRunner.shutdownWineserver(prefix: bottle.prefixURL)
        return .notFound
    }

    /// Find Steam's main UI library (`steamui.dll`) inside the bottle.
    /// Tries common locations first; recursive walk under
    /// `<steam>/` as a fallback. Returns nil if not present yet.
    ///
    /// FRAGILITY: the file lives at the Steam install root on
    /// current Steam clients. If Valve moves it to a versioned
    /// subdirectory in the future (mirroring CEF's pattern), the
    /// recursive fallback catches it but the function gets slower.
    /// At install time `<steam>/steamapps/common/` is empty (user
    /// hasn't installed games yet) so the full walk is still fast.
    private static func findSteamUIDLL(in bottle: Bottle) -> URL? {
        let steamRoot = SteamLibraryScanner.steamInstallURL(for: bottle)

        // Fast path: known locations.
        let candidates: [URL] = [
            steamRoot.appendingPathComponent("steamui.dll"),
            steamRoot.appendingPathComponent("bin").appendingPathComponent("steamui.dll"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        // Recursive fallback.
        guard let enumerator = FileManager.default.enumerator(
            at: steamRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return nil }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == "steamui.dll" { return url }
        }
        return nil
    }

    // MARK: - Shared find / rename helpers

    private struct SteamWebHelperScan {
        let real: [URL]
        let renamed: [URL]
    }

    /// Recursively scan `<steam>/bin/` (or the whole Steam dir if
    /// `bin/` is missing) for matches of `steamwebhelper.exe` and
    /// `steamwebhelper.exe.disabled-by-carafe`. Used by both
    /// `disableSteamWebHelper` and the bootstrap polling loop.
    private static func findSteamWebHelperFiles(in bottle: Bottle) -> SteamWebHelperScan {
        let steamRoot = SteamLibraryScanner.steamInstallURL(for: bottle)
        let binRoot = steamRoot.appendingPathComponent("bin", isDirectory: true)
        let searchRoot: URL = FileManager.default
            .fileExists(atPath: binRoot.path) ? binRoot : steamRoot

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return SteamWebHelperScan(real: [], renamed: [])
        }

        var real: [URL] = []
        var renamed: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            switch url.lastPathComponent {
            case "steamwebhelper.exe":                     real.append(url)
            case "steamwebhelper.exe.disabled-by-carafe":  renamed.append(url)
            default:                                       break
            }
        }
        return SteamWebHelperScan(real: real, renamed: renamed)
    }

    /// Atomically (per-file) rename one steamwebhelper.exe to the
    /// `.disabled-by-carafe` sidecar. Returns true on success.
    /// Failures are logged, not thrown.
    @discardableResult
    private static func renameSteamWebHelperToDisabled(
        at exeURL: URL,
        steamRoot: URL,
        log: @Sendable @escaping (String) -> Void
    ) -> Bool {
        let renamed = exeURL.deletingLastPathComponent()
            .appendingPathComponent("steamwebhelper.exe.disabled-by-carafe")
        do {
            // Clear any stale sidecar from a prior aborted run so
            // the move can succeed.
            try? FileManager.default.removeItem(at: renamed)
            try FileManager.default.moveItem(at: exeURL, to: renamed)
            log("Renamed steamwebhelper.exe → steamwebhelper.exe.disabled-by-carafe at \(relativePath(exeURL, from: steamRoot)).")
            return true
        } catch {
            log("⚠️ Couldn't rename steamwebhelper.exe at \(relativePath(exeURL, from: steamRoot)): \(error.localizedDescription)")
            return false
        }
    }

    /// Return a path relative to `base` if `url` is under `base`,
    /// otherwise the URL's absolute path. Used purely for log
    /// readability.
    private static func relativePath(_ url: URL, from base: URL) -> String {
        let basePath = base.standardized.path
        let urlPath = url.standardized.path
        if urlPath == basePath { return "." }
        if urlPath.hasPrefix(basePath + "/") {
            return String(urlPath.dropFirst(basePath.count + 1))
        }
        return urlPath
    }

    enum WebHelperResult: Equatable, Sendable {
        case disabled
        case alreadyDisabled
        case notFound
    }

    /// Holds strong references to detached Processes (Steam GUI,
    /// future Epic / GOG launchers) until their children actually
    /// terminate. File-private but explicit so debug code can inspect.
    private static let launchTracker = LaunchTracker()

    private final class LaunchTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var live: [Process] = []

        func track(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            live.append(process)
        }

        func untrack(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            live.removeAll { $0 === process }
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return live.count
        }
    }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case wineMissing
        case winetricksMissing
        case downloadFailed(String)
        case installerFailed(String)
        case steamNotInstalled
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .wineMissing:
                return "Wine isn't installed. Install Game Porting Toolkit first."
            case .winetricksMissing:
                return "winetricks isn't installed. Install components require it; bootstrap from the Components sheet."
            case .downloadFailed(let detail):
                return "Couldn't download SteamSetup.exe: \(detail)"
            case .installerFailed(let detail):
                return detail
            case .steamNotInstalled:
                return "Steam isn't installed in this bottle yet."
            case .launchFailed(let detail):
                return "Couldn't spawn the Steam process: \(detail)"
            }
        }
    }

    // MARK: - Helpers

    private static func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
