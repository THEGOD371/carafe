import Foundation

/// Async wrapper around `Process` that streams stdout / stderr line-by-line.
/// All shelling out in Carafe flows through here; the live log pane in the
/// onboarding UI is driven directly off the AsyncThrowingStream.
enum ShellRunner {
    enum Event: Sendable {
        case stdout(String)
        case stderr(String)
        case exit(Int32)
    }

    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var didSucceed: Bool { exitCode == 0 }
    }

    enum Failure: LocalizedError {
        case launchFailed(String)
        case nonZeroExit(code: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let msg): return "Failed to launch process: \(msg)"
            case .nonZeroExit(let code, let stderr):
                return "Process exited with code \(code).\n\(stderr)"
            }
        }
    }

    /// GUI-launched apps on macOS inherit a minimal PATH that omits
    /// Homebrew. Pre-pend the standard install locations so `brew`,
    /// `git`, etc. resolve without callers having to think about it.
    static let defaultPath =
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Stream stdout / stderr / exit events as the process runs.
    ///
    /// `executable` may be a bare name (resolved on PATH via `/usr/bin/env`)
    /// or an absolute path. Cancelling the consuming task terminates the
    /// child process.
    static func stream(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = environment?["PATH"] ?? defaultPath
            if let environment {
                for (key, value) in environment { env[key] = value }
            }
            process.environment = env

            if let cwd = currentDirectory {
                process.currentDirectoryURL = cwd
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let stdoutBuffer = LineBuffer { line in
                continuation.yield(.stdout(line))
            }
            let stderrBuffer = LineBuffer { line in
                continuation.yield(.stderr(line))
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

            process.terminationHandler = { proc in
                stdoutBuffer.flush()
                stderrBuffer.flush()
                continuation.yield(.exit(proc.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: Failure.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Run-to-completion convenience that buffers full stdout / stderr.
    /// Throws `Failure.nonZeroExit` when `throwOnFailure` is true and exit != 0.
    @discardableResult
    static func runToCompletion(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        throwOnFailure: Bool = false
    ) async throws -> Result {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32 = -1

        for try await event in stream(
            executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        ) {
            switch event {
            case .stdout(let line): stdout += line + "\n"
            case .stderr(let line): stderr += line + "\n"
            case .exit(let code): exitCode = code
            }
        }

        let result = Result(exitCode: exitCode, stdout: stdout, stderr: stderr)
        if throwOnFailure && !result.didSucceed {
            throw Failure.nonZeroExit(code: exitCode, stderr: stderr)
        }
        return result
    }
}

// LineBuffer moved to Carafe/Core/Process/LineBuffer.swift so
// RunSession can share the line-splitting logic.
