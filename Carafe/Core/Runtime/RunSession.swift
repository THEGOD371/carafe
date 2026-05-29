import Foundation
import AppKit

/// One launch of a Windows executable inside a bottle.
///
/// State machine:
///
///   .idle ─▶ start() ─▶ .launching ─▶ .running ─┬─▶ .exited(code)  (natural)
///                            │                  ├─▶ .killed         (user Stop)
///                            └─▶ .failed(reason) (couldn't even spawn)
///
/// Only one process at a time. The view layer constructs a fresh
/// RunSession per attempt and discards it after termination so we
/// never hold stale Process references.
@MainActor
final class RunSession: ObservableObject, Identifiable {

    enum State: Sendable, Equatable {
        case idle
        case launching
        case running(pid: Int32)
        case exited(code: Int32)
        case killed
        case failed(reason: String)

        var isLive: Bool {
            switch self {
            case .launching, .running: return true
            default: return false
            }
        }

        var isTerminal: Bool {
            switch self {
            case .exited, .killed, .failed: return true
            default: return false
            }
        }
    }

    enum LogStream: Sendable, Equatable { case stdout, stderr, info }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let stream: LogStream
        let text: String
    }

    // MARK: - Configuration

    nonisolated let id = UUID()
    nonisolated let bottle: Bottle
    nonisolated let exeURL: URL
    nonisolated let arguments: [String]
    nonisolated let startedAt: Date

    /// The resolved (no-inheritance) compat config used to build the
    /// launch environment. Built by the caller from
    /// `ResolvedConfig.fromBottle(_:)` for the arbitrary-exe path or
    /// `ResolvedConfig.resolve(game:bottle:)` for tile launches.
    nonisolated let config: ResolvedConfig

    // MARK: - Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var logLines: [LogLine] = []

    // MARK: - Callbacks

    /// Invoked exactly once when the session transitions into a
    /// terminal state. Argument is wall-clock duration in seconds
    /// from `start()` being called until the terminal transition.
    /// LaunchGameSheet uses this to call GameLibrary.recordPlay.
    var onSessionEnded: (@MainActor (TimeInterval) -> Void)?

    // MARK: - Internals

    private var process: Process?
    private var userInitiatedStop = false
    private var didFireSessionEnded = false
    private let logCap = 5_000

    init(bottle: Bottle, exeURL: URL, config: ResolvedConfig) {
        self.bottle = bottle
        self.exeURL = exeURL
        self.arguments = config.arguments
        self.config = config
        self.startedAt = Date()
    }

    /// Convenience init that builds a bottle-only config (no game
    /// overrides). Used by LaunchExeSheet's arbitrary-exe flow.
    convenience init(bottle: Bottle, exeURL: URL, arguments: [String] = []) {
        self.init(
            bottle: bottle,
            exeURL: exeURL,
            config: .fromBottle(bottle, arguments: arguments)
        )
    }

    // MARK: - Lifecycle

    /// Validate, build the Process, attach pipes, run. All state
    /// transitions are made on the main actor.
    func start() async {
        guard state == .idle else { return }

        // --- Validate ---
        let fm = FileManager.default
        guard fm.fileExists(atPath: exeURL.path) else {
            transition(to: .failed(reason: "File not found: \(exeURL.path)"))
            return
        }
        // Single chokepoint for launchability: MZ check, Steam.exe
        // bypass, and per-build 32-bit policy all live in
        // `PEValidator.evaluateLaunchability`.
        let auth = PEValidator.evaluateLaunchability(at: exeURL, build: bottle.wineBuild)
        switch auth {
        case .ok:
            break
        case .warning(let message):
            // Surface as an info log line — launch continues.
            appendLog("⚠️ \(message)", stream: .info)
        case .block(let reason):
            transition(to: .failed(reason: reason))
            return
        }
        guard WineRunner.isWineAvailable(for: bottle.wineBuild) else {
            transition(to: .failed(reason:
                "\(bottle.wineBuild.shortName) isn't installed for this bottle."
            ))
            return
        }

        transition(to: .launching)
        appendLog(
            "Launching \(exeURL.lastPathComponent) in bottle “\(bottle.name)”",
            stream: .info
        )
        let cwd = exeURL.deletingLastPathComponent()
        appendLog("Working directory: \(cwd.path)", stream: .info)
        if !arguments.isEmpty {
            appendLog("Arguments: \(arguments.joined(separator: " "))", stream: .info)
        }
        appendLog(
            "Config: \(config.graphicsBackend.displayName), \(config.sync.displayName), Windows \(config.windowsVersion.displayName)\(config.metalHUD ? ", Metal HUD on" : "")\(config.retina ? ", Retina" : "")",
            stream: .info
        )

        // --- Apply Windows version override (if any) ---
        //
        // We always write the resolved Windows version to the
        // registry pre-launch. On a warm wineserver this adds ~1 s
        // to launch; on a cold one ~3 s. The trade-off is that
        // launching game A with override=win7 then game B without
        // an override doesn't leave the prefix at win7 — game B
        // gets the bottle's default applied first.
        //
        // FRAGILITY: see the FRAGILITY block in WineRunner about
        // wine-fork disagreement on which registry key drives the
        // reported version.
        await WineRunner.setWindowsVersion(
            prefix: bottle.prefixURL,
            version: config.windowsVersion,
            build: bottle.wineBuild
        ) { [weak self] line in
            Task { @MainActor [weak self] in
                self?.appendLog(line, stream: .info)
            }
        }

        // --- Build Process ---

        let proc = Process()
        // FRAGILITY: invoking wine64 directly (rather than through
        // /usr/bin/env wine64) means we depend on the resolved
        // wine64 path for the bottle's build. For GPTK that's the
        // brew symlink at /opt/homebrew/bin/wine64; for Wine Staging
        // it's inside our app-support tree.
        proc.executableURL = URL(fileURLWithPath: WineRunner.wine64Path(for: bottle.wineBuild))
        proc.arguments = [exeURL.path] + arguments
        proc.currentDirectoryURL = cwd
        proc.environment = buildEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice

        let stdoutBuffer = LineBuffer { [weak self] line in
            Task { @MainActor [weak self] in
                self?.appendLog(line, stream: .stdout)
            }
        }
        let stderrBuffer = LineBuffer { [weak self] line in
            Task { @MainActor [weak self] in
                self?.appendLog(line, stream: .stderr)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }

        proc.terminationHandler = { [weak self] terminated in
            stdoutBuffer.flush()
            stderrBuffer.flush()
            let exitCode = terminated.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: exitCode)
            }
        }

        // --- Launch ---

        do {
            try proc.run()
            process = proc
            transition(to: .running(pid: proc.processIdentifier))
        } catch {
            transition(to: .failed(reason:
                "Couldn't launch wine: \(error.localizedDescription)"
            ))
        }
    }

    /// User-initiated stop. Sends SIGTERM, waits briefly, then falls
    /// back to `wineserver -k` for the prefix to ensure no orphans
    /// linger. Safe to call from any state — no-op outside .running.
    func stop() async {
        guard state.isLive, let proc = process else { return }
        userInitiatedStop = true
        appendLog("Stop requested by user.", stream: .info)

        proc.terminate()

        // Give it 2 seconds to exit on its own.
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if proc.isRunning {
            // Wine sometimes ignores SIGTERM on the wrapper because
            // the actual work lives in wineserver children. Kill the
            // server outright.
            appendLog("Process didn't exit on SIGTERM — killing wineserver for this prefix.", stream: .info)
            await WineRunner.shutdownWineserver(prefix: bottle.prefixURL, build: bottle.wineBuild)
        }
    }

    /// Sweep any leftover wineserver in this prefix. Called from
    /// the UI after a terminal state so re-launches start cold.
    /// Idempotent.
    func cleanup() async {
        await WineRunner.shutdownWineserver(prefix: bottle.prefixURL, build: bottle.wineBuild)
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - Helpers

    private func buildEnvironment() -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        let wineEnv = WineRunner.environment(
            for: bottle.prefixURL,
            build: bottle.wineBuild,
            // Use the *effective* overrides (which include DXVK
            // entries when graphicsBackend == .dxvk).
            dllOverrides: config.effectiveDLLOverrides,
            bottleEnvironment: config.environment,
            extra: config.derivedEnvironment
        )
        for (k, v) in wineEnv { base[k] = v }
        return base
    }

    private func transition(to newState: State) {
        state = newState
        switch newState {
        case .failed(let reason):
            appendLog("⛔ \(reason)", stream: .info)
        case .exited(let code):
            appendLog("Process exited with code \(code).", stream: .info)
        case .killed:
            appendLog("Process terminated by user.", stream: .info)
        case .running(let pid):
            appendLog("Running (pid \(pid)).", stream: .info)
        default:
            break
        }
        // Fire the session-ended callback exactly once on any
        // terminal transition. The .failed case (couldn't even
        // launch) still fires with a near-zero duration so the host
        // can count "attempted launch" if it wants — GameLibrary
        // currently ignores tiny intervals.
        if newState.isTerminal && !didFireSessionEnded {
            didFireSessionEnded = true
            let duration = Date().timeIntervalSince(startedAt)
            onSessionEnded?(duration)
        }
    }

    private func handleTermination(exitCode: Int32) {
        process = nil
        if userInitiatedStop {
            transition(to: .killed)
        } else {
            transition(to: .exited(code: exitCode))
        }
        // Defensive: wineserver may have leftover children even
        // after a natural exit. Kick it to make sure the next
        // launch in this prefix starts from a clean state.
        Task { await WineRunner.shutdownWineserver(prefix: bottle.prefixURL, build: bottle.wineBuild) }
    }

    private func appendLog(_ text: String, stream: LogStream) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(.init(timestamp: Date(), stream: stream, text: trimmed))
        if logLines.count > logCap {
            logLines.removeFirst(logLines.count - logCap)
        }
    }
}
