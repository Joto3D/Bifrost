import Foundation

/// Pure parsing over Steam's `console_log.txt` lines — no file I/O of its
/// own, so `--check` can drive it against fixed fixture lines (including
/// copies of real log excerpts) without touching the filesystem or Steam.
/// See `SteamLogWatcher` for the file-tailing half.
enum SteamLaunchLogParser {
    /// One `GameAction [AppID X, ActionID Y] : LaunchApp ...` event, parsed
    /// from a single `console_log.txt` line.
    enum Event: Sendable, Equatable {
        case changedTask(appID: String, actionID: String, task: String)
        case waitingForUserResponse(appID: String, actionID: String, task: String)
        case continuesWithUserResponse(appID: String, actionID: String, task: String)

        var appID: String {
            switch self {
            case .changedTask(let appID, _, _),
                 .waitingForUserResponse(let appID, _, _),
                 .continuesWithUserResponse(let appID, _, _):
                return appID
            }
        }
    }

    /// How a launch attempt for one app reads, given the lines seen so far.
    enum Outcome: Sendable, Equatable {
        /// No `GameAction` line has appeared for this app at all.
        case dropped
        /// A dialog asked for a user response and hasn't been answered (or
        /// otherwise progressed) within the attention window.
        case blocked(task: String)
        /// A "changed task to Completed" event was seen — always wins over
        /// any earlier unresolved wait, since Steam can silently move on
        /// from a dialog once the user answers it outside the log (see the
        /// `KickingOtherSession` fixture in `DebugCheck`).
        case completed
        /// GameAction lines are appearing but nothing decisive yet — either
        /// still progressing normally, or a wait that's still within its
        /// grace window (or was already answered).
        case inProgress
    }

    // MARK: - Startup readiness

    /// True if any line reports Steam's own startup finishing — its
    /// "System startup time: N.NN seconds" line, logged once per Steam
    /// session rather than per-app.
    static func containsStartupCompletion(_ lines: [String]) -> Bool {
        lines.contains { $0.contains("System startup time:") }
    }

    // MARK: - Launch classification

    /// Classifies a launch attempt for `appID` from the lines seen so far.
    /// `now` is the reference time a wait's "unanswered" duration is
    /// measured against — pass the real current time when polling live, or
    /// a time safely after the last fixture line when testing a scenario
    /// meant to have gone unanswered by then.
    static func classifyLaunch(lines: [String], appID: String, now: Date, attentionThreshold: TimeInterval = 5) -> Outcome {
        struct Entry {
            let index: Int
            let timestamp: Date
            let event: Event
        }

        var entries: [Entry] = []
        for (index, line) in lines.enumerated() {
            guard let event = parseGameActionLine(line), event.appID == appID else { continue }
            entries.append(Entry(index: index, timestamp: timestamp(of: line) ?? now, event: event))
        }
        guard !entries.isEmpty else { return .dropped }

        for entry in entries {
            if case .changedTask(_, _, let task) = entry.event, task == "Completed" {
                return .completed
            }
        }

        // Walk backwards to the most recent "waiting for user response" —
        // that's the only one whose staleness matters.
        for entry in entries.reversed() {
            guard case .waitingForUserResponse(_, _, let task) = entry.event else { continue }

            let answeredLater = entries.contains { candidate in
                guard candidate.index > entry.index else { return false }
                guard case .continuesWithUserResponse(_, _, let answeredTask) = candidate.event else { return false }
                return answeredTask == task
            }
            if answeredLater { return .inProgress }

            if now.timeIntervalSince(entry.timestamp) >= attentionThreshold {
                return .blocked(task: task)
            }
            return .inProgress
        }

        return .inProgress
    }

    // MARK: - Line parsing

    /// Parses a single `[TIMESTAMP] GameAction [AppID X, ActionID Y] :
    /// LaunchApp ...` line. Returns `nil` for any other line.
    static func parseGameActionLine(_ line: String) -> Event? {
        guard let marker = line.range(of: "GameAction [AppID ") else { return nil }
        let afterMarker = line[marker.upperBound...]

        guard let appIDEnd = afterMarker.range(of: ",") else { return nil }
        let appID = String(afterMarker[..<appIDEnd.lowerBound]).trimmingCharacters(in: .whitespaces)

        guard let actionIDMarker = afterMarker.range(of: "ActionID ") else { return nil }
        let afterActionID = afterMarker[actionIDMarker.upperBound...]
        guard let actionIDEnd = afterActionID.range(of: "]") else { return nil }
        let actionID = String(afterActionID[..<actionIDEnd.lowerBound]).trimmingCharacters(in: .whitespaces)

        guard let launchAppMarker = line.range(of: "LaunchApp ") else { return nil }
        let rest = line[launchAppMarker.upperBound...]

        if let taskMarker = rest.range(of: "changed task to ") {
            guard let task = quotedPrefixTask(after: taskMarker.upperBound, in: rest, separator: " with \"") else { return nil }
            return .changedTask(appID: appID, actionID: actionID, task: task)
        }
        if let taskMarker = rest.range(of: "waiting for user response to ") {
            guard let task = quotedPrefixTask(after: taskMarker.upperBound, in: rest, separator: " \"") else { return nil }
            return .waitingForUserResponse(appID: appID, actionID: actionID, task: task)
        }
        if let taskMarker = rest.range(of: "continues with user response \"") {
            let afterQuote = rest[taskMarker.upperBound...]
            guard let closingQuote = afterQuote.range(of: "\"") else { return nil }
            return .continuesWithUserResponse(appID: appID, actionID: actionID, task: String(afterQuote[..<closingQuote.lowerBound]))
        }
        return nil
    }

    /// Pulls the task name out of `<task><separator>"..."` starting at
    /// `start` — used for the two event shapes whose task name is followed
    /// by a quoted detail string, rather than being quoted itself.
    private static func quotedPrefixTask(after start: Substring.Index, in text: Substring, separator: String) -> String? {
        let remainder = text[start...]
        guard let separatorRange = remainder.range(of: separator) else { return nil }
        return String(remainder[..<separatorRange.lowerBound])
    }

    /// Extracts and parses the `[yyyy-MM-dd HH:mm:ss]` prefix, if present.
    /// Builds a fresh `DateFormatter` per call — mirroring
    /// `SteamConfigurator.backupTimestamp()` — rather than caching one as
    /// global state, since `DateFormatter` isn't `Sendable`.
    static func timestamp(of line: String) -> Date? {
        guard line.hasPrefix("["), let closeBracket = line.firstIndex(of: "]") else { return nil }
        let inner = String(line[line.index(after: line.startIndex)..<closeBracket])

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: inner)
    }
}
