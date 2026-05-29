import Foundation

/// Runs a shell command line as root via `osascript`'s
/// `do shell script ... with administrator privileges`, which surfaces
/// the standard macOS authorization dialog (Touch ID / password).
///
/// **Limitation:** AppleScript returns only the final combined output,
/// so this runner cannot stream progress. Use it for short one-shot
/// privileged actions (Rosetta install, ownership fix-ups). For
/// user-mode long-running installs, prefer `ShellRunner`.
///
/// Once the user authenticates, macOS caches the credential for ~5
/// minutes, so consecutive calls within that window won't re-prompt.
enum PrivilegedRunner {
    enum Failure: LocalizedError {
        case userCancelled
        case scriptCompilationFailed
        case appleScriptError(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Authorization cancelled."
            case .scriptCompilationFailed:
                return "Could not compile the privileged-runner AppleScript."
            case .appleScriptError(let code, let message):
                return "Privileged command failed (\(code)): \(message)"
            }
        }
    }

    /// Execute `commandLine` with administrator privileges and return
    /// the combined stdout / stderr produced by `osascript`.
    static func run(_ commandLine: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let escaped = commandLine
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let source =
                    "do shell script \"\(escaped)\" with administrator privileges"

                guard let script = NSAppleScript(source: source) else {
                    cont.resume(throwing: Failure.scriptCompilationFailed)
                    return
                }

                var errorDict: NSDictionary?
                let descriptor = script.executeAndReturnError(&errorDict)

                if let errorDict {
                    let code = errorDict[NSAppleScript.errorNumber] as? Int ?? -1
                    // -128 is the standard "User cancelled" code from osascript.
                    if code == -128 {
                        cont.resume(throwing: Failure.userCancelled)
                    } else {
                        let message =
                            errorDict[NSAppleScript.errorMessage] as? String
                            ?? "Unknown AppleScript error"
                        cont.resume(throwing: Failure.appleScriptError(code: code, message: message))
                    }
                    return
                }

                cont.resume(returning: descriptor.stringValue ?? "")
            }
        }
    }
}
