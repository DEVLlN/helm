import XCTest
@testable import Helm

final class HelmTests: XCTestCase {
    func testVoiceModesRemainStable() {
        XCTAssertEqual(VoiceRuntimeMode.allCases.count, 2)
        XCTAssertEqual(VoiceRuntimeMode.localSpeech.title, "On-Device")
        XCTAssertEqual(VoiceRuntimeMode.openAIRealtime.title, "OpenAI Realtime")
    }

    func testFirstRunPairingScannerRequiresMissingPairingToken() {
        XCTAssertTrue(SessionStore.shouldShowFirstRunPairingScanner(hasPairingToken: false))
        XCTAssertFalse(SessionStore.shouldShowFirstRunPairingScanner(hasPairingToken: true))
    }

    func testSessionInputBarKeyboardReturnSubmitsOnlySingleInsertedNewline() {
        XCTAssertTrue(
            SessionInputDraftSubmitDetector.shouldSubmitDraftForKeyboardReturn(
                previous: "Send this",
                proposed: "Send this\n"
            )
        )
        XCTAssertTrue(
            SessionInputDraftSubmitDetector.shouldSubmitDraftForKeyboardReturn(
                previous: "First\nSecond",
                proposed: "First\nSecond\n"
            )
        )
        XCTAssertFalse(
            SessionInputDraftSubmitDetector.shouldSubmitDraftForKeyboardReturn(
                previous: "",
                proposed: "First\nSecond"
            )
        )
        XCTAssertFalse(
            SessionInputDraftSubmitDetector.shouldSubmitDraftForKeyboardReturn(
                previous: "Send this",
                proposed: "Send this plus more"
            )
        )
    }


    func testSessionInputReplayGuardIgnoresStaleSubmittedTextAfterSend() {
        XCTAssertTrue(
            SessionInputDraftReplayGuard.shouldIgnorePostSendReplay(
                currentDraft: "",
                proposed: "Queued message",
                submittedText: "Queued message"
            )
        )
        XCTAssertTrue(
            SessionInputDraftReplayGuard.shouldIgnorePostSendReplay(
                currentDraft: "",
                proposed: "Queued message\n",
                submittedText: "Queued message"
            )
        )
        XCTAssertFalse(
            SessionInputDraftReplayGuard.shouldIgnorePostSendReplay(
                currentDraft: "",
                proposed: "New message",
                submittedText: "Queued message"
            )
        )
        XCTAssertFalse(
            SessionInputDraftReplayGuard.shouldIgnorePostSendReplay(
                currentDraft: "draft in progress",
                proposed: "Queued message",
                submittedText: "Queued message"
            )
        )
    }

    @MainActor
    func testSessionStoreDefaultNewSessionDraftUsesPersistedCodexLaunchMode() {
        let defaults = UserDefaults.standard
        let launchModeDefaultsKey = "helm.preferred-codex-launch-mode"
        defaults.set(SessionLaunchMode.sharedThread.rawValue, forKey: launchModeDefaultsKey)
        defer {
            defaults.removeObject(forKey: launchModeDefaultsKey)
        }

        let store = SessionStore()
        store.availableBackends = [testBackendSummary(id: "codex", label: "Codex")]
        store.preferredBackendID = "codex"

        XCTAssertEqual(store.defaultNewSessionDraft().launchMode, .sharedThread)
    }

    @MainActor
    func testSessionStoreDefaultNewSessionDraftKeepsManagedShellForNonCodexBackend() {
        let defaults = UserDefaults.standard
        let launchModeDefaultsKey = "helm.preferred-codex-launch-mode"
        defaults.set(SessionLaunchMode.sharedThread.rawValue, forKey: launchModeDefaultsKey)
        defer {
            defaults.removeObject(forKey: launchModeDefaultsKey)
        }

        let store = SessionStore()
        store.availableBackends = [testBackendSummary(id: "claude-code", label: "Claude Code")]
        store.preferredBackendID = "claude-code"

        XCTAssertEqual(store.defaultNewSessionDraft().launchMode, .managedShell)
    }

    @MainActor
    func testSessionStoreTakeDraftForSendingClearsComposerImmediately() {
        let store = SessionStore()
        store.draft = "  queued from mobile  "
        store.draftImageAttachments = [
            ComposerImageAttachment(id: "image-1", filename: "image.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        ]
        store.draftFileAttachments = [
            ComposerFileAttachment(id: "file-1", filename: "notes.txt", mimeType: "text/plain", data: Data([4, 5, 6]))
        ]

        let preparedDraft = store.takeDraftForSending()

        XCTAssertEqual(preparedDraft?.text, "queued from mobile")
        XCTAssertEqual(preparedDraft?.imageAttachments.count, 1)
        XCTAssertEqual(preparedDraft?.fileAttachments.count, 1)
        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.draftImageAttachments.isEmpty)
        XCTAssertTrue(store.draftFileAttachments.isEmpty)
    }

    @MainActor
    func testSessionStoreTakeDraftForSendingIgnoresEmptyComposer() {
        let store = SessionStore()
        let whitespaceDraft = String(repeating: " ", count: 3) + "\n  "
        store.draft = whitespaceDraft

        XCTAssertNil(store.takeDraftForSending())
        XCTAssertEqual(store.draft, whitespaceDraft)
    }

    @MainActor
    func testSessionStoreTracksPendingBridgeOpenAfterSessionSelection() {
        let store = SessionStore()
        store.openSession("thread-1")

        XCTAssertTrue(store.hasPendingBridgeOpen(threadID: "thread-1"))
        XCTAssertFalse(store.hasPendingBridgeOpen(threadID: "thread-2"))
    }

    @MainActor
    func testSessionStoreKeepsLocallyArchivedLiveThreadOutOfActiveList() {
        let defaults = UserDefaults.standard
        let archivedThreadIDsDefaultsKey = "helm.archived-thread-ids"
        defaults.removeObject(forKey: archivedThreadIDsDefaultsKey)
        defaults.set(["thread-1"], forKey: archivedThreadIDsDefaultsKey)
        defer {
            defaults.removeObject(forKey: archivedThreadIDsDefaultsKey)
        }

        let thread = testRemoteThread(
            id: "thread-1",
            name: "Live but archived",
            preview: "still running",
            updatedAt: 1_000
        )
        let store = SessionStore()
        store.threads = [thread]

        XCTAssertTrue(store.activeSessionThreads.isEmpty)
        XCTAssertTrue(store.recentSessionThreads.isEmpty)
        XCTAssertEqual(store.archivedSessionThreads.map(\.id), ["thread-1"])
    }

    @MainActor
    func testSessionStorePromotesUpstreamArchivedLiveThreadWhenNotLocallyArchived() {
        let defaults = UserDefaults.standard
        let archivedThreadIDsDefaultsKey = "helm.archived-thread-ids"
        defaults.removeObject(forKey: archivedThreadIDsDefaultsKey)
        defer {
            defaults.removeObject(forKey: archivedThreadIDsDefaultsKey)
        }

        let thread = testRemoteThread(
            id: "thread-1",
            name: "Upstream archived live",
            preview: "still running",
            updatedAt: 1_000
        )
        let store = SessionStore()
        store.archivedThreads = [thread]

        XCTAssertEqual(store.activeSessionThreads.map(\.id), ["thread-1"])
        XCTAssertTrue(store.recentSessionThreads.isEmpty)
        XCTAssertTrue(store.archivedSessionThreads.isEmpty)
    }

    func testSessionStoreSelectedThreadAfterFetchKeepsCurrentWhenStillRepresented() {
        XCTAssertEqual(
            SessionStore.selectedThreadIDAfterFetch(
                current: "thread-current",
                persisted: "thread-persisted",
                visibleThreadIDs: ["thread-other"],
                preservedThreadIDs: ["thread-current", "thread-other"],
                preferred: "thread-other"
            ),
            "thread-current"
        )
    }

    func testSessionStoreSelectedThreadAfterFetchRestoresPersistedRepresentedThread() {
        XCTAssertEqual(
            SessionStore.selectedThreadIDAfterFetch(
                current: "thread-missing",
                persisted: "thread-persisted",
                visibleThreadIDs: ["thread-other"],
                preservedThreadIDs: ["thread-persisted", "thread-other"],
                preferred: "thread-other"
            ),
            "thread-persisted"
        )
    }

    func testSessionStoreSelectedThreadAfterFetchFallsBackToPreferredWhenSelectionIsGone() {
        XCTAssertEqual(
            SessionStore.selectedThreadIDAfterFetch(
                current: "thread-missing",
                persisted: "thread-also-missing",
                visibleThreadIDs: ["thread-other"],
                preservedThreadIDs: ["thread-other"],
                preferred: "thread-other"
            ),
            "thread-other"
        )
    }

    func testSessionInputSwipeActionRecognizesUpwardSwipes() {
        XCTAssertTrue(SessionInputSwipeAction.isUpwardActionSwipe(translation: CGSize(width: 0, height: -24)))
        XCTAssertTrue(SessionInputSwipeAction.isUpwardActionSwipe(translation: CGSize(width: 32, height: -36)))

        XCTAssertFalse(SessionInputSwipeAction.isUpwardActionSwipe(translation: CGSize(width: 0, height: -8)))
        XCTAssertFalse(SessionInputSwipeAction.isUpwardActionSwipe(translation: CGSize(width: 0, height: 28)))
        XCTAssertFalse(SessionInputSwipeAction.isUpwardActionSwipe(translation: CGSize(width: 110, height: -24)))
    }

    func testSelectedThreadLiveRefreshUsesActiveCadenceForRunningWork() {
        XCTAssertEqual(
            SessionStore.selectedThreadLiveRefreshDelayMS(
                threadStatus: "running",
                runtimePhase: nil,
                hasPendingOutgoingTurns: false
            ),
            900
        )
        XCTAssertEqual(
            SessionStore.selectedThreadLiveRefreshDelayMS(
                threadStatus: nil,
                runtimePhase: "thinking",
                hasPendingOutgoingTurns: false
            ),
            900
        )
        XCTAssertEqual(
            SessionStore.selectedThreadLiveRefreshDelayMS(
                threadStatus: "completed",
                runtimePhase: "idle",
                hasPendingOutgoingTurns: true
            ),
            900
        )
    }

    func testSelectedThreadLiveRefreshUsesIdleCadenceForQuietThreads() {
        XCTAssertEqual(
            SessionStore.selectedThreadLiveRefreshDelayMS(
                threadStatus: "completed",
                runtimePhase: "idle",
                hasPendingOutgoingTurns: false
            ),
            2_500
        )
    }

    func testSessionInputHistorySwipeActionMapsVerticalSwipeToTerminalArrows() {
        XCTAssertEqual(
            SessionInputHistorySwipeAction.terminalNavigationKey(for: CGSize(width: 6, height: -28)),
            .arrowUp
        )
        XCTAssertEqual(
            SessionInputHistorySwipeAction.terminalNavigationKey(for: CGSize(width: 8, height: 32)),
            .arrowDown
        )

        XCTAssertNil(
            SessionInputHistorySwipeAction.terminalNavigationKey(for: CGSize(width: 0, height: 9))
        )
        XCTAssertNil(
            SessionInputHistorySwipeAction.terminalNavigationKey(for: CGSize(width: 120, height: -30))
        )
    }

    func testSessionInputCommandHistoryReturnsRecentDistinctUserMessages() {
        let detail = RemoteThreadDetail(
            id: "thread-1",
            name: "Thread",
            cwd: "/tmp",
            workspacePath: nil,
            status: "running",
            updatedAt: 1234,
            sourceKind: nil,
            launchSource: nil,
            backendId: nil,
            backendLabel: nil,
            backendKind: nil,
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "turn-1",
                    status: "completed",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "item-1",
                            turnId: "turn-1",
                            type: "userMessage",
                            title: "ignored title",
                            detail: "first command",
                            status: nil,
                            rawText: nil,
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        ),
                        RemoteThreadItem(
                            id: "item-2",
                            turnId: "turn-1",
                            type: "agentMessage",
                            title: "agent",
                            detail: "not included",
                            status: nil,
                            rawText: nil,
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        ),
                    ]
                ),
                RemoteThreadTurn(
                    id: "turn-2",
                    status: "completed",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "item-3",
                            turnId: "turn-2",
                            type: "userMessage",
                            title: "newest title",
                            detail: "  newest command  ",
                            status: nil,
                            rawText: nil,
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        ),
                        RemoteThreadItem(
                            id: "item-4",
                            turnId: "turn-2",
                            type: "userMessage",
                            title: "duplicate title",
                            detail: "first command",
                            status: nil,
                            rawText: nil,
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        ),
                    ]
                ),
            ]
        )

        XCTAssertEqual(
            SessionInputCommandHistory.recentUserCommands(from: detail),
            ["newest command", "first command"]
        )
    }

    func testTerminalOutputPreviewUsesOneLineCollapsedWindow() {
        let output = """
        one
        two
        three
        """

        XCTAssertEqual(TerminalOutputPreview.collapsedLineCount, 1)
        XCTAssertTrue(TerminalOutputPreview.isExpandable(output))
        XCTAssertEqual(
            TerminalOutputPreview.visibleLines(from: output),
            ["one"]
        )
        XCTAssertEqual(
            TerminalOutputPreview.visibleLines(from: output, maxVisibleLines: nil),
            ["one", "two", "three"]
        )
    }

    func testTerminalCommandPreviewExpandsLongOrMultilineCommands() {
        XCTAssertFalse(TerminalCommandPreview.isExpandable("git status --short"))
        XCTAssertTrue(TerminalCommandPreview.isExpandable(
            "find data/polymarket --maxdepth 2 -printf '%s %p\\n' 2>/dev/null | sort -nr | head -80"
        ))
        XCTAssertTrue(TerminalCommandPreview.isExpandable("git status --short\npwd"))
    }

    func testTerminalCommandPreviewHidesCommandWhenCollapsedOutputCanExpand() {
        XCTAssertFalse(TerminalCommandPreview.shouldShowCommand(
            isExpanded: false,
            isExpandable: true,
            hasOutput: true,
            isTUIOutput: false
        ))
        XCTAssertTrue(TerminalCommandPreview.shouldShowCommand(
            isExpanded: true,
            isExpandable: true,
            hasOutput: true,
            isTUIOutput: false
        ))
        XCTAssertTrue(TerminalCommandPreview.shouldShowCommand(
            isExpanded: false,
            isExpandable: true,
            hasOutput: false,
            isTUIOutput: false
        ))
        XCTAssertTrue(TerminalCommandPreview.shouldShowCommand(
            isExpanded: false,
            isExpandable: false,
            hasOutput: true,
            isTUIOutput: false
        ))
    }

    func testTranscriptInlineLatexParserSplitsMarkdownAndMath() {
        let segments = TranscriptInlineLatexParser.segments(
            from: "Use **energy** $E=mc^2$ and \\(a^2+b^2=c^2\\)."
        )

        XCTAssertEqual(
            segments,
            [
                .markdown("Use **energy** "),
                .latex("E=mc^2"),
                .markdown(" and "),
                .latex("a^2+b^2=c^2"),
                .markdown("."),
            ]
        )
    }

    func testTranscriptBlockLayoutKeepsRevealCursorOffsets() {
        let blocks: [TranscriptBlock] = [
            .heading(level: 2, text: "Title"),
            .paragraph("Hello"),
            .list([
                TranscriptListItem(marker: "\u{2022}", text: "one"),
                TranscriptListItem(marker: "\u{2022}", text: "two"),
            ]),
            .latexBlock("E=mc^2"),
        ]

        let positioned = TranscriptBlockLayout.position(blocks)

        XCTAssertEqual(positioned.map(\.start), [0, 5, 10, 16])
        XCTAssertEqual(positioned.map(\.end), [5, 10, 16, 22])
        XCTAssertEqual(positioned[2].localRevealPosition(for: 12), 2.0)

        let listItems = TranscriptBlockLayout.position([
            TranscriptListItem(marker: "\u{2022}", text: "one"),
            TranscriptListItem(marker: "\u{2022}", text: "two"),
        ])
        XCTAssertEqual(listItems.map(\.start), [0, 3])
        XCTAssertEqual(listItems[1].localRevealPosition(for: 4), 1.0)
    }

    func testCodexTUIRanDetailPreviewCollapsesOnlyLongRanDetails() {
        let ran = CodexTUIEvent(
            kind: .ran,
            title: "Ran",
            summary: "curl -fsS http://127.0.0.1:8787/health",
            detail: """
            line one
            line two
            line three
            """,
            isRunning: false
        )
        let explored = CodexTUIEvent(
            kind: .explored,
            title: "Explored",
            summary: nil,
            detail: """
            Read A.swift
            Read B.swift
            Read C.swift
            """,
            isRunning: false
        )

        XCTAssertTrue(CodexTUIEventDetailPreview.isExpandable(ran))
        XCTAssertEqual(
            CodexTUIEventDetailPreview.visibleDetail(for: ran, collapsesLongRanDetails: true),
            """
            line one
            line two
            """
        )
        XCTAssertEqual(
            CodexTUIEventDetailPreview.visibleDetail(for: ran, collapsesLongRanDetails: false),
            """
            line one
            line two
            line three
            """
        )
        XCTAssertFalse(CodexTUIEventDetailPreview.isExpandable(explored))
    }

    func testCodexTUILineRevealPlanAdvancesWithinOneLineAtATime() {
        let text = "first line\nsecond line\nthird"
        var characterCount = 0
        var reachedLineBoundary = false

        while !reachedLineBoundary {
            let step = CodexTUILineRevealPlan.nextStep(after: characterCount, in: text)
            XCTAssertGreaterThan(step.characterCount, characterCount)
            characterCount = step.characterCount
            reachedLineBoundary = step.reachedLineBoundary
        }

        XCTAssertEqual(String(text.prefix(characterCount)), "first line\n")

        let nextStep = CodexTUILineRevealPlan.nextStep(after: characterCount, in: text)
        XCTAssertTrue(String(text.prefix(nextStep.characterCount)).hasPrefix("first line\ns"))
        XCTAssertFalse(String(text.prefix(nextStep.characterCount)).contains("third"))
    }

    func testCodexTUIEventParserExtractsStatusRows() {
        let tail = """
        noise
        • Ran codex --help | sed -n '1,220p'
        └ Codex CLI
        • Explored
        └ Read Package.swift
        Read README.md
        List helm-hairball-inspect
        Search sendTextViaRuntimeRelay|interruptViaRuntimeRelay in bridge
        • Tasks
        └ Update iPhone TUI
        • Waiting for background terminal (12s)
        • Queuedfollow-upmessages
        ↳ and the iphone test didn't work, the message showed up in the tui text input box again and never sent shift + ← edit last queued message › Summarize recent commits
        • Working (1m 42s • esc to interrupt)
        • Working (1m 43s • esc to interrupt)
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Ran", "Explored", "Tasks", "Waiting", "Queued", "Working"])
        XCTAssertEqual(events[0].summary, "codex --help | sed -n '1,220p'")
        XCTAssertEqual(events[0].detail, "Codex CLI")
        XCTAssertEqual(
            events[1].detail,
            """
            Read Package.swift
            Read README.md
            List helm-hairball-inspect
            Search sendTextViaRuntimeRelay|interruptViaRuntimeRelay in bridge
            """
        )
        XCTAssertEqual(events[2].detail, "Update iPhone TUI")
        XCTAssertEqual(events[3].kind, .waiting)
        XCTAssertEqual(events[3].summary, "background terminal · 12s")
        XCTAssertEqual(events[4].summary, "follow-up message")
        XCTAssertEqual(events[4].detail, "and the iphone test didn't work, the message showed up in the tui text input box again and never sent")
        XCTAssertTrue(events[4].isRunning)
        XCTAssertEqual(events[5].summary, "1m 43s")
        XCTAssertTrue(events[5].isRunning)
    }

    func testSessionFeedLiveTerminalProjectionParsesRecentLargeTail() {
        let prefix = String(repeating: "old terminal output that should not affect session open parsing\n", count: 1_400)
        let rawText = prefix + """
        • Ran git status --short
        └ M ios/Sources/SessionsView.swift
        • Working (12s • esc to interrupt)
        """
        let item = RemoteThreadItem(
            id: "live-tail-large",
            turnId: "live-tail-thread",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: rawText,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(
            from: [item],
            detailUpdatedAt: Date().timeIntervalSince1970 * 1_000,
            now: .now
        )

        XCTAssertEqual(projection.statusEvent?.kind, .working)
        XCTAssertEqual(projection.statusEvent?.summary, "12s")
    }

    func testSessionFeedLiveTerminalProjectionShowsWorkingAboveActiveQueueFallback() {
        let item = RemoteThreadItem(
            id: "live-tail-queued",
            turnId: "live-tail-thread",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Queuedfollow-upmessages
            ↳ Bring back Codex TUI event rows shift + ← edit last queued message
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [item])

        XCTAssertEqual(projection.statusEvent?.title, "Working")
        XCTAssertEqual(projection.statusEvent?.kind, .working)
        XCTAssertEqual(projection.queuedMessages, ["Bring back Codex TUI event rows"])
    }

    func testSessionFeedItemOrderingProjectsNormalizedCommandExecutionAsRanEvent() {
        let item = RemoteThreadItem(
            id: "command",
            turnId: "turn",
            type: "commandExecution",
            title: "git diff --check",
            detail: "/Users/devlin/GitHub/helm-dev | (no output)",
            status: "completed",
            rawText: "(no output)",
            metadataSummary: "cwd /Users/devlin/GitHub/helm-dev | status completed | exit 0",
            command: "git diff --check",
            cwd: "/Users/devlin/GitHub/helm-dev",
            exitCode: 0
        )

        let event = SessionFeedItemOrdering.codexToolEvent(from: item)

        XCTAssertEqual(event?.title, "Ran")
        XCTAssertEqual(event?.kind, .ran)
        XCTAssertEqual(event?.summary, "git diff --check")
        XCTAssertEqual(event?.detail, "(no output)")
    }

    func testSessionFeedItemOrderingStripsShellWrapperFromCommandSummary() {
        let item = RemoteThreadItem(
            id: "command",
            turnId: "turn",
            type: "commandExecution",
            title: "Command execution",
            detail: nil,
            status: "completed",
            rawText: nil,
            metadataSummary: nil,
            command: "/bin/zsh -lc git status --short && git rev-parse --short HEAD",
            cwd: "/Users/devlin/GitHub/helm-dev",
            exitCode: 0
        )

        let event = SessionFeedItemOrdering.codexToolEvent(from: item)

        XCTAssertEqual(event?.summary, "git status --short && git rev-parse --short HEAD")
    }

    func testSessionFeedItemOrderingSuppressesSuccessfulLocalRolloutCommands() {
        let commandItem = RemoteThreadItem(
            id: "local-command-12",
            turnId: "turn",
            type: "commandExecution",
            title: "Command execution",
            detail: nil,
            status: "completed",
            rawText: nil,
            metadataSummary: nil,
            command: "/bin/zsh -lc git push",
            cwd: "/Users/devlin/GitHub/helm-dev",
            exitCode: 0
        )
        let agentItem = RemoteThreadItem(
            id: "agent",
            turnId: "turn",
            type: "agentMessage",
            title: "Codex response",
            detail: "Pushed.",
            status: nil,
            rawText: "Pushed.",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems([commandItem, agentItem])

        XCTAssertEqual(orderedItems.map(\.id), ["agent"])
    }

    func testSessionFeedItemOrderingKeepsFailedLocalRolloutCommands() {
        let commandItem = RemoteThreadItem(
            id: "local-command-12",
            turnId: "turn",
            type: "commandExecution",
            title: "Command execution",
            detail: "exit 1",
            status: "completed",
            rawText: "exit 1",
            metadataSummary: nil,
            command: "/bin/zsh -lc curl http://127.0.0.1:8787/api/threads",
            cwd: "/Users/devlin/GitHub/helm-dev",
            exitCode: 1
        )
        let agentItem = RemoteThreadItem(
            id: "agent",
            turnId: "turn",
            type: "agentMessage",
            title: "Codex response",
            detail: "Request failed.",
            status: nil,
            rawText: "Request failed.",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems([commandItem, agentItem])

        XCTAssertEqual(orderedItems.map(\.id), ["local-command-12", "agent"])
    }

    func testSessionFeedItemOrderingProjectsNormalizedSearchToolAsCodexEvent() {
        let item = RemoteThreadItem(
            id: "search",
            turnId: "turn",
            type: "webSearch",
            title: "Web search",
            detail: "Codex TUI events",
            status: "completed",
            rawText: "Codex TUI events",
            metadataSummary: "query Codex TUI events",
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.codexToolEvent(from: item)

        XCTAssertEqual(event?.title, "Search")
        XCTAssertEqual(event?.kind, .explored)
        XCTAssertEqual(event?.summary, "Codex TUI events")
    }

    func testCodexTUIEventParserExtractsCompactActivityRows() {
        let tail = """
        • Explored  └ Read TranscriptRendering.swift, CodexTUIRendering.swift
        • Read SessionFeedView.swift
        • Search displayItems\\(|activeLiveTerminal in Sources
        • Ran git status --short
        • Edited ios/Sources/SessionFeedView.swift
        └ 1 + change
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Explored", "Read", "Search", "Ran", "Edited"])
        XCTAssertEqual(events[0].detail, "Read TranscriptRendering.swift, CodexTUIRendering.swift")
        XCTAssertEqual(events[1].summary, "SessionFeedView.swift")
        XCTAssertEqual(events[2].summary, #"displayItems\(|activeLiveTerminal in Sources"#)
        XCTAssertEqual(events[3].summary, "git status --short")
        XCTAssertEqual(events[4].summary, "ios/Sources/SessionFeedView.swift")
        XCTAssertEqual(events[4].detail, "1 + change")
    }

    func testCodexTUIEventParserExtractsUpdatedPlanRows() {
        let tail = """
        • Updated Plan
        └ ✓ Review the current patch scope
        □ Run focused iOS verification
        □ Build and install on phone
        □ Commit and push the fix
        □ Report tree state
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Updated Plan"])
        XCTAssertEqual(events.map(\.kind), [.plan])
        XCTAssertNil(events[0].summary)
        XCTAssertEqual(
            events[0].detail,
            """
            ✓ Review the current patch scope
            □ Run focused iOS verification
            □ Build and install on phone
            □ Commit and push the fix
            □ Report tree state
            """
        )

        let current = CodexTUIEventParser.currentActivityEvent(
            from: tail + "\n• Working(5s • esc to interrupt)"
        )
        XCTAssertEqual(current?.title, "Updated Plan")
    }

    func testCodexTUIPlanChecklistParserMarksFirstPendingTaskActive() {
        let tasks = CodexTUIPlanChecklistParser.tasks(
            from: """
            ✓ Review the current patch scope
            □ Run focused iOS verification
            □ Build and install on phone
            """
        )

        XCTAssertEqual(tasks.map(\.text), [
            "Review the current patch scope",
            "Run focused iOS verification",
            "Build and install on phone",
        ])
        XCTAssertEqual(tasks.map(\.marker), ["✓", "□", "□"])
        XCTAssertEqual(tasks.map(\.state), [.completed, .active, .pending])
    }

    func testCodexTUIEventParserExtractsCurrentActivityAfterLatestPrompt() {
        let tail = """
        • Ran old stale command
        └ old output
        › latest request
        • Working(0s • esc to interrupt)
        • Explored  └ Read TranscriptRendering.swift, CodexTUIRendering.swift
        • Working(5s • esc to interrupt)
        """

        let event = CodexTUIEventParser.currentActivityEvent(from: tail)

        XCTAssertEqual(event?.title, "Explored")
        XCTAssertEqual(event?.detail, "Read TranscriptRendering.swift, CodexTUIRendering.swift")
    }

    func testCodexTUIEventParserExtractsModernRunningStatusRows() {
        let tail = """
        • Thinking
        • Running xcodebuild
        • Reading SessionFeedView.swift
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Thinking", "Running", "Reading"])
        XCTAssertTrue(events.allSatisfy(\.isRunning))
        XCTAssertEqual(events[1].summary, "xcodebuild")
        XCTAssertEqual(events[2].summary, "SessionFeedView.swift")
    }

    func testCodexTUIEventParserPreservesEditedDiffForCurrentActivity() {
        let tail = """
        › file edits needs to show git diff
        • Edited ios/Sources/SessionsView.swift (+10 -5)
        └ diff --git a/ios/Sources/SessionsView.swift b/ios/Sources/SessionsView.swift
        @@ -1707,6 +1707,11 @@
        1708 + if let activityEvent = liveTerminalProjection.activityEvent {
        1718 - if !liveTerminalQueuedMessages.isEmpty {
        • Working(3s • esc to interrupt)
        """

        let event = CodexTUIEventParser.currentActivityEvent(from: tail)

        XCTAssertEqual(event?.title, "Edited")
        XCTAssertEqual(event?.summary, "ios/Sources/SessionsView.swift (+10 -5)")
        XCTAssertEqual(
            event?.detail,
            """
            diff --git a/ios/Sources/SessionsView.swift b/ios/Sources/SessionsView.swift
            @@ -1707,6 +1707,11 @@
            1708 + if let activityEvent = liveTerminalProjection.activityEvent {
            1718 - if !liveTerminalQueuedMessages.isEmpty {
            """
        )
    }

    @MainActor
    func testCodexTUIEventParserKeepsGitStatusOutputRowsVisibleInCollapsedMobilePreview() {
        let tail = """
        • Ran git status --short
        └ (no output)

        • Ran git status -sb
        └ ## backend/session-discovery...origin/backend/session-discovery

        • Ran git log -1 --oneline --decorate
        └ 8d33e6f (HEAD -> backend/session-discovery, origin/backend/session-discovery) Remove
          session row tag

        • Ran git status --short --ignored .runtime build 2>/dev/null | head -n 80
        └ !! .runtime/
          !! build/

        • Waited for background terminal
        • Working (3m 00s • esc to interrupt)
        """

        let events = CodexTUIEventParser.events(from: tail)
        let logEvents = CodexTUIEventVisibility.eventsBySuppressingPinnedStatusStrips(events)
        let visibleEvents = CodexTUIEventVisibility.collapsedEvents(
            logEvents,
            limit: SessionFeedView.collapsedCodexTUIEventCount
        )

        XCTAssertEqual(
            visibleEvents.map(\.summary),
            [
                "git status --short",
                "git status -sb",
                "git log -1 --oneline --decorate",
                "git status --short --ignored .runtime build 2>/dev/null | head -n 80",
                "background terminal",
            ]
        )
        XCTAssertEqual(visibleEvents[0].detail, "(no output)")
        XCTAssertEqual(visibleEvents[1].detail, "## backend/session-discovery...origin/backend/session-discovery")
        XCTAssertEqual(
            visibleEvents[2].detail,
            """
            8d33e6f (HEAD -> backend/session-discovery, origin/backend/session-discovery) Remove
            session row tag
            """
        )
        XCTAssertEqual(
            visibleEvents[3].detail,
            """
            !! .runtime/
            !! build/
            """
        )
        XCTAssertEqual(
            CodexTUIEventDetailPreview.visibleDetail(for: visibleEvents[3], collapsesLongRanDetails: true),
            """
            !! .runtime/
            !! build/
            """
        )
        XCTAssertFalse(visibleEvents.contains { $0.title == "Working" })
    }

    func testCodexTUIEventParserExtractsWaitingRowsFromAlternateBullets() {
        let tail = """
        - Waiting background terminal (7s)
        * WAiting background terminal (8s)
        * Ran curl -fsS http://127.0.0.1:8787/health
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Waiting", "Ran"])
        XCTAssertEqual(events[0].kind, .waiting)
        XCTAssertEqual(events[0].summary, "background terminal · 8s")
        XCTAssertTrue(events[0].isRunning)
        XCTAssertEqual(events[1].summary, "curl -fsS http://127.0.0.1:8787/health")
    }

    func testCodexTUIEventParserExtractsLifecycleStatusRows() {
        let tail = """
        • Spawned background terminal
        • WAiting for background terminal (3s)
        • Explored
        └ Search SessionFeedView.swift
        • Ran git status --short
        • Closed background terminal
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Spawned", "Waiting", "Explored", "Ran", "Closed"])
        XCTAssertEqual(events[0].kind, .status)
        XCTAssertEqual(events[0].summary, "background terminal")
        XCTAssertFalse(events[0].isRunning)
        XCTAssertEqual(events[1].kind, .waiting)
        XCTAssertEqual(events[1].summary, "background terminal · 3s")
        XCTAssertTrue(events[1].isRunning)
        XCTAssertEqual(events[4].kind, .status)
        XCTAssertEqual(events[4].summary, "background terminal")
        XCTAssertFalse(events[4].isRunning)
    }

    func testCodexTUIEventParserExtractsAgentLifecycleRows() {
        let tail = """
        . Spawned Bacon [worker] (gpt-5.3-codex medium)
        └ Add a replay CLI option so bankroll stress tests can use --allocation 500 without recorded runtime allocation overriding it.
        . Waiting for Bacon [worker]
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Spawned", "Waiting"])
        XCTAssertEqual(events[0].kind, .agent)
        XCTAssertEqual(events[0].summary, "Bacon [worker] (gpt-5.3-codex medium)")
        XCTAssertEqual(
            events[0].detail,
            "Add a replay CLI option so bankroll stress tests can use --allocation 500 without recorded runtime allocation overriding it."
        )
        XCTAssertFalse(events[0].isRunning)
        XCTAssertEqual(events[1].kind, .waiting)
        XCTAssertEqual(events[1].summary, "Bacon [worker]")
        XCTAssertTrue(events[1].isRunning)
    }

    func testCodexTUIEventParserExtractsMCPStartupStatus() {
        let tail = """
        • Starting MCP servers (1/2): XcodeBuildMCP (3m 16s · esc to interrupt)
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Starting MCP servers"])
        XCTAssertEqual(events[0].kind, .status)
        XCTAssertEqual(events[0].summary, "1/2: XcodeBuildMCP · 3m 16s")
        XCTAssertEqual(events[0].detail, "esc to interrupt")
        XCTAssertTrue(events[0].isRunning)
    }

    func testCodexTUIHighlighterColorsAgentLifecycleSyntax() {
        let runs = CodexTUIHighlighter.runs(
            for: "Bacon [worker] (gpt-5.3-codex medium)",
            eventKind: .agent,
            part: .summary
        )

        XCTAssertTrue(runs.contains(CodexTUITextRun(text: "Bacon", role: .agentName)))
        XCTAssertTrue(runs.contains(CodexTUITextRun(text: "[worker]", role: .agentRole)))
        XCTAssertTrue(runs.contains(CodexTUITextRun(text: "(gpt-5.3-codex medium)", role: .model)))
    }

    func testCodexTUIEventParserExtractsUpstreamWorkerAndSeparatorRows() {
        let tail = """
        . Waiting for Euclid [worker]
        . Finished waiting
        L Euclid [worker]: Completed - Implemented a focused SwiftUI animation cleanup.
        Closed Poincare [worker]
        ───── Worked for 1m 23s ─────
        Ran git diff --check -- ios/Sources/SessionStore.swift ios/Sources/SessionsView.swift
        L (no output)
        Explored
        L Read SessionsView.swift, SessionStore.swift, Models.swift
        . COLLABAGENTTOOLCALL Collab Agent Tool Call
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Waiting", "Finished waiting", "Closed", "Worked", "Ran", "Explored", "Agent Tool"])
        XCTAssertEqual(events[0].kind, .waiting)
        XCTAssertEqual(events[0].summary, "Euclid [worker]")
        XCTAssertTrue(events[0].isRunning)
        XCTAssertEqual(events[1].kind, .agent)
        XCTAssertEqual(events[1].detail, "Euclid [worker]: Completed - Implemented a focused SwiftUI animation cleanup.")
        XCTAssertEqual(events[2].kind, .agent)
        XCTAssertEqual(events[2].summary, "Poincare [worker]")
        XCTAssertFalse(events[2].isRunning)
        XCTAssertEqual(events[3].summary, "1m 23s")
        XCTAssertFalse(events[3].isRunning)
        XCTAssertEqual(events[4].summary, "git diff --check -- ios/Sources/SessionStore.swift ios/Sources/SessionsView.swift")
        XCTAssertEqual(events[4].detail, "(no output)")
        XCTAssertTrue(
            events[5].detail == "Read SessionsView.swift, SessionStore.swift, Models.swift" ||
                events[5].summary == "Read SessionsView.swift, SessionStore.swift, Models.swift"
        )
        XCTAssertEqual(events[6].kind, .status)
        XCTAssertEqual(events[6].summary, nil)
    }

    func testCodexTUIEventParserClearsWaitingRowsAfterWaitedCompletion() {
        let tail = """
        * Waiting background terminal (43s)
        gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 70% · weekly 29%
        - Waited background terminal
        * Ran git status --short --branch
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Waited", "Ran"])
        XCTAssertFalse(events.contains { $0.kind == .waiting })
        XCTAssertEqual(events[0].kind, .waited)
        XCTAssertEqual(events[0].summary, "background terminal")
        XCTAssertFalse(events[0].isRunning)
        XCTAssertEqual(events[1].summary, "git status --short --branch")
    }

    func testCodexTUIEventParserExtractsNewQueueHeader() {
        let tail = """
        • Messages to be submitted after next tool call
        ↳ Testing from iPhone shift + ← edit last queued message
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Queued"])
        XCTAssertEqual(events[0].detail, "Testing from iPhone")
        XCTAssertTrue(events[0].isRunning)
    }

    func testCodexTUIEventParserExtractsQueuedMessages() {
        let tail = """
        • Messages to be submitted after next tool call
        ↳ First phone message shift + ← edit last queued message
        ↳ Second phone message shift + ← edit last queued message
        • Working (1m 43s • esc to interrupt)
        """

        let messages = CodexTUIEventParser.queuedMessages(from: tail)

        XCTAssertEqual(messages, ["First phone message", "Second phone message"])
    }

    func testCodexTUIEventParserExtractsCompactedQueuedMessageFromLiveTail() {
        let tail = """
        • Working (3m 41s • esc to interrupt)
        • Queuedfollow-upmessages  ↳ mobile tui also does not show queued messages from the cli either. it needs to show them.show the next message thats up in queue and let me click to expand to see the rest. shift + ← edit last queued message › Write tests for @filename   gpt-5.4 xhigh · Fast off · 5h 82% · weekly 14% · ~/GitHub/helm-dev · Helm Dev
        • Working (3m 44s • esc to interrupt)
        """

        let messages = CodexTUIEventParser.queuedMessages(from: tail)

        XCTAssertEqual(
            messages,
            [
                "mobile tui also does not show queued messages from the cli either. it needs to show them.show the next message thats up in queue and let me click to expand to see the rest."
            ]
        )
    }

    func testCodexTUIEventParserExtractsCurrentQueuedMessageAfterCliToolRows() {
        let tail = """
        • Queuedfollow-upmessages
        ↳ Next queued message shift + ← edit last queued message
        • Ran git status --short
        └ (no output)
        • Working(5s • esc to interrupt) › Write tests for @filename   gpt-5.4 xhigh · Fast off · 5h 82% · weekly 14% · ~/GitHub/helm-dev · Helm Dev
        """

        let messages = CodexTUIEventParser.currentQueuedMessages(from: tail)

        XCTAssertEqual(messages, ["Next queued message"])
    }

    func testCodexTUIEventParserDropsConsumedQueuedMessageFromAppendOnlyTail() {
        let tail = """
        • Queuedfollow-upmessages
        ↳ Old queued message shift + ← edit last queued message
        • Finished the previous turn.
        › Old queued message
        • Working(0s • esc to interrupt)
        """

        let messages = CodexTUIEventParser.currentQueuedMessages(from: tail)

        XCTAssertTrue(messages.isEmpty)
    }

    func testCodexTUIQueuedMessagePreviewExpandsLongSingleMessage() {
        let longMessage = "mobile tui also does not show queued messages from the cli either. it needs to show them and let me expand the queued text."

        XCTAssertFalse(CodexTUIQueuedMessagesPreview.canExpand(["short queue item"]))
        XCTAssertTrue(CodexTUIQueuedMessagesPreview.canExpand([longMessage]))
        XCTAssertEqual(
            CodexTUIQueuedMessagesPreview.collapsedText(for: [longMessage]),
            "\(longMessage) ..."
        )
        XCTAssertEqual(
            CodexTUIQueuedMessagesPreview.collapsedText(for: ["line one\nline two"]),
            "line one ..."
        )
    }

    func testCodexTUIEventParserExtractsStatuslineCheckboxOptions() {
        let tail = """
        Configure status line
        ❯ [x] model
          [ ] current directory
          ☑ weekly limit
          ☐ 5h limit
        Enter to confirm · Space to toggle
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.kind), [.option, .option, .option, .option])
        XCTAssertEqual(events.map(\.title), ["[x]", "[ ]", "☑", "☐"])
        XCTAssertEqual(events.map(\.summary), ["model", "current directory", "weekly limit", "5h limit"])
        XCTAssertEqual(events.map(\.isSelected), [true, false, false, false])
    }

    func testCodexTUIEventParserExtractsFlattenedStatuslineMenuOptions() {
        let tail = """
        Configure Status Line Select which items to display in the status line. Type to search > › [x] model-with-reasoning  Current model name with reasoning level [x] fast-mode  Whether Fast mode is currently active [x] five-hour-limit  Remaining usage on 5-hour usage limit [x] weekly-limit  Remaining usage on weekly usage limit [x] current-dir  Current working directory [x] thread-title  Current thread title (omitted unless changed by user) [20;3H[ [20;5H] [20;7Hmodel-name  Current model name [21;3H[ [21;5H] [21;7Hproject-root  Project root directory (omitted when unavailable) gpt-5.4 xhigh · Fast off · 5h 92% · weekly 16% · /private/tmp Use ↑↓ to navigate, ←→ to move, space to select, enter to confirm, esc to cancel
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.kind), Array(repeating: .option, count: 8))
        XCTAssertEqual(events.map(\.title), ["[x]", "[x]", "[x]", "[x]", "[x]", "[x]", "[ ]", "[ ]"])
        XCTAssertEqual(events.map(\.summary), [
            "model-with-reasoning Current model name with reasoning level",
            "fast-mode Whether Fast mode is currently active",
            "five-hour-limit Remaining usage on 5-hour usage limit",
            "weekly-limit Remaining usage on weekly usage limit",
            "current-dir Current working directory",
            "thread-title Current thread title (omitted unless changed by user)",
            "model-name Current model name",
            "project-root Project root directory (omitted when unavailable)",
        ])
        XCTAssertEqual(events.map(\.isSelected), [true, false, false, false, false, false, false, false])
    }

    func testCodexTUIVisibilityKeepsInteractiveOptionsExpanded() {
        let events = CodexTUIEventParser.events(
            from: """
            Configure status line
            ❯ [x] model
              [ ] current directory
              [ ] project name
              [x] effort level
              [ ] context usage
              [ ] fast mode
              [ ] five hour limit
              [x] weekly limit
            Enter to confirm · Space to toggle
            """
        )

        let visibleEvents = CodexTUIEventVisibility.collapsedEvents(events, limit: 4)

        XCTAssertEqual(visibleEvents.count, 8)
        XCTAssertEqual(visibleEvents.map(\.summary), [
            "model",
            "current directory",
            "project name",
            "effort level",
            "context usage",
            "fast mode",
            "five hour limit",
            "weekly limit",
        ])
        XCTAssertEqual(visibleEvents.map(\.isSelected), [true, false, false, false, false, false, false, false])
    }

    func testCodexTUIEventParserStopsQueuedDetailBeforePromptStatus() {
        let tail = """
        • Messages to be submitted after next tool call
        ↳ [Image #1] for example what i was talking about. › Run /review on my current changes gpt-5.4 xhigh · Context [██▍  ] · Context [██▍  ] · 258K window · Fast off · 5h 70% · weekly 29%
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Queued"])
        XCTAssertEqual(events[0].detail, "[Image #1] for example what i was talking about.")
    }

    func testCodexTUIStatusBarParserExtractsCodexCliStatus() {
        let status = CodexTUIStatusBarParser.status(
            from: "gpt-5.4 xhigh · Context [██▍  ] · Context [██▍  ] · 258K window · Fast off · 5h 70% · weekly 29%"
        )

        XCTAssertEqual(status?.model, "gpt-5.4")
        XCTAssertEqual(status?.effort, "xhigh")
        XCTAssertEqual(status?.contexts, ["Context [██▍ ]", "Context [██▍ ]"])
        XCTAssertEqual(status?.window, "258K window")
        XCTAssertEqual(status?.fastMode, "Fast off")
        XCTAssertEqual(status?.fiveHourLimit, "5h 70%")
        XCTAssertEqual(status?.weeklyLimit, "weekly 29%")
    }

    func testCodexTUIStatusBarParserExtractsCustomizedCodexCliStatus() {
        let status = CodexTUIStatusBarParser.status(
            from: "gpt-5.4 xhigh · Fast off · 5h 93% · weekly 23% · ~/GitHub/prediction-markets-bot · PolymarketBot"
        )

        XCTAssertEqual(status?.model, "gpt-5.4")
        XCTAssertEqual(status?.effort, "xhigh")
        XCTAssertEqual(status?.contexts, [])
        XCTAssertEqual(status?.window, "")
        XCTAssertEqual(status?.fastMode, "Fast off")
        XCTAssertEqual(status?.fiveHourLimit, "5h 93%")
        XCTAssertEqual(status?.weeklyLimit, "weekly 23%")
        XCTAssertEqual(
            status?.parts,
            ["gpt-5.4", "xhigh", "Fast off", "5h 93%", "weekly 23%", "~/GitHub/prediction-markets-bot", "PolymarketBot"]
        )
    }

    func testCodexTUIStatusBarParserKeepsTruncatedStatuslineSegmentsVisible() {
        let status = CodexTUIStatusBarParser.status(
            from: "gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 92% · weekly…▌▌3WWo"
        )

        XCTAssertEqual(status?.contexts, ["Context [███▌ ]", "Context [███▌ ]"])
        XCTAssertEqual(status?.window, "258K window")
        XCTAssertEqual(status?.weeklyLimit, "weekly…")
        XCTAssertEqual(status?.parts.suffix(3), ["Fast off", "5h 92%", "weekly…"])
    }

    func testCodexTUIStatusBarParserStopsBeforeConcatenatedRedraws() {
        let status = CodexTUIStatusBarParser.status(
            from: "gpt-5.4 xhigh · Context [██▍ ] · 258K window · Fast off · 5h 70% · weekly 29%gpt-5.4 xhigh · Context [██▌ ] · 258K window · Fast off · 5h 71% · weekly 30%gpt-5.4 xhigh · Context [██▋ ] · 258K window · Fast off · 5h 72% · weekly 31%"
        )

        XCTAssertEqual(status?.parts, ["gpt-5.4", "xhigh", "Context [██▋ ]", "258K window", "Fast off", "5h 72%", "weekly 31%"])
    }

    func testCodexTUIStatusBarParserExtractsCwdProjectOnlyStatusline() {
        let status = CodexTUIStatusBarParser.status(
            from: "gpt-5.4 xhigh · ~/GitHub/helm-dev · helm"
        )

        XCTAssertEqual(status?.model, "gpt-5.4")
        XCTAssertEqual(status?.effort, "xhigh")
        XCTAssertEqual(status?.parts, ["gpt-5.4", "xhigh", "~/GitHub/helm-dev", "helm"])
    }

    func testCodexTUIStatusBarParserDropsPromptTailAfterStatusline() {
        let status = CodexTUIStatusBarParser.status(
            from: "gpt-5.4 xhigh · Fast off · 5h 93% · weekly 23% · ~/GitHub/helm-dev · helm › also, the statusline bar on the mobile tui seems to be picking up the last message sent"
        )

        XCTAssertEqual(status?.model, "gpt-5.4")
        XCTAssertEqual(status?.effort, "xhigh")
        XCTAssertEqual(
            status?.parts,
            ["gpt-5.4", "xhigh", "Fast off", "5h 93%", "weekly 23%", "~/GitHub/helm-dev", "helm"]
        )
    }

    func testCodexTUIEventParserExtractsBareWorkingStatusLine() {
        let events = CodexTUIEventParser.events(
            from: "•Working · 1 background terminal running · /ps to view · /stop to close"
        )

        XCTAssertEqual(events.map(\.title), ["Working"])
        XCTAssertEqual(events[0].summary, "1 background terminal running · /ps to view · /stop to close")
        XCTAssertTrue(events[0].isRunning)
    }

    func testCodexTUICollapsedEventsKeepRunningStatusVisible() {
        let events = CodexTUIEventParser.events(
            from: """
            • Queued follow-up messages
            ↳ Testing from iPhone
            • Working (1m 43s • esc to interrupt)
            • Ran git status --short --branch
            • Explored
            └ Read TASKS.md
            • Edited ios/Sources/SessionFeedView.swift
            └ 1 + change
            • Context compacted
            • Ran git diff --check
            """
        )

        let visibleEvents = CodexTUIEventVisibility.collapsedEvents(events, limit: 4)

        XCTAssertEqual(visibleEvents.map(\.title), ["Queued", "Working", "Explored", "Edited", "Context compacted", "Ran"])
        XCTAssertTrue(visibleEvents.contains { $0.title == "Queued" && $0.detail == "Testing from iPhone" })
        XCTAssertTrue(visibleEvents.contains { $0.title == "Working" && $0.summary == "1m 43s" })
    }

    func testSessionFeedItemOrderingKeepsWorkingOnlyLiveTerminalVisibleWhenRunning() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: "•Working(52s • esc to interrupt)",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Test",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let agentItem = RemoteThreadItem(
            id: "agent",
            turnId: "turn",
            type: "agentMessage",
            title: "Codex response",
            detail: nil,
            status: nil,
            rawText: "Working on it.",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems([liveTerminalItem, userItem, agentItem])

        XCTAssertEqual(orderedItems.map(\.id), ["live-tail", "user", "agent"])
    }

    func testSessionFeedItemOrderingKeepsWorkingOnlyLiveTerminalVisibleWhenStatusLags() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: "• Working (52s • esc to interrupt)",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Test",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems([liveTerminalItem, userItem])

        XCTAssertEqual(orderedItems.map(\.id), ["live-tail", "user"])
    }

    func testSessionFeedItemOrderingHidesCompletedLiveTerminalHistory() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Ran xcrun devicectl device install app --device CEAC9A27 /tmp/Helm.app
            └ App installed
            • Ran git status --short --branch
            └ ## backend/session-discovery...origin/backend/session-discovery
            • Ran git log -1 --oneline
            └ 61cbf74 Use swipe-up input actions
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Push to my phone now",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let agentItem = RemoteThreadItem(
            id: "agent",
            turnId: "turn",
            type: "agentMessage",
            title: "Codex response",
            detail: nil,
            status: nil,
            rawText: "Installed and launched.",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems(
            [liveTerminalItem, userItem, agentItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 2_000,
            now: now
        )

        XCTAssertEqual(orderedItems.map(\.id), ["user", "agent"])
        XCTAssertFalse(SessionFeedItemOrdering.hasCurrentLiveTerminalRunningStatus(liveTerminalItem))
        XCTAssertFalse(SessionFeedItemOrdering.isActiveLiveTerminalItem(
            liveTerminalItem,
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 2_000,
            now: now
        ))
    }

    func testSessionFeedItemOrderingProjectsCurrentQueuedLiveTerminalWhenStatusLags() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Messages to be submitted after next tool call
            ↳ Testing from iPhone shift + ← edit last queued message
            gpt-5.4 xhigh · Context [██▌ ] · Context [██▌ ] · 258K window · Fast off · 5h 71% · weekly 30%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Testing",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems(
            [liveTerminalItem, userItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 2_000,
            now: now
        )
        let messages = SessionFeedItemOrdering.activeLiveTerminalQueuedMessages(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 2_000,
            now: now
        )

        XCTAssertEqual(orderedItems.map(\.id), ["user"])
        XCTAssertEqual(messages, ["Testing from iPhone"])
        XCTAssertTrue(SessionFeedItemOrdering.hasCurrentLiveTerminalRunningStatus(liveTerminalItem))
    }

    func testCodexTUIVisibilitySuppressesOnlyPinnedWorkingStatus() {
        let events = CodexTUIEventParser.events(
            from: """
            • Explored
            └ Read SessionFeedView.swift
            • Waiting for background terminal (38s)
            • Working (1m 42s • esc to interrupt)
            • Working (1m 43s • esc to interrupt)
            • Queued follow-up messages
            ↳ Testing from iPhone
            """
        )

        let visibleEvents = CodexTUIEventVisibility.eventsBySuppressingPinnedWorkingStatus(events)

        XCTAssertEqual(visibleEvents.map(\.title), ["Explored", "Waiting", "Queued"])
        XCTAssertTrue(visibleEvents.contains { $0.kind == .waiting && $0.summary == "background terminal · 38s" })
        XCTAssertFalse(visibleEvents.contains { $0.title == "Working" })
        XCTAssertTrue(visibleEvents.contains { $0.title == "Queued" && $0.detail == "Testing from iPhone" })
    }

    func testCodexTUIVisibilitySuppressesPinnedStatusStrips() {
        let events = CodexTUIEventParser.events(
            from: """
            • Explored
            └ Read SessionFeedView.swift
            • Queued follow-up messages
            ↳ Testing from iPhone
            • Working (1m 43s • esc to interrupt)
            """
        )

        let visibleEvents = CodexTUIEventVisibility.eventsBySuppressingPinnedStatusStrips(events)

        XCTAssertEqual(visibleEvents.map(\.title), ["Explored"])
    }

func testCodexTUIVisibilitySuppressesPinnedThinkingStatusStrip() {
    let events = CodexTUIEventParser.events(
        from: """
        • Thinking
        • Running xcodebuild
        • Reading SessionFeedView.swift
        """
    )

    let visibleEvents = CodexTUIEventVisibility.eventsBySuppressingPinnedStatusStrips(events)

    XCTAssertEqual(visibleEvents.map(\.title), ["Running", "Reading"])
    XCTAssertEqual(visibleEvents.map(\.summary), ["xcodebuild", "SessionFeedView.swift"])
}

    func testSessionFeedItemOrderingExtractsPinnedLiveTerminalWorkingOnly() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Queuedfollow-upmessages
            ↳ Testing from iPhone
            • Exploring
            └ Search runtime-launches in bridge
            • Working (1m 43s • esc to interrupt)
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(from: [liveTerminalItem])

        XCTAssertEqual(event?.title, "Working")
        XCTAssertEqual(event?.summary, "1m 43s")
        XCTAssertTrue(event?.isRunning == true)
    }

    func testCodexTUIEventParserDetectsInterruptedConversationStatus() {
        let events = CodexTUIEventParser.events(
            from: """
            ■Conversationinterrupted-tellthemodelwhattododifferently. Somethingwentwrong? Hit`/feedback`toreporttheissue.
            """
        )

        XCTAssertEqual(events.last?.kind, .interrupted)
        XCTAssertEqual(events.last?.title, "Interrupted")
        XCTAssertEqual(events.last?.detail, "Tell the model what to do differently.")
        XCTAssertFalse(events.last?.isRunning ?? true)
    }

    func testSessionFeedItemOrderingProjectsInterruptedLiveTerminalStatus() {
        let now = Date(timeIntervalSince1970: 1_776_261_700)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            Tip:Youcanresumeapreviousconversationbyrunningcodexresume›Usetheshelltooltorun`sleep30`,thensayDONE.Startnow.
            •Runningsleep30now.
            ■Conversationinterrupted-tellthemodelwhattododifferently. Somethingwentwrong? Hit`/feedback`toreporttheissue.
            gpt-5.4 xhigh · Context [██▌ ] · 258K window · Fast off · 5h 71% · weekly 30%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 90_000,
            now: now
        )

        XCTAssertEqual(projection.statusEvent?.kind, .interrupted)
        XCTAssertEqual(projection.statusEvent?.title, "Interrupted")
        XCTAssertEqual(projection.statusEvent?.detail, "Tell the model what to do differently.")
        XCTAssertFalse(projection.statusEvent?.isRunning ?? true)
    }

    func testSessionFeedItemOrderingKeepsActiveLiveTerminalActivityInFeed() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Ran stale command
            └ stale output
            › Add mobile TUI activity support
            • Working(0s • esc to interrupt)
            • Explored  └ Search displayItems\\(|activeLiveTerminal in Sources
            Read SessionFeedView.swift, CodexTUIRendering.swift
            • Working(9s • esc to interrupt)
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Keep activities in the TUI chat",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems([liveTerminalItem, userItem])
        let visibleEvents = CodexTUIEventVisibility.eventsBySuppressingPinnedStatusStrips(
            CodexTUIEventParser.currentTurnEvents(from: liveTerminalItem.rawText ?? "")
        )

        XCTAssertEqual(orderedItems.map(\.id), ["live-tail", "user"])
        XCTAssertEqual(visibleEvents.map(\.title), ["Explored"])
        XCTAssertEqual(
            visibleEvents.first?.detail,
            """
            Search displayItems\\(|activeLiveTerminal in Sources
            Read SessionFeedView.swift, CodexTUIRendering.swift
            """
        )
    }

    func testSessionFeedItemOrderingProjectsCurrentLiveTerminalActivity() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            › Restore mobile activity status
            • Working(0s • esc to interrupt)
            • Read SessionFeedView.swift
            • Working(9s • esc to interrupt)
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.statusEvent?.title, "Working")
        XCTAssertEqual(projection.activityEvent?.title, "Read")
        XCTAssertEqual(projection.activityEvent?.summary, "SessionFeedView.swift")
        XCTAssertTrue(projection.activityEvent?.isRunning ?? false)
    }

func testSessionFeedItemOrderingPinsWorkingStatusLineInsteadOfReadActivity() {
    let liveTerminalItem = RemoteThreadItem(
        id: "live-tail",
        turnId: "live-tail-turn",
        type: "commandExecution",
        title: "Live terminal",
        detail: nil,
        status: "running",
        rawText: """
        › Restore mobile activity status
        • Working(0s • esc to interrupt)
        • Read SessionFeedView.swift
        • Working(9s • esc to interrupt)
        """,
        metadataSummary: nil,
        command: nil,
        cwd: nil,
        exitCode: nil
    )

    let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

    XCTAssertEqual(projection.pinnedStatusLineEvent?.title, "Working")
    XCTAssertEqual(projection.pinnedStatusLineEvent?.summary, "9s")
}

func testSessionFeedItemOrderingPinsThinkingStatusLine() {
    let reasoningItem = RemoteThreadItem(
        id: "reasoning",
        turnId: "turn",
        type: "reasoning",
        title: "Reasoning",
        detail: "Review launch mode defaults",
        status: "running",
        rawText: nil,
        metadataSummary: nil,
        command: nil,
        cwd: nil,
        exitCode: nil
    )

    let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(
        from: [reasoningItem],
        detailUpdatedAt: Date().timeIntervalSince1970 * 1_000,
        now: .now
    )

    XCTAssertEqual(projection.pinnedStatusLineEvent?.title, "Thinking")
    XCTAssertEqual(projection.pinnedStatusLineEvent?.summary, "Review launch mode defaults")
}

func testSessionFeedItemOrderingLeavesExploringInThreadInsteadOfPinnedStatusLine() {
    let liveTerminalItem = RemoteThreadItem(
        id: "live-tail",
        turnId: "live-tail-turn",
        type: "commandExecution",
        title: "Live terminal",
        detail: nil,
        status: "running",
        rawText: """
        • Exploring Search runtime launches in bridge
        """,
        metadataSummary: nil,
        command: nil,
        cwd: nil,
        exitCode: nil
    )

    let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

    XCTAssertEqual(projection.statusEvent?.title, "Exploring")
    XCTAssertNil(projection.pinnedStatusLineEvent)
}

    func testSessionFeedItemOrderingProjectsStructuredRunningCommandActivity() {
        let commandItem = RemoteThreadItem(
            id: "local-command-1",
            turnId: "turn",
            type: "commandExecution",
            title: "Command execution",
            detail: nil,
            status: "running",
            rawText: nil,
            metadataSummary: nil,
            command: "/bin/zsh -lc xcodebuild -project ios/Helm.xcodeproj -scheme Helm build",
            cwd: "/Users/devlin/GitHub/helm-dev",
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(
            from: [commandItem],
            detailUpdatedAt: Date().timeIntervalSince1970 * 1_000,
            now: .now
        )
        let event = SessionFeedItemOrdering.codexToolEvent(from: commandItem)

        XCTAssertEqual(projection.activityEvent?.title, "Running")
        XCTAssertEqual(projection.activityEvent?.summary, "xcodebuild -project ios/Helm.xcodeproj -scheme Helm build")
        XCTAssertTrue(projection.activityEvent?.isRunning ?? false)
        XCTAssertEqual(event?.title, "Running")
        XCTAssertTrue(event?.isRunning ?? false)
    }

    func testSessionFeedItemOrderingDoesNotPinWaitingAsWorkingStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            * Waiting background terminal (8s)
            gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(from: [liveTerminalItem])
        let tuiEvents = CodexTUIEventParser.events(from: liveTerminalItem.rawText ?? "")

        XCTAssertNil(event)
        XCTAssertEqual(tuiEvents.map(\.title), ["Waiting"])
        XCTAssertEqual(tuiEvents.first?.summary, "background terminal · 8s")
    }

    func testSessionFeedItemOrderingProjectsWaitingLiveTerminalStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            * Waiting background terminal (8s)
            gpt-5.4 xhigh · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.statusEvent?.kind, .waiting)
        XCTAssertEqual(projection.statusEvent?.title, "Waiting")
        XCTAssertEqual(projection.statusEvent?.summary, "background terminal · 8s")
        XCTAssertTrue(projection.statusEvent?.isRunning ?? false)
    }

    func testSessionFeedItemOrderingProjectsWaitingForWorkerStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            . Waiting for Euclid [worker]
            gpt-5.4 xhigh · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.statusEvent?.kind, .waiting)
        XCTAssertEqual(projection.statusEvent?.title, "Waiting")
        XCTAssertEqual(projection.statusEvent?.summary, "Euclid [worker]")
        XCTAssertTrue(projection.statusEvent?.isRunning ?? false)
        XCTAssertNil(projection.workingEvent)
    }

    func testSessionFeedItemOrderingExtractsActiveQueuedMessages() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Messages to be submitted after next tool call
            ↳ First queued message shift + ← edit last queued message
            ↳ Second queued message shift + ← edit last queued message
            • Working (1m 43s • esc to interrupt)
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let messages = SessionFeedItemOrdering.activeLiveTerminalQueuedMessages(from: [liveTerminalItem])

        XCTAssertEqual(messages, ["First queued message", "Second queued message"])
    }

    func testSessionFeedItemOrderingKeepsWorkingVisibleWhenQueuedMessagesAreActive() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Working(12s • esc to interrupt)
            • Queuedfollow-upmessages
            ↳ Next queued message shift + ← edit last queued message
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.workingEvent?.title, "Working")
        XCTAssertEqual(projection.workingEvent?.summary, "12s")
        XCTAssertEqual(projection.queuedMessages, ["Next queued message"])
    }

    func testSessionFeedItemOrderingProjectsWorkingForElapsedStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            - Working for 1m 23s
            gpt-5.4 xhigh · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.workingEvent?.title, "Working")
        XCTAssertEqual(projection.workingEvent?.summary, "1m 23s")
        XCTAssertTrue(projection.workingEvent?.isRunning ?? false)
    }

    func testSessionFeedItemOrderingProjectsExploringLiveTerminalStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Exploring Search runtime launches in bridge
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.statusEvent?.kind, .exploring)
        XCTAssertEqual(projection.statusEvent?.title, "Exploring")
        XCTAssertEqual(projection.statusEvent?.summary, "Search runtime launches in bridge")
        XCTAssertTrue(projection.statusEvent?.isRunning ?? false)
    }

    func testSessionFeedItemOrderingProjectsGenericRunningLifecycleStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Spawned background terminal
            • Opening runtime relay (2s)
            gpt-5.4 xhigh · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertEqual(projection.statusEvent?.kind, .status)
        XCTAssertEqual(projection.statusEvent?.title, "Opening")
        XCTAssertEqual(projection.statusEvent?.summary, "runtime relay (2s)")
        XCTAssertTrue(projection.statusEvent?.isRunning ?? false)
    }

    func testSessionFeedItemOrderingProjectsMCPStartupStatus() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Starting MCP servers (1/2): XcodeBuildMCP (3m 16s · esc to interrupt)
            gpt-5.4 xhigh · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        )

        XCTAssertEqual(projection.statusEvent?.kind, .status)
        XCTAssertEqual(projection.statusEvent?.title, "Starting MCP servers")
        XCTAssertEqual(projection.statusEvent?.summary, "1/2: XcodeBuildMCP · 3m 26s")
        XCTAssertEqual(projection.statusEvent?.detail, "esc to interrupt")
        XCTAssertTrue(projection.statusEvent?.isRunning ?? false)
    }

    func testSessionFeedItemOrderingDoesNotPinClosedLifecycleStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Spawned background terminal
            • Closed background terminal
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertNil(projection.statusEvent)
        XCTAssertFalse(SessionFeedItemOrdering.hasCurrentLiveTerminalRunningStatus(liveTerminalItem))
    }

    func testSessionFeedItemOrderingDoesNotPinFinishedWaitingClosedOrWorkedSeparator() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            . Waiting for Euclid [worker]
            . Finished waiting
            L Euclid [worker]: Completed - Implemented a focused SwiftUI animation cleanup.
            . Closed Euclid [worker]
            ───── Worked for 1m 23s ─────
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let projection = SessionFeedItemOrdering.activeLiveTerminalProjection(from: [liveTerminalItem])

        XCTAssertNil(projection.statusEvent)
        XCTAssertFalse(SessionFeedItemOrdering.hasCurrentLiveTerminalRunningStatus(liveTerminalItem))
    }

    func testSessionFeedItemOrderingKeepsCliQueuedMessagesVisibleBetweenStatusTicks() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Queuedfollow-upmessages
            ↳ Next queued message shift + ← edit last queued message
            • Ran git status --short
            └ (no output)
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let messages = SessionFeedItemOrdering.activeLiveTerminalQueuedMessages(from: [liveTerminalItem])

        XCTAssertEqual(messages, ["Next queued message"])
    }

    func testSessionFeedItemOrderingDoesNotSurfaceConsumedQueuedMessageFromAppendOnlyTail() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Queuedfollow-upmessages
            ↳ Old queued message shift + ← edit last queued message
            • Finished and pushed the previous turn.
            › Old queued message
            • Working(0s • esc to interrupt)
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let messages = SessionFeedItemOrdering.activeLiveTerminalQueuedMessages(from: [liveTerminalItem])

        XCTAssertTrue(messages.isEmpty)
    }

    func testSessionFeedItemOrderingDoesNotPinQueuedMessagesFromCompletedTail() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Messages to be submitted after next tool call
            ↳ Old queued message shift + ← edit last queued message
            Fixed and pushed.
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let messages = SessionFeedItemOrdering.activeLiveTerminalQueuedMessages(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        )

        XCTAssertTrue(messages.isEmpty)
    }

    func testSessionFeedItemOrderingExtractsPinnedWorkingWhenBridgeStatusLags() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            › Testing from iPhone
            • Working (1m 43s • esc to interrupt)
            gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(from: [liveTerminalItem])

        XCTAssertEqual(event?.title, "Working")
        XCTAssertEqual(event?.summary, "1m 43s")
        XCTAssertTrue(event?.isRunning == true)
        XCTAssertTrue(SessionFeedItemOrdering.isActiveLiveTerminalItem(liveTerminalItem))
    }

    func testSessionFeedItemOrderingKeepsWorkingOnlyLiveTerminalVisibleInFeed() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Working (1m 43s • esc to interrupt)
            gpt-5.4 xhigh · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Keep the working tab visible",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems(
            [liveTerminalItem, userItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        )

        XCTAssertEqual(orderedItems.map(\.id), ["live-tail", "user"])
    }

    func testSessionFeedItemOrderingKeepsCompletedActivityLiveTerminalVisibleInFeed() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Ran rg -n "turn/steer" bridge/src
            • Explored bridge/src/codexAppServerClient.ts
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )
        let userItem = RemoteThreadItem(
            id: "user",
            turnId: "turn",
            type: "userMessage",
            title: "User message",
            detail: nil,
            status: nil,
            rawText: "Show completed activity rows",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let orderedItems = SessionFeedItemOrdering.displayItems(
            [liveTerminalItem, userItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 120_000,
            now: now
        )

        XCTAssertEqual(orderedItems.map(\.id), ["live-tail", "user"])
        XCTAssertEqual(
            SessionFeedItemOrdering.liveTerminalFeedEvents(from: liveTerminalItem).map(\.title),
            ["Ran", "Explored"]
        )
    }

    func testSessionStoreMergesLiveTailOnlyDetailIntoExistingHistory() {
        let existing = RemoteThreadDetail(
            id: "thread",
            name: "Session",
            cwd: "/tmp",
            workspacePath: "/tmp",
            status: "running",
            updatedAt: 100,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "live-tail-thread",
                    status: "running",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "live-tail-item-old",
                            turnId: "live-tail-thread",
                            type: "commandExecution",
                            title: "Live terminal",
                            detail: nil,
                            status: "running",
                            rawText: "• Working (1s • esc to interrupt)",
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        )
                    ]
                ),
                RemoteThreadTurn(
                    id: "turn-1",
                    status: "completed",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "user-1",
                            turnId: "turn-1",
                            type: "userMessage",
                            title: "User message",
                            detail: nil,
                            status: nil,
                            rawText: "hello",
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        )
                    ]
                )
            ]
        )

        let incoming = RemoteThreadDetail(
            id: "thread",
            name: nil,
            cwd: "/tmp",
            workspacePath: nil,
            status: "running",
            updatedAt: 104,
            sourceKind: nil,
            launchSource: nil,
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "live-tail-thread",
                    status: "running",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "live-tail-item-new",
                            turnId: "live-tail-thread",
                            type: "commandExecution",
                            title: "Live terminal",
                            detail: nil,
                            status: "running",
                            rawText: "• Working (5s • esc to interrupt)",
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        )
                    ]
                )
            ]
        )

        let merged = SessionStore.mergedLiveTailDetail(existing, with: incoming)

        XCTAssertEqual(merged?.turns.map(\.id), ["live-tail-thread", "turn-1"])
        XCTAssertEqual(merged?.turns.first?.items.first?.rawText, "• Working (5s • esc to interrupt)")
        XCTAssertEqual(merged?.updatedAt, 104)
        XCTAssertEqual(merged?.workspacePath, "/tmp")
    }

    func testSessionStoreMergedLiveTailDetailPreservesStableFieldsWhenIncomingIsBlank() {
        let existing = RemoteThreadDetail(
            id: "thread",
            name: "Session",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 100,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "turn-1", status: "completed", error: nil, items: []),
                RemoteThreadTurn(id: "live-tail-thread", status: "running", error: nil, items: []),
            ]
        )

        let incoming = RemoteThreadDetail(
            id: "thread",
            name: " ",
            cwd: "",
            workspacePath: nil,
            status: "running",
            updatedAt: 104,
            sourceKind: "",
            launchSource: nil,
            backendId: "",
            backendLabel: "  ",
            backendKind: nil,
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "live-tail-thread", status: "running", error: nil, items: [])
            ]
        )

        let merged = SessionStore.mergedLiveTailDetail(existing, with: incoming)

        XCTAssertEqual(merged?.name, "Session")
        XCTAssertEqual(merged?.cwd, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged?.workspacePath, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged?.backendId, "codex-cli")
        XCTAssertEqual(merged?.backendLabel, "Codex")
        XCTAssertEqual(merged?.sourceKind, "cli")
    }

    func testSessionStoreMergedPlaceholderDetailPreservesCachedTurns() {
        let existing = RemoteThreadDetail(
            id: "thread",
            name: "Cached Session",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 100,
            sourceKind: "vscode",
            launchSource: nil,
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "turn-1", status: "completed", error: nil, items: []),
                RemoteThreadTurn(id: "turn-2", status: "running", error: nil, items: []),
            ]
        )

        let incoming = RemoteThreadDetail(
            id: "thread",
            name: " ",
            cwd: "",
            workspacePath: nil,
            status: "completed",
            updatedAt: 120,
            sourceKind: nil,
            launchSource: nil,
            backendId: nil,
            backendLabel: nil,
            backendKind: nil,
            command: nil,
            affordances: nil,
            turns: []
        )

        let merged = SessionStore.mergedPlaceholderDetail(existing, with: incoming)

        XCTAssertEqual(merged?.turns.map(\.id), ["turn-1", "turn-2"])
        XCTAssertEqual(merged?.name, "Cached Session")
        XCTAssertEqual(merged?.cwd, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged?.status, "completed")
        XCTAssertEqual(merged?.updatedAt, 120)
        XCTAssertEqual(merged?.sourceKind, "vscode")
    }

    func testSessionStoreMergedPartialCodexAppDetailPreservesCachedHistory() {
        let existing = RemoteThreadDetail(
            id: "thread",
            name: "Codex App Session",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "completed",
            updatedAt: 100,
            sourceKind: "vscode",
            launchSource: nil,
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "turn-1", status: "completed", error: nil, items: []),
                RemoteThreadTurn(id: "turn-2", status: "completed", error: nil, items: []),
                RemoteThreadTurn(id: "turn-3", status: "completed", error: nil, items: []),
            ]
        )

        let incoming = RemoteThreadDetail(
            id: "thread",
            name: nil,
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: nil,
            status: "running",
            updatedAt: 140,
            sourceKind: nil,
            launchSource: nil,
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "turn-3", status: "running", error: nil, items: []),
                RemoteThreadTurn(id: "turn-4", status: "running", error: nil, items: []),
            ]
        )

        let merged = SessionStore.mergedPartialCodexAppDetail(existing, with: incoming)

        XCTAssertEqual(merged?.turns.map(\.id), ["turn-1", "turn-2", "turn-3", "turn-4"])
        XCTAssertEqual(merged?.turns.first(where: { $0.id == "turn-3" })?.status, "running")
        XCTAssertEqual(merged?.status, "running")
        XCTAssertEqual(merged?.updatedAt, 140)
        XCTAssertEqual(merged?.name, "Codex App Session")
        XCTAssertEqual(merged?.sourceKind, "vscode")
    }

    func testSessionStoreDoesNotMergePartialCliReplacementDetail() {
        let existing = RemoteThreadDetail(
            id: "thread",
            name: "CLI Session",
            cwd: "/tmp",
            workspacePath: "/tmp",
            status: "running",
            updatedAt: 100,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "turn-1", status: "completed", error: nil, items: []),
                RemoteThreadTurn(id: "turn-2", status: "completed", error: nil, items: []),
            ]
        )
        let incoming = RemoteThreadDetail(
            id: "thread",
            name: "CLI Session",
            cwd: "/tmp",
            workspacePath: "/tmp",
            status: "completed",
            updatedAt: 120,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "replacement-turn", status: "completed", error: nil, items: [])
            ]
        )

        XCTAssertNil(SessionStore.mergedPartialCodexAppDetail(existing, with: incoming))
    }

    func testSessionStoreStabilizedThreadSnapshotPreservesNonEmptyCurrentValues() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let incoming = RemoteThread(
            id: "thread",
            name: nil,
            preview: " ",
            cwd: "",
            workspacePath: " ",
            status: "running",
            updatedAt: 200,
            sourceKind: "",
            launchSource: nil,
            backendId: " ",
            backendLabel: "",
            backendKind: nil,
            controller: nil
        )

        let merged = SessionStore.stabilizedThreadSnapshot(
            incoming: incoming,
            currentThread: current,
            detail: nil,
            stableTitle: nil
        )

        XCTAssertEqual(merged.name, "Current Name")
        XCTAssertEqual(merged.preview, "Current preview")
        XCTAssertEqual(merged.cwd, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged.workspacePath, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged.backendLabel, "Codex")
        XCTAssertEqual(merged.backendId, "codex-cli")
        XCTAssertEqual(merged.updatedAt, 225)
    }

    func testSessionStoreStabilizedThreadSnapshotPreservesListSummaryDuringLiveTailChurn() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let incoming = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 500,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let detail = RemoteThreadDetail(
            id: "thread",
            name: "Current Name",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 500,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "live-tail-thread", status: "running", error: nil, items: []),
                RemoteThreadTurn(id: "turn-1", status: "completed", error: nil, items: [])
            ]
        )

        let merged = SessionStore.stabilizedThreadSnapshot(
            incoming: incoming,
            currentThread: current,
            detail: detail,
            stableTitle: nil
        )

        XCTAssertEqual(merged.preview, "Current preview")
        XCTAssertEqual(merged.updatedAt, 225)
    }

    func testSessionStoreStabilizedThreadSummaryPreservesCurrentWhenDetailFieldsAreBlank() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let detail = RemoteThreadDetail(
            id: "thread",
            name: " ",
            cwd: "",
            workspacePath: nil,
            status: "running",
            updatedAt: 200,
            sourceKind: " ",
            launchSource: nil,
            backendId: "",
            backendLabel: " ",
            backendKind: nil,
            command: nil,
            affordances: nil,
            turns: []
        )

        let merged = SessionStore.stabilizedThreadSummary(
            detail: detail,
            detailPreview: nil,
            currentThread: current,
            stableTitle: nil
        )

        XCTAssertEqual(merged.name, "Current Name")
        XCTAssertEqual(merged.preview, "Current preview")
        XCTAssertEqual(merged.cwd, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged.workspacePath, "/Users/devlin/GitHub/helm-dev")
        XCTAssertEqual(merged.backendLabel, "Codex")
        XCTAssertEqual(merged.backendId, "codex-cli")
        XCTAssertEqual(merged.updatedAt, 225)
    }

    func testSessionStoreStabilizedThreadSummaryPreservesListSummaryDuringLiveTailOnlyUpdate() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let detail = RemoteThreadDetail(
            id: "thread",
            name: "Current Name",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 400,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "live-tail-thread",
                    status: "running",
                    error: nil,
                    items: []
                )
            ]
        )

        let merged = SessionStore.stabilizedThreadSummary(
            detail: detail,
            detailPreview: "volatile live tail preview",
            currentThread: current,
            stableTitle: nil,
            preserveCurrentListSummary: true
        )

        XCTAssertEqual(merged.preview, "Current preview")
        XCTAssertEqual(merged.updatedAt, 225)
    }

    func testSessionStoreStabilizedThreadSummaryPreservesListSummaryDuringMixedLiveTailChurn() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let detail = RemoteThreadDetail(
            id: "thread",
            name: "Current Name",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 500,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "live-tail-thread", status: "running", error: nil, items: []),
                RemoteThreadTurn(
                    id: "turn-1",
                    status: "completed",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "agent-1",
                            turnId: "turn-1",
                            type: "agentMessage",
                            title: "Current preview",
                            detail: "Current preview",
                            status: nil,
                            rawText: "Current preview",
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(SessionStore.shouldPreserveListSummaryForLiveTailChurn(
            incomingPreview: "Current preview",
            currentThread: current,
            detail: detail
        ))

        let merged = SessionStore.stabilizedThreadSummary(
            detail: detail,
            detailPreview: "Current preview",
            currentThread: current,
            stableTitle: nil,
            preserveCurrentListSummary: true
        )

        XCTAssertEqual(merged.preview, "Current preview")
        XCTAssertEqual(merged.updatedAt, 225)
    }

    func testSessionStoreStabilizedThreadSummaryPreservesListSummaryDuringRunningChurn() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Stable list preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let detail = RemoteThreadDetail(
            id: "thread",
            name: "Current Name",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 500,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "turn-1",
                    status: "inProgress",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "agent-1",
                            turnId: "turn-1",
                            type: "agentMessage",
                            title: "Partial active update",
                            detail: nil,
                            status: "running",
                            rawText: "Partial active update",
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        )
                    ]
                )
            ]
        )

        let merged = SessionStore.stabilizedThreadSummary(
            detail: detail,
            detailPreview: "Partial active update",
            currentThread: current,
            stableTitle: nil
        )

        XCTAssertEqual(merged.preview, "Stable list preview")
        XCTAssertEqual(merged.updatedAt, 225)
        XCTAssertEqual(merged.status, "running")
    }

    func testSessionStoreStabilizedThreadSnapshotPreservesListSummaryDuringRunningChurn() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Stable list preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let incoming = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Partial active update",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 500,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let merged = SessionStore.stabilizedThreadSnapshot(
            incoming: incoming,
            currentThread: current,
            detail: nil,
            stableTitle: nil
        )

        XCTAssertEqual(merged.preview, "Stable list preview")
        XCTAssertEqual(merged.updatedAt, 225)
        XCTAssertEqual(merged.status, "running")
    }

    func testSessionStoreStabilizedThreadSummaryStillUpdatesForNormalDetail() {
        let current = RemoteThread(
            id: "thread",
            name: "Current Name",
            preview: "Current preview",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "running",
            updatedAt: 225,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            controller: nil
        )

        let detail = RemoteThreadDetail(
            id: "thread",
            name: "Current Name",
            cwd: "/Users/devlin/GitHub/helm-dev",
            workspacePath: "/Users/devlin/GitHub/helm-dev",
            status: "completed",
            updatedAt: 400,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex-cli",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "turn-2",
                    status: "completed",
                    error: nil,
                    items: [
                        RemoteThreadItem(
                            id: "agent-1",
                            turnId: "turn-2",
                            type: "agentMessage",
                            title: "Agent message",
                            detail: nil,
                            status: nil,
                            rawText: "New result preview",
                            metadataSummary: nil,
                            command: nil,
                            cwd: nil,
                            exitCode: nil
                        )
                    ]
                )
            ]
        )

        let merged = SessionStore.stabilizedThreadSummary(
            detail: detail,
            detailPreview: "New result preview",
            currentThread: current,
            stableTitle: nil
        )

        XCTAssertEqual(merged.preview, "New result preview")
        XCTAssertEqual(merged.updatedAt, 400)
    }

    func testSessionStoreIsLiveTailOnlyDetailUpdate() {
        let liveTailOnly = RemoteThreadDetail(
            id: "thread",
            name: nil,
            cwd: "/tmp",
            workspacePath: nil,
            status: "running",
            updatedAt: 100,
            sourceKind: nil,
            launchSource: nil,
            backendId: nil,
            backendLabel: nil,
            backendKind: nil,
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "live-tail-thread", status: "running", error: nil, items: [])
            ]
        )
        let mixed = RemoteThreadDetail(
            id: "thread",
            name: nil,
            cwd: "/tmp",
            workspacePath: nil,
            status: "running",
            updatedAt: 100,
            sourceKind: nil,
            launchSource: nil,
            backendId: nil,
            backendLabel: nil,
            backendKind: nil,
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(id: "live-tail-thread", status: "running", error: nil, items: []),
                RemoteThreadTurn(id: "turn-1", status: "completed", error: nil, items: [])
            ]
        )

        XCTAssertTrue(SessionStore.isLiveTailOnlyDetailUpdate(liveTailOnly))
        XCTAssertFalse(SessionStore.isLiveTailOnlyDetailUpdate(mixed))
    }

    func testSessionStoreDeduplicatesThreadSnapshotsByNewestEntry() {
        let older = testRemoteThread(
            id: "duplicate-thread",
            name: "Old",
            preview: "older preview",
            updatedAt: 100
        )
        let newer = testRemoteThread(
            id: "duplicate-thread",
            name: "New",
            preview: "newer preview",
            updatedAt: 200
        )
        let other = testRemoteThread(
            id: "other-thread",
            name: "Other",
            preview: "other preview",
            updatedAt: 150
        )

        let deduplicated = SessionStore.deduplicatedThreadsByID([older, other, newer])

        XCTAssertEqual(deduplicated.map(\.id), ["duplicate-thread", "other-thread"])
        XCTAssertEqual(deduplicated.first?.name, "New")
        XCTAssertEqual(deduplicated.first?.preview, "newer preview")
    }

    func testSessionStoreDeduplicatesRuntimeSnapshotsByNewestEntry() {
        let older = testRuntimeThread(
            threadId: "duplicate-thread",
            phase: "running",
            title: "Old",
            lastUpdatedAt: 100
        )
        let newer = testRuntimeThread(
            threadId: "duplicate-thread",
            phase: "completed",
            title: "New",
            lastUpdatedAt: 200
        )
        let other = testRuntimeThread(
            threadId: "other-thread",
            phase: "running",
            title: "Other",
            lastUpdatedAt: 150
        )

        let deduplicated = SessionStore.deduplicatedRuntimeThreadsByID([older, other, newer])

        XCTAssertEqual(deduplicated.map(\.threadId), ["duplicate-thread", "other-thread"])
        XCTAssertEqual(deduplicated.first?.title, "New")
        XCTAssertEqual(deduplicated.first?.phase, "completed")
    }

    func testSessionStoreQueuedDeliveryModeRecognizesAppServerSteer() {
        XCTAssertTrue(SessionStore.isQueuedDeliveryMode("shellRelayQueued"))
        XCTAssertTrue(SessionStore.isQueuedDeliveryMode("appServerSteerQueued"))
        XCTAssertFalse(SessionStore.isQueuedDeliveryMode("shellRelay"))
        XCTAssertFalse(SessionStore.isQueuedDeliveryMode(nil))
    }

    func testSessionStoreKeepsQueuedDraftClearedForAmbiguousShellRelayFailure() {
        XCTAssertTrue(SessionStore.queuedSendFailureMayHaveReachedCLI(
            "shell relay did not confirm Codex queued the follow-up for thread-1"
        ))
        XCTAssertTrue(SessionStore.queuedSendFailureMayHaveReachedCLI(
            "Codex thread thread-1 is running; queued delivery could not be confirmed"
        ))
        XCTAssertFalse(SessionStore.queuedSendFailureMayHaveReachedCLI("Bridge unavailable"))
    }

    func testSessionStoreDoesNotMergeNonLiveTailReplacementDetail() {
        let existing = RemoteThreadDetail(
            id: "thread",
            name: "Session",
            cwd: "/tmp",
            workspacePath: "/tmp",
            status: "running",
            updatedAt: 100,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "turn-1",
                    status: "completed",
                    error: nil,
                    items: []
                )
            ]
        )

        let incoming = RemoteThreadDetail(
            id: "thread",
            name: "Session",
            cwd: "/tmp",
            workspacePath: "/tmp",
            status: "completed",
            updatedAt: 101,
            sourceKind: "cli",
            launchSource: "helm-shell-wrapper",
            backendId: "codex",
            backendLabel: "Codex",
            backendKind: "codex",
            command: nil,
            affordances: nil,
            turns: [
                RemoteThreadTurn(
                    id: "turn-2",
                    status: "completed",
                    error: nil,
                    items: []
                )
            ]
        )

        XCTAssertNil(SessionStore.mergedLiveTailDetail(existing, with: incoming))
    }

    func testSessionFeedItemOrderingExtractsFreshPinnedWorkingWhenBridgeStatusLags() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: "• Working (1m 43s • esc to interrupt)",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        )

        XCTAssertEqual(event?.title, "Working")
        XCTAssertEqual(event?.summary, "1m 53s")
        XCTAssertTrue(SessionFeedItemOrdering.isActiveLiveTerminalItem(
            liveTerminalItem,
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        ))
    }

    func testSessionFeedItemOrderingDoesNotUseStaleWorkingElapsedWhenCurrentWorkingHasNoTime() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Working (11m 24s • esc to interrupt)
            intermediate output from an earlier turn
            • Working
            gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        )

        XCTAssertEqual(event?.title, "Working")
        XCTAssertNil(event?.summary)
    }

    func testSessionFeedItemOrderingDoesNotPinFreshTailWhenWorkingIsNotCurrentStatus() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Working (11m 24s • esc to interrupt)
            gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            Fixed, installed on The Phone, and pushed.
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        )

        XCTAssertNil(event)
        XCTAssertFalse(SessionFeedItemOrdering.isActiveLiveTerminalItem(
            liveTerminalItem,
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 10_000,
            now: now
        ))
    }

    func testSessionFeedItemOrderingDoesNotPinStaleWorkingTail() {
        let now = Date(timeIntervalSince1970: 1_776_025_000)
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: """
            • Working (11m 24s • esc to interrupt)
            › Run /review on my current changes
            gpt-5.4 xhigh · Context [███▌ ] · Context [███▌ ] · 258K window · Fast off · 5h 66% · weekly 28%
            Implemented, installed on The Phone, committed, and pushed.
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(
            from: [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 120_000,
            now: now
        )

        let orderedItems = SessionFeedItemOrdering.displayItems(
            [liveTerminalItem],
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 120_000,
            now: now
        )

        XCTAssertNil(event)
        XCTAssertFalse(SessionFeedItemOrdering.isActiveLiveTerminalItem(
            liveTerminalItem,
            detailUpdatedAt: now.timeIntervalSince1970 * 1_000 - 120_000,
            now: now
        ))
        XCTAssertTrue(orderedItems.isEmpty)
    }

    func testSessionFeedItemOrderingDoesNotPinQueuedLiveTerminalStatus() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Queuedfollow-upmessages
            ↳ Testing from iPhone
            • Exploring
            └ Search runtime-launches in bridge
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let event = SessionFeedItemOrdering.activeLiveTerminalWorkingEvent(from: [liveTerminalItem])

        XCTAssertNil(event)
    }

    func testSessionFeedItemOrderingExtractsLiveTerminalStatusBar() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "running",
            rawText: """
            • Working (1m 43s • esc to interrupt)
            › Run /review on my current changes
            gpt-5.4 xhigh · Context [██▍  ] · Context [██▍  ] · 258K window · Fast off · 5h 70% · weekly 29%
            """,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let status = SessionFeedItemOrdering.activeLiveTerminalStatusBar(from: [liveTerminalItem])

        XCTAssertEqual(status?.model, "gpt-5.4")
        XCTAssertEqual(status?.effort, "xhigh")
        XCTAssertEqual(status?.fastMode, "Fast off")
        XCTAssertEqual(status?.fiveHourLimit, "5h 70%")
        XCTAssertEqual(status?.weeklyLimit, "weekly 29%")
    }

    func testSessionFeedItemOrderingExtractsIdleLiveTerminalStatusBar() {
        let liveTerminalItem = RemoteThreadItem(
            id: "live-tail",
            turnId: "live-tail-turn",
            type: "commandExecution",
            title: "Live terminal",
            detail: nil,
            status: "completed",
            rawText: "gpt-5.4 xhigh · Context [██▍  ] · Context [██▍  ] · 258K window · Fast off · 5h 70% · weekly 29%",
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let status = SessionFeedItemOrdering.activeLiveTerminalStatusBar(from: [liveTerminalItem])

        XCTAssertEqual(status?.model, "gpt-5.4")
        XCTAssertEqual(status?.effort, "xhigh")
    }

    func testCodexSlashCommandCatalogSuggestsStatuslineConfiguration() {
        let suggestions = CodexSlashCommandCatalog.suggestions(for: "/stat")

        XCTAssertEqual(suggestions.map(\.command), ["/status", "/statusline"])
        XCTAssertTrue(CodexSlashCommandCatalog.all.contains { $0.command == "/permissions" })
        XCTAssertTrue(CodexSlashCommandCatalog.all.contains { $0.command == "/review" })
    }

    func testCodexSlashCommandCatalogDoesNotSuggestRemovedHelpCommand() {
        XCTAssertFalse(CodexSlashCommandCatalog.all.contains { $0.command == "/help" })
        XCTAssertFalse(CodexSlashCommandCatalog.suggestions(for: "/").contains { $0.command == "/help" })
        XCTAssertEqual(CodexSlashCommandCatalog.suggestions(for: "/h").map(\.command), [])
    }

    func testCodexSlashCommandCatalogCompletesDraftPreservingArguments() {
        let command = CodexSlashCommandCatalog.all.first { $0.command == "/model" }!

        XCTAssertEqual(
            CodexSlashCommandCatalog.completedDraft(selecting: command, in: "/mo gpt-5.4"),
            "/model gpt-5.4"
        )
        XCTAssertEqual(
            CodexSlashCommandCatalog.completedDraft(selecting: command, in: "/mo"),
            "/model "
        )
    }

    func testComposerCompletionEngineDetectsFileAndSkillTokens() {
        XCTAssertEqual(
            ComposerCompletionEngine.query(in: "Review @ios/Sour", cwd: "/repo"),
            .file(prefix: "ios/Sour", cwd: "/repo")
        )
        XCTAssertEqual(
            ComposerCompletionEngine.query(in: "Use $swift", cwd: "/repo"),
            .skill(prefix: "swift", cwd: "/repo")
        )
    }

    func testComposerCompletionEngineCompletesTrailingFileAndSkillTokens() {
        let fileSuggestion = ComposerCompletionEngine.fileSuggestions([
            FileTagSuggestion(
                path: "ios/Sources/SessionInputBar.swift",
                displayPath: "ios/Sources/SessionInputBar.swift",
                completion: "ios/Sources/SessionInputBar.swift",
                isDirectory: false
            )
        ])[0]
        XCTAssertEqual(
            ComposerCompletionEngine.completedDraft(
                selecting: fileSuggestion,
                in: "Inspect @ios/Sour"
            ),
            "Inspect @ios/Sources/SessionInputBar.swift "
        )

        let skillSuggestion = ComposerCompletionEngine.skillSuggestions([
            SkillSuggestion(
                name: "swiftui-ui-patterns",
                summary: "SwiftUI best practices",
                path: "/Users/devlin/.codex/skills/swiftui-ui-patterns"
            )
        ])[0]
        XCTAssertEqual(
            ComposerCompletionEngine.completedDraft(
                selecting: skillSuggestion,
                in: "Use $swi"
            ),
            "Use $swiftui-ui-patterns "
        )
    }

    func testComposerCompletionEnginePreservesSlashCompletionBehavior() {
        XCTAssertEqual(
            ComposerCompletionEngine.query(in: "/mo gpt-5.4", cwd: "/repo"),
            .slash("/mo")
        )

        let slashSuggestion = ComposerCompletionEngine.slashSuggestions(for: "/mo gpt-5.4")[0]
        XCTAssertEqual(
            ComposerCompletionEngine.completedDraft(
                selecting: slashSuggestion,
                in: "/mo gpt-5.4"
            ),
            "/model gpt-5.4"
        )
    }

    func testComposerCompletionEngineAllowsFileCompletionInsideSlashArguments() {
        XCTAssertEqual(
            ComposerCompletionEngine.query(in: "/review @ios/Sour", cwd: "/repo"),
            .file(prefix: "ios/Sour", cwd: "/repo")
        )

        let fileSuggestion = ComposerCompletionEngine.fileSuggestions([
            FileTagSuggestion(
                path: "ios/Sources/SessionInputBar.swift",
                displayPath: "ios/Sources/SessionInputBar.swift",
                completion: "ios/Sources/SessionInputBar.swift",
                isDirectory: false
            )
        ])[0]

        XCTAssertEqual(
            ComposerCompletionEngine.completedDraft(
                selecting: fileSuggestion,
                in: "/review @ios/Sour"
            ),
            "/review @ios/Sources/SessionInputBar.swift "
        )
    }

    func testCodexTUIHighlighterColorsShellRows() {
        let runs = CodexTUIHighlighter.runs(
            for: "codex --help | sed -n '1,220p'",
            eventKind: .ran,
            part: .summary
        )

        XCTAssertEqual(
            runs,
            [
                CodexTUITextRun(text: "codex", role: .command),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "--help", role: .option),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "|", role: .operatorToken),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "sed", role: .command),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "-n", role: .option),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "'1,220p'", role: .literal),
            ]
        )
    }

    func testCodexTUIHighlighterColorsExploredRows() {
        let runs = CodexTUIHighlighter.runs(
            for: "Read Package.swift\nList helm-hairball-inspect\nSearch sendTextViaRuntimeRelay|interruptViaRuntimeRelay in bridge",
            eventKind: .explored,
            part: .detail
        )

        XCTAssertEqual(
            runs,
            [
                CodexTUITextRun(text: "Read", role: .action),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "Package.swift", role: .identifier),
                CodexTUITextRun(text: "\n", role: .primary),
                CodexTUITextRun(text: "List", role: .action),
                CodexTUITextRun(text: " helm-hairball-inspect\n", role: .primary),
                CodexTUITextRun(text: "Search", role: .action),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "sendTextViaRuntimeRelay|interruptViaRuntimeRelay", role: .identifier),
                CodexTUITextRun(text: " ", role: .primary),
                CodexTUITextRun(text: "in", role: .secondary),
                CodexTUITextRun(text: " bridge", role: .primary),
            ]
        )
    }

    func testCodexTUIEventParserExtractsEditedRows() {
        let tail = """
        • Edited ios/Sources/SessionStore.swift
        └ 1185 +     for threadID in uniqueThreadIDs {
        1186 - dismissedActiveThreadMarkers.removeValue(forKey: threadID)
        1187 +     dismissActiveThreadMarkers[threadID] = dismissedMarker
        """

        let events = CodexTUIEventParser.events(from: tail)

        XCTAssertEqual(events.map(\.title), ["Edited"])
        XCTAssertEqual(events[0].summary, "ios/Sources/SessionStore.swift")
        XCTAssertEqual(
            events[0].detail,
            """
            1185 +     for threadID in uniqueThreadIDs {
            1186 - dismissedActiveThreadMarkers.removeValue(forKey: threadID)
            1187 +     dismissActiveThreadMarkers[threadID] = dismissedMarker
            """
        )
    }

    func testCodexTUIEditedDiffParserClassifiesLines() {
        let lines = CodexTUIEditedDiffParser.lines(
            from: """
            @@ session marker
            1185 +     for threadID in uniqueThreadIDs {
            1186 - dismissedActiveThreadMarkers.removeValue(forKey: threadID)
            1187 dismissedActiveThreadMarkers[threadID] = dismissedMarker
            + trailing addition
            - trailing deletion
            """
        )

        XCTAssertEqual(lines.map(\.kind), [.hunk, .addition, .deletion, .context, .addition, .deletion])
        XCTAssertEqual(lines[1].lineNumber, "1185")
        XCTAssertEqual(lines[1].marker, "+")
        XCTAssertEqual(lines[1].content, "    for threadID in uniqueThreadIDs {")
        XCTAssertEqual(lines[2].lineNumber, "1186")
        XCTAssertEqual(lines[2].marker, "-")
        XCTAssertEqual(lines[3].lineNumber, "1187")
        XCTAssertNil(lines[3].marker)
    }

    func testFeedStyleLabelsCollabAgentToolCallAsAgent() {
        let item = RemoteThreadItem(
            id: "collab-tool",
            turnId: "turn-1",
            type: "collabAgentToolCall",
            title: "Collab Agent Tool Call",
            detail: nil,
            status: nil,
            rawText: nil,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        XCTAssertEqual(FeedStyle.itemLabel(for: item), "Agent")
        XCTAssertEqual(FeedStyle.itemAccent(for: item), AppPalette.accent)
    }

    func testTranscriptSemanticHighlighterColorsCliTokens() {
        let runs = TranscriptSemanticHighlighter.runs(
            for: "Ran git status in TASKS.md after commit d4c919e; tests passed."
        )

        XCTAssertTrue(runs.contains(TranscriptSemanticTextRun(text: "Ran", role: .accent)))
        XCTAssertTrue(runs.contains(TranscriptSemanticTextRun(text: "git", role: .command)))
        XCTAssertTrue(runs.contains(TranscriptSemanticTextRun(text: "TASKS.md", role: .path)))
        XCTAssertTrue(runs.contains(TranscriptSemanticTextRun(text: "d4c919e;", role: .path)))
        XCTAssertTrue(runs.contains(TranscriptSemanticTextRun(text: "passed.", role: .success)))
    }

    func testTranscriptSemanticHighlightingPolicySuppressesColorsDuringAnimatedReveal() {
        let text = "Ran git status in TASKS.md after commit d4c919e; tests passed."

        XCTAssertTrue(
            TranscriptSemanticHighlightingPolicy.shouldHighlight(
                text,
                role: .assistant,
                animateText: false
            )
        )
        XCTAssertFalse(
            TranscriptSemanticHighlightingPolicy.shouldHighlight(
                text,
                role: .assistant,
                animateText: true
            )
        )
    }
}

private func testRemoteThread(
    id: String,
    name: String?,
    preview: String,
    updatedAt: Double
) -> RemoteThread {
    RemoteThread(
        id: id,
        name: name,
        preview: preview,
        cwd: "/tmp/\(id)",
        workspacePath: nil,
        status: "running",
        updatedAt: updatedAt,
        sourceKind: "cli",
        launchSource: nil,
        backendId: "codex",
        backendLabel: "Codex",
        backendKind: "codex",
        controller: nil
    )
}

private func testBackendSummary(id: String, label: String) -> BackendSummary {
    BackendSummary(
        id: id,
        label: label,
        kind: id,
        description: "\(label) backend",
        isDefault: id == "codex",
        available: true,
        availabilityDetail: nil,
        capabilities: BackendCapabilities(
            threadListing: true,
            threadCreation: true,
            turnExecution: true,
            turnInterrupt: true,
            approvals: true,
            planMode: false,
            voiceCommand: true,
            realtimeVoice: id == "codex",
            hooksAndSkillsParity: id == "codex",
            sharedThreadHandoff: id == "codex"
        ),
        command: BackendCommandSemantics(
            routing: "threadTurns",
            approvals: "bridgeDecisions",
            handoff: id == "codex" ? "sharedThread" : "sessionResume",
            voiceInput: "bridgeRealtime",
            voiceOutput: "bridgeSpeech",
            supportsCommandFollowups: true,
            notes: "\(label) semantics"
        )
    )
}

private func testRuntimeThread(
    threadId: String,
    phase: String,
    title: String,
    lastUpdatedAt: Double
) -> RemoteRuntimeThread {
    RemoteRuntimeThread(
        threadId: threadId,
        phase: phase,
        currentTurnId: nil,
        title: title,
        detail: nil,
        lastUpdatedAt: lastUpdatedAt,
        pendingApprovals: [],
        recentEvents: []
    )
}
