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

            // Both pipes must be drained continuously as the child runs,
            // not just once after it exits: the kernel pipe buffer is only
            // ~64KB, and a command that writes more than that before
            // terminating (a chatty `ditto -xk`/`zip -r` on a real mod
            // archive, in particular) would block forever on write() with
            // nobody reading — which means it never terminates, which
            // means a naive "read everything in the termination handler"
            // approach never runs either. Deadlock. `readabilityHandler`
            // fires with an empty `Data` at EOF, which is what marks each
            // pipe "closed" below; completion only fires once the process
            // has terminated AND both pipes have hit EOF, so nothing here
            // races the final read.
            let syncQueue = DispatchQueue(label: "ShellRunner.sync")
            var stdoutData = Data()
            var stderrData = Data()
            var terminationStatus: Int32?
            var stdoutOpen = true
            var stderrOpen = true
            var didFinish = false

            func finishIfReady() {
                guard !didFinish, let status = terminationStatus, !stdoutOpen, !stderrOpen else { return }
                didFinish = true
                let result = Result(
                    status: status,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                syncQueue.async {
                    if chunk.isEmpty {
                        stdoutOpen = false
                        handle.readabilityHandler = nil
                    } else {
                        stdoutData.append(chunk)
                    }
                    finishIfReady()
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                syncQueue.async {
                    if chunk.isEmpty {
                        stderrOpen = false
                        handle.readabilityHandler = nil
                    } else {
                        stderrData.append(chunk)
                    }
                    finishIfReady()
                }
            }

            process.terminationHandler = { finishedProcess in
                syncQueue.async {
                    terminationStatus = finishedProcess.terminationStatus
                    finishIfReady()
                }
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
