import Foundation

/// Service for installing Steam's Windows client into a Carafe bottle.
///
/// Pipeline:
///   1. Ensure vcrun2022 (or 2019) is present.
///   2. Download SteamSetup.exe to the shared cache.
///   3. Run SteamSetup.exe /S inside the bottle (silent NSIS install).
///   4. Verify Steam.exe at the canonical path.
///   5. Disable steamwebhelper.exe to force Steam's legacy UI mode.
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
/// Carafe's current mitigation is the legacy-UI workaround in step 5:
/// rename steamwebhelper.exe so Steam falls back to its old WinAPI
/// UI, which works fine on Wine 7.7. This loses the friends panel,
/// the embedded store browser, and the React login — but the client
/// is *usable* and games launch.
///
/// The proper fix is a newer wine. Gcenx ships `gcenx/wine/wine-crossover`
/// at Wine 8.0.1 (CrossOver 23.7.1 sources), free and Apple-Silicon-
/// native. Adding multi-wine-version support to BottleManager so a
/// Steam bottle can opt into wine-crossover is sketched as a next-
/// milestone task, not done here.
///
/// ## ⚠️ Auto-update overwrites our workaround
///
/// Steam's self-update runs on every launch and **restores
/// steamwebhelper.exe** if it's missing. So our rename is a one-shot:
/// after a Steam client update the user will see the crash again and
/// needs to re-run "Install Steam in Bottle…" (we detect the install
/// is present, skip the heavy steps, and re-run only the webhelper
/// disable). Documented in TESTING.md.
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
///   - Flags: `-no-cef-sandbox -noreactlogin -nofriendsui
///            -skipinitialbootstrap -windowed -allosarches
///            -cef-force-32bit -cef-in-process-gpu`
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
/// 4. **steamwebhelper.exe location.** `bin/cef/cef.win7x64/` is the
///    current relative path. Steam has moved CEF between
///    subdirectories over the years (cef.win7, cef.win7x64,
///    cef.win10, etc.); if a future Steam update changes the path,
///    `disableSteamWebHelper` finds nothing and the legacy-UI
///    workaround silently doesn't kick in. Log the miss but don't
///    fail the install.
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

    /// Steam launch flags we pass for the legacy-UI / Wine workaround.
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
    static let steamLaunchFlags = [
        "-no-cef-sandbox",
        "-noreactlogin",
        "-nofriendsui",
        "-skipinitialbootstrap",
        "-windowed",
        "-allosarches",
        "-cef-force-32bit",
        "-cef-in-process-gpu",
    ]

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
            [WineRunner.wine64Path(for: bottle.wineBuild), steamExe.path] + steamLaunchFlags

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.prefixURL.path
        env["WINE"] = WineRunner.wine64Path(for: bottle.wineBuild)
        env["WINESERVER"] = WineRunner.wineserverPath(for: bottle.wineBuild)
        env["PATH"] = ShellRunner.defaultPath
        env["WINEDEBUG"] = "fixme-all"
        env["WINEMSYNC"] = "1"
        // CEF / browser disables. Both env vars are checked by the
        // Steam client and by Chromium inside steamwebhelper.exe —
        // belt and braces in case our file-rename workaround missed
        // (e.g., Steam restored the file after an update and the
        // user hasn't re-run our pipeline yet).
        env["WEBKIT_DISABLE_COMPOSITING_MODE"] = "1"
        env["STEAM_DISABLE_BROWSER"] = "1"

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
        // bottle.environment is applied AFTER these so a power
        // user can override WINEDLLOVERRIDES if needed.
        env["WINEDLLOVERRIDES"] = "libglesv2=disabled;dcomp=disabled"
        env["METAL_DEVICE_WRAPPER_TYPE"] = "1"

        for (k, v) in bottle.environment { env[k] = v }
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
}
