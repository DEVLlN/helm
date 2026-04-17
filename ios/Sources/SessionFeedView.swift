import Foundation
import SwiftUI

struct SessionFeedView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let threadID: String
    @State private var expandedTerminalItemIDs: Set<String> = []
    @State private var cachedRenderState = FeedRenderState.empty
    @State private var cachedRenderSignature: FeedRenderSignature?
    @State private var visibleHistoryLimit = Self.initialVisibleHistoryLimit

    static let collapsedCodexTUIEventCount = 5
    private static let initialVisibleHistoryLimit = 48
    private static let historyPageSize = 48
    private static let renderHistoryItemLimit = 220
    private static let maxAnimatedAssistantTextLength = 2_400

    private struct FeedRenderState {
        let threadID: String
        let detailID: String
        let detailUpdatedAt: Double
        let backendID: String?
        let backendLabel: String?
        let displayItems: [RemoteThreadItem]
        let pendingItemIDs: Set<String>
        let currentTurnTUIEventsByItemID: [String: [CodexTUIEvent]]
        let liveTerminalFeedEventsByItemID: [String: [CodexTUIEvent]]
        let animationKey: String

        static let empty = FeedRenderState(
            threadID: "",
            detailID: "",
            detailUpdatedAt: 0,
            backendID: nil,
            backendLabel: nil,
            displayItems: [],
            pendingItemIDs: [],
            currentTurnTUIEventsByItemID: [:],
            liveTerminalFeedEventsByItemID: [:],
            animationKey: "0"
        )
    }

    private struct FeedRenderSignature: Equatable {
        private static let liveTerminalItemScanLimit = 320

        let threadID: String
        let detailUpdatedAtMS: Int64
        let turnCount: Int
        let lastTurnID: String
        let lastTurnStatus: String
        let lastTurnItemCount: Int
        let lastItemID: String
        let lastItemType: String
        let lastItemStatus: String
        let lastItemRawLength: Int
        let lastItemRawTailHash: Int
        let lastItemDetailLength: Int
        let latestLiveTerminalItemID: String
        let latestLiveTerminalItemStatus: String
        let latestLiveTerminalRawLength: Int
        let latestLiveTerminalRawTailHash: Int
        let latestLiveTerminalDetailLength: Int
        let pendingLocalTurnsSignature: String
        let backendID: String
        let backendLabel: String

        init(detail: RemoteThreadDetail, threadID: String) {
            let normalizedUpdatedAt =
                detail.updatedAt > 10_000_000_000
                    ? detail.updatedAt
                    : detail.updatedAt * 1_000
            detailUpdatedAtMS = Int64(normalizedUpdatedAt.rounded())
            self.threadID = threadID
            turnCount = detail.turns.count
            lastTurnID = detail.turns.last?.id ?? ""
            lastTurnStatus = detail.turns.last?.status ?? ""
            lastTurnItemCount = detail.turns.last?.items.count ?? 0
            let lastItem = detail.turns.last?.items.last
            lastItemID = lastItem?.id ?? ""
            lastItemType = lastItem?.type ?? ""
            lastItemStatus = lastItem?.status ?? ""
            lastItemRawLength = lastItem?.rawText?.count ?? 0
            lastItemRawTailHash = Self.tailHash(lastItem?.rawText)
            lastItemDetailLength = lastItem?.detail?.count ?? 0
            let latestLiveTerminalItem = Self.latestLiveTerminalItem(in: detail)
            latestLiveTerminalItemID = latestLiveTerminalItem?.id ?? ""
            latestLiveTerminalItemStatus = latestLiveTerminalItem?.status ?? ""
            latestLiveTerminalRawLength = latestLiveTerminalItem?.rawText?.count ?? 0
            latestLiveTerminalRawTailHash = Self.tailHash(latestLiveTerminalItem?.rawText)
            latestLiveTerminalDetailLength = latestLiveTerminalItem?.detail?.count ?? 0
            pendingLocalTurnsSignature = detail.turns
                .suffix(8)
                .filter { $0.id.hasPrefix("local-turn-") }
                .map { "\($0.id):\($0.items.count)" }
                .joined(separator: "|")
            backendID = detail.backendId ?? ""
            backendLabel = detail.backendLabel ?? ""
        }

        private static func latestLiveTerminalItem(in detail: RemoteThreadDetail) -> RemoteThreadItem? {
            var scannedItemCount = 0
            for turn in detail.turns.reversed() {
                for item in turn.items.reversed() {
                    scannedItemCount += 1
                    if SessionFeedItemOrdering.isLiveTerminalItem(item) {
                        return item
                    }
                    if scannedItemCount >= liveTerminalItemScanLimit {
                        return nil
                    }
                }
            }
            return nil
        }

        private static func tailHash(_ value: String?) -> Int {
            guard let value, !value.isEmpty else { return 0 }
            return String(value.suffix(1024)).hashValue
        }
    }

    private var homeDirectoryPath: String {
        NSHomeDirectory()
    }

    private var currentRenderSignature: FeedRenderSignature? {
        guard let detail = store.threadDetail(for: threadID) else { return nil }
        return FeedRenderSignature(detail: detail, threadID: threadID)
    }

    private var renderStateForDisplay: FeedRenderState {
        guard cachedRenderState.threadID == threadID else { return .empty }
        return cachedRenderState
    }

    var body: some View {
        Group {
            if let detail = store.threadDetail(for: threadID) {
                let renderState = renderStateForDisplay
                let allItems = renderState.displayItems
                let visibleItems = visibleHistoryItems(from: allItems)
                let hiddenItemCount = max(0, allItems.count - visibleItems.count)
                let enumeratedItems = Array(visibleItems.enumerated())
                if allItems.isEmpty {
                    WorkingStatusLabel(
                        text: "Waiting for output...",
                        preset: .dots2,
                        tint: AppPalette.secondaryText
                    )
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if hiddenItemCount > 0 {
                            olderHistoryButton(hiddenItemCount: hiddenItemCount)
                        }

                        ForEach(enumeratedItems, id: \.element.id) { entry in
                            let item = entry.element
                            feedLine(
                                item,
                                backendID: renderState.backendID ?? detail.backendId,
                                backendLabel: renderState.backendLabel ?? detail.backendLabel,
                                animateText: shouldAnimateAgentText(item, allItems: allItems),
                                isPending: renderState.pendingItemIDs.contains(item.id)
                            )
                            .transition(AppMotion.fade)
                        }
                    }
                    .animation(AppMotion.quick(reduceMotion), value: renderState.animationKey)
                }
            } else if let error = store.threadDetailError(for: threadID) {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryText)
                    .padding(.vertical, 20)
            } else {
                WorkingStatusLabel(
                    text: "Loading session...",
                    preset: .rollingLine,
                    tint: AppPalette.secondaryText
                )
                .padding(.vertical, 20)
            }
        }
        .onAppear {
            refreshRenderState(force: true)
        }
        .onChange(of: threadID) { _, _ in
            cachedRenderState = .empty
            cachedRenderSignature = nil
            visibleHistoryLimit = Self.initialVisibleHistoryLimit
            refreshRenderState(force: true)
        }
        .onChange(of: currentRenderSignature) { _, _ in
            refreshRenderState()
        }
    }

    private func refreshRenderState(force: Bool = false) {
        guard let detail = store.threadDetail(for: threadID) else {
            cachedRenderState = .empty
            cachedRenderSignature = nil
            return
        }

        let signature = FeedRenderSignature(detail: detail, threadID: threadID)
        guard force || signature != cachedRenderSignature else { return }
        cachedRenderState = buildRenderState(from: detail)
        cachedRenderSignature = signature
    }

    private func buildRenderState(from detail: RemoteThreadDetail) -> FeedRenderState {
        let sourceItems = materializedSourceItems(from: detail.turns)
        let items = SessionFeedItemOrdering.displayItems(
            sourceItems,
            detailUpdatedAt: detail.updatedAt
        )
        var currentTurnTUIEventsByItemID: [String: [CodexTUIEvent]] = [:]
        var liveTerminalFeedEventsByItemID: [String: [CodexTUIEvent]] = [:]
        for item in items where item.type == "commandExecution" {
            if item.title == "Live terminal",
               let output = terminalOutputContent(for: item) {
                currentTurnTUIEventsByItemID[item.id] = CodexTUIEventParser.currentTurnEvents(from: output)
            }
            if SessionFeedItemOrdering.isLiveTerminalItem(item) {
                liveTerminalFeedEventsByItemID[item.id] = SessionFeedItemOrdering.liveTerminalFeedEvents(from: item)
            }
        }
        let pendingItemIDs = Set(
            detail.turns
                .suffix(8)
                .filter { $0.id.hasPrefix("local-turn-") }
                .flatMap(\.items)
                .map(\.id)
        )

        return FeedRenderState(
            threadID: threadID,
            detailID: detail.id,
            detailUpdatedAt: detail.updatedAt,
            backendID: detail.backendId,
            backendLabel: detail.backendLabel,
            displayItems: items,
            pendingItemIDs: pendingItemIDs,
            currentTurnTUIEventsByItemID: currentTurnTUIEventsByItemID,
            liveTerminalFeedEventsByItemID: liveTerminalFeedEventsByItemID,
            animationKey: SessionFeedAnimationSignature.make(from: items)
        )
    }

    private func materializedSourceItems(from turns: [RemoteThreadTurn]) -> [RemoteThreadItem] {
        let targetLimit = max(Self.renderHistoryItemLimit, visibleHistoryLimit + Self.historyPageSize)
        var reversedItems: [RemoteThreadItem] = []
        reversedItems.reserveCapacity(targetLimit)
        var activeLiveTerminal: RemoteThreadItem?

        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                if activeLiveTerminal == nil, SessionFeedItemOrdering.isActiveLiveTerminalItem(item) {
                    activeLiveTerminal = item
                }
                if reversedItems.count < targetLimit {
                    reversedItems.append(item)
                }
            }

            if reversedItems.count >= targetLimit, activeLiveTerminal != nil {
                break
            }
        }

        var materializedItems = Array(reversedItems.reversed())
        if let activeLiveTerminal,
           !materializedItems.contains(where: { $0.id == activeLiveTerminal.id }) {
            materializedItems.insert(activeLiveTerminal, at: 0)
        }
        return materializedItems
    }

    private func visibleHistoryItems(from items: [RemoteThreadItem]) -> [RemoteThreadItem] {
        guard items.count > visibleHistoryLimit else { return items }

        var visibleItems = Array(items.suffix(visibleHistoryLimit))
        if let liveTerminal = items.first(where: { SessionFeedItemOrdering.isActiveLiveTerminalItem($0) }),
           !visibleItems.contains(where: { $0.id == liveTerminal.id }) {
            visibleItems.insert(liveTerminal, at: 0)
        }
        return visibleItems
    }

    private func shouldAnimateAgentText(_ item: RemoteThreadItem, allItems: [RemoteThreadItem]) -> Bool {
        guard !reduceMotion,
              item.id == allItems.last?.id,
              item.type == "agentMessage" else {
            return false
        }

        let textLength = (item.rawText ?? item.detail ?? item.title).count
        return textLength <= Self.maxAnimatedAssistantTextLength
    }

    private func olderHistoryButton(hiddenItemCount: Int) -> some View {
        Button {
            visibleHistoryLimit += Self.historyPageSize
            refreshRenderState(force: true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))

                Text("Show earlier history")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))

                Text("\(hiddenItemCount) older")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(AppPalette.secondaryText)
            }
            .foregroundStyle(AppPalette.primaryText)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                AppPalette.mutedPanel.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppPalette.border.opacity(0.7), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func feedLine(
        _ item: RemoteThreadItem,
        backendID: String?,
        backendLabel: String?,
        animateText: Bool,
        isPending: Bool
    ) -> some View {
        switch item.type {
        case "commandExecution":
            if let event = SessionFeedItemOrdering.codexToolEvent(from: item) {
                codexToolEventLine(item, event: event)
            } else {
                terminalBlock(item)
            }
        case "userMessage":
            userLine(item, isPending: isPending)
        case "agentMessage":
            agentLine(item, backendID: backendID, backendLabel: backendLabel, animateText: animateText)
        case "fileChange":
            fileLine(item)
        case "collabAgentToolCall":
            collabAgentToolLine(item)
        case "mcpToolCall", "dynamicToolCall", "webSearch":
            if let event = SessionFeedItemOrdering.codexToolEvent(from: item) {
                codexToolEventLine(item, event: event)
            } else {
                genericLine(item)
            }
        default:
            genericLine(item)
        }
    }

    @ViewBuilder
    private func logEntry<Content: View>(
        label: String,
        accent: Color,
        metadata: String? = nil,
        showsHeader: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsHeader || metadata?.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if showsHeader {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent)
                    }

                    if let metadata, !metadata.isEmpty {
                        Text(metadata)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(AppPalette.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    // MARK: - Terminal command + output

    private func terminalBlock(_ item: RemoteThreadItem) -> some View {
        let accent = terminalAccent(for: item)
        let output = terminalOutputContent(for: item)
        let command = normalizedCommand(item)
        let renderState = renderStateForDisplay
        let tuiEvents = renderState.currentTurnTUIEventsByItemID[item.id] ?? []
        let logTUIEvents = SessionFeedItemOrdering.isLiveTerminalItem(item)
            ? renderState.liveTerminalFeedEventsByItemID[item.id] ?? []
            : tuiEvents
        let isTUIOutput = !tuiEvents.isEmpty
        let visibleTUIEvents = visibleCodexTUIEvents(logTUIEvents, itemID: item.id)
        let isCommandExpandable = command.map { TerminalCommandPreview.isExpandable($0) } ?? false
        let isExpandable = isTUIOutput
            ? logTUIEvents.count > Self.collapsedCodexTUIEventCount ||
                logTUIEvents.contains { CodexTUIEventDetailPreview.isExpandable($0) }
            : (output.map { TerminalOutputPreview.isExpandable($0) } ?? false) || isCommandExpandable
        let isExpanded = expandedTerminalItemIDs.contains(item.id)
        let showsCommand = TerminalCommandPreview.shouldShowCommand(
            isExpanded: isExpanded,
            isExpandable: isExpandable,
            hasOutput: output != nil,
            isTUIOutput: isTUIOutput
        )

        return logEntry(
            label: "Terminal",
            accent: accent,
            metadata: terminalMetadata(for: item) ?? terminalHeadline(for: item),
            showsHeader: !isTUIOutput
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if let cmd = command, showsCommand {
                    Text("$ \(cmd)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(terminalAccent(for: item))
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }

                if isTUIOutput {
                    if !visibleTUIEvents.isEmpty {
                        CodexTUITimelineView(events: visibleTUIEvents, collapsesLongRanDetails: !isExpanded) { event in
                            Task { await toggleTerminalOption(event, in: logTUIEvents) }
                        }
                    }
                } else if let output {
                    TerminalInlineOutputView(
                        content: output,
                        accent: accent,
                        maxVisibleLines: isExpandable && !isExpanded ? TerminalOutputPreview.collapsedLineCount : nil
                    )
                }

                if isExpandable {
                    Button {
                        withAnimation(AppMotion.standard(reduceMotion)) {
                            if isExpanded {
                                expandedTerminalItemIDs.remove(item.id)
                            } else {
                                expandedTerminalItemIDs.insert(item.id)
                            }
                        }
                    } label: {
                        Text(isExpanded ? "Tap to collapse" : "Tap to expand")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isExpandable && !isTUIOutput else { return }
                withAnimation(AppMotion.standard(reduceMotion)) {
                    if isExpanded {
                        expandedTerminalItemIDs.remove(item.id)
                    } else {
                        expandedTerminalItemIDs.insert(item.id)
                    }
                }
            }
        }
    }

    private func visibleCodexTUIEvents(_ events: [CodexTUIEvent], itemID: String) -> [CodexTUIEvent] {
        if expandedTerminalItemIDs.contains(itemID) || events.count <= Self.collapsedCodexTUIEventCount {
            return events
        }
        return CodexTUIEventVisibility.collapsedEvents(
            events,
            limit: Self.collapsedCodexTUIEventCount
        )
    }

    private func toggleTerminalOption(_ event: CodexTUIEvent, in events: [CodexTUIEvent]) async {
        let options = events.filter { $0.kind == .option }
        guard let targetIndex = options.firstIndex(of: event) else {
            await store.sendTerminalInput(.space, threadID: threadID)
            return
        }

        var keys: [TerminalInputKey] = []
        if let selectedIndex = options.firstIndex(where: { $0.isSelected }) {
            let delta = targetIndex - selectedIndex
            let navigationKey: TerminalInputKey = delta > 0 ? .arrowDown : .arrowUp
            keys.append(contentsOf: Array(repeating: navigationKey, count: abs(delta)))
        }
        keys.append(.space)
        await store.sendTerminalInputs(keys, threadID: threadID)
    }

    private func normalizedCommand(_ item: RemoteThreadItem) -> String? {
        let command = item.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return nil }
        return command
    }

    private func terminalHeadline(for item: RemoteThreadItem) -> String {
        let status = item.status?.lowercased()

        if status == "running", terminalStatusShouldReadAsRunning(for: item) {
            return "Working"
        }

        if let exitCode = item.exitCode, exitCode != 0 {
            return "Terminal task failed"
        }

        if let command = normalizedCommand(item) {
            return "Ran \(command)"
        }

        return "Terminal task"
    }

    private func terminalMetadata(for item: RemoteThreadItem) -> String? {
        var parts: [String] = []

        if let status = item.status?.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty,
           status.lowercased() != "completed",
           terminalStatusShouldReadAsRunning(for: item) {
            parts.append(status.capitalized)
        }

        if let cwd = item.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            parts.append(compactPath(cwd))
        }

        if let exitCode = item.exitCode, exitCode != 0 {
            parts.append("exit \(exitCode)")
        }

        if parts.isEmpty,
           let summary = item.metadataSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }

        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }

    private func terminalOutputContent(for item: RemoteThreadItem) -> String? {
        normalizedMultilineText(item.rawText)
    }

    private func terminalAccent(for item: RemoteThreadItem) -> Color {
        if let exitCode = item.exitCode, exitCode != 0 {
            return AppPalette.danger
        }

        if item.status?.lowercased() == "running", terminalStatusShouldReadAsRunning(for: item) {
            return AppPalette.accent
        }

        return .green
    }

    private func terminalStatusShouldReadAsRunning(for item: RemoteThreadItem) -> Bool {
        if SessionFeedItemOrdering.isLiveTerminalItem(item) {
            return SessionFeedItemOrdering.hasCurrentLiveTerminalRunningStatus(item)
        }

        return true
    }

    // MARK: - User input

    private func userLine(_ item: RemoteThreadItem, isPending: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 44)

            TranscriptMessageBubble(
                text: item.rawText ?? item.detail ?? item.title,
                role: isPending ? .pendingUser : .user,
                backendId: nil
            )
            .equatable()
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                AppPalette.mutedPanel.opacity(isPending ? 0.56 : 0.82),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke((isPending ? AppPalette.warning : AppPalette.border).opacity(0.55), lineWidth: 1)
            )
            .frame(maxWidth: 280, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 2)
    }

    // MARK: - Agent message

    private func agentLine(
        _ item: RemoteThreadItem,
        backendID: String?,
        backendLabel: String?,
        animateText: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptMessageBubble(
                text: item.rawText ?? item.detail ?? item.title,
                role: .assistant,
                backendId: backendID,
                animateText: animateText
            )
            .equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    // MARK: - File changes

    private func fileLine(_ item: RemoteThreadItem) -> some View {
        logEntry(
            label: "Changed:",
            accent: .blue,
            metadata: item.detail ?? item.title
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let rawText = fileChangeSnippet(for: item) {
                    TranscriptCodeBlockCard(
                        content: rawText,
                        language: "diff",
                        accent: .blue,
                        background: AppPalette.mutedPanel.opacity(0.7),
                        border: AppPalette.border
                    )
                }
            }
        }
    }

    private func backendDisplayLabel(backendID: String?, backendLabel: String?) -> String {
        if let backendLabel, !backendLabel.isEmpty {
            return backendLabel
        }

        if backendID == "claude-code" {
            return "Claude"
        }

        return "Codex"
    }

    private func assistantAccent(for backendID: String?) -> Color {
        backendID == "claude-code" ? .orange : .green
    }

    private func fileChangeSnippet(for item: RemoteThreadItem) -> String? {
        truncatedSnippet(item.rawText)
    }

    private func normalizedMultilineText(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func truncatedSnippet(_ text: String?, maxLines: Int = 6) -> String? {
        guard let normalized = normalizedMultilineText(text) else { return nil }

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let snippet = lines.prefix(maxLines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else { return nil }

        return lines.count > maxLines ? "\(snippet)\n…" : snippet
    }

    private func compactPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if path == homeDirectoryPath {
            return "~"
        }
        if path.hasPrefix(homeDirectoryPath + "/") {
            return "~" + path.dropFirst(homeDirectoryPath.count)
        }
        return path
    }

    // MARK: - Generic (hooks, skills, plans, reasoning, web search)

    private func collabAgentToolLine(_ item: RemoteThreadItem) -> some View {
        let sourceText = item.rawText ?? item.detail ?? item.title
        let parsedEvents = CodexTUIEventParser.currentTurnEvents(from: sourceText)
        let isRunningStatus = (item.status ?? "").lowercased() == "running" ||
            (item.status ?? "").lowercased() == "inprogress"
        let fallbackSummary = [item.detail, item.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { value in
                !value.isEmpty &&
                    !value.localizedCaseInsensitiveContains("collab agent tool call") &&
                    !value.localizedCaseInsensitiveContains("collabagenttoolcall")
            })
        let fallbackEvent = CodexTUIEvent(
            kind: .status,
            title: "Agent Tool",
            summary: fallbackSummary,
            detail: nil,
            isRunning: isRunningStatus
        )
        let events = parsedEvents.isEmpty ? [fallbackEvent] : parsedEvents

        return logEntry(
            label: "Agent",
            accent: AppPalette.accent,
            metadata: nil,
            showsHeader: false
        ) {
            CodexTUITimelineView(events: events, collapsesLongRanDetails: true) { event in
                Task { await toggleTerminalOption(event, in: events) }
            }
        }
    }

    private func codexToolEventLine(_ item: RemoteThreadItem, event: CodexTUIEvent) -> some View {
        logEntry(
            label: "Codex",
            accent: CodexTUIEventStyle.accent(for: event),
            metadata: nil,
            showsHeader: false
        ) {
            CodexTUITimelineView(events: [event], collapsesLongRanDetails: true) { event in
                Task { await toggleTerminalOption(event, in: [event]) }
            }
        }
    }

    private func genericLine(_ item: RemoteThreadItem) -> some View {
        logEntry(
            label: FeedStyle.itemLabel(for: item),
            accent: FeedStyle.itemAccent(for: item),
            metadata: item.title != FeedStyle.itemLabel(for: item) ? item.title : nil
        ) {
            Text(item.rawText ?? item.detail ?? item.title)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppPalette.secondaryText)
                .textSelection(.enabled)
        }
    }
}

private enum SessionFeedAnimationSignature {
    static func make(from items: [RemoteThreadItem]) -> String {
        guard let last = items.last else { return "0" }
        return [
            "\(items.count)",
            last.id,
            last.type,
            last.title,
            last.status ?? "",
            "\(last.exitCode ?? 0)",
        ].joined(separator: "|")
    }
}

enum TerminalOutputPreview {
    static let collapsedLineCount = 1

    static func lines(from content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func visibleLines(from content: String) -> [String] {
        visibleLines(from: content, maxVisibleLines: collapsedLineCount)
    }

    static func visibleLines(from content: String, maxVisibleLines: Int?) -> [String] {
        let lines = lines(from: content)
        guard let maxVisibleLines, maxVisibleLines > 0 else { return lines }
        return Array(lines.prefix(maxVisibleLines))
    }

    static func isExpandable(_ content: String) -> Bool {
        isExpandable(content, collapsedLineCount: collapsedLineCount)
    }

    static func isExpandable(_ content: String, collapsedLineCount: Int) -> Bool {
        lines(from: content).count > collapsedLineCount
    }
}

enum TerminalCommandPreview {
    static let collapsedCharacterCount = 48

    static func isExpandable(_ command: String) -> Bool {
        lines(from: command).count > 1 ||
            command.count > collapsedCharacterCount
    }

    static func shouldShowCommand(
        isExpanded: Bool,
        isExpandable: Bool,
        hasOutput: Bool,
        isTUIOutput: Bool
    ) -> Bool {
        isExpanded || !isExpandable || !hasOutput || isTUIOutput
    }

    private static func lines(from command: String) -> [String] {
        command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

private struct TerminalInlineOutputView: View {
    let content: String
    let accent: Color
    var maxVisibleLines: Int? = nil

    private var visibleLines: [String] {
        TerminalOutputPreview.visibleLines(from: content, maxVisibleLines: maxVisibleLines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { entry in
                terminalLine(entry.element)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func terminalLine(_ line: String) -> some View {
        Text(verbatim: line.isEmpty ? " " : line)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(accent.opacity(0.68))
            .lineLimit(maxVisibleLines == nil ? nil : 1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SessionFeedItemOrdering {
    private static let activeWorkingFreshnessInterval: TimeInterval = 30
    private static let liveTerminalParseUTF16Limit = 32_000

    struct LiveTerminalProjection: Hashable {
        var statusEvent: CodexTUIEvent?
        var activityEvent: CodexTUIEvent?
        var statusBar: CodexTUIStatusBar?
        var queuedMessages: [String] = []

        var workingEvent: CodexTUIEvent? {
            guard statusEvent?.kind == .working else { return nil }
            return statusEvent
        }

        var interruptedEvent: CodexTUIEvent? {
            guard statusEvent?.kind == .interrupted else { return nil }
            return statusEvent
        }

        var thinkingEvent: CodexTUIEvent? {
            if let statusEvent, SessionFeedItemOrdering.isPinnedThinkingEvent(statusEvent) {
                return statusEvent
            }
            if let activityEvent, SessionFeedItemOrdering.isPinnedThinkingEvent(activityEvent) {
                return activityEvent
            }
            return nil
        }

        var pinnedStatusLineEvent: CodexTUIEvent? {
            workingEvent ?? thinkingEvent
        }

        static let empty = LiveTerminalProjection()
    }

    static func displayItems(
        _ items: [RemoteThreadItem],
        detailUpdatedAt: Double? = nil,
        now: Date = .now
    ) -> [RemoteThreadItem] {
        let visibleLiveTerminalItemID = items.reversed().first { item in
            isDisplayableLiveTerminalItem(
                item,
                detailUpdatedAt: detailUpdatedAt,
                now: now
            )
        }?.id

        return items.filter { item in
            guard !isSuppressibleCompletedLocalToolItem(item) else { return false }
            guard isLiveTerminalItem(item) else { return true }
            return item.id == visibleLiveTerminalItemID
        }
    }

    static func activeLiveTerminalWorkingEvent(
        from items: [RemoteThreadItem],
        detailUpdatedAt: Double? = nil,
        now: Date = .now
    ) -> CodexTUIEvent? {
        activeLiveTerminalProjection(
            from: items,
            detailUpdatedAt: detailUpdatedAt,
            now: now
        ).workingEvent
    }

    static func activeLiveTerminalStatusBar(from items: [RemoteThreadItem]) -> CodexTUIStatusBar? {
        activeLiveTerminalProjection(from: items).statusBar
    }

    static func activeLiveTerminalQueuedMessages(
        from items: [RemoteThreadItem],
        detailUpdatedAt: Double? = nil,
        now: Date = .now
    ) -> [String] {
        activeLiveTerminalProjection(
            from: items,
            detailUpdatedAt: detailUpdatedAt,
            now: now
        ).queuedMessages
    }

    static func activeLiveTerminalProjection(
        from items: [RemoteThreadItem],
        detailUpdatedAt: Double? = nil,
        now: Date = .now
    ) -> LiveTerminalProjection {
        var projection = LiveTerminalProjection.empty
        let isFresh = isFreshLiveTerminalDetail(detailUpdatedAt, now: now)
        var statusSourceText: String? = nil

        for item in items.reversed() where isLiveTerminalItem(item) {
            guard let rawText = item.rawText ?? item.detail else { continue }
            let text = recentLiveTerminalParseText(from: rawText)

            if projection.statusBar == nil {
                projection.statusBar = CodexTUIStatusBarParser.status(from: text)
            }

            if projection.statusEvent == nil,
               let interruptedEvent = latestCurrentInterruptedStatusEvent(in: text) {
                projection.statusEvent = interruptedEvent
                statusSourceText = text
            }

            let hasFreshRunningTail = isFresh || item.status == "running"
            guard hasFreshRunningTail else { continue }

            let currentRunningEvent = latestCurrentRunningStatusEvent(in: text)

            if projection.activityEvent == nil,
               currentRunningEvent != nil,
               let currentActivityEvent = CodexTUIEventParser.currentActivityEvent(from: text) {
                projection.activityEvent = runningActivityEvent(currentActivityEvent)
            }

            if projection.queuedMessages.isEmpty {
                let currentQueuedMessages = CodexTUIEventParser.currentQueuedMessages(from: text)
                if !currentQueuedMessages.isEmpty,
                   currentRunningEvent != nil || item.status == "running" {
                    projection.queuedMessages = currentQueuedMessages
                }
            }

            if projection.statusEvent == nil,
               let currentStatusEvent = latestCurrentPinnedStatusEvent(in: text) {
                projection.statusEvent = currentStatusEvent
                statusSourceText = text
            }

            if projection.statusEvent == nil,
               !projection.queuedMessages.isEmpty,
               hasFreshRunningTail {
                projection.statusEvent = CodexTUIEvent(
                    kind: .working,
                    title: "Working",
                    summary: nil,
                    detail: nil,
                    isRunning: true
                )
                statusSourceText = text
            }
        }

        if projection.activityEvent == nil,
           isFresh,
           let structuredActivityEvent = latestStructuredActivityEvent(from: items) {
            projection.activityEvent = structuredActivityEvent
        }

        if projection.statusEvent == nil,
           isFresh,
           projection.activityEvent == nil,
           let fallbackEvent = freshRunningFallbackEvent(from: items) {
            projection.statusEvent = fallbackEvent
        }

        guard let statusEvent = projection.statusEvent else { return projection }
        guard let statusSourceText,
              let elapsedSummary = latestRunningElapsedSummary(
                in: statusSourceText,
                event: statusEvent,
                detailUpdatedAt: detailUpdatedAt,
                now: now
              ),
              statusEvent.summary != elapsedSummary
        else {
            return projection
        }

        projection.statusEvent = CodexTUIEvent(
            kind: statusEvent.kind,
            title: statusEvent.title,
            summary: elapsedSummary,
            detail: statusEvent.detail,
            isRunning: statusEvent.isRunning
        )
        return projection
    }

    private static func runningActivityEvent(_ event: CodexTUIEvent) -> CodexTUIEvent {
        CodexTUIEvent(
            kind: event.kind,
            title: event.title,
            summary: event.summary,
            detail: event.detail,
            isRunning: true,
            isSelected: event.isSelected
        )
    }

    private static func latestStructuredActivityEvent(from items: [RemoteThreadItem]) -> CodexTUIEvent? {
        for item in items.reversed() where !isLiveTerminalItem(item) {
            if let event = structuredActivityEvent(from: item) {
                return event
            }
        }
        return nil
    }

    private static func structuredActivityEvent(from item: RemoteThreadItem) -> CodexTUIEvent? {
        let normalizedStatus = item.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isRunning = isStructuredRunningStatus(normalizedStatus)

        if item.type == "reasoning" {
            guard isRunning else { return nil }
            return CodexTUIEvent(
                kind: .status,
                title: "Thinking",
                summary: cleanCodexToolText(item.detail) ?? cleanCodexToolText(item.rawText),
                detail: nil,
                isRunning: true
            )
        }

        guard isRunning else { return nil }

        if item.type == "commandExecution",
           let command = codexCommandSummary(from: item) {
            return CodexTUIEvent(
                kind: .status,
                title: "Running",
                summary: command,
                detail: nil,
                isRunning: true
            )
        }

        if let event = codexToolEvent(from: item) {
            return runningActivityEvent(event)
        }

        return nil
    }

    private static func freshRunningFallbackEvent(from items: [RemoteThreadItem]) -> CodexTUIEvent? {
        guard let latestItem = items.last else { return nil }
        switch latestItem.type {
        case "agentMessage":
            let normalizedStatus = latestItem.status?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedStatus == "commentary" ||
                    normalizedStatus == "thinking" ||
                    normalizedStatus == "reasoning" ||
                    isStructuredRunningStatus(normalizedStatus)
            else {
                return nil
            }
            return CodexTUIEvent(
                kind: .status,
                title: "Thinking",
                summary: nil,
                detail: nil,
                isRunning: true
            )
        default:
            return nil
        }
    }

    private static func isStructuredRunningStatus(_ status: String?) -> Bool {
        status == "running" ||
            status == "inprogress" ||
            status == "in_progress" ||
            status == "pending" ||
            status == "started" ||
            status == "thinking" ||
            status == "reasoning" ||
            status == "streaming"
    }

    static func isPinnedWorkingEvent(_ event: CodexTUIEvent) -> Bool {
        event.kind == .working &&
            event.title == "Working" &&
            event.isRunning
    }

    static func isPinnedThinkingEvent(_ event: CodexTUIEvent) -> Bool {
        event.kind == .status &&
            event.title == "Thinking" &&
            event.isRunning
    }

    static func codexToolEvent(from item: RemoteThreadItem) -> CodexTUIEvent? {
        guard !isLiveTerminalItem(item) else { return nil }

        let normalizedStatus = item.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isRunning = normalizedStatus == "running" || normalizedStatus == "inprogress"
        let detail = codexToolDetail(from: item)

        switch item.type {
        case "commandExecution":
            guard let command = codexCommandSummary(from: item) else { return nil }
            if isRunning {
                return CodexTUIEvent(
                    kind: .status,
                    title: "Running",
                    summary: command,
                    detail: nil,
                    isRunning: true
                )
            }
            return CodexTUIEvent(
                kind: .ran,
                title: "Ran",
                summary: command,
                detail: detail,
                isRunning: isRunning
            )
        case "webSearch":
            guard let query = codexToolSummary(from: item) else { return nil }
            return CodexTUIEvent(
                kind: .explored,
                title: "Search",
                summary: query,
                detail: nil,
                isRunning: isRunning
            )
        case "mcpToolCall", "dynamicToolCall":
            if let operationTitle = codexOperationTitle(from: item.title) {
                return CodexTUIEvent(
                    kind: .explored,
                    title: operationTitle,
                    summary: codexToolSummary(from: item),
                    detail: detail,
                    isRunning: isRunning
                )
            }

            return CodexTUIEvent(
                kind: .status,
                title: "Agent Tool",
                summary: codexToolSummary(from: item),
                detail: detail,
                isRunning: isRunning
            )
        default:
            return nil
        }
    }

    static func isActiveLiveTerminalItem(
        _ item: RemoteThreadItem,
        detailUpdatedAt: Double? = nil,
        now: Date = .now
    ) -> Bool {
        guard isLiveTerminalItem(item) else { return false }
        let hasFreshRunningTail = isFreshLiveTerminalDetail(detailUpdatedAt, now: now) || item.status == "running"
        guard hasFreshRunningTail else { return false }

        guard let text = item.rawText ?? item.detail else { return false }
        return latestCurrentRunningStatusEvent(in: text) != nil
    }

    static func isLiveTerminalItem(_ item: RemoteThreadItem) -> Bool {
        item.type == "commandExecution" &&
            item.title == "Live terminal"
    }

    private static func isSuppressibleCompletedLocalToolItem(_ item: RemoteThreadItem) -> Bool {
        guard item.type == "commandExecution",
              item.id.hasPrefix("local-command-"),
              item.exitCode ?? 0 == 0
        else {
            return false
        }

        let normalizedStatus = item.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedStatus == nil ||
            normalizedStatus == "" ||
            normalizedStatus == "completed" ||
            normalizedStatus == "success"
    }

    private static func isDisplayableLiveTerminalItem(
        _ item: RemoteThreadItem,
        detailUpdatedAt: Double?,
        now: Date
    ) -> Bool {
        return !visibleLiveTerminalEvents(from: item).isEmpty
    }

    private static func visibleLiveTerminalEvents(from item: RemoteThreadItem) -> [CodexTUIEvent] {
        guard let text = item.rawText ?? item.detail else { return [] }
        return liveTerminalFeedEvents(from: recentLiveTerminalParseText(from: text))
    }

    static func liveTerminalFeedEvents(from item: RemoteThreadItem) -> [CodexTUIEvent] {
        guard let text = item.rawText ?? item.detail else { return [] }
        return liveTerminalFeedEvents(from: recentLiveTerminalParseText(from: text))
    }

    private static func liveTerminalFeedEvents(from text: String) -> [CodexTUIEvent] {
        let events = CodexTUIEventParser.currentTurnEvents(from: text)
        let visible = CodexTUIEventVisibility.eventsBySuppressingPinnedStatusStrips(events)
        if !visible.isEmpty {
            if shouldSuppressRanOnlyHistory(visible, in: text) {
                return []
            }
            return visible
        }

        if let interrupted = events.last(where: { $0.kind == .interrupted }) {
            return [interrupted]
        }

        if let working = events.last(where: isPinnedWorkingEvent(_:)) {
            return [working]
        }

        return []
    }

    private static func codexCommandSummary(from item: RemoteThreadItem) -> String? {
        if let command = cleanCodexCommandText(item.command) {
            return command
        }

        let genericTitles = ["Command execution", "Live terminal", "Terminal"]
        guard !genericTitles.contains(item.title) else { return nil }
        return cleanCodexCommandText(item.title)
    }

    private static func codexToolSummary(from item: RemoteThreadItem) -> String? {
        cleanCodexToolText(item.detail) ??
            cleanCodexToolText(item.rawText) ??
            cleanCodexToolText(item.title)
    }

    private static func codexToolDetail(from item: RemoteThreadItem) -> String? {
        let output = cleanCodexToolText(item.rawText)
        let detail = cleanCodexToolText(item.detail)
        let command = cleanCodexToolText(item.command)

        var details: [String] = []
        if let output, output != command {
            details.append(output)
        } else if let detail, detail != command {
            details.append(detail)
        }

        if let exitCode = item.exitCode, exitCode != 0 {
            details.append("exit \(exitCode)")
        }

        let joined = details.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func codexOperationTitle(from title: String) -> String? {
        let cleaned = cleanCodexToolText(title) ?? ""
        let compacted = cleaned
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if compacted.contains("read") { return "Read" }
        if compacted.contains("search") { return "Search" }
        if compacted.contains("list") { return "List" }
        if compacted.contains("open") { return "Open" }
        if compacted.contains("inspect") { return "Inspect" }
        if compacted.contains("edit") { return "Edit" }
        if compacted.contains("update") { return "Update" }
        if compacted.contains("write") { return "Write" }
        return nil
    }

    private static func cleanCodexToolText(_ text: String?) -> String? {
        let cleaned = text?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanCodexCommandText(_ text: String?) -> String? {
        guard var cleaned = cleanCodexToolText(text) else { return nil }
        if let shellRange = cleaned.range(
            of: #"^(?:/[^\s]+/)?(?:zsh|bash|sh)\s+-lc\s+"#,
            options: .regularExpression
        ) {
            cleaned.removeSubrange(shellRange)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.count >= 2,
           cleaned.first == "\"",
           cleaned.last == "\"" {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned.isEmpty ? nil : cleaned
    }

    private static func shouldSuppressRanOnlyHistory(_ events: [CodexTUIEvent], in text: String) -> Bool {
        guard !events.isEmpty, events.allSatisfy({ $0.kind == .ran }) else { return false }
        return latestCurrentRunningStatusEvent(in: text) == nil
    }

    static func hasCurrentLiveTerminalRunningStatus(_ item: RemoteThreadItem) -> Bool {
        guard isLiveTerminalItem(item),
              let text = item.rawText ?? item.detail
        else {
            return false
        }
        return latestCurrentRunningStatusEvent(in: recentLiveTerminalParseText(from: text)) != nil
    }

    private static func recentLiveTerminalParseText(from text: String) -> String {
        guard text.utf16.count > liveTerminalParseUTF16Limit else {
            return text
        }

        let utf16Start = text.utf16.index(text.utf16.endIndex, offsetBy: -liveTerminalParseUTF16Limit)
        let startIndex = String.Index(utf16Start, within: text) ?? text.startIndex
        let suffix = text[startIndex...]

        guard let firstNewline = suffix.firstIndex(of: "\n") else {
            return String(suffix)
        }

        let lineStart = suffix.index(after: firstNewline)
        return String(suffix[lineStart...])
    }

    private static func latestWorkingElapsedSummary(
        in text: String,
        detailUpdatedAt: Double?,
        now: Date
    ) -> String? {
        guard let statusLine = latestCurrentWorkingStatusLine(in: text) else { return nil }
        let pattern = #"Working(?:\s+for)?\s*(?:\(|·|\s)?(\d+h(?:\s+\d+m)?(?:\s+\d+s)?|\d+m(?:\s+\d+s)?|\d+s)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(statusLine.startIndex..<statusLine.endIndex, in: statusLine)
        let matches = expression.matches(in: statusLine, range: range)
        guard let match = matches.last, match.numberOfRanges > 1 else { return nil }
        guard let captureRange = Range(match.range(at: 1), in: statusLine) else { return nil }
        let elapsed = String(statusLine[captureRange])
        guard let elapsedSeconds = elapsedSeconds(from: elapsed) else {
            return elapsed
        }

        let advancedSeconds = elapsedSeconds + liveTailAgeSeconds(detailUpdatedAt: detailUpdatedAt, now: now)
        return elapsedSummary(fromSeconds: advancedSeconds)
    }

    private static func latestRunningElapsedSummary(
        in text: String,
        event: CodexTUIEvent,
        detailUpdatedAt: Double?,
        now: Date
    ) -> String? {
        if event.kind == .working {
            return latestWorkingElapsedSummary(
                in: text,
                detailUpdatedAt: detailUpdatedAt,
                now: now
            )
        }

        guard event.isRunning,
              let summary = event.summary
        else {
            return nil
        }

        return CodexTUIElapsedTimer.advancingSummary(
            summary,
            by: liveTailAgeSeconds(detailUpdatedAt: detailUpdatedAt, now: now)
        )
    }

    private static func latestWorkingStatusLineAppearsCurrent(in text: String) -> Bool {
        latestCurrentWorkingStatusLine(in: text) != nil
    }

    private static func latestCurrentRunningStatusEvent(in text: String) -> CodexTUIEvent? {
        let events = CodexTUIEventParser.events(from: text)
        guard let latestEvent = events.last, latestEvent.isRunning else { return nil }
        return latestRunningStatusLineAppearsCurrent(in: text, event: latestEvent) ? latestEvent : nil
    }

    private static func latestCurrentPinnedStatusEvent(in text: String) -> CodexTUIEvent? {
        let events = CodexTUIEventParser.events(from: text)

        for event in events.reversed() where event.isRunning && event.kind != .queued {
            if latestRunningStatusLineAppearsCurrent(in: text, event: event) {
                return event
            }
        }

        return nil
    }

    private static func latestCurrentInterruptedStatusEvent(in text: String) -> CodexTUIEvent? {
        let events = CodexTUIEventParser.events(from: text)
        guard let latestEvent = events.last, latestEvent.kind == .interrupted else { return nil }
        return latestEvent
    }

    private static func latestRunningStatusLineAppearsCurrent(in text: String, event: CodexTUIEvent) -> Bool {
        if event.kind == .working {
            return latestWorkingStatusLineAppearsCurrent(in: text)
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let runningIndex = lines.indices.reversed().first(where: { index in
            isRunningStatusLine(String(lines[index]), event: event)
        }) else {
            return false
        }

        let suffixStart = lines.index(after: runningIndex)
        return lines[suffixStart...].allSatisfy { rawLine in
            isIgnorableLineAfterRunningStatus(String(rawLine), event: event)
        }
    }

    private static func latestCurrentWorkingStatusLine(in text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let workingIndex = lines.indices.reversed().first(where: { index in
            isWorkingStatusLine(String(lines[index]))
        }) else {
            return nil
        }

        let suffixStart = lines.index(after: workingIndex)
        guard lines[suffixStart...].allSatisfy({ rawLine in
            isIgnorableLineAfterWorkingStatus(String(rawLine))
        }) else {
            return nil
        }
        return String(lines[workingIndex])
    }

    private static func isWorkingStatusLine(_ line: String) -> Bool {
        let cleaned = cleanStatusLine(line)
        return cleaned == "Working" ||
            cleaned.hasPrefix("Working(") ||
            cleaned.hasPrefix("Working (") ||
            cleaned.hasPrefix("Working·") ||
            cleaned.hasPrefix("Working ·") ||
            hasStatusPrefix(cleaned, prefix: "Working for")
    }

    private static func isRunningStatusLine(_ line: String, event: CodexTUIEvent) -> Bool {
        let cleaned = cleanStatusLine(line)
        switch event.kind {
        case .working:
            return isWorkingStatusLine(line)
        case .waiting:
            return hasStatusPrefix(cleaned, prefix: "Waiting for background terminal") ||
                hasStatusPrefix(cleaned, prefix: "Waiting background terminal") ||
                hasStatusPrefix(cleaned, prefix: "Waiting for") ||
                hasStatusPrefix(cleaned, prefix: "Waiting")
        case .exploring:
            return hasStatusPrefix(cleaned, prefix: "Exploring")
        case .queued:
            return isQueuedStatusLine(cleaned)
        case .agent:
            return hasStatusPrefix(cleaned, prefix: event.title)
        case .status:
            return hasStatusPrefix(cleaned, prefix: event.title)
        default:
            return false
        }
    }

    private static func isIgnorableLineAfterWorkingStatus(_ line: String) -> Bool {
        let cleaned = cleanStatusLine(line)
        guard !cleaned.isEmpty else { return true }
        if isSeparatorOnlyStatusLine(cleaned) { return true }
        if CodexTUIStatusBarParser.status(from: cleaned) != nil { return true }
        if isQueuedStatusLine(cleaned) { return true }
        if cleaned.hasPrefix("\u{21B3}") ||
            cleaned.localizedCaseInsensitiveContains("edit last queued message") {
            return true
        }

        let lowercased = cleaned.lowercased()
        return lowercased.contains("context [") ||
            lowercased.contains("· window") ||
            lowercased.contains("window ·") ||
            lowercased.contains("fast on") ||
            lowercased.contains("fast off") ||
            lowercased.contains("5h ") ||
            lowercased.contains("weekly ")
    }

    private static func isIgnorableLineAfterRunningStatus(_ line: String, event: CodexTUIEvent) -> Bool {
        if isIgnorableLineAfterWorkingStatus(line) {
            return true
        }

        let cleaned = cleanStatusLine(line)
        switch event.kind {
        case .queued:
            return cleaned.hasPrefix("\u{21B3}") ||
                cleaned.localizedCaseInsensitiveContains("edit last queued message")
        case .waiting:
            return cleaned.hasPrefix("\u{2514}") ||
                cleaned.hasPrefix("\u{251C}") ||
                cleaned.hasPrefix("\u{2502}") ||
                cleaned.hasPrefix("\u{21B3}") ||
                cleaned.hasPrefix("L ")
        case .agent, .exploring, .status:
            return cleaned.hasPrefix("\u{2514}") ||
                cleaned.hasPrefix("\u{251C}") ||
                cleaned.hasPrefix("\u{2502}") ||
                cleaned.hasPrefix("\u{21B3}") ||
                cleaned.hasPrefix("Read ") ||
                cleaned.hasPrefix("Search ") ||
                cleaned.hasPrefix("List ") ||
                cleaned.hasPrefix("Open ") ||
                cleaned.hasPrefix("Inspect ") ||
                cleaned.hasPrefix("Edit ") ||
                cleaned.hasPrefix("Update ") ||
                cleaned.hasPrefix("Write ") ||
                cleaned.hasPrefix("Task ") ||
                cleaned.hasPrefix("Tasks ") ||
                cleaned.hasPrefix("Plan ")
        default:
            return false
        }
    }

    private static func hasStatusPrefix(_ line: String, prefix: String) -> Bool {
        let normalizedLine = line.lowercased()
        let normalizedPrefix = prefix.lowercased()
        guard normalizedLine.hasPrefix(normalizedPrefix) else { return false }
        if normalizedLine.count == normalizedPrefix.count {
            return true
        }

        let boundaryIndex = normalizedLine.index(
            normalizedLine.startIndex,
            offsetBy: normalizedPrefix.count
        )
        let boundary = normalizedLine[boundaryIndex]
        return !(boundary.isLetter || boundary.isNumber)
    }

    private static func isQueuedStatusLine(_ cleaned: String) -> Bool {
        let compacted = cleaned.replacingOccurrences(of: " ", with: "").lowercased()
        return compacted.hasPrefix("queuedfollow-upmessages") ||
            compacted.hasPrefix("queuedfollowupmessages") ||
            compacted.hasPrefix("messagestobesubmittedafternexttoolcall") ||
            compacted.hasPrefix("messagestobesubmittedafterthenexttoolcall")
    }

    private static func cleanStatusLine(_ line: String) -> String {
        var cleaned = line
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let separatorPrefix = cleaned.range(
            of: #"^[─━—―\-_=]{3,}\s*"#,
            options: .regularExpression
        ) {
            cleaned.removeSubrange(separatorPrefix)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while let first = cleaned.first,
              first == "\u{2022}" ||
              first == "-" ||
              first == "*" ||
              first == "." ||
              first == "\u{00B7}" {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }

    private static func isSeparatorOnlyStatusLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.range(
            of: #"^[─━—―\-_=]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isFreshLiveTerminalDetail(_ updatedAt: Double?, now: Date) -> Bool {
        guard let updatedAt else { return true }
        let updatedAtMS = updatedAt > 10_000_000_000 ? updatedAt : updatedAt * 1_000
        let nowMS = now.timeIntervalSince1970 * 1_000
        return nowMS - updatedAtMS <= activeWorkingFreshnessInterval * 1_000
    }

    private static func liveTailAgeSeconds(detailUpdatedAt: Double?, now: Date) -> Int {
        guard let detailUpdatedAt else { return 0 }
        let updatedAtMS = detailUpdatedAt > 10_000_000_000 ? detailUpdatedAt : detailUpdatedAt * 1_000
        let nowMS = now.timeIntervalSince1970 * 1_000
        let ageSeconds = Int((nowMS - updatedAtMS) / 1_000)
        let maxAgeSeconds = Int(activeWorkingFreshnessInterval)
        return min(max(ageSeconds, 0), maxAgeSeconds)
    }

    private static func elapsedSeconds(from summary: String) -> Int? {
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

    private static func elapsedSummary(fromSeconds totalSeconds: Int) -> String {
        let seconds = max(totalSeconds, 0)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }

        if minutes > 0 {
            if remainingSeconds > 0 {
                return "\(minutes)m \(remainingSeconds)s"
            }
            return "\(minutes)m"
        }

        return "\(remainingSeconds)s"
    }
}

// MARK: - Shared feed styling

enum FeedStyle {
    static func itemLabel(for item: RemoteThreadItem) -> String {
        switch item.type {
        case "userMessage": return "You"
        case "agentMessage": return "Codex"
        case "commandExecution": return "Terminal"
        case "fileChange": return "Files"
        case "mcpToolCall": return "Hook"
        case "dynamicToolCall": return "Skill"
        case "plan": return "Plan"
        case "collabAgentToolCall": return "Agent"
        case "reasoning": return "Reasoning"
        case "webSearch": return "Web"
        default: return item.type.capitalized
        }
    }

    static func itemAccent(for item: RemoteThreadItem) -> Color {
        switch item.type {
        case "userMessage": return .secondary
        case "agentMessage": return AppPalette.accent
        case "commandExecution": return .green
        case "fileChange": return .blue
        case "mcpToolCall", "dynamicToolCall": return .orange
        case "plan": return .purple
        case "collabAgentToolCall": return AppPalette.accent
        case "reasoning": return .pink
        case "webSearch": return .teal
        default: return .secondary
        }
    }

    static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "running": return AppPalette.accent
        case "waitingApproval": return AppPalette.warning
        case "completed": return .blue
        case "blocked": return AppPalette.danger
        default: return AppPalette.secondaryText
        }
    }

    static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "waitingApproval": return "Needs Approval"
        case "unknown": return "Attached"
        default: return phase.capitalized
        }
    }

    static func phasePill(_ phase: String) -> some View {
        Text(phaseLabel(phase))
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(phaseColor(phase).opacity(0.12), in: Capsule())
            .foregroundStyle(phaseColor(phase))
    }
}
