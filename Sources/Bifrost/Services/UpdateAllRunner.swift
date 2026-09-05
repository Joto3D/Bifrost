import Foundation

/// Runs a batch of mod updates one at a time, collecting a per-mod result
/// rather than aborting the whole batch on the first failure — backs
/// `InstalledModsView`'s "Update All" toolbar action. Pure and
/// injectable (`updater` is passed in rather than calling `ModManager`
/// directly), so a `--check` section can exercise the aggregation logic
/// with a fixture failure without touching any real mod files.
enum UpdateAllRunner {
    /// One mod's outcome from a run.
    struct ModResult: Sendable, Equatable {
        let fullName: String
        let outcome: Outcome

        enum Outcome: Sendable, Equatable {
            case success
            case failure(String)
        }
    }

    struct Summary: Sendable, Equatable {
        let results: [ModResult]

        var succeededCount: Int {
            results.filter {
                if case .success = $0.outcome { return true }
                return false
            }.count
        }

        var failedCount: Int { results.count - succeededCount }

        var failures: [(fullName: String, message: String)] {
            results.compactMap {
                guard case .failure(let message) = $0.outcome else { return nil }
                return ($0.fullName, message)
            }
        }
    }

    /// Runs `updater` sequentially for every entry in `fullNames`, in order,
    /// calling `onProgress` immediately before each one starts. A failure is
    /// recorded in the returned summary and the loop continues — never
    /// thrown, never aborts the rest of the batch.
    static func run(
        fullNames: [String],
        onProgress: @Sendable (String) -> Void = { _ in },
        updater: (String) async throws -> Void
    ) async -> Summary {
        var results: [ModResult] = []
        for fullName in fullNames {
            onProgress(fullName)
            do {
                try await updater(fullName)
                results.append(ModResult(fullName: fullName, outcome: .success))
            } catch {
                results.append(ModResult(fullName: fullName, outcome: .failure(error.localizedDescription)))
            }
        }
        return Summary(results: results)
    }
}
