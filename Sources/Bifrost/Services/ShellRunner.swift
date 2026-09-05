import Foundation

/// Small async wrapper over `Foundation.Process` for running external
/// commands and capturing their output without blocking the caller.
enum ShellRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `executable` with `args`, waiting for completion off the main
    /// thread. Throws if the process cannot be launched at all; a non-zero
    /// exit status is reported via `status`, not a thrown error.
    ///
    /// - Parameter currentDirectory: When given, the process is launched
    ///   with this as its working directory — used by `--check`'s
    ///   "install from file" fixtures to run `/usr/bin/zip` against
    ///   relative paths so the resulting archive doesn't embed the temp
    ///   directory's absolute path in every entry.
    static func run(_ executable: String, _ args: [String] = [], currentDirectory: URL? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { finishedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = Result(
                    status: finishedProcess.terminationStatus,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
