import Foundation

/// Tails Steam's own `console_log.txt` incrementally: reads only the bytes
/// appended since a previous offset, so watching a launch doesn't mean
/// re-scanning the whole (often multi-megabyte) log on every poll.
///
/// Deliberately does no interpretation of the lines it returns — that's
/// `SteamLaunchLogParser`'s job, kept separate so the parsing logic can be
/// driven by fixed fixture lines in `--check` without touching the
/// filesystem.
enum SteamLogWatcher {
    /// Steam's own console log, under the same `Steam` root every other
    /// service in this app reads (`GameLocator.steamRoot`,
    /// `SteamConfigurator`'s userdata lookups).
    static var defaultLogURL: URL {
        GameLocator.steamRoot.appendingPathComponent("logs/console_log.txt")
    }

    /// The log's current end-of-file byte offset, or 0 if it can't be read
    /// (missing, no permission). Callers mark this before taking an action
    /// that will make Steam append to the log, so `readAppended` only ever
    /// sees lines caused by that action.
    static func currentOffset(logURL: URL = defaultLogURL) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return 0 }
        defer { try? handle.close() }
        return (try? handle.seekToEnd()) ?? 0
    }

    /// Lines appended to `logURL` since `offset`, plus the offset to pass on
    /// the next call. Only complete, newline-terminated lines are returned —
    /// a line Steam is still mid-write on is left for the next read instead
    /// of being yielded truncated.
    static func readAppended(logURL: URL = defaultLogURL, since offset: UInt64) -> (lines: [String], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return ([], offset) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return ([], offset) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], offset) }
        guard let text = String(data: data, encoding: .utf8) else { return ([], offset + UInt64(data.count)) }

        let completeText: String
        if text.hasSuffix("\n") {
            completeText = text
        } else if let lastNewline = text.lastIndex(of: "\n") {
            completeText = String(text[...lastNewline])
        } else {
            return ([], offset) // no complete line has landed yet
        }

        let lines = completeText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return (lines, offset + UInt64(completeText.utf8.count))
    }
}
