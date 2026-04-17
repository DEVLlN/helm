import Foundation
import Observation
import UserNotifications
import WatchKit

@MainActor
@Observable
final class WatchSessionStore {
    var bridge = WatchBridgeClient()
    var threads: [WatchRemoteThread] = []
    var runtimeByThreadID: [String: WatchRuntimeThread] = [:]
    var threadDetailByID: [String: WatchRemoteThreadDetail] = [:]
    var selectedThreadID: String?
    var commandDraft = ""
    var connectionSummary = "Bridge disconnected"
    var recoverySummary: String?
    var pairingSummary = "Pairing token required"
    var notificationAuthorizationSummary = "Unknown"
    var attentionEvents: [WatchAttentionEvent] = []

    private let selectedThreadDefaultsKey = "helm.watch.selected-thread-id"
    private let notifications = WatchNotificationCoordinator.shared
    private var hasSeededRuntime = false
    private var hasStarted = false
    private var isSceneActive = true
    private var bridgeRealtimeConnected = false
    private var lastForegroundRefreshAt: Date?
    private var realtimeReconnectTask: Task<Void, Never>?
    private var backgroundSuspendTask: Task<Void, Never>?
    private var recoverySummaryClearTask: Task<Void, Never>?
    private var realtimeReconnectAttempt = 0
    private var realtimeReconnectStartedAt: Date?
    private var detailRefreshTask: Task<Void, Never>?
    private let launchStartedAt = Date()
    private var awaitingRecoveryRefresh = false
    private(set) var lastSnapshotLatencyMS: Int?
    private(set) var lastCommandLatencyMS: Int?
    private(set) var lastApprovalLatencyMS: Int?
    private(set) var lastLaunchReadyLatencyMS: Int?
    private(set) var lastReconnectLatencyMS: Int?

    init() {
        selectedThreadID = UserDefaults.standard.string(forKey: selectedThreadDefaultsKey)
    }

    var selectedThread: WatchRemoteThread? {
        threads.first(where: { $0.id == selectedThreadID })
    }

    var selectedRuntime: WatchRuntimeThread? {
        guard let selectedThreadID else { return nil }
        return runtimeByThreadID[selectedThreadID]
    }

    var selectedThreadDetail: WatchRemoteThreadDetail? {
        guard let selectedThreadID else { return nil }
        return threadDetailByID[selectedThreadID]
    }

    var selectedThreadCommandSummary: String? {
        selectedThreadDetail?.affordances?.notes ?? selectedThreadDetail?.command?.notes
    }

    var selectedThreadCanRespondToApprovals: Bool {
        selectedThreadDetail?.affordances?.canRespondToApprovals ?? true
    }

    var selectedThreadSupportsCommand: Bool {
        guard let command = selectedThreadDetail?.command else {
            return true
        }

        return command.voiceInput != "unsupported"
    }

    var highestPriorityThread: WatchRemoteThread? {
        threads.max { lhs, rhs in
            priorityScore(for: lhs.id) < priorityScore(for: rhs.id)
        }
    }

    var highestPrioritySummary: String {
        guard let thread = highestPriorityThread else {
            return "Standing by."
        }

        let name = thread.name ?? "Selected Session"
        guard let runtime = runtimeByThreadID[thread.id] else {
            return "\(name) is ready."
        }

        switch runtime.phase {
        case "waitingApproval":
            return "\(name) needs approval."
        case "blocked":
            return runtime.detail ?? "\(name) is blocked."
        case "completed":
            return runtime.detail ?? "\(name) completed recent work."
        case "running":
            return runtime.title ?? "\(name) is active."
        default:
            return "\(name) is ready."
        }
    }

    var diagnosticsMetrics: [WatchResponsivenessBudgetMetric] {
        [
            WatchResponsivenessBudgetMetric(id: "launch", title: "Launch", sampleMS: lastLaunchReadyLatencyMS, healthyThresholdMS: 1500, warningThresholdMS: 3000),
            WatchResponsivenessBudgetMetric(id: "snapshot", title: "Snapshot", sampleMS: lastSnapshotLatencyMS, healthyThresholdMS: 1000, warningThresholdMS: 2000),
            WatchResponsivenessBudgetMetric(id: "command", title: "Command Ack", sampleMS: lastCommandLatencyMS, healthyThresholdMS: 1200, warningThresholdMS: 2200),
            WatchResponsivenessBudgetMetric(id: "approval", title: "Approval", sampleMS: lastApprovalLatencyMS, healthyThresholdMS: 1400, warningThresholdMS: 2600),
            WatchResponsivenessBudgetMetric(id: "reconnect", title: "Reconnect", sampleMS: lastReconnectLatencyMS, healthyThresholdMS: 1800, warningThresholdMS: 3600)
        ]
    }

    var diagnosticsHealthStatus: WatchResponsivenessBudgetStatus {
        if awaitingRecoveryRefresh || recoveryNeedsAttention {
            return .critical
        }

        return diagnosticsMetrics
            .map(\.status)
            .max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
    }

    var diagnosticsHealthSummary: String {
        if recoveryNeedsAttention {
            return "Live recovery still needs attention."
        }

        if awaitingRecoveryRefresh {
            return "Recovering live state."
        }

        switch diagnosticsHealthStatus {
        case .unknown:
            return "Collecting responsiveness samples."
        case .healthy:
            return "Current watch samples are within target."
        case .warning:
            return "One or more watch paths are slower than target."
        case .critical:
            return "Watch responsiveness needs attention."
        }
    }

    var selectedThreadHandoffSummary: String {
        guard let thread = selectedThread else {
            return "helm and the CLI stay attached to the same Codex thread."
        }

        let backendLabel = thread.backendLabel ?? "Codex"

        if let controller = thread.controller {
            if controller.clientId == bridge.identity.id {
                return "This watch is currently driving the shared thread."
            }

            return "\(controller.clientName) currently has control. You can keep observing here or continue on iPhone."
        }

        switch thread.sourceKind {
        case "cli":
            return "Started in the CLI. You can continue it here or hand off to iPhone."
        case "vscode":
            return "Started from the editor. helm can continue the same \(backendLabel) work across devices."
        default:
            return "This shared thread is ready to continue from any helm surface."
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        backgroundSuspendTask?.cancel()
        await refreshPairing()
        let granted = await notifications.requestAuthorizationIfNeeded()
        notificationAuthorizationSummary = granted ? "Enabled" : await notifications.authorizationDescription()
        await refreshAll()
        lastForegroundRefreshAt = .now
        if isSceneActive {
            connectRealtime()
        }
        lastLaunchReadyLatencyMS = Int(Date().timeIntervalSince(launchStartedAt) * 1000)
    }

    func refreshAll() async {
        let startedAt = Date()
        do {
            async let threadsTask = bridge.fetchThreads()
            async let runtimeTask = bridge.fetchRuntime()
            let (threads, runtime) = try await (threadsTask, runtimeTask)

            let previousRuntime = runtimeByThreadID
            applyThreadsSnapshot(threads)
            applyRuntimeSnapshot(runtime)

            if let selectedThreadID, threads.contains(where: { $0.id == selectedThreadID }) {
                // keep
            } else {
                self.selectedThreadID = threads.first?.id
            }

            processAttentionUpdates(previous: previousRuntime, current: self.runtimeByThreadID)
            await refreshSelectedThreadDetail()
            lastSnapshotLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)

            connectionSummary = "Connected to helm"
            noteHealthyRecoveryStateIfNeeded()
        } catch {
            connectionSummary = bridge.lastError ?? "Bridge unavailable"
        }
    }

    func refreshPairing() async {
        do {
            let pairing = try await bridge.fetchPairingStatus()
            if let token = pairing.token, bridge.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bridge.pairingToken = token
            }
            pairingSummary = "Paired with \(pairing.tokenHint)"
        } catch {
            pairingSummary = bridge.pairingToken.isEmpty ? "Pairing token required" : "Pairing token configured"
        }
    }

    func selectThread(_ threadID: String) {
        selectedThreadID = threadID
        UserDefaults.standard.set(threadID, forKey: selectedThreadDefaultsKey)
        scheduleSelectedThreadDetailRefresh()
    }

    func updateScenePhase(_ isActive: Bool) {
        isSceneActive = isActive
        Task { @MainActor in
            await handleScenePhaseTransition(isActive)
        }
    }

    func decideApproval(_ approval: WatchPendingApproval, decision: String) async {
        do {
            let startedAt = Date()
            try await bridge.decideApproval(approval.requestId, decision: decision)
            lastApprovalLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            await refreshAll()
        } catch {
            connectionSummary = bridge.lastError ?? "Approval response failed"
        }
    }

    func sendCommand() async {
        guard let selectedThreadID else {
            connectionSummary = "Select a session first"
            return
        }

        guard selectedThreadSupportsCommand else {
            connectionSummary = selectedThreadCommandSummary ?? "Command is not available for this backend yet"
            return
        }

        let trimmed = commandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionSummary = "Dictate or type a task first"
            return
        }

        commandDraft = ""

        do {
            let startedAt = Date()
            let acknowledgement = try await bridge.sendVoiceCommand(threadID: selectedThreadID, text: trimmed)
            lastCommandLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            connectionSummary = acknowledgement
            await refreshAll()
        } catch {
            connectionSummary = bridge.lastError ?? "Failed to send command"
        }
    }

    func refreshSelectedThreadDetail() async {
        guard let selectedThreadID else { return }

        do {
            let detail = try await bridge.fetchThreadDetail(threadID: selectedThreadID)
            applyThreadDetail(detail, for: selectedThreadID)
        } catch {
            connectionSummary = bridge.lastError ?? "Thread detail unavailable"
        }
    }

    private func processAttentionUpdates(
        previous: [String: WatchRuntimeThread],
        current: [String: WatchRuntimeThread]
    ) {
        guard hasSeededRuntime else {
            hasSeededRuntime = true
            return
        }

        for (threadId, runtime) in current {
            let prior = previous[threadId]
            let threadName = threads.first(where: { $0.id == threadId })?.name ?? "Session"

            if runtime.pendingApprovals.count > (prior?.pendingApprovals.count ?? 0) {
                let detail = runtime.pendingApprovals.first?.detail ?? runtime.pendingApprovals.first?.title
                addAttentionEvent(
                    threadId: threadId,
                    title: "\(threadName) needs approval",
                    detail: detail
                )
                Task {
                    await notifications.post(
                        title: "\(threadName) needs approval",
                        body: detail ?? "Approval is required before work can continue.",
                        threadID: threadId
                    )
                }
                WKInterfaceDevice.current().play(.notification)
                continue
            }

            guard runtime.phase != prior?.phase else { continue }

            switch runtime.phase {
            case "blocked":
                let detail = runtime.detail ?? runtime.title
                addAttentionEvent(
                    threadId: threadId,
                    title: "\(threadName) is blocked",
                    detail: detail
                )
                Task {
                    await notifications.post(
                        title: "\(threadName) is blocked",
                        body: detail ?? "A blocker needs attention.",
                        threadID: threadId
                    )
                }
                WKInterfaceDevice.current().play(.failure)
            case "completed":
                let detail = runtime.detail ?? runtime.title
                addAttentionEvent(
                    threadId: threadId,
                    title: "\(threadName) completed",
                    detail: detail
                )
                Task {
                    await notifications.post(
                        title: "\(threadName) completed",
                        body: detail ?? "Recent work completed.",
                        threadID: threadId
                    )
                }
                WKInterfaceDevice.current().play(.success)
            default:
                break
            }
        }
    }

    private func addAttentionEvent(threadId: String, title: String, detail: String?) {
        attentionEvents.insert(
            WatchAttentionEvent(threadId: threadId, title: title, detail: detail, timestamp: .now),
            at: 0
        )

        if attentionEvents.count > 6 {
            attentionEvents.removeLast(attentionEvents.count - 6)
        }
    }

    private func priorityScore(for threadID: String) -> Int {
        switch runtimeByThreadID[threadID]?.phase {
        case "waitingApproval":
            return 4
        case "blocked":
            return 3
        case "running":
            return 2
        case "completed":
            return 1
        default:
            return 0
        }
    }

    private func connectRealtime() {
        guard !bridge.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if realtimeReconnectAttempt > 0 {
            realtimeReconnectStartedAt = .now
        }
        bridge.connectRealtime(
            onMessage: { [weak self] message in
                self?.bridgeRealtimeConnected = true
                self?.realtimeReconnectTask?.cancel()
                self?.realtimeReconnectAttempt = 0
                self?.handleRealtimeMessage(message)
            },
            onDisconnect: { [weak self] message in
                guard let self else { return }
                self.bridgeRealtimeConnected = false
                self.awaitingRecoveryRefresh = true
                self.connectionSummary = message.map { "Realtime disconnected: \($0)" } ?? "Realtime disconnected"
                self.recoverySummary = "Recovering live connection."
                self.scheduleRealtimeReconnect()
            }
        )
    }

    private func handleRealtimeMessage(_ message: WatchBridgeRealtimeMessage) {
        if let realtimeReconnectStartedAt {
            lastReconnectLatencyMS = Int(Date().timeIntervalSince(realtimeReconnectStartedAt) * 1000)
            self.realtimeReconnectStartedAt = nil
        }

        switch message {
        case .ready(let payload):
            bridgeRealtimeConnected = true
            connectionSummary = payload.message
            if awaitingRecoveryRefresh {
                awaitingRecoveryRefresh = false
                Task { @MainActor in
                    await performPostReconnectRecovery()
                }
            }
        case .runtimeSnapshot(let threads):
            bridgeRealtimeConnected = true
            let previous = runtimeByThreadID
            applyRuntimeSnapshot(threads)
            processAttentionUpdates(previous: previous, current: runtimeByThreadID)
            if selectedThreadID != nil {
                scheduleSelectedThreadDetailRefresh()
            }
        case .runtimeThread(let thread):
            let previousThread = runtimeByThreadID[thread.threadId]
            if previousThread != thread {
                runtimeByThreadID[thread.threadId] = thread
            }
            processAttentionUpdates(
                previous: previousThread.map { [thread.threadId: $0] } ?? [:],
                current: [thread.threadId: thread]
            )
            if thread.threadId == selectedThreadID {
                scheduleSelectedThreadDetailRefresh()
            }
        }
    }

    private func performPostReconnectRecovery() async {
        let startedAt = Date()
        await refreshAll()
        let latencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)

        if connectionSummary == "Bridge unavailable" || connectionSummary == "Thread detail unavailable" {
            recoverySummary = "Live transport returned, but state refresh still needs attention."
            return
        }

        recoverySummary = "Recovered live state in \(latencyMS) ms."
        connectionSummary = "Connected to helm"
        scheduleRecoverySummaryClear()
    }

    private var recoveryNeedsAttention: Bool {
        recoverySummary?.localizedCaseInsensitiveContains("needs attention") == true
    }

    private func noteHealthyRecoveryStateIfNeeded() {
        guard recoverySummary != nil, !awaitingRecoveryRefresh, !recoveryNeedsAttention else {
            return
        }

        scheduleRecoverySummaryClear()
    }

    private func scheduleRecoverySummaryClear(after delay: Duration = .seconds(8)) {
        recoverySummaryClearTask?.cancel()
        guard recoverySummary != nil else { return }

        recoverySummaryClearTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard !self.awaitingRecoveryRefresh, !self.recoveryNeedsAttention else { return }
            self.recoverySummary = nil
        }
    }

    private func scheduleSelectedThreadDetailRefresh(delay: Duration = .milliseconds(150)) {
        detailRefreshTask?.cancel()
        detailRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.refreshSelectedThreadDetail()
        }
    }

    private func scheduleRealtimeReconnect() {
        realtimeReconnectTask?.cancel()
        guard isSceneActive else { return }
        realtimeReconnectAttempt += 1
        let seconds = min(pow(2.0, Double(max(realtimeReconnectAttempt - 1, 0))), 30.0)
        realtimeReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.connectRealtime()
        }
    }

    private func handleScenePhaseTransition(_ isActive: Bool) async {
        guard hasStarted else { return }

        if isActive {
            backgroundSuspendTask?.cancel()
            backgroundSuspendTask = nil
            let shouldRefresh: Bool
            if let lastForegroundRefreshAt {
                shouldRefresh = Date().timeIntervalSince(lastForegroundRefreshAt) > 20
            } else {
                shouldRefresh = true
            }

            lastForegroundRefreshAt = .now

            if !bridgeRealtimeConnected {
                connectRealtime()
            }

            if shouldRefresh {
                await refreshAll()
            }
            return
        }

        scheduleBackgroundSuspend()
    }

    private func scheduleBackgroundSuspend() {
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        detailRefreshTask?.cancel()
        detailRefreshTask = nil
        backgroundSuspendTask?.cancel()
        backgroundSuspendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard !self.isSceneActive else { return }
            self.suspendLiveServices()
        }
    }

    private func suspendLiveServices() {
        backgroundSuspendTask?.cancel()
        backgroundSuspendTask = nil
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        bridge.disconnectRealtime()
        bridgeRealtimeConnected = false
        connectionSummary = "helm paused live updates to preserve battery."
    }

    private func applyThreadsSnapshot(_ fetchedThreads: [WatchRemoteThread]) {
        if threads != fetchedThreads {
            threads = fetchedThreads
        }
        pruneStaleThreadDetails(keeping: Set(fetchedThreads.map(\.id)))
    }

    private func applyRuntimeSnapshot(_ runtimeThreads: [WatchRuntimeThread]) {
        let snapshot = Dictionary(uniqueKeysWithValues: runtimeThreads.map { ($0.threadId, $0) })
        if runtimeByThreadID != snapshot {
            runtimeByThreadID = snapshot
        }
    }

    private func applyThreadDetail(_ detail: WatchRemoteThreadDetail?, for threadID: String) {
        if let detail {
            if threadDetailByID[threadID] != detail {
                threadDetailByID[threadID] = detail
            }
            return
        }

        if threadDetailByID[threadID] != nil {
            threadDetailByID.removeValue(forKey: threadID)
        }
    }

    private func pruneStaleThreadDetails(keeping activeThreadIDs: Set<String>) {
        let staleThreadIDs = threadDetailByID.keys.filter { !activeThreadIDs.contains($0) }
        guard !staleThreadIDs.isEmpty else { return }
        for threadID in staleThreadIDs {
            threadDetailByID.removeValue(forKey: threadID)
        }
    }
}
