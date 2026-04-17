import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CodexSlashCommand: Hashable, Identifiable {
    let command: String
    let argumentHint: String?
    let summary: String
    let category: String

    var id: String { command }

    var displayText: String {
        if let argumentHint {
            return "\(command) \(argumentHint)"
        }
        return command
    }

    var insertsTrailingSpace: Bool {
        argumentHint != nil ||
            ["/model", "/permissions", "/statusline", "/sandbox-add-read-dir", "/rename", "/resume", "/fork", "/agent"].contains(command)
    }
}

enum CodexSlashCommandCatalog {
    static let all: [CodexSlashCommand] = [
        .init(command: "/new", argumentHint: nil, summary: "Start a fresh idea; the previous session stays in history.", category: "Session"),
        .init(command: "/compact", argumentHint: nil, summary: "Summarize history to free context.", category: "Session"),
        .init(command: "/resume", argumentHint: "[thread]", summary: "Resume a saved chat.", category: "Session"),
        .init(command: "/fork", argumentHint: "[thread]", summary: "Fork the current or selected chat.", category: "Session"),
        .init(command: "/rename", argumentHint: "[name]", summary: "Rename the current thread.", category: "Session"),
        .init(command: "/clear", argumentHint: nil, summary: "Clear the terminal and start a new chat.", category: "Session"),
        .init(command: "/undo", argumentHint: nil, summary: "Roll back the last turn.", category: "Session"),

        .init(command: "/status", argumentHint: nil, summary: "Show model, approvals, token usage, and limits.", category: "Status"),
        .init(command: "/statusline", argumentHint: nil, summary: "Configure which items appear in the Codex status line.", category: "Status"),
        .init(command: "/ps", argumentHint: nil, summary: "List background terminals.", category: "Status"),
        .init(command: "/stop", argumentHint: nil, summary: "Stop all background terminals.", category: "Status"),
        .init(command: "/rollout", argumentHint: nil, summary: "Print the rollout file path.", category: "Status"),
        .init(command: "/diff", argumentHint: nil, summary: "Show git diff, including untracked files.", category: "Status"),

        .init(command: "/model", argumentHint: "[model]", summary: "Choose model and reasoning effort.", category: "Config"),
        .init(command: "/fast", argumentHint: nil, summary: "Toggle Fast mode.", category: "Config"),
        .init(command: "/permissions", argumentHint: nil, summary: "Choose what Codex is allowed to do.", category: "Config"),
        .init(command: "/approvals", argumentHint: nil, summary: "Configure approval behavior.", category: "Config"),
        .init(command: "/sandbox", argumentHint: nil, summary: "Set up elevated agent sandboxing.", category: "Config"),
        .init(command: "/sandbox-add-read-dir", argumentHint: "<absolute_path>", summary: "Let sandboxed Codex read an extra directory.", category: "Config"),
        .init(command: "/experimental", argumentHint: nil, summary: "Toggle experimental features.", category: "Config"),
        .init(command: "/theme", argumentHint: nil, summary: "Choose syntax highlighting theme.", category: "Config"),
        .init(command: "/style", argumentHint: nil, summary: "Choose a communication style for Codex.", category: "Config"),
        .init(command: "/personality", argumentHint: nil, summary: "Choose a communication style for Codex.", category: "Config"),

        .init(command: "/init", argumentHint: nil, summary: "Create an AGENTS.md with project-specific guidance.", category: "Project"),
        .init(command: "/review", argumentHint: nil, summary: "Review current changes and find issues.", category: "Project"),
        .init(command: "/skills", argumentHint: nil, summary: "List available skills or ask Codex to use one.", category: "Project"),
        .init(command: "/mcp", argumentHint: nil, summary: "List configured MCP tools.", category: "Project"),
        .init(command: "/apps", argumentHint: nil, summary: "Manage apps.", category: "Project"),
        .init(command: "/plugins", argumentHint: nil, summary: "Browse plugins.", category: "Project"),

        .init(command: "/plan", argumentHint: nil, summary: "Switch to Plan mode.", category: "Mode"),
        .init(command: "/collab", argumentHint: nil, summary: "Change collaboration mode.", category: "Mode"),
        .init(command: "/agent", argumentHint: "[thread]", summary: "Switch the active agent thread.", category: "Mode"),
        .init(command: "/realtime", argumentHint: nil, summary: "Toggle realtime voice mode.", category: "Mode"),
        .init(command: "/audio", argumentHint: nil, summary: "Configure realtime microphone and speaker.", category: "Mode"),

        .init(command: "/login", argumentHint: nil, summary: "Log in to Codex.", category: "Account"),
        .init(command: "/logout", argumentHint: nil, summary: "Log out of Codex.", category: "Account"),
        .init(command: "/feedback", argumentHint: nil, summary: "Send logs to maintainers.", category: "Account"),
        .init(command: "/debug-config", argumentHint: nil, summary: "Show config layers and requirement sources.", category: "Debug"),
        .init(command: "/test-approval", argumentHint: nil, summary: "Test approval requests.", category: "Debug"),
    ]

    static func suggestions(for draft: String, limit: Int = 8) -> [CodexSlashCommand] {
        guard let query = slashQuery(in: draft) else { return [] }
        guard query != "/" else { return Array(all.prefix(limit)) }

        let normalizedQuery = query.lowercased()
        let matches = all.filter { command in
            command.command.lowercased().hasPrefix(normalizedQuery)
        }
        return Array(matches.prefix(limit))
    }

    static func completedDraft(selecting command: CodexSlashCommand, in draft: String) -> String {
        let leadingWhitespace = String(draft.prefix { $0.isWhitespace })
        let trimmedLeading = String(draft.dropFirst(leadingWhitespace.count))
        guard trimmedLeading.hasPrefix("/") else {
            return leadingWhitespace + command.command + (command.insertsTrailingSpace ? " " : "")
        }

        let firstWhitespace = trimmedLeading.firstIndex(where: { $0.isWhitespace })
        let remainder: String
        if let firstWhitespace {
            remainder = String(trimmedLeading[firstWhitespace...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            remainder = ""
        }

        if !remainder.isEmpty {
            return "\(leadingWhitespace)\(command.command) \(remainder)"
        }
        return leadingWhitespace + command.command + (command.insertsTrailingSpace ? " " : "")
    }

    static func slashQuery(in draft: String) -> String? {
        let trimmedLeading = draft.drop(while: { $0.isWhitespace })
        guard trimmedLeading.first == "/" else { return nil }
        let token = trimmedLeading
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .first
            .map(String.init)
        return token
    }
}

enum ComposerCompletionKind: String, Hashable {
    case slash
    case file
    case skill
}

enum ComposerCompletionQuery: Hashable {
    case slash(String)
    case file(prefix: String, cwd: String)
    case skill(prefix: String, cwd: String?)

    var remoteKey: String? {
        switch self {
        case .slash:
            return nil
        case .file(let prefix, let cwd):
            return "file|\(cwd)|\(prefix)"
        case .skill(let prefix, let cwd):
            return "skill|\(cwd ?? "")|\(prefix)"
        }
    }

    var panelTitle: String {
        switch self {
        case .slash:
            return "Codex Commands"
        case .file:
            return "Files"
        case .skill:
            return "Skills"
        }
    }
}

struct ComposerCompletionSuggestion: Hashable, Identifiable {
    let kind: ComposerCompletionKind
    let title: String
    let summary: String
    let category: String
    let replacement: String
    let insertsTrailingSpace: Bool
    let slashCommand: CodexSlashCommand?

    var id: String { "\(kind.rawValue):\(replacement)" }
}

enum ComposerCompletionEngine {
    static func query(in draft: String, cwd: String?) -> ComposerCompletionQuery? {
        if let token = trailingToken(in: draft), let marker = token.first {
            switch marker {
            case "@":
                guard let cwd, !cwd.isEmpty else { return nil }
                return .file(prefix: String(token.dropFirst()), cwd: cwd)
            case "$":
                return .skill(prefix: String(token.dropFirst()), cwd: cwd)
            default:
                break
            }
        }

        if let slashQuery = CodexSlashCommandCatalog.slashQuery(in: draft) {
            return .slash(slashQuery)
        }

        return nil
    }

    static func slashSuggestions(for draft: String) -> [ComposerCompletionSuggestion] {
        CodexSlashCommandCatalog.suggestions(for: draft).map { command in
            ComposerCompletionSuggestion(
                kind: .slash,
                title: command.displayText,
                summary: command.summary,
                category: command.category,
                replacement: command.command,
                insertsTrailingSpace: command.insertsTrailingSpace,
                slashCommand: command
            )
        }
    }

    static func fileSuggestions(_ suggestions: [FileTagSuggestion]) -> [ComposerCompletionSuggestion] {
        suggestions.map { suggestion in
            ComposerCompletionSuggestion(
                kind: .file,
                title: "@\(suggestion.displayPath)",
                summary: suggestion.isDirectory ? "Directory" : "File",
                category: suggestion.isDirectory ? "Folder" : "File",
                replacement: "@\(suggestion.completion)",
                insertsTrailingSpace: !suggestion.isDirectory,
                slashCommand: nil
            )
        }
    }

    static func skillSuggestions(_ suggestions: [SkillSuggestion]) -> [ComposerCompletionSuggestion] {
        suggestions.map { suggestion in
            ComposerCompletionSuggestion(
                kind: .skill,
                title: "$\(suggestion.name)",
                summary: suggestion.summary.isEmpty ? "Codex skill" : suggestion.summary,
                category: "Skill",
                replacement: "$\(suggestion.name)",
                insertsTrailingSpace: true,
                slashCommand: nil
            )
        }
    }

    static func completedDraft(selecting suggestion: ComposerCompletionSuggestion, in draft: String) -> String {
        if let slashCommand = suggestion.slashCommand {
            return CodexSlashCommandCatalog.completedDraft(selecting: slashCommand, in: draft)
        }

        guard let tokenRange = trailingTokenRange(in: draft) else {
            return draft + suggestion.replacement + (suggestion.insertsTrailingSpace ? " " : "")
        }

        var completed = draft
        completed.replaceSubrange(
            tokenRange,
            with: suggestion.replacement + (suggestion.insertsTrailingSpace ? " " : "")
        )
        return completed
    }

    private static func trailingToken(in draft: String) -> Substring? {
        guard let range = trailingTokenRange(in: draft) else { return nil }
        return draft[range]
    }

    private static func trailingTokenRange(in draft: String) -> Range<String.Index>? {
        guard let last = draft.indices.last, !draft[last].isWhitespace else { return nil }
        let tokenStart = draft[..<draft.endIndex].lastIndex(where: { $0.isWhitespace })
            .map { draft.index(after: $0) }
            ?? draft.startIndex
        guard tokenStart < draft.endIndex else { return nil }
        return tokenStart..<draft.endIndex
    }
}

enum SessionInputDraftSubmitDetector {
    static func shouldSubmitDraftForKeyboardReturn(previous: String, proposed: String) -> Bool {
        guard proposed.count == previous.count + 1 else { return false }

        for index in proposed.indices where proposed[index].isNewline {
            var candidate = proposed
            candidate.remove(at: index)
            if candidate == previous {
                return true
            }
        }

        return false
    }
}

enum SessionInputDraftReplayGuard {
    static func shouldIgnorePostSendReplay(currentDraft: String, proposed: String, submittedText: String?) -> Bool {
        guard currentDraft.isEmpty, let submittedText else { return false }
        let normalizedProposed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSubmitted = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProposed.isEmpty else { return false }
        return normalizedProposed == normalizedSubmitted
    }
}

enum SessionInputSwipeAction {
    private static let minimumUpwardTranslation: CGFloat = 18
    private static let maximumSidewaysDrift: CGFloat = 54

    static func isUpwardActionSwipe(translation: CGSize) -> Bool {
        translation.height <= -minimumUpwardTranslation &&
            abs(translation.width) <= max(maximumSidewaysDrift, abs(translation.height) * 1.45)
    }
}

enum SessionInputHistorySwipeAction {
    private static let minimumVerticalTranslation: CGFloat = 16
    private static let maximumHorizontalDrift: CGFloat = 56

    static func terminalNavigationKey(for translation: CGSize) -> TerminalInputKey? {
        guard abs(translation.height) >= minimumVerticalTranslation else { return nil }
        guard abs(translation.width) <= max(maximumHorizontalDrift, abs(translation.height) * 1.3) else { return nil }
        return translation.height < 0 ? .arrowUp : .arrowDown
    }
}

enum SessionInputCommandHistory {
    static func recentUserCommands(from detail: RemoteThreadDetail?, limit: Int = 24) -> [String] {
        guard let detail, limit > 0 else { return [] }

        var chronologicalHistory: [String] = []
        var seen: Set<String> = []
        for turn in detail.turns {
            for item in turn.items where item.type == "userMessage" {
                let text = (item.rawText ?? item.detail ?? item.title)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if seen.insert(text).inserted {
                    chronologicalHistory.append(text)
                }
            }
        }
        return Array(chronologicalHistory.reversed().prefix(limit))
    }
}

private enum ComposerFileAttachmentPreparer {
    static let maxAttachmentCount = 4
    static let maxAttachmentBytes = 4 * 1024 * 1024

    static func preparedAttachment(from url: URL) async -> ComposerFileAttachment? {
        await Task.detached(priority: .userInitiated) {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
            if let fileSize = values?.fileSize, fileSize > maxAttachmentBytes {
                return nil
            }

            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return nil
            }
            guard data.count <= maxAttachmentBytes else {
                return nil
            }

            let filename = sanitizedFilename(values?.name ?? url.lastPathComponent)
            let mimeType = values?.contentType?.preferredMIMEType
                ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            return ComposerFileAttachment(
                id: UUID().uuidString,
                filename: filename,
                mimeType: mimeType,
                data: data
            )
        }.value
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let cleaned = filename
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard let cleaned, !cleaned.isEmpty else { return "file" }
        return String(cleaned.prefix(96))
    }
}

struct SessionInputBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var textFieldFocused: Bool
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showDocumentPicker = false
    @State private var showHistoryPanel = false
    @State private var isImageDropTargeted = false
    @State private var remoteCompletionKey: String?
    @State private var remoteCompletionSuggestions: [ComposerCompletionSuggestion] = []
    @State private var isLoadingRemoteCompletion = false
    @State private var postSendReplaySuppressionText: String?

    let threadID: String
    var onActivateCommander: () -> Void

    private var composerWorkingDirectory: String? {
        store.composerWorkingDirectory(for: threadID)
    }

    private var completionQuery: ComposerCompletionQuery? {
        ComposerCompletionEngine.query(in: store.draft, cwd: composerWorkingDirectory)
    }

    private var completionRequestKey: String {
        completionQuery?.remoteKey ?? ""
    }

    private var recentCommandHistory: [String] {
        SessionInputCommandHistory.recentUserCommands(from: store.threadDetail(for: threadID))
    }

    private var completionSuggestions: [ComposerCompletionSuggestion] {
        guard let completionQuery else { return [] }
        switch completionQuery {
        case .slash:
            return ComposerCompletionEngine.slashSuggestions(for: store.draft)
        case .file, .skill:
            guard remoteCompletionKey == completionQuery.remoteKey else { return [] }
            return remoteCompletionSuggestions
        }
    }

    private var shouldShowAutocomplete: Bool {
        textFieldFocused && (!completionSuggestions.isEmpty || isLoadingRemoteCompletion)
    }

    var body: some View {
        VStack(spacing: 0) {
            actionControlStrip

            if showHistoryPanel && !recentCommandHistory.isEmpty {
                historyPanel
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(AppMotion.fadeScale)
            }

            if shouldShowAutocomplete {
                autocompletePanel
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(AppMotion.fadeScale)
            }

            if !store.draftImageAttachments.isEmpty || !store.draftFileAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
                    .transition(AppMotion.fadeScale)
            }

            composerToolbar
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Send to Codex...", text: Binding(
                    get: { store.draft },
                    set: { newValue in handleDraftChange(newValue) }
                ), axis: .vertical)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(false)
                    .keyboardType(.default)
                    .focused($textFieldFocused)
                    .onSubmit {
                        sendDraft()
                    }
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isImageDropTargeted ? AppPalette.accent.opacity(0.10) : AppPalette.panel,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isImageDropTargeted ? AppPalette.accent : AppPalette.border, lineWidth: 1)
                    )
                    .onDrop(
                        of: [UTType.image.identifier],
                        isTargeted: $isImageDropTargeted,
                        perform: handleImageDrop(_:)
                    )

                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(AppPalette.backgroundBottom)
        .dismissesKeyboardOnDownSwipe(minimumDistance: 6, verticalThreshold: 10)
        .animation(AppMotion.quick(reduceMotion), value: completionSuggestions)
        .animation(AppMotion.quick(reduceMotion), value: store.draftImageAttachments)
        .animation(AppMotion.quick(reduceMotion), value: store.draftFileAttachments)
        .task(id: completionRequestKey) {
            await refreshRemoteCompletions(for: completionRequestKey)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, 4 - store.draftImageAttachments.count),
            matching: .images,
            preferredItemEncoding: .compatible
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            loadPhotoItems(newItems)
        }
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            loadDocumentURLs(result)
        }
        .sheet(isPresented: $showCamera) {
            CameraImagePicker { image in
                attachCameraImage(image)
            }
        }
        .onChange(of: threadID) { _, _ in
            showHistoryPanel = false
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppPalette.border)
                .frame(height: 0.5)
        }
    }

    private func sendDraft() {
        guard !threadID.isEmpty else { return }
        let deliveryMode = store.composerSendMode
        guard let preparedDraft = store.takeDraftForSending() else { return }
        suppressPostSendReplay(of: preparedDraft.text)
        Task { await store.sendPreparedDraft(preparedDraft, to: threadID, deliveryMode: deliveryMode) }
        textFieldFocused = false
    }

    private func handleDraftChange(_ newValue: String) {
        if SessionInputDraftReplayGuard.shouldIgnorePostSendReplay(
            currentDraft: store.draft,
            proposed: newValue,
            submittedText: postSendReplaySuppressionText
        ) {
            return
        }
        postSendReplaySuppressionText = nil

        if SessionInputDraftSubmitDetector.shouldSubmitDraftForKeyboardReturn(previous: store.draft, proposed: newValue) {
            sendDraft()
            return
        }

        store.draft = newValue
    }

    private func suppressPostSendReplay(of text: String) {
        postSendReplaySuppressionText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            if postSendReplaySuppressionText == text {
                postSendReplaySuppressionText = nil
            }
        }
    }

    private func refreshRemoteCompletions(for requestKey: String) async {
        guard !requestKey.isEmpty,
              let query = completionQuery,
              query.remoteKey == requestKey
        else {
            remoteCompletionKey = nil
            remoteCompletionSuggestions = []
            isLoadingRemoteCompletion = false
            return
        }

        isLoadingRemoteCompletion = true
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled,
              let currentQuery = completionQuery,
              currentQuery.remoteKey == requestKey
        else {
            return
        }

        do {
            let suggestions: [ComposerCompletionSuggestion]
            switch currentQuery {
            case .slash:
                suggestions = []
            case .file(let prefix, _):
                suggestions = ComposerCompletionEngine.fileSuggestions(
                    try await store.fetchFileTagSuggestions(threadID: threadID, prefix: prefix)
                )
            case .skill(let prefix, _):
                suggestions = ComposerCompletionEngine.skillSuggestions(
                    try await store.fetchSkillSuggestions(prefix: prefix, threadID: threadID)
                )
            }

            guard !Task.isCancelled,
                  completionQuery?.remoteKey == requestKey
            else {
                return
            }
            remoteCompletionKey = requestKey
            remoteCompletionSuggestions = suggestions
            isLoadingRemoteCompletion = false
        } catch is CancellationError {
            return
        } catch {
            guard completionQuery?.remoteKey == requestKey else { return }
            remoteCompletionKey = requestKey
            remoteCompletionSuggestions = []
            isLoadingRemoteCompletion = false
        }
    }

    private var composerToolbar: some View {
        HStack(spacing: 8) {
            toolbarButton(
                icon: store.realtimeCaptureActive ? "waveform.circle.fill" : "mic.fill",
                tint: store.realtimeCaptureActive ? AppPalette.accent : AppPalette.secondaryText,
                accessibilityLabel: "Command"
            ) {
                onActivateCommander()
            }

            toolbarButton(icon: "camera", accessibilityLabel: "Camera") {
                showCamera = true
            }

            toolbarButton(icon: "photo.on.rectangle", accessibilityLabel: "Camera roll") {
                showPhotoPicker = true
            }

            toolbarButton(icon: "doc", accessibilityLabel: "Attach iPhone file") {
                showDocumentPicker = true
            }

            historyToolbarButton

            Spacer(minLength: 0)
        }
    }

    private var historyToolbarButton: some View {
        toolbarButtonChrome(
            icon: showHistoryPanel ? "clock.fill" : "clock.arrow.circlepath",
            tint: showHistoryPanel ? AppPalette.accent : AppPalette.secondaryText
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if recentCommandHistory.isEmpty {
                showHistoryPanel = false
                return
            }
            showHistoryPanel.toggle()
            textFieldFocused = false
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onEnded { value in
                    guard let key = SessionInputHistorySwipeAction.terminalNavigationKey(for: value.translation) else { return }
                    Task { await store.sendTerminalInput(key, threadID: threadID) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Command history")
        .accessibilityHint("Tap to show recent messages. Swipe up or down to send terminal arrow keys.")
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(AppPalette.secondaryText)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(recentCommandHistory.enumerated()), id: \.offset) { index, command in
                        Button {
                            store.draft = command
                            textFieldFocused = true
                            showHistoryPanel = false
                        } label: {
                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppPalette.primaryText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < recentCommandHistory.count - 1 {
                            Divider()
                                .overlay(AppPalette.border.opacity(0.5))
                        }
                    }
                }
            }
            .frame(maxHeight: 210)
            .background(AppPalette.elevatedPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppPalette.border.opacity(0.8), lineWidth: 1)
            )
        }
    }

    private func toolbarButton(
        icon: String,
        tint: Color = AppPalette.secondaryText,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarButtonChrome(icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func toolbarButtonChrome(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(AppPalette.mutedPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppPalette.border.opacity(0.7), lineWidth: 1)
            )
    }

    private func insertFileToken() {
        let draft = store.draft
        if draft.isEmpty {
            store.draft = "@"
        } else if draft.last?.isWhitespace == true {
            store.draft += "@"
        } else {
            store.draft += " @"
        }
        textFieldFocused = true
    }

    private var attachmentPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.draftImageAttachments) { attachment in
                    imageAttachmentPreview(attachment)
                }

                ForEach(store.draftFileAttachments) { attachment in
                    fileAttachmentPreview(attachment)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityIdentifier("sessions.detail.attachments")
    }

    private func imageAttachmentPreview(_ attachment: ComposerImageAttachment) -> some View {
        HStack(spacing: 6) {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(AppPalette.mutedPanel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)

                Text(byteCountLabel(attachment.byteCount))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: 120, alignment: .leading)

            Button {
                store.removeDraftImageAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(AppPalette.mutedPanel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(AppPalette.elevatedPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppPalette.border.opacity(0.8), lineWidth: 1)
        )
    }

    private func fileAttachmentPreview(_ attachment: ComposerFileAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 34, height: 34)
                .background(AppPalette.mutedPanel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppPalette.primaryText)
                    .lineLimit(1)

                Text(byteCountLabel(attachment.byteCount))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppPalette.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)

            Button {
                store.removeDraftFileAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(AppPalette.mutedPanel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(AppPalette.elevatedPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppPalette.border.opacity(0.8), lineWidth: 1)
        )
    }

    private var sendButton: some View {
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !store.draftImageAttachments.isEmpty ||
            !store.draftFileAttachments.isEmpty
        let tint = sendModeTint

        return VStack(spacing: 2) {
            Image(systemName: store.composerSendMode == .interrupt ? "bolt.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(hasDraft ? tint : AppPalette.secondaryText)

            Text(store.composerSendMode == .interrupt ? "now" : "queue")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .frame(width: 42, height: 38)
        .contentShape(Rectangle())
        .onTapGesture {
            sendDraft()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 16, coordinateSpace: .local)
                .onEnded { value in
                    guard SessionInputSwipeAction.isUpwardActionSwipe(translation: value.translation) else { return }
                    store.toggleComposerSendMode()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Send to Codex")
        .accessibilityValue(store.composerSendMode == .interrupt ? "Send immediately" : "Queue after current turn")
        .accessibilityHint("Tap or press keyboard Send to use the selected mode. Swipe up to switch between queue and interrupt send.")
    }

    private var sendModeTint: Color {
        store.composerSendMode == .interrupt ? AppPalette.warning : AppPalette.accent
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for (index, item) in items.enumerated() {
                guard store.draftImageAttachments.count < 4 else { break }
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                attachImageData(data, suggestedFilename: "camera-roll-\(index + 1).jpg")
            }
            selectedPhotoItems = []
        }
    }

    private func loadDocumentURLs(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task {
            for url in urls {
                guard store.draftFileAttachments.count < ComposerFileAttachmentPreparer.maxAttachmentCount else { break }
                guard let attachment = await ComposerFileAttachmentPreparer.preparedAttachment(from: url) else { continue }
                store.appendDraftFileAttachment(attachment)
            }
        }
    }

    private func attachCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return }
        attachImageData(data, suggestedFilename: "camera.jpg")
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        let imageProviders = providers.filter { provider in
            provider.registeredTypeIdentifiers.contains { typeIdentifier in
                UTType(typeIdentifier)?.conforms(to: .image) ?? false
            }
        }
        guard !imageProviders.isEmpty else { return false }

        for (index, provider) in imageProviders.prefix(4 - store.draftImageAttachments.count).enumerated() {
            guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { typeIdentifier in
                UTType(typeIdentifier)?.conforms(to: .image) ?? false
            }) else {
                continue
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    attachImageData(data, suggestedFilename: "dropped-image-\(index + 1).jpg")
                }
            }
        }

        return true
    }

    private func attachImageData(_ data: Data, suggestedFilename: String) {
        guard let attachment = Self.preparedAttachment(from: data, suggestedFilename: suggestedFilename) else { return }
        store.appendDraftImageAttachment(attachment)
    }

    private static func preparedAttachment(from data: Data, suggestedFilename: String) -> ComposerImageAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        let resized = image.resizedForHelmAttachment(maxPixelDimension: 1_800)
        guard let jpeg = resized.jpegData(compressionQuality: 0.86) else { return nil }
        return ComposerImageAttachment(
            id: UUID().uuidString,
            filename: sanitizedAttachmentFilename(suggestedFilename, fallbackExtension: "jpg"),
            mimeType: "image/jpeg",
            data: jpeg
        )
    }

    private static func sanitizedAttachmentFilename(_ filename: String, fallbackExtension: String) -> String {
        let fallback = "image.\(fallbackExtension)"
        let cleaned = filename
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard let cleaned, !cleaned.isEmpty else { return fallback }
        if cleaned.range(of: #"\.[A-Za-z0-9]{2,5}$"#, options: .regularExpression) != nil {
            return cleaned
        }
        return "\(cleaned).\(fallbackExtension)"
    }

    private func byteCountLabel(_ byteCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(byteCount))
    }

    private var autocompletePanel: some View {
        let suggestions = completionSuggestions
        let title = completionQuery?.panelTitle ?? "Completions"

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(AppPalette.secondaryText)

                Spacer()

                Text(isLoadingRemoteCompletion && suggestions.isEmpty ? "Loading..." : "Tap to complete")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(AppPalette.tertiaryText)
            }

            if suggestions.isEmpty {
                HStack(spacing: 8) {
                    WorkingSpriteView(
                        preset: .dots,
                        tint: AppPalette.tertiaryText,
                        font: .system(.caption2, design: .monospaced, weight: .semibold),
                        accessibilityLabel: "Loading completions"
                    )

                    Text("Finding matches")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(AppPalette.secondaryText)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
            } else {
                completionList(suggestions)
            }
        }
        .padding(9)
        .background(AppPalette.elevatedPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppPalette.border.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: AppPalette.shadow, radius: 10, y: 6)
        .accessibilityIdentifier("sessions.detail.composerAutocomplete")
    }

    private func completionList(_ suggestions: [ComposerCompletionSuggestion]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        store.draft = ComposerCompletionEngine.completedDraft(selecting: suggestion, in: store.draft)
                        textFieldFocused = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(suggestion.title)
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .foregroundStyle(completionTint(for: suggestion.kind))
                                .lineLimit(1)
                                .frame(minWidth: 112, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.summary)
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundStyle(AppPalette.primaryText)
                                    .lineLimit(2)

                                Text(suggestion.category)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(AppPalette.tertiaryText)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if suggestion.id != suggestions.last?.id {
                        Divider()
                            .overlay(AppPalette.border.opacity(0.5))
                    }
                }
            }
        }
        .frame(maxHeight: 210)
    }

    private func completionTint(for kind: ComposerCompletionKind) -> Color {
        switch kind {
        case .slash:
            return AppPalette.accent
        case .file:
            return AppPalette.success
        case .skill:
            return AppPalette.warning
        }
    }

    @ViewBuilder
    private var actionControlStrip: some View {
        if shouldShowActionControlStrip {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if shouldShowTerminalInputControls {
                        terminalInputButton("↑", accessibilityLabel: "Terminal arrow up", key: .arrowUp)
                        terminalInputButton("↓", accessibilityLabel: "Terminal arrow down", key: .arrowDown)
                        terminalInputButton("←", accessibilityLabel: "Terminal arrow left", key: .arrowLeft)
                        terminalInputButton("→", accessibilityLabel: "Terminal arrow right", key: .arrowRight)
                        terminalInputButton("Space", accessibilityLabel: "Terminal space", key: .space)
                        terminalInputButton("Enter", accessibilityLabel: "Terminal enter", key: .enter)
                        terminalInputButton("Esc", accessibilityLabel: "Terminal escape", key: .escape)
                    }

                    if shouldShowInterruptControl {
                        controlButton("Interrupt", icon: "stop.fill", tint: AppPalette.warning) {
                            Task { await store.interruptTurn(threadID: threadID) }
                        }
                    }

                    if let approval = pendingApprovalForControlStrip {
                        controlButton("Approve", icon: "checkmark", tint: AppPalette.accent) {
                            Task { await store.decideApproval(approval, decision: "accept") }
                        }

                        if approval.supportsAcceptForSession {
                            controlButton("Session", icon: "checkmark.shield", tint: AppPalette.accent) {
                                Task { await store.decideApproval(approval, decision: "acceptForSession") }
                            }
                        }

                        controlButton("Decline", icon: "xmark", tint: AppPalette.warning) {
                            Task { await store.decideApproval(approval, decision: "decline") }
                        }

                        controlButton("Cancel", icon: "slash.circle", tint: AppPalette.secondaryText) {
                            Task { await store.decideApproval(approval, decision: "cancel") }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private var shouldShowActionControlStrip: Bool {
        shouldShowTerminalInputControls || shouldShowInterruptControl || pendingApprovalForControlStrip != nil
    }

    private var shouldShowTerminalInputControls: Bool {
        guard let detail = store.threadDetail(for: threadID) else { return false }
        return detail.turns
            .flatMap(\.items)
            .filter(SessionFeedItemOrdering.isLiveTerminalItem(_:))
            .contains(where: hasInteractiveTerminalMenu(_:))
    }

    private func hasInteractiveTerminalMenu(_ item: RemoteThreadItem) -> Bool {
        guard let text = item.rawText ?? item.detail else { return false }
        if CodexTUIEventParser.events(from: text).contains(where: { $0.kind == .option }) {
            return true
        }

        let normalized = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        return normalized.contains("space to toggle") ||
            normalized.contains("space to select") ||
            normalized.contains("enter to confirm") ||
            normalized.contains("esc to cancel") ||
            normalized.contains("escape to cancel")
    }

    private var shouldShowInterruptControl: Bool {
        guard store.thread(for: threadID)?.controller?.clientId == store.bridge.identity.id else {
            return false
        }
        guard store.threadDetail(for: threadID)?.affordances?.canInterrupt ?? true else {
            return false
        }
        return store.runtime(for: threadID)?.phase == "running"
    }

    private var pendingApprovalForControlStrip: RemotePendingApproval? {
        guard store.threadDetail(for: threadID)?.affordances?.canRespondToApprovals ?? true else {
            return nil
        }
        return store.threadApprovals(for: threadID).first { $0.canRespond }
    }

    private func terminalInputButton(
        _ title: String,
        accessibilityLabel: String,
        key: TerminalInputKey
    ) -> some View {
        Button {
            Task { await store.sendTerminalInput(key, threadID: threadID) }
        } label: {
            Text(title)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(AppPalette.primaryText)
                .frame(minWidth: title.count == 1 ? 24 : 44)
                .padding(.vertical, 6)
                .padding(.horizontal, title.count == 1 ? 4 : 8)
                .background(AppPalette.mutedPanel.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppPalette.border.opacity(0.78), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func controlButton(_ title: String, icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
            }
            .foregroundStyle(tint ?? AppPalette.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((tint ?? AppPalette.primaryText).opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private extension UIImage {
    func resizedForHelmAttachment(maxPixelDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxPixelDimension, longestSide > 0 else {
            return normalizedForHelmAttachment()
        }

        let scale = maxPixelDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        return renderedForHelmAttachment(size: targetSize)
    }

    private func normalizedForHelmAttachment() -> UIImage {
        renderedForHelmAttachment(size: size)
    }

    private func renderedForHelmAttachment(size targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
