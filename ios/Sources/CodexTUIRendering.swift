import Foundation
import SwiftUI

enum CodexTUIEventKind: String, Hashable {
    case working
    case interrupted
    case waiting
    case agent
    case status
    case ran
    case edited
    case explored
    case exploring
    case queued
    case waited
    case context
    case plan
    case option
}

struct CodexTUIEvent: Identifiable, Hashable {
    let kind: CodexTUIEventKind
    let title: String
    let summary: String?
    let detail: String?
    let isRunning: Bool
    var isSelected = false

    var id: String {
        if isRunning || kind == .interrupted {
            return "\(kind.rawValue)|\(title)"
        }
        return "\(kind.rawValue)|\(title)|\(summary ?? "")|\(detail ?? "")"
    }
}

enum CodexTUITextPart: Hashable {
    case summary
    case detail
}

enum CodexTUITextRole: Hashable {
    case primary
    case secondary
    case dim
    case command
    case agentName
    case agentRole
    case model
    case option
    case literal
    case operatorToken
    case action
    case identifier
}

struct CodexTUITextRun: Hashable {
    let text: String
    let role: CodexTUITextRole
}

struct CodexTUIStatusBar: Hashable {
    let model: String
    let effort: String
    let segments: [String]
    let contexts: [String]
    let window: String
    let fastMode: String
    let fiveHourLimit: String
    let weeklyLimit: String

    var parts: [String] {
        ([model, effort] + segments).filter { !$0.isEmpty }
    }
}

enum CodexTUIElapsedTimer {
    private static let elapsedPattern = #"\d+h(?:\s+\d+m)?(?:\s+\d+s)?|\d+m(?:\s+\d+s)?|\d+s"#

    static func containsElapsed(in text: String) -> Bool {
        elapsedRange(in: text) != nil
    }

    static func advancingSummary(_ summary: String, by offsetSeconds: Int) -> String? {
        guard let range = elapsedRange(in: summary) else { return nil }
        let elapsed = String(summary[range])
        guard let baseSeconds = elapsedSeconds(from: elapsed) else { return nil }

        var updated = summary
        updated.replaceSubrange(range, with: elapsedSummary(fromSeconds: baseSeconds + max(offsetSeconds, 0)))
        return updated
    }

    static func elapsedSeconds(from summary: String) -> Int? {
        let pattern = #"^(?:(\d+)h(?:\s+|$))?(?:(\d+)m(?:\s+|$))?(?:(\d+)s)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range) else { return nil }

        func integerCapture(_ index: Int) -> Int {
            guard match.numberOfRanges > index,
                  let range = Range(match.range(at: index), in: trimmed)
            else {
                return 0
            }
            return Int(trimmed[range]) ?? 0
        }

        return integerCapture(1) * 3_600 + integerCapture(2) * 60 + integerCapture(3)
    }

    static func elapsedSummary(fromSeconds totalSeconds: Int) -> String {
        let seconds = max(totalSeconds, 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            if minutes > 0 {
                return remainingSeconds > 0 ? "\(hours)h \(minutes)m \(remainingSeconds)s" : "\(hours)h \(minutes)m"
            }
            return remainingSeconds > 0 ? "\(hours)h \(remainingSeconds)s" : "\(hours)h"
        }
        if minutes > 0 {
            return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
        }
        return "\(remainingSeconds)s"
    }

    private static func elapsedRange(in text: String) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(pattern: elapsedPattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range)
            .last
            .flatMap { Range($0.range, in: text) }
    }
}

private final class CodexTUIEventArrayCacheEntry: NSObject {
    let value: [CodexTUIEvent]

    init(_ value: [CodexTUIEvent]) {
        self.value = value
    }
}

private final class CodexTUIStringArrayCacheEntry: NSObject {
    let value: [String]

    init(_ value: [String]) {
        self.value = value
    }
}

private final class CodexTUIStatusBarCacheEntry: NSObject {
    let value: CodexTUIStatusBar?

    init(_ value: CodexTUIStatusBar?) {
        self.value = value
    }
}

private enum CodexTUIParserCache {
    nonisolated(unsafe) private static let eventsCache: NSCache<NSString, CodexTUIEventArrayCacheEntry> = {
        let cache = NSCache<NSString, CodexTUIEventArrayCacheEntry>()
        cache.countLimit = 48
        return cache
    }()

    nonisolated(unsafe) private static let currentTurnEventsCache: NSCache<NSString, CodexTUIEventArrayCacheEntry> = {
        let cache = NSCache<NSString, CodexTUIEventArrayCacheEntry>()
        cache.countLimit = 48
        return cache
    }()

    nonisolated(unsafe) private static let currentQueuedMessagesCache: NSCache<NSString, CodexTUIStringArrayCacheEntry> = {
        let cache = NSCache<NSString, CodexTUIStringArrayCacheEntry>()
        cache.countLimit = 48
        return cache
    }()

    nonisolated(unsafe) private static let statusBarCache: NSCache<NSString, CodexTUIStatusBarCacheEntry> = {
        let cache = NSCache<NSString, CodexTUIStatusBarCacheEntry>()
        cache.countLimit = 48
        return cache
    }()

    static func events(for text: String, build: () -> [CodexTUIEvent]) -> [CodexTUIEvent] {
        let key = text as NSString
        if let cached = eventsCache.object(forKey: key) {
            return cached.value
        }
        let value = build()
        eventsCache.setObject(CodexTUIEventArrayCacheEntry(value), forKey: key)
        return value
    }

    static func currentTurnEvents(for text: String, build: () -> [CodexTUIEvent]) -> [CodexTUIEvent] {
        let key = text as NSString
        if let cached = currentTurnEventsCache.object(forKey: key) {
            return cached.value
        }
        let value = build()
        currentTurnEventsCache.setObject(CodexTUIEventArrayCacheEntry(value), forKey: key)
        return value
    }

    static func currentQueuedMessages(for text: String, build: () -> [String]) -> [String] {
        let key = text as NSString
        if let cached = currentQueuedMessagesCache.object(forKey: key) {
            return cached.value
        }
        let value = build()
        currentQueuedMessagesCache.setObject(CodexTUIStringArrayCacheEntry(value), forKey: key)
        return value
    }

    static func statusBar(for text: String, build: () -> CodexTUIStatusBar?) -> CodexTUIStatusBar? {
        let key = text as NSString
        if let cached = statusBarCache.object(forKey: key) {
            return cached.value
        }
        let value = build()
        statusBarCache.setObject(CodexTUIStatusBarCacheEntry(value), forKey: key)
        return value
    }
}

enum CodexTUIStatusBarParser {
    private static let statusLineStartPattern = #"\b(?:gpt|o|codex)[A-Za-z0-9._/-]*(?:-[A-Za-z0-9._/-]+)*\s+(?:xhigh|high|medium|low|minimal|normal)\s*·"#

    static func status(from text: String) -> CodexTUIStatusBar? {
        CodexTUIParserCache.statusBar(for: text) {
            let normalized = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            let pattern = #"\b((?:gpt|o|codex)[A-Za-z0-9._/-]*(?:-[A-Za-z0-9._/-]+)*)\s+(xhigh|high|medium|low|minimal|normal)\s*·\s*(.+?)(?=\b(?:gpt|o|codex)[A-Za-z0-9._/-]*(?:-[A-Za-z0-9._/-]+)*\s+(?:xhigh|high|medium|low|minimal|normal)\s*·|[•\n\r]|$)"#
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return nil
            }

            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            let candidates = expression.matches(in: normalized, range: range)
                .compactMap { match in
                    status(from: match, in: normalized)
                }
            guard let candidate = candidates.max(by: { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.location < rhs.location
            }) else {
                return nil
            }

            return candidate.status
        }
    }

    private struct Candidate {
        let status: CodexTUIStatusBar
        let score: Int
        let location: Int
    }

    private static func status(from match: NSTextCheckingResult, in text: String) -> Candidate? {
        func capture(_ index: Int) -> String? {
            guard match.numberOfRanges > index,
                  let range = Range(match.range(at: index), in: text)
            else {
                return nil
            }
            return cleanLine(String(text[range])).nilIfEmpty
        }

        guard let model = capture(1),
              let effort = capture(2),
              let rawSegments = capture(3)
        else {
            return nil
        }

        let segments = segmentText(from: rawSegments)
            .split(separator: "\u{00B7}")
            .compactMap { cleanSegment(String($0)).nilIfEmpty }
        guard !segments.isEmpty else {
            return nil
        }

        let contexts = segments.filter { $0.range(of: #"^Context\s+\["#, options: [.regularExpression, .caseInsensitive]) != nil }
        let window = segments.first(where: { $0.localizedCaseInsensitiveContains("window") }) ?? ""
        let fastMode = segments.first(where: { $0.range(of: #"^Fast\s+(?:on|off)$"#, options: [.regularExpression, .caseInsensitive]) != nil }) ?? ""
        let fiveHourLimit = segments.first(where: { $0.range(of: #"^5h\s+\d+%"#, options: [.regularExpression, .caseInsensitive]) != nil }) ?? ""
        let weeklyLimit = segments.first(where: { $0.range(of: #"^weekly(?:\s+\d+%|…)"#, options: [.regularExpression, .caseInsensitive]) != nil }) ?? ""
        let pathLikeSegmentCount = segments.filter { segment in
            segment.hasPrefix("~/") || segment.hasPrefix("/") || segment.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
        }.count
        let knownSegmentCount = contexts.count
            + (window.isEmpty ? 0 : 1)
            + (fastMode.isEmpty ? 0 : 1)
            + (fiveHourLimit.isEmpty ? 0 : 1)
            + (weeklyLimit.isEmpty ? 0 : 1)
            + pathLikeSegmentCount
        let hasCwdProjectShape = pathLikeSegmentCount >= 1 && segments.count >= 2
        guard knownSegmentCount >= 2 || hasCwdProjectShape else {
            return nil
        }

        let status = CodexTUIStatusBar(
            model: model,
            effort: effort,
            segments: segments,
            contexts: contexts,
            window: window,
            fastMode: fastMode,
            fiveHourLimit: fiveHourLimit,
            weeklyLimit: weeklyLimit
        )

        return Candidate(
            status: status,
            score: knownSegmentCount * 10 + segments.count,
            location: match.range.location
        )
    }

    private static func cleanLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[0-9?][0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func segmentText(from rawSegments: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: statusLineStartPattern,
            options: [.caseInsensitive]
        ) else {
            return rawSegments
        }

        let range = NSRange(rawSegments.startIndex..<rawSegments.endIndex, in: rawSegments)
        guard let match = expression.firstMatch(in: rawSegments, range: range),
              match.range.location > 0,
              let redrawRange = Range(match.range, in: rawSegments)
        else {
            return rawSegments
        }

        return String(rawSegments[..<redrawRange.lowerBound])
    }

    private static func cleanSegment(_ text: String) -> String {
        let cleaned = cleanLine(text)
            .replacingOccurrences(of: #"\s*›.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^weekly….*$"#, with: "weekly…", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^(weekly\s+\d+%).*$"#, with: "$1", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\d+(?:W|Wo|Wor|Work|Worki|Workin|Working)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }
}

enum CodexTUIEditedDiffLineKind: Hashable {
    case addition
    case deletion
    case hunk
    case context
}

struct CodexTUIEditedDiffLine: Identifiable, Hashable {
    let lineNumber: String?
    let marker: String?
    let content: String
    let kind: CodexTUIEditedDiffLineKind

    var id: String {
        "\(lineNumber ?? "_")|\(marker ?? "_")|\(content)|\(kind)"
    }
}

enum CodexTUIEditedDiffParser {
    static func lines(from text: String) -> [CodexTUIEditedDiffLine] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { line(from: $0) }
    }

    private static func line(from rawLine: String) -> CodexTUIEditedDiffLine? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("@@") {
            return CodexTUIEditedDiffLine(
                lineNumber: nil,
                marker: nil,
                content: trimmed,
                kind: .hunk
            )
        }

        if let numbered = numberedLine(from: trimmed) {
            return numbered
        }

        if let marker = trimmed.first, marker == "+" || marker == "-" {
            let contentStart = trimmed.index(after: trimmed.startIndex)
            let content = trimmed[contentStart...].droppingOneLeadingSpace()
            return CodexTUIEditedDiffLine(
                lineNumber: nil,
                marker: String(marker),
                content: String(content),
                kind: marker == "+" ? .addition : .deletion
            )
        }

        return CodexTUIEditedDiffLine(
            lineNumber: nil,
            marker: nil,
            content: trimmed,
            kind: .context
        )
    }

    private static func numberedLine(from trimmed: String) -> CodexTUIEditedDiffLine? {
        var numberEnd = trimmed.startIndex
        while numberEnd < trimmed.endIndex, trimmed[numberEnd].isNumber {
            numberEnd = trimmed.index(after: numberEnd)
        }

        guard numberEnd > trimmed.startIndex else { return nil }

        let lineNumber = String(trimmed[..<numberEnd])
        var restStart = numberEnd
        while restStart < trimmed.endIndex, trimmed[restStart].isWhitespace {
            restStart = trimmed.index(after: restStart)
        }

        guard restStart < trimmed.endIndex else {
            return CodexTUIEditedDiffLine(
                lineNumber: lineNumber,
                marker: nil,
                content: "",
                kind: .context
            )
        }

        let marker = trimmed[restStart]
        if marker == "+" || marker == "-" {
            let contentStart = trimmed.index(after: restStart)
            let content = trimmed[contentStart...].droppingOneLeadingSpace()
            return CodexTUIEditedDiffLine(
                lineNumber: lineNumber,
                marker: String(marker),
                content: String(content),
                kind: marker == "+" ? .addition : .deletion
            )
        }

        return CodexTUIEditedDiffLine(
            lineNumber: lineNumber,
            marker: nil,
            content: String(trimmed[restStart...]),
            kind: .context
        )
    }
}

enum CodexTUIPlanTaskState: Hashable {
    case completed
    case active
    case pending
}

struct CodexTUIPlanTask: Identifiable, Hashable {
    let marker: String
    var text: String
    var state: CodexTUIPlanTaskState

    var id: String {
        "\(marker)|\(text)|\(state)"
    }
}

enum CodexTUIPlanChecklistParser {
    static func tasks(from text: String) -> [CodexTUIPlanTask] {
        var tasks: [CodexTUIPlanTask] = []
        for line in normalizedLines(from: text) {
            if let task = task(from: line) {
                tasks.append(task)
            } else if let continuation = continuationText(from: line),
                      !tasks.isEmpty {
                tasks[tasks.count - 1].text += " \(continuation)"
            }
        }

        if let activeIndex = tasks.firstIndex(where: { $0.state == .pending }) {
            tasks[activeIndex].state = .active
        }
        return tasks
    }

    private static func normalizedLines(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func task(from rawLine: String) -> CodexTUIPlanTask? {
        var line = cleaned(rawLine)
        guard !line.isEmpty else { return nil }
        line = droppingTreePrefix(from: line)

        var hasActivePrefix = false
        if let activeMarker = activeMarkers.first(where: { line.hasPrefix($0) }) {
            hasActivePrefix = true
            line = String(line.dropFirst(activeMarker.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for marker in completedMarkers where line.hasPrefix(marker) {
            return makeTask(
                marker: "\u{2713}",
                text: String(line.dropFirst(marker.count)),
                state: .completed
            )
        }

        for marker in pendingMarkers where line.hasPrefix(marker) {
            return makeTask(
                marker: "\u{25A1}",
                text: String(line.dropFirst(marker.count)),
                state: hasActivePrefix ? .active : .pending
            )
        }

        return nil
    }

    private static func makeTask(
        marker: String,
        text rawText: String,
        state: CodexTUIPlanTaskState
    ) -> CodexTUIPlanTask? {
        let text = cleaned(rawText)
        guard !text.isEmpty else { return nil }
        return CodexTUIPlanTask(marker: marker, text: text, state: state)
    }

    private static func continuationText(from rawLine: String) -> String? {
        let text = cleaned(droppingTreePrefix(from: cleaned(rawLine)))
        guard !text.isEmpty else { return nil }
        guard !looksLikeTaskLine(text) else { return nil }
        return text
    }

    private static func looksLikeTaskLine(_ line: String) -> Bool {
        let cleaned = droppingTreePrefix(from: cleaned(line))
        return completedMarkers.contains(where: { cleaned.hasPrefix($0) }) ||
            pendingMarkers.contains(where: { cleaned.hasPrefix($0) }) ||
            activeMarkers.contains(where: { cleaned.hasPrefix($0) })
    }

    private static func droppingTreePrefix(from text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = line.first,
              first == "\u{2514}" ||
              first == "\u{251C}" ||
              first == "\u{2502}" ||
              first == "\u{21B3}" {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }

    private static func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[0-9?][0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let completedMarkers = ["[x]", "[X]", "\u{2713}", "\u{2714}", "\u{2611}"]
    private static let pendingMarkers = ["[ ]", "\u{25A1}", "\u{2610}"]
    private static let activeMarkers = ["\u{276F}", "\u{203A}", ">", "\u{25B8}", "\u{25B6}", "\u{2192}"]
}

enum CodexTUIEventParser {
    private struct LifecycleStatusRule {
        let title: String
        let prefixes: [String]
        let isRunning: Bool
    }

    private static let operationTitles = [
        "Read",
        "Search",
        "List",
        "Open",
        "Inspect",
        "Edit",
        "Update",
        "Write",
        "Task",
        "Tasks",
        "Plan",
    ]

    private static let lifecycleStatusRules: [LifecycleStatusRule] = [
        LifecycleStatusRule(title: "Spawned", prefixes: ["Spawned"], isRunning: false),
        LifecycleStatusRule(title: "Thinking", prefixes: ["Thinking"], isRunning: true),
        LifecycleStatusRule(title: "Running", prefixes: ["Running"], isRunning: true),
        LifecycleStatusRule(title: "Reading", prefixes: ["Reading"], isRunning: true),
        LifecycleStatusRule(title: "Opening", prefixes: ["Opening"], isRunning: true),
        LifecycleStatusRule(title: "Opened", prefixes: ["Opened"], isRunning: false),
        LifecycleStatusRule(title: "Starting", prefixes: ["Starting"], isRunning: true),
        LifecycleStatusRule(title: "Started", prefixes: ["Started"], isRunning: false),
        LifecycleStatusRule(title: "Launching", prefixes: ["Launching"], isRunning: true),
        LifecycleStatusRule(title: "Launched", prefixes: ["Launched"], isRunning: false),
        LifecycleStatusRule(title: "Connecting", prefixes: ["Connecting"], isRunning: true),
        LifecycleStatusRule(title: "Connected", prefixes: ["Connected"], isRunning: false),
        LifecycleStatusRule(title: "Disconnecting", prefixes: ["Disconnecting"], isRunning: true),
        LifecycleStatusRule(title: "Disconnected", prefixes: ["Disconnected"], isRunning: false),
        LifecycleStatusRule(title: "Resuming", prefixes: ["Resuming"], isRunning: true),
        LifecycleStatusRule(title: "Resumed", prefixes: ["Resumed"], isRunning: false),
        LifecycleStatusRule(title: "Finished waiting", prefixes: ["Finished waiting"], isRunning: false),
        LifecycleStatusRule(title: "Closing", prefixes: ["Closing"], isRunning: true),
        LifecycleStatusRule(title: "Closed", prefixes: ["Closed"], isRunning: false),
        LifecycleStatusRule(title: "Worked", prefixes: ["Worked for", "Worked"], isRunning: false),
        LifecycleStatusRule(title: "Failed", prefixes: ["Failed"], isRunning: false),
        LifecycleStatusRule(title: "Error", prefixes: ["Error", "Errored"], isRunning: false),
    ]

    private static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func canonicalizedStatusBullets(in text: String) -> String {
        let statusTitlePattern = [
            "Working",
            "Working for",
            "Thinking",
            "Running",
            "Reading",
            "Waiting",
            "Waiting for",
            #"Waiting(?:\s+for)?\s+background terminal"#,
            "Waited",
            #"Waited(?:\s+for)?\s+background terminal"#,
            "Spawned",
            "Opening",
            "Opened",
            "Starting",
            "Started",
            "Launching",
            "Launched",
            "Connecting",
            "Connected",
            "Disconnecting",
            "Disconnected",
            "Resuming",
            "Resumed",
            "Closing",
            "Closed",
            "Finished waiting",
            "Worked",
            "Failed",
            "Error",
            "Errored",
            "Ran",
            "Edited",
            "Explored",
            "Exploring",
            "Context compacted",
            "Updated Plan",
            "CollabAgentToolCall",
            "Collab Agent Tool Call",
            #"Queued\s*follow-?up\s*messages"#,
            #"Messages to be submitted after(?: the)? next tool call"#,
        ] + operationTitles

        let bulletPattern = #"(?m)^([ \t]*)[-*.•·]\s+(?=(?:"# + statusTitlePattern.joined(separator: "|") + #")\b)"#
        guard let bulletExpression = try? NSRegularExpression(pattern: bulletPattern, options: [.caseInsensitive]) else {
            return text
        }
        let separatorPattern = #"(?m)^([ \t]*[─━—―-]{3,}[ \t]*)(?=(?:"# + statusTitlePattern.joined(separator: "|") + #")\b)"#
        guard let separatorExpression = try? NSRegularExpression(pattern: separatorPattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let bulletCanonicalized = bulletExpression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1\u{2022} "
        )

        let canonicalizedRange = NSRange(
            bulletCanonicalized.startIndex..<bulletCanonicalized.endIndex,
            in: bulletCanonicalized
        )
        let separatorCanonicalized = separatorExpression.stringByReplacingMatches(
            in: bulletCanonicalized,
            options: [],
            range: canonicalizedRange,
            withTemplate: "$1\u{2022} "
        )
        return canonicalizedLooseStatusLines(in: separatorCanonicalized)
    }

    private static func canonicalizedLooseStatusLines(in text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                let line = String(rawLine)
                guard let statusLine = looseStatusLine(from: line) else {
                    return line
                }
                return "\u{2022} \(statusLine)"
            }
            .joined(separator: "\n")
    }

    private static func looseStatusLine(from rawLine: String) -> String? {
        var line = sanitize(rawLine)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard !line.hasPrefix("\u{2022}") else { return nil }
        guard !line.hasPrefix("\u{2514}"),
              !line.hasPrefix("\u{251C}"),
              !line.hasPrefix("\u{2502}"),
              !line.hasPrefix("\u{21B3}"),
              !line.hasPrefix("L ")
        else {
            return nil
        }

        while let first = line.first,
              first == "-" ||
              first == "*" ||
              first == "." ||
              first == "\u{00B7}" ||
              first == "\u{2500}" ||
              first == "\u{2501}" ||
              first == "\u{2014}" ||
              first == "\u{2015}" {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while let last = line.last,
              last == "\u{2500}" ||
              last == "\u{2501}" ||
              last == "\u{2014}" ||
              last == "\u{2015}" ||
              last == "-" {
            line.removeLast()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cleaned = cleanLine(line)
        guard !cleaned.isEmpty, looksLikeLooseStatusHeadline(cleaned) else {
            return nil
        }
        return cleaned
    }

    private static func looksLikeLooseStatusHeadline(_ line: String) -> Bool {
        let pattern = #"^(?:Working(?:\s+for\b|\b)|Thinking\b|Running\b|Reading\b|Worked\s+for\b|Waiting(?:\s+for\b|\b)|Finished\s+waiting\b|Waited(?:\s+for\b|\b)|Spawned\b|Opening\b|Opened\b|Starting\b|Started\b|Launching\b|Launched\b|Connecting\b|Connected\b|Disconnecting\b|Disconnected\b|Resuming\b|Resumed\b|Closing\b|Closed\b|Failed\b|Error\b|Errored\b|Ran\b|Edited\b|Explored\b|Exploring\b|Context compacted\b|Updated Plan\b|Plan\b|Tasks\b|CollabAgentToolCall\b|COLLABAGENTTOOLCALL\b|Collab\s+Agent\s+Tool\s+Call\b)"#
        return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func events(from text: String) -> [CodexTUIEvent] {
        CodexTUIParserCache.events(for: text) {
            let normalized = canonicalizedStatusBullets(in: normalizedText(text))

            var events: [CodexTUIEvent] = []
            for rawSegment in normalized.split(separator: "\u{2022}", omittingEmptySubsequences: true) {
                guard let event = event(from: String(rawSegment)) else { continue }
                append(event, to: &events)
            }

            for event in optionEvents(from: normalized) where !events.contains(event) {
                events.append(event)
            }

            return events
        }
    }

    static func currentTurnEvents(from text: String) -> [CodexTUIEvent] {
        CodexTUIParserCache.currentTurnEvents(for: text) {
            events(from: currentTurnText(from: text))
        }
    }

    static func currentActivityEvent(from text: String) -> CodexTUIEvent? {
        currentTurnEvents(from: text)
            .reversed()
            .first(where: isActivityEvent(_:))
    }

    private static func append(_ event: CodexTUIEvent, to events: inout [CodexTUIEvent]) {
        if event.kind == .waited {
            events.removeAll { $0.kind == .waiting }
        }

        if let last = events.last, shouldReplace(last, with: event) {
            events[events.count - 1] = event
        } else if events.last != event {
            events.append(event)
        }
    }

    static func queuedMessages(from text: String) -> [String] {
        queuedCandidateSegments(from: text)
            .flatMap { rawSegment -> [String] in
                let segment = String(rawSegment)
                let flatSegment = cleanLine(segment)
                guard isQueuedFollowUpSegment(flatSegment) else { return [] }
                return queuedMessages(fromQueuedBody: queuedFollowUpBody(from: segment))
            }
    }

    static func currentQueuedMessages(from text: String) -> [String] {
        CodexTUIParserCache.currentQueuedMessages(for: text) {
            let segments = queuedCandidateSegments(from: text)
            guard let queueIndex = segments.indices.reversed().first(where: { index in
                isQueuedFollowUpSegment(cleanLine(segments[index]))
            }) else {
                return []
            }

            let messages = queuedMessages(fromQueuedBody: queuedFollowUpBody(from: segments[queueIndex]))
            guard !messages.isEmpty else { return [] }

            let followingText = segments[segments.index(after: queueIndex)...].joined(separator: "\n")
            return queuedMessagesWereConsumed(messages, afterQueueText: followingText) ? [] : messages
        }
    }

    private static func queuedCandidateSegments(from text: String) -> [String] {
        let normalized = canonicalizedStatusBullets(in: normalizedText(text))
        return normalized
            .split(separator: "\u{2022}", omittingEmptySubsequences: true)
            .map { rawSegment in
                sanitize(String(rawSegment))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private static func currentTurnText(from text: String) -> String {
        let normalized = normalizedText(text)
        let pattern = #"(?m)(?:^|\n)›\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return normalized
        }

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = expression.matches(in: normalized, range: range).last,
              let promptRange = Range(match.range, in: normalized)
        else {
            return normalized
        }

        return String(normalized[promptRange.upperBound...])
    }

    private static func isActivityEvent(_ event: CodexTUIEvent) -> Bool {
        switch event.kind {
        case .ran, .edited, .explored, .exploring, .plan, .agent:
            return true
        case .status:
            return event.isRunning
        default:
            return false
        }
    }

    private static func event(from rawSegment: String) -> CodexTUIEvent? {
        let segment = sanitize(rawSegment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let flatSegment = cleanLine(segment)
        let flatStatusLine = firstStatusLine(from: segment)
        guard !segment.isEmpty else { return nil }

        if isInterruptedSegment(segment) {
            return interruptedEvent(from: segment)
        }

        if isWorkingSegment(flatStatusLine) {
            return workingEvent(from: flatStatusLine)
        }

        if let waitingPrefix = statusPrefix(for: flatStatusLine, candidates: [
            "Waiting for background terminal",
            "Waiting background terminal",
        ]) {
            return CodexTUIEvent(
                kind: .waiting,
                title: "Waiting",
                summary: statusSummary(from: flatStatusLine, prefix: waitingPrefix),
                detail: nil,
                isRunning: true
            )
        }

        if let waitedPrefix = statusPrefix(for: flatStatusLine, candidates: [
            "Waited for background terminal",
            "Waited background terminal",
        ]) {
            return CodexTUIEvent(
                kind: .waited,
                title: "Waited",
                summary: statusSummary(from: flatStatusLine, prefix: waitedPrefix),
                detail: nil,
                isRunning: false
            )
        }

        if let waitingPrefix = statusPrefix(for: flatStatusLine, candidates: ["Waiting for", "Waiting"]) {
            return CodexTUIEvent(
                kind: .waiting,
                title: "Waiting",
                summary: statusSummary(from: flatStatusLine, prefix: waitingPrefix),
                detail: nil,
                isRunning: true
            )
        }

        if let workedPrefix = statusPrefix(for: flatStatusLine, candidates: ["Worked for", "Worked"]) {
            return CodexTUIEvent(
                kind: .status,
                title: "Worked",
                summary: statusSummary(from: flatStatusLine, prefix: workedPrefix),
                detail: nil,
                isRunning: false
            )
        }

        if let waitedPrefix = statusPrefix(for: flatStatusLine, candidates: ["Waited"]) {
            return CodexTUIEvent(
                kind: .waited,
                title: "Waited",
                summary: statusSummary(from: flatStatusLine, prefix: waitedPrefix),
                detail: nil,
                isRunning: false
            )
        }

        if isQueuedFollowUpSegment(flatSegment) {
            return queuedFollowUpEvent(from: segment)
        }

        if let collabToolEvent = collabAgentToolEvent(from: segment, flatSegment: flatSegment) {
            return collabToolEvent
        }

        if let mcpStartupEvent = mcpStartupEvent(from: flatStatusLine) {
            return mcpStartupEvent
        }

        if let lifecycleStatusEvent = lifecycleStatusEvent(from: segment, flatStatusLine: flatStatusLine) {
            return lifecycleStatusEvent
        }

        if flatSegment.hasPrefix("Ran ") {
            return prefixedEvent(
                kind: .ran,
                title: "Ran",
                segment: segment,
                prefix: "Ran ",
                isRunning: false
            )
        }

        if flatSegment == "Edited" || flatSegment.hasPrefix("Edited ") {
            return prefixedEvent(
                kind: .edited,
                title: "Edited",
                segment: segment,
                prefix: "Edited",
                isRunning: false
            )
        }

        if flatSegment.hasPrefix("Explored") {
            return prefixedEvent(
                kind: .explored,
                title: "Explored",
                segment: segment,
                prefix: "Explored",
                isRunning: false
            )
        }

        if flatSegment.hasPrefix("Exploring") {
            return prefixedEvent(
                kind: .exploring,
                title: "Exploring",
                segment: segment,
                prefix: "Exploring",
                isRunning: true
            )
        }

        if flatSegment.hasPrefix("Context compacted") {
            return CodexTUIEvent(
                kind: .context,
                title: "Context compacted",
                summary: nil,
                detail: nil,
                isRunning: false
            )
        }

        if let planEvent = planEvent(from: segment, flatSegment: flatSegment) {
            return planEvent
        }

        if let operationEvent = operationEvent(from: segment, flatSegment: flatSegment) {
            return operationEvent
        }

        return nil
    }

    private static func optionEvents(from text: String) -> [CodexTUIEvent] {
        var events: [CodexTUIEvent] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = cleanLine(rawLine)
            guard !isPlanChecklistChildLine(line) else { continue }
            for event in optionEvents(in: line) where !events.contains(event) {
                events.append(event)
            }
        }

        return events
    }

    private static func optionEvents(in line: String) -> [CodexTUIEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = checkboxMarkers(in: trimmed)
        guard !markers.isEmpty else { return [] }

        return markers.enumerated().compactMap { index, marker in
            let bodyStart = marker.range.upperBound
            let bodyEnd = markers.indices.contains(index + 1)
                ? markers[index + 1].range.lowerBound
                : trimmed.endIndex
            let cursorStart = index > 0 ? markers[index - 1].range.upperBound : trimmed.startIndex
            let cursorPrefix = String(trimmed[cursorStart..<marker.range.lowerBound])
            let body = cleanOptionBody(String(trimmed[bodyStart..<bodyEnd]))
            guard !body.isEmpty else { return nil }

            return CodexTUIEvent(
                kind: .option,
                title: marker.text,
                summary: body,
                detail: nil,
                isRunning: false,
                isSelected: hasMenuCursor(cursorPrefix)
            )
        }
    }

    private static func hasMenuCursor(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return false
        }
        let cursorCharacters: Set<Character> = [
            "\u{276F}",
            "\u{203A}",
            ">",
            "\u{276D}",
            "\u{25B8}",
            "\u{25B6}",
            "\u{2192}",
        ]
        return cursorCharacters.contains(first) || trimmed.last.map { cursorCharacters.contains($0) } == true
    }

    private static func stripMenuCursor(from line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first,
              first == "\u{276F}" ||
              first == "\u{203A}" ||
              first == ">" ||
              first == "\u{276D}" ||
              first == "\u{25B8}" ||
              first == "\u{25B6}" ||
              first == "\u{2192}" ||
              first == "-" ||
              first == "*" {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func checkboxMarkers(in line: String) -> [(text: String, range: Range<String.Index>)] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[(?:x|X| )\]|☑|☒|☐|✅|✓|✔"#
        ) else {
            return []
        }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.matches(in: line, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return (String(line[range]), range)
        }
    }

    private static func cleanOptionBody(_ body: String) -> String {
        var cleaned = stripMenuCursor(from: body)

        for pattern in [
            #"\b(?:gpt|o|codex)[A-Za-z0-9._/-]*(?:-[A-Za-z0-9._/-]+)*\s+(?:xhigh|high|medium|low|minimal|normal)\s*·.*$"#,
            #"\bUse\s+[↑↓].*$"#,
            #"\bUse\s+arrow.*$"#,
            #"\b(?:space\s+to\s+(?:select|toggle)|enter\s+to\s+confirm|esc\s+to\s+cancel|escape\s+to\s+cancel).*$"#,
        ] {
            if let range = cleaned.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }

        return cleanLine(cleaned)
    }

    private static func isPlanChecklistChildLine(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first,
              first == "\u{2514}" ||
              first == "\u{251C}" ||
              first == "\u{2502}" ||
              first == "\u{21B3}"
        else {
            return false
        }
        trimmed.removeFirst()
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[x]") ||
            trimmed.hasPrefix("[X]") ||
            trimmed.hasPrefix("[ ]") ||
            trimmed.hasPrefix("\u{2713}") ||
            trimmed.hasPrefix("\u{2714}") ||
            trimmed.hasPrefix("\u{2611}") ||
            trimmed.hasPrefix("\u{25A1}") ||
            trimmed.hasPrefix("\u{2610}")
    }

    private static func isQueuedFollowUpSegment(_ segment: String) -> Bool {
        let compacted = segment.replacingOccurrences(of: " ", with: "").lowercased()
        return compacted.hasPrefix("queuedfollow-upmessages")
            || compacted.hasPrefix("queuedfollowupmessages")
            || compacted.hasPrefix("messagestobesubmittedafternexttoolcall")
            || compacted.hasPrefix("messagestobesubmittedafterthenexttoolcall")
    }

    private static func isInterruptedSegment(_ segment: String) -> Bool {
        normalizedStatusTokenText(segment).contains("conversationinterrupted")
    }

    private static func isWorkingSegment(_ segment: String) -> Bool {
        segment == "Working" ||
            segment.hasPrefix("Working(") ||
            segment.hasPrefix("Working (") ||
            segment.hasPrefix("Working·") ||
            segment.hasPrefix("Working ·") ||
            hasPrefix(segment, candidate: "Working for")
    }

    private static func firstStatusLine(from segment: String) -> String {
        let lines = segment.components(separatedBy: .newlines)
        for line in lines {
            let cleaned = cleanLine(line)
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return cleanLine(segment)
    }

    private static func workingEvent(from segment: String) -> CodexTUIEvent {
        CodexTUIEvent(
            kind: .working,
            title: "Working",
            summary: workingSummary(from: segment),
            detail: nil,
            isRunning: true
        )
    }

    private static func interruptedEvent(from segment: String) -> CodexTUIEvent {
        let normalized = normalizedStatusTokenText(segment)
        let detail = normalized.contains("tellthemodelwhattododifferently")
            ? "Tell the model what to do differently."
            : "Conversation interrupted."
        return CodexTUIEvent(
            kind: .interrupted,
            title: "Interrupted",
            summary: nil,
            detail: detail,
            isRunning: false
        )
    }

    private static func workingSummary(from segment: String) -> String? {
        if let summary = parentheticalText(in: segment) {
            return summary
        }
        if let forPrefix = statusPrefix(for: segment, candidates: ["Working for"]) {
            return statusSummary(from: segment, prefix: forPrefix)
        }
        return trailingStatusSummary(after: "Working", in: segment)
    }

    private static func collabAgentToolEvent(from segment: String, flatSegment: String) -> CodexTUIEvent? {
        let normalized = normalizedStatusTokenText(flatSegment)
        guard normalized.contains("collabagenttoolcall") else { return nil }

        let body = segment
            .replacingOccurrences(
                of: #"\bcollab\s*agent\s*tool\s*call\b"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"\bcollabagenttoolcall\b"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if body.isEmpty {
            return CodexTUIEvent(
                kind: .status,
                title: "Agent Tool",
                summary: nil,
                detail: nil,
                isRunning: false
            )
        }

        let split = splitHeadlineAndDetail(body)
        let statusText = [split.headline, split.detail]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let isRunning = statusText.contains("in progress") || statusText.contains("running")

        return CodexTUIEvent(
            kind: .status,
            title: "Agent Tool",
            summary: split.headline,
            detail: split.detail,
            isRunning: isRunning
        )
    }

    private static func mcpStartupEvent(from flatStatusLine: String) -> CodexTUIEvent? {
        let prefix = "Starting MCP servers"
        guard hasPrefix(flatStatusLine, candidate: prefix) else {
            return nil
        }

        var body = String(flatStatusLine.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var detailParts: [String] = []
        var elapsed: String?

        if let trailing = removeTrailingParenthetical(from: &body) {
            for part in trailing.split(separator: "\u{00B7}") {
                let cleanedPart = cleanLine(String(part))
                guard !cleanedPart.isEmpty else { continue }
                if elapsed == nil, CodexTUIElapsedTimer.containsElapsed(in: cleanedPart) {
                    elapsed = cleanedPart
                } else {
                    detailParts.append(cleanedPart)
                }
            }
        }

        let progress = removeLeadingParenthetical(from: &body)
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(":") {
            body.removeFirst()
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var summaryParts: [String] = []
        if let progress, !body.isEmpty {
            summaryParts.append("\(progress): \(body)")
        } else if let progress {
            summaryParts.append(progress)
        } else if !body.isEmpty {
            summaryParts.append(body)
        }
        if let elapsed {
            summaryParts.append(elapsed)
        }

        return CodexTUIEvent(
            kind: .status,
            title: "Starting MCP servers",
            summary: summaryParts.isEmpty ? nil : summaryParts.joined(separator: " \u{00B7} "),
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " \u{00B7} "),
            isRunning: true
        )
    }

    private static func removeTrailingParenthetical(from text: inout String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"),
              let open = trimmed.lastIndex(of: "(")
        else {
            text = trimmed
            return nil
        }

        let contentStart = trimmed.index(after: open)
        let contentEnd = trimmed.index(before: trimmed.endIndex)
        let content = String(trimmed[contentStart..<contentEnd])
        text = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content
    }

    private static func removeLeadingParenthetical(from text: inout String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("("),
              let close = trimmed.firstIndex(of: ")")
        else {
            text = trimmed
            return nil
        }

        let contentStart = trimmed.index(after: trimmed.startIndex)
        let content = String(trimmed[contentStart..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = String(trimmed[trimmed.index(after: close)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmed
        return content.nilIfEmpty
    }

    private static func statusPrefix(for segment: String, candidates: [String]) -> String? {
        let normalizedSegment = segment.lowercased()
        for candidate in candidates {
            guard hasPrefix(normalizedSegment, candidate: candidate.lowercased()) else { continue }

            if let forRange = candidate.range(of: " for ") {
                return String(candidate[..<forRange.upperBound])
            }
            if let spaceIndex = candidate.firstIndex(of: " ") {
                return String(candidate[...spaceIndex])
            }
            return candidate
        }
        return nil
    }

    private static func shouldReplace(_ existing: CodexTUIEvent, with candidate: CodexTUIEvent) -> Bool {
        existing.kind == candidate.kind &&
            existing.title == candidate.title &&
            existing.detail == nil &&
            candidate.detail == nil &&
            (candidate.kind == .working ||
                candidate.kind == .waiting ||
                candidate.kind == .exploring ||
                (candidate.kind == .status && candidate.isRunning))
    }

    private static func lifecycleStatusEvent(from segment: String, flatStatusLine: String) -> CodexTUIEvent? {
        for rule in lifecycleStatusRules {
            guard let prefix = statusPrefix(for: flatStatusLine, candidates: rule.prefixes) else {
                continue
            }

            guard let event = prefixedEvent(
                kind: .status,
                title: rule.title,
                segment: segment,
                prefix: prefix,
                isRunning: rule.isRunning
            ) else {
                return nil
            }

            if isAgentLifecycleEvent(event) {
                return CodexTUIEvent(
                    kind: .agent,
                    title: event.title,
                    summary: event.summary,
                    detail: event.detail,
                    isRunning: event.isRunning
                )
            }
            return event
        }
        return nil
    }

    private static func prefixedEvent(
        kind: CodexTUIEventKind,
        title: String,
        segment: String,
        prefix: String,
        isRunning: Bool
    ) -> CodexTUIEvent? {
        let body = String(segment.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let split = splitHeadlineAndDetail(
            body,
            preservesDetailSpacing: kind == .edited
        )
        return CodexTUIEvent(
            kind: kind,
            title: title,
            summary: split.headline,
            detail: split.detail,
            isRunning: isRunning
        )
    }

    private static func operationEvent(from segment: String, flatSegment: String) -> CodexTUIEvent? {
        guard let title = operationTitles.first(where: { title in
            flatSegment == title || flatSegment.hasPrefix("\(title) ")
        }) else {
            return nil
        }

        return prefixedEvent(
            kind: .explored,
            title: title,
            segment: segment,
            prefix: title,
            isRunning: false
        )
    }

    private static func planEvent(from segment: String, flatSegment: String) -> CodexTUIEvent? {
        for title in ["Updated Plan", "Plan", "Tasks"] where flatSegment == title || flatSegment.hasPrefix("\(title) ") {
            return prefixedEvent(
                kind: .plan,
                title: title,
                segment: segment,
                prefix: title,
                isRunning: false
            )
        }
        return nil
    }

    private static func queuedFollowUpEvent(from segment: String) -> CodexTUIEvent {
        let body = queuedFollowUpBody(from: segment)
        let split = splitHeadlineAndDetail(body)
        return CodexTUIEvent(
            kind: .queued,
            title: "Queued",
            summary: "follow-up message",
            detail: cleanQueuedFollowUpDetail(split.detail ?? split.headline),
            isRunning: true
        )
    }

    private static func queuedFollowUpBody(from segment: String) -> String {
        if let arrowRange = segment.range(of: "\u{21B3}") {
            return String(segment[arrowRange.lowerBound...])
        }

        for prefix in [
            "Queued follow-up messages",
            "Queuedfollow-upmessages",
            "Queued followup messages",
            "Queuedfollowupmessages",
            "Messages to be submitted after next tool call",
            "Messages to be submitted after the next tool call",
            "Messagestobesubmittedafternexttoolcall",
            "Messagestobesubmittedafterthenexttoolcall",
        ] {
            if let range = segment.range(of: prefix) {
                return String(segment[range.upperBound...])
            }
        }

        return segment
    }

    private static func cleanQueuedFollowUpDetail(_ text: String?) -> String? {
        guard var detail = text else { return nil }
        if let editHintRange = detail.range(of: " shift + \u{2190}", options: .caseInsensitive) {
            detail = String(detail[..<editHintRange.lowerBound])
        }
        for marker in [" tab to queue message", " press esc to interrupt"] {
            if let markerRange = detail.range(of: marker, options: .caseInsensitive) {
                detail = String(detail[..<markerRange.lowerBound])
            }
        }
        if let promptRange = detail.range(
            of: #"\s+›\s+"#,
            options: .regularExpression
        ) {
            detail = String(detail[..<promptRange.lowerBound])
        }
        if let statusRange = detail.range(
            of: #"\s+(?:gpt|o|codex)[A-Za-z0-9._/-]*(?:-[A-Za-z0-9._/-]+)*\s+(?:xhigh|high|medium|low|minimal|normal)\s*·\s*Context\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            detail = String(detail[..<statusRange.lowerBound])
        }
        return cleanLine(detail).nilIfEmpty
    }

    private static func queuedMessages(fromQueuedBody body: String) -> [String] {
        let sanitizedBody = sanitize(body)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedBody.isEmpty else { return [] }

        let arrowParts = sanitizedBody
            .components(separatedBy: "\u{21B3}")
            .dropFirst()
            .compactMap(cleanQueuedFollowUpDetail(_:))
        if !arrowParts.isEmpty {
            return uniqueMessages(arrowParts)
        }

        return cleanQueuedFollowUpDetail(sanitizedBody).map { [$0] } ?? []
    }

    private static func uniqueMessages(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { message in
            seen.insert(message).inserted
        }
    }

    private static func queuedMessagesWereConsumed(
        _ messages: [String],
        afterQueueText text: String
    ) -> Bool {
        let promptBodies = promptBodies(in: text)
        guard !promptBodies.isEmpty else { return false }

        return messages.contains { message in
            promptBodies.contains { promptBody in
                queuedMessage(message, matchesConsumedPrompt: promptBody)
            }
        }
    }

    private static func promptBodies(in text: String) -> [String] {
        text.components(separatedBy: "\u{203A}")
            .dropFirst()
            .compactMap { rawBody in
                var body = String(rawBody)
                if let bulletRange = body.range(of: "\u{2022}") {
                    body = String(body[..<bulletRange.lowerBound])
                }
                if let statusRange = body.range(
                    of: #"\b(?:gpt|o|codex)[A-Za-z0-9._/-]*(?:-[A-Za-z0-9._/-]+)*\s+(?:xhigh|high|medium|low|minimal|normal)\s*·.*$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) {
                    body = String(body[..<statusRange.lowerBound])
                }
                return cleanLine(body).nilIfEmpty
            }
    }

    private static func queuedMessage(
        _ message: String,
        matchesConsumedPrompt promptBody: String
    ) -> Bool {
        let queued = comparableQueuedMessage(message)
        let prompt = comparableQueuedMessage(promptBody)
        guard !queued.isEmpty, !prompt.isEmpty else { return false }

        if queued.count < 12 {
            return prompt == queued
        }

        return prompt == queued ||
            prompt.contains(queued) ||
            (prompt.count >= 24 && queued.contains(prompt))
    }

    private static func comparableQueuedMessage(_ text: String) -> String {
        cleanLine(text)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func splitHeadlineAndDetail(
        _ body: String,
        preservesDetailSpacing: Bool = false
    ) -> (headline: String?, detail: String?) {
        for childMarker in ["\u{2514}", "\u{21B3}", "L "] {
            if let markerRange = body.range(of: childMarker) {
                let headline = cleanLine(String(body[..<markerRange.lowerBound]))
                let detailStart = markerRange.upperBound
                let detail = cleanMultilineDetail(
                    String(body[detailStart...]),
                    preservesSpacing: preservesDetailSpacing
                )
                return (headline.nilIfEmpty, detail.nilIfEmpty)
            }
        }

        if let newlineIndex = body.firstIndex(of: "\n") {
            let headline = cleanLine(String(body[..<newlineIndex]))
            let detailStart = body.index(after: newlineIndex)
            let detail = cleanMultilineDetail(
                String(body[detailStart...]),
                preservesSpacing: preservesDetailSpacing
            )
            return (headline.nilIfEmpty, detail.nilIfEmpty)
        }

        return (cleanLine(body).nilIfEmpty, nil)
    }

    private static func statusSummary(from segment: String, prefix: String) -> String? {
        var summary = String(segment.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let elapsed = parentheticalText(in: segment) {
            if let closedRange = summary.range(of: "(\(elapsed))") {
                summary.removeSubrange(closedRange)
            } else if let openRange = summary.range(of: "(\(elapsed)") {
                summary.removeSubrange(openRange)
            }
            summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? elapsed : "\(summary) · \(elapsed)"
        }
        if summary.hasPrefix("for ") {
            summary = String(summary.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleanLine(trimDecorativeStatusTail(summary)).nilIfEmpty
    }

    private static func trailingStatusSummary(after prefix: String, in segment: String) -> String? {
        var summary = String(segment.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in ["·", "\u{2022}", "-"] {
            if summary.hasPrefix(separator) {
                summary = String(summary.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if summary.hasPrefix("for ") {
            summary = String(summary.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleanLine(trimDecorativeStatusTail(summary)).nilIfEmpty
    }

    private static func parentheticalText(in segment: String) -> String? {
        guard let open = segment.firstIndex(of: "(") else { return nil }
        let start = segment.index(after: open)
        let suffix = segment[start...]
        let end = suffix.firstIndex(of: ")") ?? suffix.endIndex
        return cleanLine(String(suffix[..<end])).nilIfEmpty
    }

    private static func isAgentLifecycleEvent(_ event: CodexTUIEvent) -> Bool {
        [event.summary, event.detail]
            .compactMap { $0 }
            .contains(where: containsAgentMention(_:))
    }

    private static func containsAgentMention(_ text: String) -> Bool {
        text.range(
            of: #"\b[A-Za-z][A-Za-z0-9._-]*\s+\[[A-Za-z][A-Za-z0-9._ -]*\]"#,
            options: .regularExpression
        ) != nil
    }

    private static func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[0-9?][0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func normalizedStatusTokenText(_ text: String) -> String {
        sanitize(text)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func cleanLine(_ text: String) -> String {
        sanitize(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanMultilineDetail(
        _ text: String,
        preservesSpacing: Bool = false
    ) -> String {
        sanitize(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                cleanDetailLine(String(line), preservesSpacing: preservesSpacing)
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private static func cleanDetailLine(_ line: String, preservesSpacing: Bool = false) -> String {
        if preservesSpacing {
            let withoutNewline = line.trimmingCharacters(in: .newlines)
            let cleaned = stripTreeMarkerPrefix(from: withoutNewline)
            return cleaned.trimmingCharacters(in: .whitespaces)
        }

        let cleaned = stripTreeMarkerPrefix(from: line.trimmingCharacters(in: .whitespacesAndNewlines))
        return cleanLine(cleaned)
    }

    private static func stripTreeMarkerPrefix(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["\u{2514}", "\u{21B3}", "\u{251C}", "\u{2502}"] {
            if cleaned.hasPrefix(marker) {
                cleaned.removeFirst()
                return cleaned.trimmingCharacters(in: .whitespaces)
            }
        }
        if cleaned.hasPrefix("L ") {
            cleaned.removeFirst()
            return cleaned.trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }

    private static func trimDecorativeStatusTail(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s*[─━—―-]{3,}\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func hasPrefix(_ line: String, candidate: String) -> Bool {
        let normalizedLine = line.lowercased()
        let normalizedCandidate = candidate.lowercased()
        guard normalizedLine.hasPrefix(normalizedCandidate) else { return false }
        if normalizedLine.count == normalizedCandidate.count {
            return true
        }
        let boundaryIndex = normalizedLine.index(
            normalizedLine.startIndex,
            offsetBy: normalizedCandidate.count
        )
        let boundary = normalizedLine[boundaryIndex]
        return !(boundary.isLetter || boundary.isNumber)
    }
}

enum CodexTUIHighlighter {
    static func runs(
        for text: String,
        eventKind: CodexTUIEventKind,
        part: CodexTUITextPart
    ) -> [CodexTUITextRun] {
        switch (eventKind, part) {
        case (.ran, .summary):
            return shellRuns(for: text)
        case (.edited, .summary), (.plan, .summary):
            return operationRuns(for: text)
        case (.explored, _), (.exploring, _):
            return operationRuns(for: text)
        case (.working, _), (.waiting, _), (.agent, _), (.waited, _), (.status, _):
            return statusRuns(for: text)
        case (.interrupted, _):
            return [CodexTUITextRun(text: text, role: .primary)]
        case (.option, .summary):
            return operationRuns(for: text)
        case (.queued, _):
            return [
                CodexTUITextRun(
                    text: text,
                    role: part == .summary ? .secondary : .primary
                )
            ]
        default:
            return [CodexTUITextRun(text: text, role: .primary)]
        }
    }

    private static func shellRuns(for text: String) -> [CodexTUITextRun] {
        var runs: [CodexTUITextRun] = []
        var expectCommand = true

        for token in shellTokens(from: text) {
            switch token.kind {
            case .whitespace:
                runs.append(CodexTUITextRun(text: token.text, role: .primary))
            case .quoted:
                runs.append(CodexTUITextRun(text: token.text, role: .literal))
            case .word:
                let role = shellRole(for: token.text, expectCommand: expectCommand)
                runs.append(CodexTUITextRun(text: token.text, role: role))

                if isShellCommandBoundary(token.text) {
                    expectCommand = true
                } else if token.text != "env" {
                    expectCommand = false
                }
            }
        }

        return coalescedRuns(runs)
    }

    private static func shellRole(for token: String, expectCommand: Bool) -> CodexTUITextRole {
        if isShellOperator(token) {
            return .operatorToken
        }
        if token.hasPrefix("-") {
            return .option
        }
        if token.range(of: #"^\d+[A-Za-z]?$"#, options: .regularExpression) != nil ||
            token.range(of: #"^\d+,\d+[A-Za-z]?$"#, options: .regularExpression) != nil {
            return .literal
        }
        if token.contains("/") || token.contains(".") {
            return .identifier
        }
        if expectCommand {
            return .command
        }
        return .primary
    }

    private static func operationRuns(for text: String) -> [CodexTUITextRun] {
        var runs: [CodexTUITextRun] = []
        var isFirstWord = true

        for token in wordTokens(from: text) {
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runs.append(CodexTUITextRun(text: token, role: .primary))
                if token.contains("\n") {
                    isFirstWord = true
                }
                continue
            }

            let role: CodexTUITextRole
            if isFirstWord && isOperationVerb(token) {
                role = .action
            } else if token == "in" || token == "from" || token == "to" || token == "with" {
                role = .secondary
            } else if token.contains("/") || token.contains(".") || token.contains("|") {
                role = .identifier
            } else {
                role = .primary
            }

            runs.append(CodexTUITextRun(text: token, role: role))
            isFirstWord = false
        }

        return coalescedRuns(runs)
    }

    private static func statusRuns(for text: String) -> [CodexTUITextRun] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\((?:gpt|o|codex)[A-Za-z0-9._/-]*(?:\s+[^)]*)?\)|\b[A-Za-z][A-Za-z0-9._-]*\s+\[[A-Za-z][A-Za-z0-9._ -]*\]"#,
            options: []
        ) else {
            return plainStatusRuns(for: text)
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else {
            return plainStatusRuns(for: text)
        }

        var runs: [CodexTUITextRun] = []
        var cursor = text.startIndex
        var usesSecondaryAfterSeparator = false

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            if cursor < matchRange.lowerBound {
                runs.append(contentsOf: plainStatusRuns(
                    for: String(text[cursor..<matchRange.lowerBound]),
                    usesSecondaryAfterSeparator: &usesSecondaryAfterSeparator
                ))
            }

            let matchedText = String(text[matchRange])
            if matchedText.hasPrefix("(") {
                runs.append(CodexTUITextRun(text: matchedText, role: .model))
            } else {
                runs.append(contentsOf: agentMentionRuns(for: matchedText))
            }
            cursor = matchRange.upperBound
        }

        if cursor < text.endIndex {
            runs.append(contentsOf: plainStatusRuns(
                for: String(text[cursor...]),
                usesSecondaryAfterSeparator: &usesSecondaryAfterSeparator
            ))
        }

        return coalescedRuns(runs)
    }

    private static func plainStatusRuns(for text: String) -> [CodexTUITextRun] {
        var usesSecondaryAfterSeparator = false
        return plainStatusRuns(
            for: text,
            usesSecondaryAfterSeparator: &usesSecondaryAfterSeparator
        )
    }

    private static func plainStatusRuns(
        for text: String,
        usesSecondaryAfterSeparator: inout Bool
    ) -> [CodexTUITextRun] {
        guard !text.isEmpty else { return [] }

        var runs: [CodexTUITextRun] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let separatorRanges = [" • ", " · "].compactMap { separator -> Range<String.Index>? in
                text.range(of: separator, range: cursor..<text.endIndex)
            }
            guard let separatorRange = separatorRanges.min(by: { $0.lowerBound < $1.lowerBound }) else {
                let role: CodexTUITextRole = usesSecondaryAfterSeparator ? .secondary : .primary
                runs.append(CodexTUITextRun(text: String(text[cursor...]), role: role))
                break
            }

            if cursor < separatorRange.lowerBound {
                let role: CodexTUITextRole = usesSecondaryAfterSeparator ? .secondary : .primary
                runs.append(CodexTUITextRun(text: String(text[cursor..<separatorRange.lowerBound]), role: role))
            }

            runs.append(CodexTUITextRun(text: String(text[separatorRange]), role: .dim))
            usesSecondaryAfterSeparator = true
            cursor = separatorRange.upperBound
        }

        return runs
    }

    private static func agentMentionRuns(for text: String) -> [CodexTUITextRun] {
        guard let bracketRange = text.range(of: " [") else {
            return [CodexTUITextRun(text: text, role: .agentName)]
        }

        return [
            CodexTUITextRun(text: String(text[..<bracketRange.lowerBound]), role: .agentName),
            CodexTUITextRun(text: " ", role: .primary),
            CodexTUITextRun(text: String(text[text.index(after: bracketRange.lowerBound)...]), role: .agentRole),
        ]
    }

    private static func isOperationVerb(_ token: String) -> Bool {
        [
            "Read",
            "Search",
            "List",
            "Open",
            "Inspect",
            "Edit",
            "Update",
            "Write",
            "Task",
            "Tasks",
            "Plan",
            "Updated",
        ].contains(token)
    }

    private enum ShellTokenKind {
        case word
        case quoted
        case whitespace
    }

    private struct ShellToken {
        let text: String
        let kind: ShellTokenKind
    }

    private static func shellTokens(from text: String) -> [ShellToken] {
        var tokens: [ShellToken] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character.isWhitespace {
                let start = index
                while index < text.endIndex, text[index].isWhitespace {
                    index = text.index(after: index)
                }
                tokens.append(ShellToken(text: String(text[start..<index]), kind: .whitespace))
                continue
            }

            if character == "\"" || character == "'" {
                let quote = character
                let start = index
                index = text.index(after: index)
                while index < text.endIndex {
                    let current = text[index]
                    index = text.index(after: index)
                    if current == quote {
                        break
                    }
                }
                tokens.append(ShellToken(text: String(text[start..<index]), kind: .quoted))
                continue
            }

            let start = index
            while index < text.endIndex,
                  !text[index].isWhitespace,
                  text[index] != "\"",
                  text[index] != "'" {
                index = text.index(after: index)
            }
            tokens.append(ShellToken(text: String(text[start..<index]), kind: .word))
        }

        return tokens
    }

    private static func wordTokens(from text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            let start = index
            let isWhitespace = text[index].isWhitespace
            while index < text.endIndex, text[index].isWhitespace == isWhitespace {
                index = text.index(after: index)
            }
            tokens.append(String(text[start..<index]))
        }

        return tokens
    }

    private static func isShellOperator(_ token: String) -> Bool {
        ["|", "||", "&&", ";", ">", ">>", "<", "2>", "2>&1"].contains(token)
    }

    private static func isShellCommandBoundary(_ token: String) -> Bool {
        ["|", "||", "&&", ";"].contains(token)
    }

    private static func coalescedRuns(_ runs: [CodexTUITextRun]) -> [CodexTUITextRun] {
        var output: [CodexTUITextRun] = []
        for run in runs {
            guard !run.text.isEmpty else { continue }
            if let last = output.last, last.role == run.role {
                output[output.count - 1] = CodexTUITextRun(
                    text: last.text + run.text,
                    role: run.role
                )
            } else {
                output.append(run)
            }
        }
        return output
    }
}

enum CodexTUIEventVisibility {
    static func eventsBySuppressingPinnedWorkingStatus(_ events: [CodexTUIEvent]) -> [CodexTUIEvent] {
        guard events.contains(where: { event in
            SessionFeedItemOrdering.isPinnedWorkingEvent(event) ||
                SessionFeedItemOrdering.isPinnedThinkingEvent(event)
        }) else {
            return events
        }

        return events.filter { event in
            !SessionFeedItemOrdering.isPinnedWorkingEvent(event) &&
                !SessionFeedItemOrdering.isPinnedThinkingEvent(event)
        }
    }

    static func eventsBySuppressingPinnedStatusStrips(_ events: [CodexTUIEvent]) -> [CodexTUIEvent] {
        let withoutQueued = events.filter { $0.kind != .queued }
        return eventsBySuppressingPinnedWorkingStatus(withoutQueued)
    }

    static func collapsedEvents(_ events: [CodexTUIEvent], limit: Int) -> [CodexTUIEvent] {
        guard !events.contains(where: { $0.kind == .option }) else {
            return events
        }
        guard limit > 0, events.count > limit else { return events }

        let tail = Array(events.suffix(limit))
        let tailIDs = Set(tail.map(\.id))
        let stickyRunningEvents = events.filter { event in
            event.isRunning && !tailIDs.contains(event.id)
        }

        return stickyRunningEvents + tail
    }
}

enum CodexTUIEventDetailPreview {
    static let collapsedLineCount = 2

    static func visibleDetail(
        for event: CodexTUIEvent,
        collapsesLongRanDetails: Bool
    ) -> String? {
        guard let detail = event.detail else { return nil }
        guard collapsesLongRanDetails, isExpandable(event) else { return detail }
        return visibleLines(from: detail).joined(separator: "\n")
    }

    static func isExpandable(_ event: CodexTUIEvent) -> Bool {
        guard event.kind == .ran, let detail = event.detail else { return false }
        return lines(from: detail).count > collapsedLineCount
    }

    private static func visibleLines(from detail: String) -> [String] {
        Array(lines(from: detail).prefix(collapsedLineCount))
    }

    private static func lines(from detail: String) -> [String] {
        detail
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

enum CodexTUILineRevealPlan {
    struct Step: Equatable {
        let characterCount: Int
        let reachedLineBoundary: Bool
    }

    static func startingCharacterCount(
        text: String,
        previousText: String,
        currentCharacterCount: Int
    ) -> Int {
        if previousText.isEmpty {
            return 0
        }
        if text.hasPrefix(previousText) {
            return min(currentCharacterCount, previousText.count, text.count)
        }
        return 0
    }

    static func nextStep(after characterCount: Int, in text: String) -> Step {
        let targetCount = text.count
        let safeCharacterCount = min(max(characterCount, 0), targetCount)
        guard safeCharacterCount < targetCount else {
            return Step(characterCount: targetCount, reachedLineBoundary: false)
        }

        let lineBoundaryCount = nextLineBoundaryCount(after: safeCharacterCount, in: text)
        let remainingInLine = max(1, lineBoundaryCount - safeCharacterCount)
        let characterStep = max(1, min(8, Int(ceil(Double(remainingInLine) * 0.22))))
        let nextCharacterCount = min(lineBoundaryCount, safeCharacterCount + characterStep)

        return Step(
            characterCount: nextCharacterCount,
            reachedLineBoundary: nextCharacterCount == lineBoundaryCount && nextCharacterCount < targetCount
        )
    }

    private static func nextLineBoundaryCount(after characterCount: Int, in text: String) -> Int {
        let start = text.index(text.startIndex, offsetBy: characterCount)
        if let newline = text[start..<text.endIndex].firstIndex(of: "\n") {
            return text.distance(from: text.startIndex, to: text.index(after: newline))
        }
        return text.count
    }
}

enum CodexTUIEventStyle {
    static func spinnerPreset(for event: CodexTUIEvent) -> HelmSpinnerPreset {
        switch event.kind {
        case .queued:
            return .rollingLine
        case .waiting:
            return .point
        case .status:
            return event.isRunning ? .point : .dots
        case .agent:
            return event.isRunning ? .point : .dots
        case .exploring:
            return .point
        case .working:
            return .dots2
        case .interrupted:
            return .point
        default:
            return .dots
        }
    }

    static func accent(for event: CodexTUIEvent) -> Color {
        switch event.kind {
        case .working, .exploring:
            return AppPalette.accent
        case .status:
            let normalizedTitle = event.title.lowercased()
            if normalizedTitle == "failed" || normalizedTitle == "error" {
                return AppPalette.warning
            }
            return event.isRunning ? AppPalette.accent : AppPalette.secondaryText
        case .agent:
            return event.isRunning ? AppPalette.accent : .green
        case .interrupted:
            return AppPalette.warning
        case .waiting:
            return AppPalette.secondaryText
        case .option:
            return AppPalette.accent
        case .queued:
            return AppPalette.warning
        case .ran, .edited, .explored, .plan:
            return .green
        case .waited:
            return AppPalette.secondaryText
        case .context:
            return .blue
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Substring {
    func droppingOneLeadingSpace() -> Substring {
        guard first == " " else { return self }
        return dropFirst()
    }
}

struct CodexTUIQueuedMessagesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let messages: [String]
    let isExpanded: Bool
    let onToggle: () -> Void

    private var collapsedText: String {
        CodexTUIQueuedMessagesPreview.collapsedText(for: messages)
    }

    private var canExpand: Bool {
        CodexTUIQueuedMessagesPreview.canExpand(messages)
    }

    var body: some View {
        Button {
            guard canExpand else { return }
            onToggle()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    WorkingSpriteView(
                        preset: CodexTUIEventStyle.spinnerPreset(for: queuedEvent),
                        tint: accent,
                        font: .system(size: 11, weight: .bold, design: .monospaced),
                        accessibilityLabel: "Queued"
                    )

                    Text("Queued")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)

                    Text("\u{21B3}")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppPalette.tertiaryText)

                    Text(collapsedText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppPalette.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if canExpand {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppPalette.tertiaryText)
                    }
                }

                if isExpanded, canExpand {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\u{21B3}")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AppPalette.tertiaryText)

                                Text(entry.element)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.leading, 26)
                    .transition(AppMotion.fade)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppPalette.backgroundBottom.opacity(0.96))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppPalette.border.opacity(0.55))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(AppMotion.quick(reduceMotion), value: isExpanded)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.detail.queuedMessages")
        .dismissesKeyboardOnDownSwipe()
    }

    private var queuedEvent: CodexTUIEvent {
        CodexTUIEvent(
            kind: .queued,
            title: "Queued",
            summary: nil,
            detail: messages.first,
            isRunning: true
        )
    }

    private var accent: Color {
        CodexTUIEventStyle.accent(for: queuedEvent)
    }
}

enum CodexTUIQueuedMessagesPreview {
    private static let collapsedCharacterCount = 72

    static func collapsedText(for messages: [String]) -> String {
        guard let first = messages.first else { return "" }
        let firstLine = first
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? first
        return canExpand(messages) ? "\(firstLine) ..." : firstLine
    }

    static func canExpand(_ messages: [String]) -> Bool {
        messages.count > 1 || messages.contains(where: isExpandable(_:))
    }

    private static func isExpandable(_ message: String) -> Bool {
        message.count > collapsedCharacterCount ||
            message
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .contains("\n")
    }
}

private struct CodexTUIPlanChecklistView: View {
    let detail: String
    var maxVisibleTasks: Int? = nil

    private var visibleTasks: [CodexTUIPlanTask] {
        let tasks = CodexTUIPlanChecklistParser.tasks(from: detail)
        guard let maxVisibleTasks, maxVisibleTasks > 0 else {
            return tasks
        }
        return Array(tasks.prefix(maxVisibleTasks))
    }

    private var isTruncated: Bool {
        guard let maxVisibleTasks, maxVisibleTasks > 0 else { return false }
        return CodexTUIPlanChecklistParser.tasks(from: detail).count > maxVisibleTasks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleTasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(task.marker)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(markerColor(for: task))
                        .frame(width: 14, alignment: .center)

                    Text(task.text)
                        .font(.system(size: 11, weight: task.state == .active ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(textColor(for: task))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isTruncated {
                Text("..")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryText)
                    .padding(.leading, 21)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markerColor(for task: CodexTUIPlanTask) -> Color {
        switch task.state {
        case .completed:
            return .green
        case .active:
            return AppPalette.accent
        case .pending:
            return .green.opacity(0.72)
        }
    }

    private func textColor(for task: CodexTUIPlanTask) -> Color {
        switch task.state {
        case .completed:
            return .green.opacity(0.72)
        case .active:
            return AppPalette.accent
        case .pending:
            return .green.opacity(0.72)
        }
    }
}

struct CodexTUITimelineView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let events: [CodexTUIEvent]
    var collapsesLongRanDetails = false
    var onOptionToggle: ((CodexTUIEvent) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(nonActiveEvents) { event in
                eventRow(event)
                    .transition(AppMotion.fade)
            }

            if let activeStatusEvent {
                eventRow(activeStatusEvent)
                    .transition(AppMotion.fade)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(AppMotion.quick(reduceMotion), value: animationKey)
    }

    private var activeStatusEvent: CodexTUIEvent? {
        events.reversed().first { $0.isRunning }
    }

    private var nonActiveEvents: [CodexTUIEvent] {
        guard let activeStatusEvent else { return events }
        return events.filter { $0.id != activeStatusEvent.id }
    }

    private var animationKey: String {
        let activeID = activeStatusEvent?.id ?? ""
        let trailingID = events.last?.id ?? ""
        return "\(events.count)|\(activeID)|\(trailingID)"
    }

    private func eventRow(_ event: CodexTUIEvent) -> some View {
        let shouldRevealText = event.id == events.last?.id

        return HStack(alignment: .top, spacing: 8) {
            leadingIndicator(for: event)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent(for: event))

                    if let summary = event.summary {
                        CodexTUIHighlightedText(
                            text: summary,
                            event: event,
                            part: .summary,
                            fallback: AppPalette.primaryText,
                            animateReveal: shouldRevealText
                        )
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let detail = CodexTUIEventDetailPreview.visibleDetail(for: event, collapsesLongRanDetails: collapsesLongRanDetails) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(detailIndicator(for: event))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(detailIndicatorColor(for: event))

                        if event.kind == .edited {
                            CodexTUIEditedDiffView(
                                text: detail,
                                animateReveal: shouldRevealText
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if event.kind == .plan {
                            CodexTUIPlanChecklistView(
                                detail: detail,
                                maxVisibleTasks: collapsesLongRanDetails ? 6 : nil
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            CodexTUIHighlightedText(
                                text: detail,
                                event: event,
                                part: .detail,
                                fallback: detailFallback(for: event),
                                animateReveal: shouldRevealText
                            )
                            .lineLimit(detailLineLimit(for: event))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if collapsesLongRanDetails, CodexTUIEventDetailPreview.isExpandable(event) {
                        Text("..")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(accent(for: event).opacity(0.58))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .contentShape(Rectangle())
        .background(
            event.isSelected ? accent(for: event).opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if event.isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent(for: event))
                    .frame(width: 3)
            }
        }
        .highPriorityGesture(
            TapGesture().onEnded {
                guard event.kind == .option else { return }
                onOptionToggle?(event)
            }
        )
    }

    @ViewBuilder
    private func leadingIndicator(for event: CodexTUIEvent) -> some View {
        if event.kind == .option {
            Text(event.isSelected ? "\u{276F}" : " ")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent(for: event))
                .frame(minWidth: 14, alignment: .center)
                .accessibilityHidden(!event.isSelected)
        } else if event.kind == .waiting {
            WaitingWaveSpriteView(
                tint: accent(for: event),
                font: .system(size: 11, weight: .bold, design: .monospaced),
                accessibilityLabel: event.title
            )
        } else if event.isRunning {
            WorkingSpriteView(
                preset: spinnerPreset(for: event),
                tint: accent(for: event),
                font: .system(size: 11, weight: .bold, design: .monospaced),
                accessibilityLabel: event.title
            )
        } else {
            Text("\u{2022}")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent(for: event))
        }
    }

    private func spinnerPreset(for event: CodexTUIEvent) -> HelmSpinnerPreset {
        CodexTUIEventStyle.spinnerPreset(for: event)
    }

    private func accent(for event: CodexTUIEvent) -> Color {
        CodexTUIEventStyle.accent(for: event)
    }

    private func detailFallback(for event: CodexTUIEvent) -> Color {
        event.kind == .ran ? accent(for: event).opacity(0.68) : AppPalette.secondaryText
    }

    private func detailLineLimit(for event: CodexTUIEvent) -> Int? {
        if event.kind == .ran {
            return collapsesLongRanDetails ? CodexTUIEventDetailPreview.collapsedLineCount : nil
        }
        return 5
    }

    private func detailIndicator(for event: CodexTUIEvent) -> String {
        event.kind == .queued ? "\u{21B3}" : "\u{2514}"
    }

    private func detailIndicatorColor(for event: CodexTUIEvent) -> Color {
        event.kind == .queued ? AppPalette.tertiaryText : accent(for: event).opacity(0.8)
    }
}

struct CodexTUIStatusLineView: View {
    let event: CodexTUIEvent
    @State private var timerAnchorDate = Date()
    @State private var timerAnchorSummary: String?

    var body: some View {
        Group {
            if usesLiveElapsedTimer {
                TimelineView(.periodic(from: timerAnchorDate, by: 1)) { context in
                    content(now: context.date)
                }
            } else {
                content(now: nil)
            }
        }
        .onAppear {
            resetTimerAnchor()
        }
        .onChange(of: timerAnchorKey) { _, _ in
            resetTimerAnchor()
        }
    }

    private func content(now: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow(now: now)

            if let detail = stackedDetail {
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2514}")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.8))

                    if event.kind == .edited {
                        CodexTUIEditedDiffView(
                            text: detail,
                            animateReveal: false,
                            maxVisibleLines: 12
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if event.kind == .plan {
                        CodexTUIPlanChecklistView(
                            detail: detail,
                            maxVisibleTasks: 6
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppPalette.backgroundBottom.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.border.opacity(0.55))
                .frame(height: 1)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.detail.liveTerminalStatus")
        .dismissesKeyboardOnDownSwipe()
    }

    private func headerRow(now: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusIndicator

            Text(event.title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)

            if let summary = summaryText(now: now) {
                CodexTUIHighlightedText(
                    text: summary,
                    event: event,
                    part: .summary,
                    fallback: AppPalette.primaryText,
                    animateReveal: false
                )
                .lineLimit(1)
            }

            if let detail = inlineDetail {
                Text("\u{21B3}")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.tertiaryText)

                CodexTUIHighlightedText(
                    text: detail,
                    event: event,
                    part: .detail,
                    fallback: AppPalette.primaryText,
                    animateReveal: false
                )
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var usesLiveElapsedTimer: Bool {
        guard event.isRunning else { return false }
        if event.kind == .working {
            return true
        }
        return event.summary.map(CodexTUIElapsedTimer.containsElapsed(in:)) ?? false
    }

    private var timerAnchorKey: String {
        "\(event.id)|\(event.summary ?? "")"
    }

    private func resetTimerAnchor() {
        timerAnchorDate = .now
        timerAnchorSummary = event.summary
    }

    private func summaryText(now: Date?) -> String? {
        guard usesLiveElapsedTimer else {
            return event.summary
        }

        let baseSummary = timerAnchorSummary ?? event.summary
        let elapsedOffset = max(0, Int((now ?? timerAnchorDate).timeIntervalSince(timerAnchorDate).rounded(.down)))

        if let baseSummary,
           let updatedSummary = CodexTUIElapsedTimer.advancingSummary(baseSummary, by: elapsedOffset) {
            return updatedSummary
        }

        if event.summary == nil {
            return CodexTUIElapsedTimer.elapsedSummary(fromSeconds: elapsedOffset)
        }

        return event.summary
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if event.kind == .waiting {
            WaitingWaveSpriteView(
                tint: accent,
                font: .system(size: 11, weight: .bold, design: .monospaced),
                accessibilityLabel: event.title
            )
        } else if event.isRunning {
            WorkingSpriteView(
                preset: CodexTUIEventStyle.spinnerPreset(for: event),
                tint: accent,
                font: .system(size: 11, weight: .bold, design: .monospaced),
                accessibilityLabel: event.title
            )
        } else {
            Text("\u{2022}")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
    }

    private var accent: Color {
        CodexTUIEventStyle.accent(for: event)
    }

    private var stackedDetail: String? {
        guard event.kind == .edited || event.kind == .plan else { return nil }
        return event.detail?.nilIfEmpty
    }

    private var inlineDetail: String? {
        if event.kind == .queued {
            return event.detail
        }
        guard event.kind != .edited, event.kind != .plan else { return nil }
        guard event.summary == nil else { return nil }
        return event.detail?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

struct CodexTUIStatusBarView: View {
    let status: CodexTUIStatusBar

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(status.parts.enumerated()), id: \.offset) { entry in
                    statusPart(entry.element, index: entry.offset)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(AppPalette.backgroundBottom.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.border.opacity(0.45))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.detail.codexStatusBar")
        .dismissesKeyboardOnDownSwipe()
    }

    private func statusPart(_ text: String, index: Int) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced, weight: index < 2 ? .semibold : .regular))
            .foregroundStyle(color(for: text, index: index))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppPalette.mutedPanel.opacity(index < 2 ? 0.78 : 0.45))
            )
    }

    private func color(for text: String, index: Int) -> Color {
        if index == 0 {
            return AppPalette.accent
        }
        if index == 1 || text.hasPrefix("Context") {
            return AppPalette.primaryText
        }
        if text.hasPrefix("~/") || text.hasPrefix("/") {
            return AppPalette.accentMuted
        }
        if text.localizedCaseInsensitiveContains("Fast off") {
            return AppPalette.secondaryText
        }
        if text.localizedCaseInsensitiveContains("Fast on") {
            return .green
        }
        return AppPalette.secondaryText
    }
}

private struct CodexTUIEditedDiffView: View {
    let text: String
    var animateReveal = true
    var maxVisibleLines: Int? = nil

    @State private var revealedCharacterCount = 0
    @State private var previousText = ""

    private var visibleText: String {
        guard animateReveal else { return text }
        return String(text.prefix(revealedCharacterCount))
    }

    private var lines: [CodexTUIEditedDiffLine] {
        let parsed = CodexTUIEditedDiffParser.lines(from: visibleText)
        guard let maxVisibleLines, maxVisibleLines > 0 else {
            return parsed
        }
        return Array(parsed.prefix(maxVisibleLines))
    }

    private var isTruncated: Bool {
        guard let maxVisibleLines, maxVisibleLines > 0 else { return false }
        return CodexTUIEditedDiffParser.lines(from: visibleText).count > maxVisibleLines
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    lineRow(line)
                }

                if isTruncated {
                    Text("..")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppPalette.secondaryText)
                        .padding(.leading, 38)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.mutedPanel.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppPalette.border.opacity(0.72), lineWidth: 1)
        )
        .task(id: text) {
            await animateRevealIfNeeded()
        }
    }

    private func lineRow(_ line: CodexTUIEditedDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.lineNumber ?? "")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(AppPalette.tertiaryText)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            Text(line.marker ?? " ")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(markerColor(for: line.kind))
                .frame(width: 16, alignment: .center)

            Text(verbatim: line.content)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(textColor(for: line.kind))
        }
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .background(
            rowBackground(for: line.kind),
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func textColor(for kind: CodexTUIEditedDiffLineKind) -> Color {
        switch kind {
        case .addition:
            return .green
        case .deletion:
            return AppPalette.danger
        case .hunk:
            return AppPalette.accent
        case .context:
            return AppPalette.primaryText
        }
    }

    private func markerColor(for kind: CodexTUIEditedDiffLineKind) -> Color {
        switch kind {
        case .addition:
            return .green
        case .deletion:
            return AppPalette.danger
        case .hunk:
            return AppPalette.accent
        case .context:
            return AppPalette.tertiaryText
        }
    }

    private func rowBackground(for kind: CodexTUIEditedDiffLineKind) -> Color {
        switch kind {
        case .addition:
            return Color.green.opacity(0.10)
        case .deletion:
            return AppPalette.danger.opacity(0.10)
        case .hunk:
            return AppPalette.accent.opacity(0.08)
        case .context:
            return Color.clear
        }
    }

    @MainActor
    private func animateRevealIfNeeded() async {
        guard animateReveal else {
            revealedCharacterCount = text.count
            previousText = text
            return
        }

        revealedCharacterCount = CodexTUILineRevealPlan.startingCharacterCount(
            text: text,
            previousText: previousText,
            currentCharacterCount: revealedCharacterCount
        )

        let targetCount = text.count
        while revealedCharacterCount < targetCount {
            let step = CodexTUILineRevealPlan.nextStep(
                after: revealedCharacterCount,
                in: text
            )
            revealedCharacterCount = step.characterCount
            do {
                try await Task.sleep(for: .milliseconds(step.reachedLineBoundary ? 36 : 16))
            } catch {
                return
            }
        }

        previousText = text
    }
}

private struct CodexTUIHighlightedText: View {
    let text: String
    let event: CodexTUIEvent
    let part: CodexTUITextPart
    let fallback: Color
    var animateReveal = true

    @State private var revealedCharacterCount = 0
    @State private var previousText = ""

    var body: some View {
        highlightedText
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .textRenderer(
                TranscriptRolloutTextRenderer(
                    revealPosition: animateReveal ? Double(revealedCharacterCount) : Double(text.count),
                    fadeWidth: 6
                )
            )
            .task(id: text) {
                await animateRevealIfNeeded()
            }
    }

    private var highlightedText: Text {
        let runs = CodexTUIHighlighter.runs(
            for: text,
            eventKind: event.kind,
            part: part
        )

        return runs.reduce(Text(verbatim: "")) { partial, run in
            partial + Text(verbatim: run.text).foregroundColor(color(for: run.role))
        }
    }

    private func color(for role: CodexTUITextRole) -> Color {
        switch role {
        case .primary:
            return fallback
        case .secondary:
            return AppPalette.secondaryText
        case .dim:
            return AppPalette.tertiaryText
        case .command, .action:
            return AppPalette.accent
        case .agentName:
            return .cyan
        case .agentRole:
            return .green
        case .model:
            return .purple
        case .option:
            return .pink
        case .literal:
            return .green
        case .operatorToken:
            return AppPalette.tertiaryText
        case .identifier:
            return .cyan
        }
    }

    @MainActor
    private func animateRevealIfNeeded() async {
        guard animateReveal else {
            revealedCharacterCount = text.count
            previousText = text
            return
        }

        revealedCharacterCount = CodexTUILineRevealPlan.startingCharacterCount(
            text: text,
            previousText: previousText,
            currentCharacterCount: revealedCharacterCount
        )

        let targetCount = text.count
        while revealedCharacterCount < targetCount {
            let step = CodexTUILineRevealPlan.nextStep(
                after: revealedCharacterCount,
                in: text
            )
            revealedCharacterCount = step.characterCount
            do {
                try await Task.sleep(for: .milliseconds(step.reachedLineBoundary ? 36 : 16))
            } catch {
                return
            }
        }

        previousText = text
    }
}
