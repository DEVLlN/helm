import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI
import UIKit
import UserNotifications

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case day
    case night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .day:
            return "Day"
        case .night:
            return "Night"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .day:
            return .light
        case .night:
            return .dark
        }
    }
}

@MainActor
@Observable
final class SessionStore {
    private static let maxVoiceEntries = 80
    private static let debugStartSectionArgument = "-helm-start-section"
    private static let healthySessionListProjectionMS = 150
    private static let warningSessionListProjectionMS = 300
    private static let healthyThreadDetailMS = 500
    private static let warningThreadDetailMS = 1000
    private static let healthySessionOpenMS = 500
    private static let warningSessionOpenMS = 1200
    private static let healthySnapshotMS = 800
    private static let warningSnapshotMS = 1500
    private static let healthyCommandAckMS = 800
    private static let warningCommandAckMS = 1800
    private static let healthyRealtimeAgeMS = 500
    private static let warningRealtimeAgeMS = 1200
    nonisolated private static let activeSelectedThreadDetailRefreshMS = 900
    nonisolated private static let idleSelectedThreadDetailRefreshMS = 2_500
    private static let pendingOutgoingReconciliationItemScanLimit = 320
    private static let pendingOutgoingLiveTerminalTailCharacterLimit = 12000

    private enum SessionListPlacement {
        case active
        case recent
        case archived
    }

    private struct SessionListProjectionSignature: Equatable {
        let threads: [String]
        let archivedThreads: [String]
        let runtime: [String]
        let dismissedActiveMarkers: [String]
        let archivedThreadIDs: [String]
    }

    private struct SessionListProjection {
        let signature: SessionListProjectionSignature
        let visibleThreads: [RemoteThread]
        let visibleThreadsByActivity: [RemoteThread]
        let activeSessionThreads: [RemoteThread]
        let recentSessionThreads: [RemoteThread]
        let archivedSessionThreads: [RemoteThread]
        let allPendingApprovals: [RemotePendingApproval]
        let priorityThread: RemoteThread?
        let preferredCommandThread: RemoteThread?
    }

    struct PreparedDraft {
        let text: String
        let imageAttachments: [ComposerImageAttachment]
        let fileAttachments: [ComposerFileAttachment]
    }

    private enum CommandMessageKind {
        case acknowledgement
        case status
        case approval
        case completion
        case blocker
        case failure
    }

    private enum CommandIntent {
        case status
        case interrupt
        case approve
        case decline
        case takeControl(force: Bool)
        case releaseControl
        case switchThread(query: String, runtimeTarget: String?)
        case routeCommand(query: String, command: String, runtimeTarget: String?)
        case createThreadNeedsCwd
        case createThread(cwd: String)
        case passthrough
    }

    private enum PendingCommandClarification {
        case selectThreadForCommand(command: String, runtimeTarget: String?)
        case chooseThreadForSwitch(matchIDs: [String])
        case chooseThreadForApproval(decision: String, approvals: [RemotePendingApproval])
        case createThreadCwd
        case confirmTakeOver(threadID: String, command: String, controllerName: String)
    }

    var bridge = BridgeClient()
    var threads: [RemoteThread] = []
    var archivedThreads: [RemoteThread] = []
    var runtimeByThreadID: [String: RemoteRuntimeThread] = [:]
    var threadDetailByID: [String: RemoteThreadDetail] = [:]
    var threadDetailErrorByID: [String: String] = [:]
    var pendingOutgoingTurnsByThreadID: [String: [RemoteThreadTurn]] = [:]
    var selectedThreadID: String?
    var composerSendMode: TurnDeliveryMode
    var draft = ""
    var cwdDraft = ""
    var voiceMode: VoiceRuntimeMode = .localSpeech
    var appAppearanceMode: AppAppearanceMode
    var selectedSection: AppSection = .sessions
    var sessionsNavigationPath = NavigationPath()
    var draftImageAttachments: [ComposerImageAttachment] = []
    var draftFileAttachments: [ComposerFileAttachment] = []
    var availableBackends: [BackendSummary] = []
    var bridgeDefaultBackendID: String?
    var preferredBackendID: String?
    var preferredCodexLaunchMode: SessionLaunchMode
    var availableVoiceProviders: [VoiceProviderSummary] = []
    var bridgeDefaultVoiceProviderID: String?
    var preferredVoiceProviderID: String?
    var voiceProviderBootstrapSummary = "No voice provider bootstrap loaded yet."
    var voiceProviderBootstrapJSON = ""
    var isBusy = false
    var connectionSummary = "Bridge disconnected"
    var recoverySummary: String?
    var voiceEntries: [VoiceTranscriptEntry] = []
    var pairingStatusSummary = "Pairing token required"
    var pairingFilePath: String?
    var pairingSuggestedBridgeURLs: [String] = []
    var pairingSetupURLString: String?
    var notificationsEnabled: Bool
    var spokenStatusEnabled: Bool
    var spokenAlertMode: SpokenAlertMode
    var commandResponseStyle: CommandResponseStyle
    var commandAutoResumeEnabled: Bool
    var sessionAutoCollapseEnabled: Bool
    var notificationAuthorizationSummary = "Unknown"
    var realtimeStatusSummary = "Realtime session not prepared"
    var realtimeBootstrap: RealtimeSessionBootstrap?
    var realtimeCaptureActive = false
    var realtimeCaptureSummary = "Realtime capture idle"
    var realtimeTranscriptPreview = ""
    var realtimeRecentEvents: [RealtimeTranscriptEvent] = []
    var realtimePlaybackRequest: RealtimePlaybackRequest?
    var realtimePlaybackStopToken = UUID()
    var realtimeQueuedSpeechCount = 0
    var liveCommandPhase: LiveCommandPhase = .idle

    private let synthesizer = AVSpeechSynthesizer()
    private let notifications = NotificationCoordinator.shared
    private let selectedThreadDefaultsKey = "helm.selected-thread-id"
    private let voiceModeDefaultsKey = "helm.voice-runtime-mode"
    private let appAppearanceModeDefaultsKey = "helm.app-appearance-mode"
    private let preferredBackendDefaultsKey = "helm.preferred-backend-id"
    private let preferredCodexLaunchModeDefaultsKey = "helm.preferred-codex-launch-mode"
    private let preferredVoiceProviderDefaultsKey = "helm.preferred-voice-provider-id"
    private let notificationsEnabledDefaultsKey = "helm.notifications-enabled"
    private let spokenStatusDefaultsKey = "helm.spoken-status-enabled"
    private let spokenAlertModeDefaultsKey = "helm.spoken-alert-mode"
    private let commandResponseStyleDefaultsKey = "helm.command-response-style"
    private let commandAutoResumeDefaultsKey = "helm.command-auto-resume-enabled"
    private let sessionAutoCollapseDefaultsKey = "helm.session-auto-collapse-enabled"
    private let onboardingDismissedDefaultsKey = "helm.onboarding-dismissed"
    private let dismissedActiveThreadMarkersDefaultsKey = "helm.dismissed-active-thread-markers"
    private let archivedThreadIDsDefaultsKey = "helm.archived-thread-ids"
    private let composerSendModeDefaultsKey = "helm.composer-send-mode"
    private var seenRuntimeEventIDs = Set<String>()
    private var seenApprovalIDs = Set<String>()
    private var heartbeatTask: Task<Void, Never>?
    private var realtimeReconnectTask: Task<Void, Never>?
    private var backgroundSuspendTask: Task<Void, Never>?
    private var recoverySummaryClearTask: Task<Void, Never>?
    private var realtimeBootstrapRefreshTask: Task<Void, Never>?
    private var realtimeReconnectAttempt = 0
    private var realtimeReconnectStartedAt: Date?
    private var detailRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var threadsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var selectedThreadDetailLiveRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var threadDetailRefreshTasksByID: [String: Task<Void, Never>] = [:]
    private var pendingOutgoingTurnRefreshTasksByThreadID: [String: Task<Void, Never>] = [:]
    private var pendingBridgeOpenThreadID: String?
    private var openingThreadIDs = Set<String>()
    private var dismissedActiveThreadMarkers: [String: Double]
    private var archivedThreadIDs: Set<String>
    private var lastRealtimeSubmittedTranscript = ""
    private var lastRealtimeSubmittedAt: Date?
    private var lastVoiceCommandThreadID: String?
    private var lastVoiceCommandAcceptedAt: Date?
    private var openAISpeechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var pendingClarification: PendingCommandClarification?
    private var isSceneActive = true
    private var hasStarted = false
    private var bridgeRealtimeConnected = false
    private var awaitingRecoveryRefresh = false
    private var lastForegroundRefreshAt: Date?
    private var realtimePlaybackQueue: [String] = []
    private var realtimePlaybackActive = false
    @ObservationIgnored private var stableThreadTitlesByID: [String: String] = [:]
    @ObservationIgnored private var sessionListProjectionCache: SessionListProjection?
    private(set) var lastSnapshotLatencyMS: Int?
    private(set) var lastSessionListProjectionLatencyMS: Int?
    private(set) var lastThreadDetailLatencyMS: Int?
    private(set) var lastSessionOpenLatencyMS: Int?
    private(set) var lastCommandLatencyMS: Int?
    private(set) var lastRealtimeMessageAgeMS: Int?
    private(set) var lastApprovalLatencyMS: Int?
    private(set) var lastLaunchReadyLatencyMS: Int?
    private(set) var lastReconnectLatencyMS: Int?
    var onboardingDismissed: Bool

    init() {
        let defaults = UserDefaults.standard
        notificationsEnabled = defaults.object(forKey: notificationsEnabledDefaultsKey) as? Bool ?? true
        spokenStatusEnabled = defaults.object(forKey: spokenStatusDefaultsKey) as? Bool ?? true
        spokenAlertMode =
            defaults.string(forKey: spokenAlertModeDefaultsKey)
                .flatMap(SpokenAlertMode.init(rawValue:)) ?? .backgroundCritical
        commandResponseStyle =
            defaults.string(forKey: commandResponseStyleDefaultsKey)
                .flatMap(CommandResponseStyle.init(rawValue:)) ?? .codex
        commandAutoResumeEnabled = defaults.object(forKey: commandAutoResumeDefaultsKey) as? Bool ?? true
        selectedThreadID = defaults.string(forKey: selectedThreadDefaultsKey)
        composerSendMode =
            defaults.string(forKey: composerSendModeDefaultsKey)
                .flatMap(TurnDeliveryMode.init(rawValue:)) ?? .queue
        voiceMode =
            defaults.string(forKey: voiceModeDefaultsKey)
                .flatMap(VoiceRuntimeMode.init(rawValue:)) ?? .localSpeech
        appAppearanceMode =
            defaults.string(forKey: appAppearanceModeDefaultsKey)
                .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
        sessionAutoCollapseEnabled = defaults.object(forKey: sessionAutoCollapseDefaultsKey) as? Bool ?? false
        preferredBackendID = defaults.string(forKey: preferredBackendDefaultsKey)
        preferredCodexLaunchMode =
            defaults.string(forKey: preferredCodexLaunchModeDefaultsKey)
                .flatMap(SessionLaunchMode.init(rawValue:)) ?? .managedShell
        preferredVoiceProviderID = defaults.string(forKey: preferredVoiceProviderDefaultsKey)
        onboardingDismissed = defaults.object(forKey: onboardingDismissedDefaultsKey) as? Bool ?? false
        dismissedActiveThreadMarkers = defaults.dictionary(forKey: dismissedActiveThreadMarkersDefaultsKey) as? [String: Double] ?? [:]
        archivedThreadIDs = Set(defaults.stringArray(forKey: archivedThreadIDsDefaultsKey) ?? [])
        notifications.onThreadOpened = { [weak self] threadID in
            guard let self else { return }
            self.openSession(threadID)
            self.selectedSection = .sessions
        }
        notifications.onApprovalAction = { [weak self] approvalID, decision, threadID in
            guard let self else { return }
            Task { @MainActor in
                await self.handleApprovalActionFromNotification(
                    approvalID: approvalID,
                    decision: decision,
                    threadID: threadID
                )
            }
        }
    }

    private var sessionListProjection: SessionListProjection {
        let startedAt = Date()
        let signature = makeSessionListProjectionSignature()
        if let cached = sessionListProjectionCache, cached.signature == signature {
            return cached
        }

        let promotedArchivedThreads = archivedThreads.filter(shouldPromoteArchivedThreadToVisible(_:))
        let promotedArchivedThreadIDs = Set(promotedArchivedThreads.map(\.id))
        let visibleThreads = orderedUniqueThreads(threads + promotedArchivedThreads)
            .filter { sessionListPlacement(for: $0) != .archived }
        let visibleThreadsByActivity = visibleThreads.sorted(by: sessionActivityPrecedes(_:_:))
        let activeSessionThreads = visibleThreads
            .filter { sessionListPlacement(for: $0) == .active }
            .sorted(by: sessionAlphabeticalPrecedes(_:_:))
        let recentSessionThreads = visibleThreadsByActivity.filter { sessionListPlacement(for: $0) == .recent }
        let locallyArchivedThreads = threads.filter { sessionListPlacement(for: $0) == .archived }
        let archivedSessionThreads = orderedUniqueThreads(
            archivedThreads.filter { !promotedArchivedThreadIDs.contains($0.id) } + locallyArchivedThreads
        )
            .sorted(by: sessionActivityPrecedes(_:_:))
        let allPendingApprovals = runtimeByThreadID.values
            .flatMap(\.pendingApprovals)
            .sorted { $0.requestedAt > $1.requestedAt }
        let priorityThread = activeSessionThreads.first ?? visibleThreads.sorted(by: priorityThreadPrecedes(_:_:)).first
        let preferredCommandThread = visibleThreads.sorted(by: commandPreferencePrecedes(_:_:)).first

        let projection = SessionListProjection(
            signature: signature,
            visibleThreads: visibleThreads,
            visibleThreadsByActivity: visibleThreadsByActivity,
            activeSessionThreads: activeSessionThreads,
            recentSessionThreads: recentSessionThreads,
            archivedSessionThreads: archivedSessionThreads,
            allPendingApprovals: allPendingApprovals,
            priorityThread: priorityThread,
            preferredCommandThread: preferredCommandThread
        )
        sessionListProjectionCache = projection
        let latencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        lastSessionListProjectionLatencyMS = latencyMS
        Self.logResponsivenessSample(
            title: "Session list projection",
            sampleMS: latencyMS,
            healthyThresholdMS: Self.healthySessionListProjectionMS,
            warningThresholdMS: Self.warningSessionListProjectionMS
        )
        return projection
    }

    private func makeSessionListProjectionSignature() -> SessionListProjectionSignature {
        SessionListProjectionSignature(
            threads: threads.map(Self.threadProjectionSignature(_:)),
            archivedThreads: archivedThreads.map(Self.threadProjectionSignature(_:)),
            runtime: runtimeByThreadID.values
                .sorted { $0.threadId < $1.threadId }
                .map(Self.runtimeProjectionSignature(_:)),
            dismissedActiveMarkers: dismissedActiveThreadMarkers
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" },
            archivedThreadIDs: archivedThreadIDs.sorted()
        )
    }

    private static func threadProjectionSignature(_ thread: RemoteThread) -> String {
        [
            thread.id,
            thread.name ?? "",
            thread.preview,
            thread.cwd,
            thread.workspacePath ?? "",
            thread.status,
            String(thread.updatedAt),
            thread.sourceKind ?? "",
            thread.launchSource ?? "",
            thread.backendId ?? "",
            thread.backendLabel ?? "",
            thread.backendKind ?? "",
            thread.controller?.clientId ?? "",
            thread.controller?.clientName ?? "",
            String(thread.controller?.claimedAt ?? 0),
            String(thread.controller?.lastSeenAt ?? 0),
        ].joined(separator: "\u{001F}")
    }

    private static func runtimeProjectionSignature(_ runtime: RemoteRuntimeThread) -> String {
        let approvals = runtime.pendingApprovals
            .map { "\($0.requestId):\($0.requestedAt):\($0.canRespond):\($0.supportsAcceptForSession)" }
            .joined(separator: "\u{001E}")
        let events = runtime.recentEvents
            .map { "\($0.id):\($0.phase):\($0.createdAt)" }
            .joined(separator: "\u{001E}")
        return [
            runtime.threadId,
            runtime.phase,
            runtime.currentTurnId ?? "",
            runtime.title ?? "",
            runtime.detail ?? "",
            String(runtime.lastUpdatedAt),
            approvals,
            events,
        ].joined(separator: "\u{001F}")
    }

    var selectedThread: RemoteThread? {
        threads.first(where: { $0.id == selectedThreadID })
    }

    var appPreferredColorScheme: ColorScheme? {
        appAppearanceMode.colorScheme
    }

    var visibleThreads: [RemoteThread] {
        sessionListProjection.visibleThreads
    }

    var visibleThreadsByActivity: [RemoteThread] {
        sessionListProjection.visibleThreadsByActivity
    }

    var activeSessionThreads: [RemoteThread] {
        sessionListProjection.activeSessionThreads
    }

    var recentSessionThreads: [RemoteThread] {
        sessionListProjection.recentSessionThreads
    }

    var archivedSessionThreads: [RemoteThread] {
        sessionListProjection.archivedSessionThreads
    }

    var selectedRuntime: RemoteRuntimeThread? {
        guard let selectedThreadID else { return nil }
        return runtimeByThreadID[selectedThreadID]
    }

    var selectedThreadDetail: RemoteThreadDetail? {
        guard let selectedThreadID else { return nil }
        return threadDetail(for: selectedThreadID)
    }

    var selectedApprovals: [RemotePendingApproval] {
        selectedRuntime?.pendingApprovals ?? []
    }

    func thread(for threadID: String) -> RemoteThread? {
        threads.first(where: { $0.id == threadID })
            ?? archivedThreads.first(where: { $0.id == threadID })
    }

    func runtime(for threadID: String) -> RemoteRuntimeThread? {
        runtimeByThreadID[threadID]
    }

    func threadDetail(for threadID: String) -> RemoteThreadDetail? {
        let pendingTurns = pendingOutgoingTurnsByThreadID[threadID] ?? []
        if let detail = threadDetailByID[threadID] {
            guard !pendingTurns.isEmpty else { return detail }
            return mergedThreadDetail(detail, appending: pendingTurnsForDisplay(pendingTurns, against: detail))
        }

        guard !pendingTurns.isEmpty, let thread = thread(for: threadID) else {
            return nil
        }

        return RemoteThreadDetail(
            id: thread.id,
            name: thread.name,
            cwd: thread.cwd,
            workspacePath: thread.workspacePath,
            status: "running",
            updatedAt: pendingTurns.last.map(latestTimestamp(from:)) ?? thread.updatedAt,
            sourceKind: thread.sourceKind,
            launchSource: thread.launchSource,
            backendId: thread.backendId,
            backendLabel: thread.backendLabel,
            backendKind: thread.backendKind,
            command: nil,
            affordances: nil,
            turns: pendingTurns
        )
    }

    func threadApprovals(for threadID: String) -> [RemotePendingApproval] {
        runtime(for: threadID)?.pendingApprovals ?? []
    }

    func threadDetailError(for threadID: String) -> String? {
        threadDetailErrorByID[threadID]
    }

    func displayTitle(for threadID: String) -> String {
        if let title = stableThreadTitle(for: threadID) {
            return title
        }

        if let thread = thread(for: threadID) {
            let workspace = stableThreadWorkspace(for: thread)
            if !workspace.isEmpty {
                return "\(displayPathComponent(for: workspace)) · \(shortThreadID(threadID))"
            }
        }

        if let detail = threadDetail(for: threadID) {
            let workspace = stableDetailWorkspace(for: detail)
            if !workspace.isEmpty {
                return "\(displayPathComponent(for: workspace)) · \(shortThreadID(threadID))"
            }
        }

        return "Session \(shortThreadID(threadID))"
    }

    var allPendingApprovals: [RemotePendingApproval] {
        sessionListProjection.allPendingApprovals
    }

    var selectedEvents: [RemoteRuntimeEvent] {
        selectedRuntime?.recentEvents ?? []
    }

    var priorityThread: RemoteThread? {
        sessionListProjection.priorityThread
    }

    var priorityRuntime: RemoteRuntimeThread? {
        guard let priorityThread else { return nil }
        return runtimeByThreadID[priorityThread.id]
    }

    var priorityPhase: String? {
        priorityRuntime?.phase
    }

    var preferredCommandThread: RemoteThread? {
        sessionListProjection.preferredCommandThread
    }

    var commandTargetThread: RemoteThread? {
        selectedThread ?? preferredCommandThread
    }

    var commandTargetRuntime: RemoteRuntimeThread? {
        guard let thread = commandTargetThread else { return nil }
        return runtimeByThreadID[thread.id]
    }

    var commandTargetDetail: RemoteThreadDetail? {
        guard let thread = commandTargetThread else { return nil }
        return threadDetailByID[thread.id]
    }

    var commandTargetBackendSummary: BackendSummary? {
        if let backendID = commandTargetDetail?.backendId ?? commandTargetThread?.backendId {
            return availableBackends.first(where: { $0.id == backendID })
        }

        return effectiveCreateBackend
    }

    var commandTargetApprovals: [RemotePendingApproval] {
        commandTargetRuntime?.pendingApprovals ?? []
    }

    var commandTargetSupportsVoiceCommand: Bool {
        commandTargetBackendSummary?.capabilities.voiceCommand ?? true
    }

    var commandTargetSupportsRealtimeCommand: Bool {
        if let affordances = commandTargetDetail?.affordances {
            return affordances.canUseRealtimeCommand
        }

        guard let backend = commandTargetBackendSummary else {
            return true
        }

        return backend.capabilities.voiceCommand && backend.capabilities.realtimeVoice
    }

    var commandTargetCanInterrupt: Bool {
        commandTargetDetail?.affordances?.canInterrupt ?? true
    }

    var commandTargetCanRespondToApprovals: Bool {
        commandTargetDetail?.affordances?.canRespondToApprovals ?? true
    }

    var commandTargetBackendNote: String? {
        commandTargetDetail?.affordances?.notes
            ?? commandTargetDetail?.command?.notes
            ?? commandTargetBackendSummary?.command.notes
    }

    var commandTargetRealtimeSummary: String {
        let backendLabel = commandTargetDetail?.backendLabel
            ?? commandTargetThread?.backendLabel
            ?? commandTargetBackendSummary?.label
            ?? "this backend"

        guard voiceProviderSupportsCurrentLiveCommandTransport else {
            if let provider = effectiveVoiceProvider, provider.supportsNativeBootstrap == true {
                return "\(provider.label) has a native helm bridge path, but iPhone Live Command does not drive that transport yet."
            }

            let providerLabel = effectiveVoiceProvider?.label ?? "The selected voice provider"
            return "\(providerLabel) is not compatible with the current iPhone Live Command transport."
        }

        if effectiveVoiceProvider?.id == "personaplex" {
            return "Live Command uses PersonaPlex through helm’s native bridge proxy for spoken input on iPhone."
        }

        if commandTargetSupportsRealtimeCommand {
            return "Live Command is available for \(backendLabel)."
        }

        return "Live Command is not available for \(backendLabel) yet. Use local Command instead."
    }

    var commandTargetSummary: String {
        guard let thread = commandTargetThread else {
            return "Select or create a session so I can work in the right thread."
        }

        let threadName = thread.name ?? "Selected Session"

        if let approval = commandTargetApprovals.first {
            if let detail = approval.detail {
                return "\(threadName) is waiting on approval. \(detail)"
            }
            return "\(threadName) is waiting on approval."
        }

        if let runtime = commandTargetRuntime {
            switch runtime.phase {
            case "running":
                if let title = runtime.title {
                    return "I’m working in \(threadName). \(title)."
                }
                return "I’m working in \(threadName)."
            case "blocked":
                if let detail = runtime.detail {
                    return "\(threadName) is blocked. \(detail)"
                }
                return "\(threadName) is blocked."
            case "completed":
                if let detail = runtime.detail {
                    return "\(threadName) completed recent work. \(detail)"
                }
                return "\(threadName) completed recent work."
            default:
                break
            }
        }

        return "\(threadName) is ready for the next Command."
    }

    var commandTargetControllerSummary: String {
        guard let thread = commandTargetThread else {
            return "No Command target selected."
        }

        guard let controller = thread.controller else {
            return "Available. No client currently controls this thread."
        }

        if controller.clientId == bridge.identity.id {
            return "Controlling from this iPhone."
        }

        return "Observing only. Controlled by \(controller.clientName)."
    }

    var needsSetupAttention: Bool {
        if !bridge.hasPairingToken {
            return true
        }

        if !threads.isEmpty {
            return false
        }

        return connectionSummary == "Bridge disconnected"
            || connectionSummary == "Bridge unavailable"
            || connectionSummary == "Bridge needs pairing"
    }

    var setupAttentionTitle: String {
        if !bridge.hasPairingToken {
            return "Pair helm with the bridge"
        }

        return "Reconnect helm to the bridge"
    }

    var setupAttentionDetail: String {
        if !bridge.hasPairingToken {
            return "Open Settings, scan the pairing QR from your Mac, or import the setup link. Manual bridge details are available in advanced pairing if you need them."
        }

        return "Make sure the bridge is running, confirm the bridge URL, and refresh the live session state from helm"
    }

    var liveCommandBannerVisible: Bool {
        guard voiceMode == .openAIRealtime else { return false }
        if realtimeCaptureActive || realtimePlaybackRequest != nil || !realtimeTranscriptPreview.isEmpty {
            return true
        }

        let summary = realtimeCaptureSummary.lowercased()
        if summary.contains("listening") || summary.contains("connecting") || summary.contains("speaking") || summary.contains("sending") {
            return true
        }

        return false
    }

    var liveCommandBannerTitle: String {
        let sessionName = commandTargetThread?.name ?? "No Session"

        if realtimeCaptureActive {
            return "\(liveCommandPhase.title) • \(sessionName)"
        }

        return "Command • \(sessionName)"
    }

    var effectiveCreateBackend: BackendSummary? {
        if let preferredBackendID,
           let backend = availableBackends.first(where: { $0.id == preferredBackendID && $0.available }) {
            return backend
        }

        if let bridgeDefaultBackendID,
           let backend = availableBackends.first(where: { $0.id == bridgeDefaultBackendID && $0.available }) {
            return backend
        }

        return availableBackends.first(where: \.available)
    }

    var preferredBackendSummary: String {
        guard let backend = effectiveCreateBackend else {
            return "No backend metadata available yet."
        }

        return "\(backend.label) is selected for new sessions."
    }

    func defaultNewSessionDraft(backendID: String? = nil) -> NewSessionDraft {
        let resolvedBackendID = backendID ?? effectiveCreateBackend?.id
        let defaultDirectory =
            cwdDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (selectedThread?.cwd ?? priorityThread?.cwd ?? "")
                : cwdDraft
        let defaultLaunchMode: SessionLaunchMode =
            resolvedBackendID == "codex" ? preferredCodexLaunchMode : .managedShell

        return NewSessionDraft(
            backendId: resolvedBackendID,
            model: "",
            workingDirectory: defaultDirectory,
            reasoningEffort: nil,
            codexFastMode: nil,
            claudeContextMode: .normal,
            launchMode: defaultLaunchMode
        )
    }

    func isThreadArchived(_ threadID: String) -> Bool {
        archivedThreadIDs.contains(threadID)
    }

    var effectiveVoiceProvider: VoiceProviderSummary? {
        if let preferredVoiceProviderID,
           let provider = availableVoiceProviders.first(where: { $0.id == preferredVoiceProviderID && $0.available }) {
            return provider
        }

        if let bridgeDefaultVoiceProviderID,
           let provider = availableVoiceProviders.first(where: { $0.id == bridgeDefaultVoiceProviderID && $0.available }) {
            return provider
        }

        return availableVoiceProviders.first(where: \.available)
    }

    var preferredVoiceProviderSummary: String {
        guard let provider = effectiveVoiceProvider else {
            return "No voice provider metadata available yet."
        }

        if !provider.supportsRealtimeSessions || !provider.supportsClientSecrets {
            if provider.id == "personaplex", provider.supportsNativeBootstrap == true {
                return "\(provider.label) is selected for the iPhone prototype live-input path through helm’s native bridge proxy."
            }

            if provider.supportsNativeBootstrap == true {
                return "\(provider.label) is available through helm’s native bridge path, but the iPhone client does not drive that transport yet."
            }

            return "\(provider.label) is selected, but it does not expose the current iPhone Live Command transport."
        }

        return "\(provider.label) is selected for Live Command speech and Realtime."
    }

    var voiceProviderSupportsCurrentLiveCommandTransport: Bool {
        guard let provider = effectiveVoiceProvider else {
            return false
        }

        if provider.supportsRealtimeSessions && provider.supportsClientSecrets {
            return true
        }

        return provider.id == "personaplex" && provider.supportsNativeBootstrap == true
    }

    var liveCommandBannerDetail: String {
        if !realtimeTranscriptPreview.isEmpty {
            return realtimeTranscriptPreview
        }

        return realtimeCaptureSummary
    }

    var liveCommandPhaseSummary: String {
        switch liveCommandPhase {
        case .idle:
            return "Live Command is idle."
        case .preparing:
            return "Preparing the live Command session."
        case .listening:
            return "Listening for the next spoken Command."
        case .dispatching:
            return "Sending the latest spoken Command to Codex."
        case .responding:
            return "Speaking back with a compact Command response."
        case .retargeting:
            return "Switching Live Command to the new shared session."
        case .failed:
            return "Live Command needs attention before it can continue cleanly."
        }
    }

    var diagnosticsSummary: String {
        var parts: [String] = []

        if let lastLaunchReadyLatencyMS {
            parts.append("Launch \(lastLaunchReadyLatencyMS) ms")
        }

        if let lastSnapshotLatencyMS {
            parts.append("Snapshot \(lastSnapshotLatencyMS) ms")
        }

        if let lastSessionListProjectionLatencyMS {
            parts.append("Session list \(lastSessionListProjectionLatencyMS) ms")
        }

        if let lastThreadDetailLatencyMS {
            parts.append("Detail \(lastThreadDetailLatencyMS) ms")
        }

        if let lastSessionOpenLatencyMS {
            parts.append("Open \(lastSessionOpenLatencyMS) ms")
        }

        if let lastCommandLatencyMS {
            parts.append("Command ack \(lastCommandLatencyMS) ms")
        }

        if let lastRealtimeMessageAgeMS {
            parts.append("Realtime age \(lastRealtimeMessageAgeMS) ms")
        }

        if let lastApprovalLatencyMS {
            parts.append("Approval \(lastApprovalLatencyMS) ms")
        }

        if let lastReconnectLatencyMS {
            parts.append("Reconnect \(lastReconnectLatencyMS) ms")
        }

        if realtimeReconnectAttempt > 0 {
            parts.append("Reconnect x\(realtimeReconnectAttempt)")
        }

        return parts.isEmpty ? "No latency samples captured yet." : parts.joined(separator: " • ")
    }

    var diagnosticsMetrics: [ResponsivenessBudgetMetric] {
        [
            ResponsivenessBudgetMetric(id: "launch", title: "Launch", sampleMS: lastLaunchReadyLatencyMS, healthyThresholdMS: 1200, warningThresholdMS: 2500),
            ResponsivenessBudgetMetric(id: "snapshot", title: "Snapshot", sampleMS: lastSnapshotLatencyMS, healthyThresholdMS: Self.healthySnapshotMS, warningThresholdMS: Self.warningSnapshotMS),
            ResponsivenessBudgetMetric(id: "session-list", title: "Session List", sampleMS: lastSessionListProjectionLatencyMS, healthyThresholdMS: Self.healthySessionListProjectionMS, warningThresholdMS: Self.warningSessionListProjectionMS),
            ResponsivenessBudgetMetric(id: "thread-detail", title: "Detail", sampleMS: lastThreadDetailLatencyMS, healthyThresholdMS: Self.healthyThreadDetailMS, warningThresholdMS: Self.warningThreadDetailMS),
            ResponsivenessBudgetMetric(id: "session-open", title: "Open", sampleMS: lastSessionOpenLatencyMS, healthyThresholdMS: Self.healthySessionOpenMS, warningThresholdMS: Self.warningSessionOpenMS),
            ResponsivenessBudgetMetric(id: "command", title: "Command Ack", sampleMS: lastCommandLatencyMS, healthyThresholdMS: Self.healthyCommandAckMS, warningThresholdMS: Self.warningCommandAckMS),
            ResponsivenessBudgetMetric(id: "realtime-age", title: "Realtime Age", sampleMS: lastRealtimeMessageAgeMS, healthyThresholdMS: Self.healthyRealtimeAgeMS, warningThresholdMS: Self.warningRealtimeAgeMS),
            ResponsivenessBudgetMetric(id: "approval", title: "Approval", sampleMS: lastApprovalLatencyMS, healthyThresholdMS: 1200, warningThresholdMS: 2500),
            ResponsivenessBudgetMetric(id: "reconnect", title: "Reconnect", sampleMS: lastReconnectLatencyMS, healthyThresholdMS: 1500, warningThresholdMS: 3200)
        ]
    }

    var diagnosticsHealthStatus: ResponsivenessBudgetStatus {
        if awaitingRecoveryRefresh || recoveryNeedsAttention {
            return .critical
        }

        return diagnosticsMetrics
            .map(\.status)
            .max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
    }

    var diagnosticsHealthSummary: String {
        if recoveryNeedsAttention {
            return "Live transport came back, but helm still needs a clean runtime refresh."
        }

        if awaitingRecoveryRefresh {
            return "helm is actively recovering the live connection and refreshing shared state."
        }

        switch diagnosticsHealthStatus {
        case .unknown:
            return "helm is collecting launch, snapshot, approval, and reconnect samples."
        case .healthy:
            return "Current latency samples are within helm’s first-pass responsiveness budgets."
        case .warning:
            return "helm is usable, but at least one primary path is slower than the current target."
        case .critical:
            return "One or more primary paths are outside target budgets."
        }
    }

    var setupChecklistItems: [SetupChecklistItem] {
        [
            SetupChecklistItem(
                id: "bridge-url",
                title: "Bridge URL",
                detail: bridge.baseURL.absoluteString,
                isComplete: !bridge.baseURL.absoluteString.isEmpty
            ),
            SetupChecklistItem(
                id: "pairing",
                title: "Pairing token",
                detail: bridge.hasPairingToken
                    ? "helm can authenticate with the bridge."
                    : "Read local pairing or paste the token from the bridge host.",
                isComplete: bridge.hasPairingToken
            ),
            SetupChecklistItem(
                id: "notifications",
                title: "Notifications",
                detail: notificationAuthorizationSummary,
                isComplete: notificationsEnabled && notificationAuthorizationSummary == "Enabled"
            ),
            SetupChecklistItem(
                id: "backend",
                title: "Backend metadata",
                detail: effectiveCreateBackend?.label ?? "Waiting for bridge backend metadata.",
                isComplete: effectiveCreateBackend != nil
            ),
            SetupChecklistItem(
                id: "voice-provider",
                title: "Voice provider metadata",
                detail: effectiveVoiceProvider?.label ?? "Waiting for bridge voice provider metadata.",
                isComplete: effectiveVoiceProvider != nil
            )
        ]
    }

    var setupCompletionSummary: String {
        let completedCount = setupChecklistItems.filter(\.isComplete).count
        return "\(completedCount) of \(setupChecklistItems.count) setup checks are ready."
    }

    var shouldShowOnboarding: Bool {
        !onboardingDismissed
    }

    var shouldShowFirstRunPairingScanner: Bool {
        Self.shouldShowFirstRunPairingScanner(hasPairingToken: bridge.hasPairingToken)
    }

    nonisolated static func shouldShowFirstRunPairingScanner(hasPairingToken: Bool) -> Bool {
        !hasPairingToken
    }

    var onboardingHighlights: [String] {
        [
            "helm attaches to the same shared session state as the CLI.",
            "Pair this iPhone to the local bridge once, then keep approvals and Command on the same live session.",
            "Use Settings for bridge URL, pairing, backend defaults, and Command behavior."
        ]
    }

    var isControllingSelectedThread: Bool {
        guard let selectedThread else { return false }
        return selectedThread.controller?.clientId == bridge.identity.id
    }

    var selectedThreadControllerSummary: String {
        guard let selectedThread else {
            return "Select a session to inspect controller state."
        }

        guard let controller = selectedThread.controller else {
            if selectedThreadDetail?.isHelmManaged ?? selectedThread.isHelmManaged {
                return "Available. This session was launched through helm integration and can be resumed from the CLI or another helm client."
            }
            if let sourceKind = selectedThread.sourceKind, sourceKind == "cli" {
                return "Available. This thread originated in the CLI and can be attached from helm"
            }
            return "Available. No client currently controls this thread."
        }

        if controller.clientId == bridge.identity.id {
            return "Controlling from this iPhone."
        }

        return "Observing only. Controlled by \(controller.clientName)."
    }

    func threadControllerSummary(for threadID: String) -> String {
        guard let thread = thread(for: threadID) else {
            return "Select a session to inspect controller state."
        }

        let detail = threadDetail(for: threadID)

        guard let controller = thread.controller else {
            if detail?.isHelmManaged ?? thread.isHelmManaged {
                return "Available. This session was launched through helm integration and can be resumed from the CLI or another helm client."
            }
            if let sourceKind = thread.sourceKind, sourceKind == "cli" {
                return "Available. This thread originated in the CLI and can be attached from helm"
            }
            return "Available. No client currently controls this thread."
        }

        if controller.clientId == bridge.identity.id {
            return "Controlling from this iPhone."
        }

        return "Observing only. Controlled by \(controller.clientName)."
    }

    var selectedThreadHandoffSummary: String {
        guard let selectedThread else {
            return "helm, the CLI, Apple Watch, macOS, and CarPlay all attach to the same shared session state."
        }

        let backendLabel = selectedThread.backendLabel ?? "the selected backend"

        if let controller = selectedThread.controller {
            if controller.clientId == bridge.identity.id {
                return "This iPhone currently has control. Other helm surfaces and the CLI can still observe this thread and resume it later."
            }

            return "\(controller.clientName) is currently driving this shared \(backendLabel) thread. You can keep observing here or take control if you need to continue on iPhone."
        }

        if selectedThreadDetail?.isHelmManaged ?? selectedThread.isHelmManaged {
            return "This session was launched through helm integration. You can stay in the CLI, attach here from iPhone, then resume it later from either side."
        }

        switch selectedThread.sourceKind {
        case "cli":
            return "This thread started in the CLI. You can attach from helm without closing the terminal, then hand it back later."
        case "vscode", "claude-desktop":
            return "This thread started from another desktop surface. helm can continue the same work here without breaking continuity."
        default:
            return "This shared \(backendLabel) thread is idle. You can continue it from iPhone, Mac, Apple Watch, CarPlay, or the CLI."
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let startStartedAt = Date()
        HelmLogger.bridge.info("Starting SessionStore")
        heartbeatTask?.cancel()
        realtimeReconnectTask?.cancel()
        backgroundSuspendTask?.cancel()
        await refreshPairingStatus()
        async let backends: Void = refreshBackends()
        async let voiceProviders: Void = refreshVoiceProviders()
        await refreshSessionSnapshot(includeSelectedThreadDetail: false)
        _ = await (backends, voiceProviders)
        lastForegroundRefreshAt = .now

        if isSceneActive {
            startHeartbeatLoop()
            connectRealtime()
            restartSelectedThreadDetailLiveRefreshLoop()
        }
        applyDebugLaunchSectionOverride()
        lastLaunchReadyLatencyMS = Int(Date().timeIntervalSince(startStartedAt) * 1000)
        HelmLogger.bridge.info("SessionStore ready in \(self.lastLaunchReadyLatencyMS ?? 0)ms")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshNotificationAuthorization()

            if self.notificationsEnabled {
                let granted = await self.notifications.requestAuthorizationIfNeeded()
                self.notificationAuthorizationSummary = granted ? "Enabled" : await self.notifications.authorizationDescription()
            }
        }
    }

    private func applyDebugLaunchSectionOverride() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: Self.debugStartSectionArgument),
              flagIndex + 1 < arguments.count
        else {
            return
        }

        switch arguments[flagIndex + 1].lowercased() {
        case "sessions":
            selectedSection = .sessions
        case "command":
            selectedSection = .command
            if selectedThreadID == nil {
                if let preferredCommandThread {
                    focusCommandThread(preferredCommandThread.id)
                }
            }
        case "settings":
            selectedSection = .settings
        default:
            break
        }
#endif
    }

    func selectThread(_ id: String, allowBridgeOpen: Bool = false) {
        handleCommandTargetChange(from: selectedThreadID, to: id)
        selectedThreadID = id
        selectedSection = .sessions
        UserDefaults.standard.set(id, forKey: selectedThreadDefaultsKey)
        pendingBridgeOpenThreadID = allowBridgeOpen ? id : nil
        scheduleSelectedThreadDetailRefresh(allowBridgeOpen: allowBridgeOpen)
        restartSelectedThreadDetailLiveRefreshLoop()
    }

    func openSession(_ id: String) {
        restoreSessionToDefaultPlacement(id)
        unarchiveThreadLocally(id)
        selectThread(id, allowBridgeOpen: true)
    }

    func isOpeningThread(_ threadID: String) -> Bool {
        openingThreadIDs.contains(threadID)
    }

    func hasPendingBridgeOpen(threadID: String) -> Bool {
        pendingBridgeOpenThreadID == threadID
    }

    func selectPriorityThreadIfAvailable() {
        guard let priorityThread else { return }
        openSession(priorityThread.id)
    }

    func focusCommandThread(_ id: String) {
        handleCommandTargetChange(from: selectedThreadID, to: id)
        selectedThreadID = id
        UserDefaults.standard.set(id, forKey: selectedThreadDefaultsKey)
        scheduleSelectedThreadDetailRefresh()
        restartSelectedThreadDetailLiveRefreshLoop()
    }

    func prepareCommandSurface() async {
        if selectedThreadID == nil {
            if let preferredCommandThread {
                focusCommandThread(preferredCommandThread.id)
            }
        }

        if voiceMode == .openAIRealtime,
           (realtimeBootstrap == nil || !realtimeBootstrapMatchesCommandTarget) {
            await prepareRealtimeSession()
        }
    }

    func refreshThreads() async {
        if let task = threadsRefreshTask {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performThreadsRefresh()
        }
        threadsRefreshTask = task
        await task.value
        threadsRefreshTask = nil
    }

    private func performThreadsRefresh() async {
        isBusy = true
        let interval = HelmLogger.sessionsSignposter.beginInterval("RefreshThreads")
        defer { isBusy = false }
        defer { HelmLogger.sessionsSignposter.endInterval("RefreshThreads", interval) }

        do {
            async let archivedThreadsResult = fetchArchivedThreadsResult()
            let fetchedThreads = try await bridge.fetchThreads()
            applyArchivedThreadsSnapshot(await archivedThreadsResult)
            applyFetchedThreads(fetchedThreads)
        } catch {
            HelmLogger.bridge.error("Thread refresh failed: \(self.logSummary(for: error))")
            if await recoverBridgeConnectionUsingStoredCandidates() {
                do {
                    async let archivedThreadsResult = fetchArchivedThreadsResult()
                    let fetchedThreads = try await bridge.fetchThreads()
                    applyArchivedThreadsSnapshot(await archivedThreadsResult)
                    applyFetchedThreads(fetchedThreads)
                    return
                } catch {
                    HelmLogger.bridge.error("Thread refresh failed after bridge URL recovery: \(self.logSummary(for: error))")
                }
            }
            connectionSummary = bridge.hasPairingToken ? "Bridge unavailable" : "Bridge needs pairing"
        }
    }

    private func fetchArchivedThreadsResult() async -> Result<[RemoteThread], Error> {
        do {
            return .success(try await bridge.fetchArchivedThreads())
        } catch {
            return .failure(error)
        }
    }

    private func applyArchivedThreadsSnapshot(_ result: Result<[RemoteThread], Error>) {
        switch result {
        case .success(let fetchedArchivedThreads):
            applyArchivedThreadsSnapshot(fetchedArchivedThreads)
        case .failure(let error):
            HelmLogger.bridge.error("Archived thread refresh failed: \(self.logSummary(for: error))")
        }
    }

    private func applyFetchedThreads(_ fetchedThreads: [RemoteThread]) {
        HelmLogger.sessions.info("Fetched \(fetchedThreads.count) threads")
        applyThreadsSnapshot(fetchedThreads)
        let visibleThreadIDs = Set(visibleThreads.map(\.id))
        let preservedThreadIDs =
            Set(threads.map(\.id))
            .union(archivedThreads.map(\.id))
            .union(threadDetailByID.keys)
            .union(runtimeByThreadID.keys)
            .union(pendingOutgoingTurnsByThreadID.compactMap { key, turns in
                turns.isEmpty ? nil : key
            })

        let persistedSelection = UserDefaults.standard.string(forKey: selectedThreadDefaultsKey)
        selectedThreadID = Self.selectedThreadIDAfterFetch(
            current: selectedThreadID,
            persisted: persistedSelection,
            visibleThreadIDs: visibleThreadIDs,
            preservedThreadIDs: preservedThreadIDs,
            preferred: preferredCommandThread?.id
        )

        if let selectedThreadID {
            UserDefaults.standard.set(selectedThreadID, forKey: selectedThreadDefaultsKey)
        }

        if connectionSummary == "Bridge disconnected" || connectionSummary == "Bridge unavailable" {
            connectionSummary = "Connected to bridge"
        }
    }

    private func recoverBridgeConnectionUsingStoredCandidates() async -> Bool {
        guard await bridge.useReachableCandidateBridgeURL() else {
            return false
        }

        pairingStatusSummary = "Recovered bridge URL"
        connectionSummary = "Connected to bridge"
        await refreshPairingStatus()
        return true
    }

    private func performBridgeRequestWithRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard await recoverBridgeConnectionUsingStoredCandidates() else {
                throw error
            }
            return try await operation()
        }
    }

    func refreshRuntime() async {
        if let task = runtimeRefreshTask {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeRefresh()
        }
        runtimeRefreshTask = task
        await task.value
        runtimeRefreshTask = nil
    }

    private func performRuntimeRefresh() async {
        let interval = HelmLogger.sessionsSignposter.beginInterval("RefreshRuntime")
        defer { HelmLogger.sessionsSignposter.endInterval("RefreshRuntime", interval) }

        do {
            let threads = try await performBridgeRequestWithRecovery {
                try await bridge.fetchRuntime()
            }
            applyRuntimeSnapshot(threads)
        } catch {
            if connectionSummary != "Bridge unavailable" {
                connectionSummary = "Runtime unavailable"
            }
        }
    }

    func refreshSelectedThreadDetail(allowBridgeOpen: Bool = false, force: Bool = false) async {
        guard let selectedThreadID else { return }
        if allowBridgeOpen,
           pendingBridgeOpenThreadID == selectedThreadID {
            pendingBridgeOpenThreadID = nil
            if !openingThreadIDs.contains(selectedThreadID),
               shouldOpenThreadViaBridge(threadID: selectedThreadID) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.openThread(threadID: selectedThreadID)
                }
                return
            }
        }
        if force || threadDetailByID[selectedThreadID] == nil || threadDetailErrorByID[selectedThreadID] != nil {
            await refreshThreadDetail(threadID: selectedThreadID)
        }
    }

    func refreshThreadDetail(threadID: String) async {
        if let task = threadDetailRefreshTasksByID[threadID] {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performThreadDetailRefresh(threadID: threadID)
        }
        threadDetailRefreshTasksByID[threadID] = task
        await task.value
        threadDetailRefreshTasksByID.removeValue(forKey: threadID)
    }

    private func performThreadDetailRefresh(threadID: String) async {
        let startedAt = Date()
        do {
            let detail = try await performBridgeRequestWithRecovery {
                try await bridge.fetchThreadDetail(threadID: threadID)
            }
            let latencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastThreadDetailLatencyMS = latencyMS
            Self.logResponsivenessSample(
                title: "Thread detail fetch",
                sampleMS: latencyMS,
                healthyThresholdMS: Self.healthyThreadDetailMS,
                warningThresholdMS: Self.warningThreadDetailMS
            )
            let canonicalThreadID = detail?.id ?? threadID
            if canonicalThreadID != threadID {
                adoptThreadReplacement(from: threadID, to: canonicalThreadID)
            }
            reconcilePendingOutgoingTurns(for: canonicalThreadID, against: detail)
            threadDetailErrorByID.removeValue(forKey: canonicalThreadID)
            applyThreadDetail(detail, for: canonicalThreadID)
        } catch {
            threadDetailErrorByID[threadID] = "Session detail unavailable. Pull to refresh."
            if selectedThreadID == threadID {
                connectionSummary = "Thread detail unavailable"
            }
        }
    }

    func openThread(threadID: String) async {
        let startedAt = Date()
        guard openingThreadIDs.insert(threadID).inserted else { return }
        defer {
            openingThreadIDs.remove(threadID)
            if pendingBridgeOpenThreadID == threadID {
                pendingBridgeOpenThreadID = nil
            }
        }

        do {
            let opened = try await performBridgeRequestWithRecovery {
                try await bridge.openThread(threadID: threadID)
            }
            let canonicalThreadID = opened.threadId
            if canonicalThreadID != threadID {
                adoptThreadReplacement(from: threadID, to: canonicalThreadID)
            }

            let detail = opened.thread
            if let detail {
                reconcilePendingOutgoingTurns(for: canonicalThreadID, against: detail)
                threadDetailErrorByID.removeValue(forKey: canonicalThreadID)
                applyThreadDetail(detail, for: canonicalThreadID)
            } else if threadDetailByID[canonicalThreadID] == nil {
                await refreshThreadDetail(threadID: canonicalThreadID)
            }
            if opened.replaced || opened.launched {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await self.refreshThreads() }
                        group.addTask { await self.refreshRuntime() }
                    }
                }
            }
            let latencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastSessionOpenLatencyMS = latencyMS
            Self.logResponsivenessSample(
                title: "Session open",
                sampleMS: latencyMS,
                healthyThresholdMS: Self.healthySessionOpenMS,
                warningThresholdMS: Self.warningSessionOpenMS
            )
        } catch {
            threadDetailErrorByID[threadID] = "Session open unavailable. Pull to refresh."
            if selectedThreadID == threadID {
                connectionSummary = userFacingMessage(for: error, fallback: "Failed to open session")
            }
        }
    }

    private func shouldOpenThreadViaBridge(threadID: String) -> Bool {
        if sessionAccess(for: threadID) == "helmManagedShell" {
            return false
        }

        guard let thread = thread(for: threadID) else {
            return true
        }

        guard !thread.isHelmManaged else {
            return false
        }

        switch thread.backendId {
        case "codex", "claude-code":
            return true
        default:
            return false
        }
    }

    func createThread() async {
        let draft = defaultNewSessionDraft()
        guard !draft.normalizedWorkingDirectory.isEmpty else { return }
        _ = await createThread(draft: draft)
    }

    func moveSessionToRecent(_ threadID: String) {
        moveSessionsToRecent([threadID])
    }

    func moveSessionsToRecent(_ threadIDs: [String]) {
        var changed = false

        for threadID in orderedUniqueThreadIDs(threadIDs) {
            guard let thread = thread(for: threadID) else { continue }
            guard sessionListPlacement(for: thread) == .active else { continue }

            dismissedActiveThreadMarkers[threadID] = activityMarker(for: thread)
            changed = true
        }

        guard changed else { return }
        persistDismissedActiveThreadMarkers()
    }

    private func orderedUniqueThreadIDs(_ threadIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return threadIDs.filter { threadID in
            seen.insert(threadID).inserted
        }
    }

    private func orderedUniqueThreads(_ threads: [RemoteThread]) -> [RemoteThread] {
        var seen: Set<String> = []
        return threads.filter { thread in
            seen.insert(thread.id).inserted
        }
    }

    func createThread(at cwd: String) async {
        var draft = defaultNewSessionDraft()
        draft.workingDirectory = cwd
        _ = await createThread(draft: draft)
    }

    @discardableResult
    func createThread(draft: NewSessionDraft) async -> String? {
        let trimmed = draft.normalizedWorkingDirectory
        guard !trimmed.isEmpty else { return nil }

        var request = draft
        request.workingDirectory = trimmed

        do {
            HelmLogger.sessions.info("Creating thread")
            let response = try await bridge.createThread(draft: request)
            let canonicalThreadID = response.thread?.id ?? response.threadId
            await refreshSessionSnapshot()
            cwdDraft = trimmed
            if request.backendId == "codex" {
                preferredCodexLaunchMode = request.launchMode
                UserDefaults.standard.set(request.launchMode.rawValue, forKey: preferredCodexLaunchModeDefaultsKey)
            }

            if let canonicalThreadID {
                openSession(canonicalThreadID)
                if let detail = response.thread {
                    applyThreadDetail(detail, for: canonicalThreadID)
                } else {
                    await refreshThreadDetail(threadID: canonicalThreadID)
                }
            }

            return canonicalThreadID
        } catch {
            HelmLogger.sessions.error("Thread creation failed: \(self.logSummary(for: error))")
            connectionSummary = userFacingMessage(for: error, fallback: "Failed to create thread")
            return nil
        }
    }

    func fetchSessionLaunchOptions(backendID: String?) async throws -> SessionLaunchOptions {
        let interval = HelmLogger.sessionsSignposter.beginInterval("FetchSessionLaunchOptions")
        defer { HelmLogger.sessionsSignposter.endInterval("FetchSessionLaunchOptions", interval) }
        return try await bridge.fetchSessionLaunchOptions(backendID: backendID)
    }

    func fetchDirectorySuggestions(prefix: String) async throws -> [DirectorySuggestion] {
        let interval = HelmLogger.sessionsSignposter.beginInterval("FetchDirectorySuggestions")
        defer { HelmLogger.sessionsSignposter.endInterval("FetchDirectorySuggestions", interval) }
        return try await bridge.fetchDirectorySuggestions(prefix: prefix)
    }

    func fetchFileTagSuggestions(threadID: String, prefix: String) async throws -> [FileTagSuggestion] {
        let interval = HelmLogger.sessionsSignposter.beginInterval("FetchFileTagSuggestions")
        defer { HelmLogger.sessionsSignposter.endInterval("FetchFileTagSuggestions", interval) }
        guard let cwd = composerWorkingDirectory(for: threadID) else { return [] }
        return try await bridge.fetchFileTagSuggestions(cwd: cwd, prefix: prefix)
    }

    func fetchSkillSuggestions(prefix: String, threadID: String) async throws -> [SkillSuggestion] {
        let interval = HelmLogger.sessionsSignposter.beginInterval("FetchSkillSuggestions")
        defer { HelmLogger.sessionsSignposter.endInterval("FetchSkillSuggestions", interval) }
        return try await bridge.fetchSkillSuggestions(prefix: prefix, cwd: composerWorkingDirectory(for: threadID))
    }

    func composerWorkingDirectory(for threadID: String) -> String? {
        if let detail = threadDetail(for: threadID) {
            return nonEmpty(detail.workspacePath) ?? nonEmpty(detail.cwd)
        }
        if let thread = thread(for: threadID) {
            return nonEmpty(thread.workspacePath) ?? nonEmpty(thread.cwd)
        }
        return nil
    }

    func archiveSession(_ threadID: String) async {
        await archiveSessions([threadID])
    }

    func openArchivedSession(_ threadID: String) async {
        unarchiveThreadLocally(threadID)
        promoteArchivedThreadLocally(threadID)
        openSession(threadID)

        do {
            try await bridge.unarchiveThread(threadID: threadID)
        } catch {
            HelmLogger.bridge.error("Failed to unarchive session \(threadID): \(self.logSummary(for: error))")
        }

        await refreshSessionSnapshot()
    }

    func archiveSessions(_ threadIDs: [String]) async {
        let uniqueThreadIDs = orderedUniqueThreadIDs(threadIDs)
        guard !uniqueThreadIDs.isEmpty else { return }

        var dismissedMarkers: [String: Double] = [:]
        for threadID in uniqueThreadIDs {
            dismissedMarkers[threadID] = dismissedActiveThreadMarkers[threadID]
            clearDismissedActiveMarker(threadID)
            archiveThreadLocally(threadID)
        }

        do {
            for threadID in uniqueThreadIDs {
                try await bridge.archiveThread(threadID: threadID)
            }

            if let currentSelectedThreadID = selectedThreadID,
               uniqueThreadIDs.contains(currentSelectedThreadID) {
                selectedThreadID = preferredCommandThread?.id
                UserDefaults.standard.set(selectedThreadID, forKey: selectedThreadDefaultsKey)
            }
            await refreshSessionSnapshot()
        } catch {
            for threadID in uniqueThreadIDs {
                unarchiveThreadLocally(threadID)
                if let dismissedMarker = dismissedMarkers[threadID] {
                    dismissedActiveThreadMarkers[threadID] = dismissedMarker
                }
            }

            if !dismissedMarkers.isEmpty {
                persistDismissedActiveThreadMarkers()
            }
            connectionSummary = userFacingMessage(for: error, fallback: "Failed to archive session")
        }
    }

    func renameSession(_ threadID: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await bridge.renameThread(threadID: threadID, name: trimmed)
            applyThreadNameLocally(trimmed, to: threadID)
            await refreshThreads()
            await refreshThreadDetail(threadID: threadID)
        } catch {
            connectionSummary = userFacingMessage(for: error, fallback: "Failed to rename session")
        }
    }

    func takeControl(threadID: String? = nil, force: Bool = false) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard let threadID = targetThreadID else { return }

        do {
            try await bridge.takeControl(threadID: threadID, force: force)
            if selectedThreadID != threadID {
                selectThread(threadID)
            }
            await refreshThreads()
            appendVoiceEntry(.init(role: .system, text: force ? "Control taken over." : "Control claimed.", timestamp: .now))
        } catch {
            let message = bridge.lastError ?? "Failed to claim control."
            appendVoiceEntry(.init(role: .system, text: message, timestamp: .now))
        }
    }

    func releaseControl(threadID: String? = nil) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard let threadID = targetThreadID else { return }

        do {
            try await bridge.releaseControl(threadID: threadID)
            await refreshThreads()
            appendVoiceEntry(.init(role: .system, text: "Control released.", timestamp: .now))
        } catch {
            let message = bridge.lastError ?? "Failed to release control."
            appendVoiceEntry(.init(role: .system, text: message, timestamp: .now))
        }
    }

    func decideApproval(_ approval: RemotePendingApproval, decision: String) async {
        do {
            let startedAt = Date()
            HelmLogger.sessions.info("Sending approval decision \(decision)")
            try await bridge.decideApproval(approvalID: approval.requestId, decision: decision)
            lastApprovalLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            HelmLogger.sessions.info("Approval delivered in \(self.lastApprovalLatencyMS ?? 0)ms")
        } catch {
            HelmLogger.sessions.error("Approval failed: \(self.logSummary(for: error))")
            appendVoiceEntry(.init(role: .system, text: userFacingMessage(for: error, fallback: "Approval response failed."), timestamp: .now))
        }
    }

    func toggleComposerSendMode() {
        let nextMode: TurnDeliveryMode = composerSendMode == .queue ? .interrupt : .queue
        setComposerSendMode(nextMode)
    }

    func setComposerSendMode(_ mode: TurnDeliveryMode) {
        composerSendMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: composerSendModeDefaultsKey)
    }

    func sendDraft(to threadID: String? = nil, deliveryMode: TurnDeliveryMode? = nil) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard targetThreadID != nil else { return }
        guard let preparedDraft = takeDraftForSending() else { return }
        await sendPreparedDraft(preparedDraft, to: targetThreadID, deliveryMode: deliveryMode)
    }

    func takeDraftForSending() -> PreparedDraft? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageAttachments = draftImageAttachments
        let fileAttachments = draftFileAttachments
        guard !text.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty else { return nil }

        draft = ""
        draftImageAttachments = []
        draftFileAttachments = []
        return PreparedDraft(text: text, imageAttachments: imageAttachments, fileAttachments: fileAttachments)
    }

    func sendPreparedDraft(
        _ preparedDraft: PreparedDraft,
        to threadID: String? = nil,
        deliveryMode: TurnDeliveryMode? = nil
    ) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard let threadID = targetThreadID else {
            restorePreparedDraftIfNeeded(preparedDraft)
            return
        }

        await dispatchCommand(
            preparedDraft.text,
            threadID: threadID,
            deliveryMode: deliveryMode ?? composerSendMode,
            imageAttachments: preparedDraft.imageAttachments,
            fileAttachments: preparedDraft.fileAttachments
        )
    }

    func sendQuickCommand(_ text: String, threadID: String? = nil) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard let threadID = targetThreadID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await dispatchCommand(trimmed, threadID: threadID, deliveryMode: .queue)
    }

    func appendDraftImageAttachment(_ attachment: ComposerImageAttachment) {
        guard draftImageAttachments.count < 4 else { return }
        guard !draftImageAttachments.contains(where: { $0.data == attachment.data }) else { return }
        draftImageAttachments.append(attachment)
    }

    func removeDraftImageAttachment(id: String) {
        draftImageAttachments.removeAll { $0.id == id }
    }

    func appendDraftFileAttachment(_ attachment: ComposerFileAttachment) {
        guard draftFileAttachments.count < 4 else { return }
        guard !draftFileAttachments.contains(where: { $0.data == attachment.data }) else { return }
        draftFileAttachments.append(attachment)
    }

    func removeDraftFileAttachment(id: String) {
        draftFileAttachments.removeAll { $0.id == id }
    }

    private func dispatchCommand(
        _ text: String,
        threadID: String,
        deliveryMode: TurnDeliveryMode,
        imageAttachments: [ComposerImageAttachment] = [],
        fileAttachments: [ComposerFileAttachment] = []
    ) async {
        let displayText = outgoingDisplayText(
            text,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )
        appendVoiceEntry(.init(role: .user, text: displayText, timestamp: .now))
        let optimisticTurnID = applyOptimisticOutgoingUserTurn(displayText, to: threadID)

        do {
            let startedAt = Date()
            HelmLogger.command.info("Sending command")
            let delivery = try await bridge.sendTurn(
                threadID: threadID,
                text: text,
                deliveryMode: deliveryMode,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            )
            let isQueuedFollowUp = Self.isQueuedDeliveryMode(delivery?.mode)
            let deliveredThreadID = delivery?.threadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let deliveryThreadID = deliveredThreadID.isEmpty ? threadID : deliveredThreadID
            let refreshThreadID = shouldAdoptDeliveryThreadReplacement(from: threadID, to: deliveryThreadID)
                ? deliveryThreadID
                : threadID
            if refreshThreadID != threadID {
                adoptThreadReplacement(from: threadID, to: deliveryThreadID)
            }
            lastCommandLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            Self.logResponsivenessSample(
                title: "Command acknowledgement",
                sampleMS: self.lastCommandLatencyMS ?? 0,
                healthyThresholdMS: Self.healthyCommandAckMS,
                warningThresholdMS: Self.warningCommandAckMS
            )
            HelmLogger.command.info("Command delivered in \(self.lastCommandLatencyMS ?? 0)ms")
            schedulePendingOutgoingTurnRefresh(for: refreshThreadID, extended: isQueuedFollowUp)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshThreadDetail(threadID: refreshThreadID)
            }
            appendVoiceEntry(
                .init(
                    role: .assistant,
                    text: isQueuedFollowUp
                        ? "Queued for this CLI. It will run after the current turn finishes."
                        : deliveryMode == .interrupt
                        ? "Interrupt sent. Full output stays in the live session."
                        : "On it. Full output stays in the live session.",
                    timestamp: .now
                )
            )
        } catch {
            HelmLogger.command.error("Command failed: \(self.logSummary(for: error))")
            if handleTypedCommandControlConflict(threadID: threadID, text: text) {
                removeOptimisticOutgoingUserTurn(optimisticTurnID, from: threadID)
                return
            }

            let deliveryErrorSummary = [String(describing: error), bridge.lastError ?? ""]
                .joined(separator: "\n")
            if deliveryMode == .queue,
               Self.queuedSendFailureMayHaveReachedCLI(deliveryErrorSummary) {
                schedulePendingOutgoingTurnRefresh(for: threadID, extended: true)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.refreshThreadDetail(threadID: threadID)
                }
                appendVoiceEntry(
                    .init(
                        role: .system,
                        text: "Queue delivery is still being verified. I kept it in the mobile feed and will reconcile with the CLI.",
                        timestamp: .now
                    )
                )
                return
            }

            removeOptimisticOutgoingUserTurn(optimisticTurnID, from: threadID)
            await refreshThreadDetail(threadID: threadID)
            restoreFailedDraft(
                text,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments,
                threadID: threadID
            )
            appendVoiceEntry(
                .init(role: .system, text: userFacingMessage(for: error, fallback: "Failed to send command."), timestamp: .now)
            )
        }
    }

    private func shouldAdoptDeliveryThreadReplacement(from retiredThreadID: String, to canonicalThreadID: String) -> Bool {
        guard retiredThreadID != canonicalThreadID else { return false }
        guard let thread = thread(for: retiredThreadID), thread.backendId == "codex" else { return true }

        switch thread.sourceKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "vscode", "appserver":
            return false
        default:
            return true
        }
    }

    private func restoreFailedDraft(
        _ text: String,
        imageAttachments: [ComposerImageAttachment],
        fileAttachments: [ComposerFileAttachment],
        threadID: String
    ) {
        guard selectedThreadID == threadID else { return }
        restoreDraftIfNeeded(
            text: text,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )
    }

    private func restorePreparedDraftIfNeeded(_ preparedDraft: PreparedDraft) {
        restoreDraftIfNeeded(
            text: preparedDraft.text,
            imageAttachments: preparedDraft.imageAttachments,
            fileAttachments: preparedDraft.fileAttachments
        )
    }

    private func restoreDraftIfNeeded(
        text: String,
        imageAttachments: [ComposerImageAttachment],
        fileAttachments: [ComposerFileAttachment]
    ) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        }
        if draftImageAttachments.isEmpty {
            draftImageAttachments = imageAttachments
        }
        if draftFileAttachments.isEmpty {
            draftFileAttachments = fileAttachments
        }
    }

    nonisolated static func isQueuedDeliveryMode(_ mode: String?) -> Bool {
        guard let mode else { return false }
        return mode.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("queued")
    }

    nonisolated static func queuedSendFailureMayHaveReachedCLI(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        return normalized.contains("queued delivery could not be confirmed")
            || normalized.contains("shell relay did not confirm")
            || normalized.contains("shell relay timed out")
            || normalized.contains("turn/steer failed")
            || normalized.contains("app-server steer failed")
    }

    func interruptTurn(threadID: String? = nil) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard let threadID = targetThreadID else { return }
        do {
            try await bridge.interrupt(threadID: threadID)
            appendVoiceEntry(.init(role: .system, text: "Interrupt sent.", timestamp: .now))
        } catch {
            await refreshThreads()
            await refreshRuntime()
            appendVoiceEntry(.init(role: .system, text: bridge.lastError ?? "Interrupt failed.", timestamp: .now))
        }
    }

    func sendTerminalInput(_ key: TerminalInputKey, threadID: String? = nil) async {
        await sendTerminalInputs([key], threadID: threadID)
    }

    func sendTerminalInputs(_ keys: [TerminalInputKey], threadID: String? = nil) async {
        let targetThreadID = threadID ?? selectedThreadID
        guard let threadID = targetThreadID, !keys.isEmpty else { return }
        do {
            _ = try await bridge.sendTerminalInputs(threadID: threadID, keys: keys)
            if !bridgeRealtimeConnected {
                await refreshThreadDetail(threadID: threadID)
            }
        } catch {
            await refreshThreads()
            await refreshRuntime()
            appendVoiceEntry(
                .init(
                    role: .system,
                    text: userFacingMessage(for: error, fallback: "Terminal input failed."),
                    timestamp: .now
                )
            )
        }
    }

    func interruptActiveTurn() async {
        await interruptTurn(threadID: selectedThreadID)
    }

    func submitVoiceCommand(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendVoiceEntry(.init(role: .user, text: trimmed, timestamp: .now))

        if await handlePendingClarification(trimmed) {
            return
        }

        if await handleCommandIntent(trimmed) {
            return
        }

        if selectedThreadID == nil, threads.count == 1, let onlyThread = threads.first {
            selectThread(onlyThread.id)
        }

        guard let threadID = selectedThreadID else {
            if !threads.isEmpty {
                pendingClarification = .selectThreadForCommand(command: trimmed, runtimeTarget: nil)
                let followUp = styledAssistantMessage(
                    "Which session should I use for that command?",
                    kind: .status
                )
                logAssistantMessage(followUp, speak: true)
                return
            }

            let failure = styledAssistantMessage(
                "Select or create a session before I can work on that.",
                kind: .failure
            )
            logAssistantMessage(failure, speak: true)
            return
        }

        await sendVoiceCommandToSelectedThread(threadID: threadID, text: trimmed)
    }

    func speak(_ text: String, forceNative: Bool = false) {
        if voiceMode == .openAIRealtime,
           effectiveVoiceProvider?.id != "personaplex",
           !forceNative,
           isSceneActive
        {
            enqueueRealtimeSpeech(text)
            return
        }

        stopSpeakingOutput()

        if voiceMode == .openAIRealtime, effectiveVoiceProvider?.id != "personaplex", !forceNative {
            openAISpeechTask?.cancel()
            openAISpeechTask = Task { [weak self] in
                guard let self else { return }
                await self.speakWithOpenAI(text)
            }
            return
        }

        prepareNativeSpeechSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.48
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: notificationsEnabledDefaultsKey)

        if enabled {
            Task {
                let granted = await notifications.requestAuthorizationIfNeeded()
                await MainActor.run {
                    notificationAuthorizationSummary = granted ? "Enabled" : "Denied"
                }
            }
        }
    }

    func setSpokenStatusEnabled(_ enabled: Bool) {
        spokenStatusEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: spokenStatusDefaultsKey)
    }

    func setSpokenAlertMode(_ mode: SpokenAlertMode) {
        spokenAlertMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: spokenAlertModeDefaultsKey)
    }

    func setVoiceMode(_ mode: VoiceRuntimeMode) {
        guard voiceMode != mode else { return }

        voiceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: voiceModeDefaultsKey)

        if mode != .openAIRealtime, realtimeCaptureActive {
            stopRealtimeCapture()
        }

        if mode == .openAIRealtime {
            Task { await prepareRealtimeSession() }
        }
    }

    func setCommandResponseStyle(_ style: CommandResponseStyle) {
        commandResponseStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: commandResponseStyleDefaultsKey)

        if voiceMode == .openAIRealtime {
            Task { await prepareRealtimeSession() }
        }
    }

    func setCommandAutoResumeEnabled(_ enabled: Bool) {
        commandAutoResumeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: commandAutoResumeDefaultsKey)
    }

    func setAppAppearanceMode(_ mode: AppAppearanceMode) {
        guard appAppearanceMode != mode else { return }
        appAppearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: appAppearanceModeDefaultsKey)
    }

    func setSessionAutoCollapseEnabled(_ enabled: Bool) {
        sessionAutoCollapseEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: sessionAutoCollapseDefaultsKey)
    }

    func dismissOnboarding() {
        onboardingDismissed = true
        UserDefaults.standard.set(true, forKey: onboardingDismissedDefaultsKey)
    }

    func reopenOnboarding() {
        onboardingDismissed = false
        UserDefaults.standard.set(false, forKey: onboardingDismissedDefaultsKey)
    }

    func refreshNotificationAuthorization() async {
        notificationAuthorizationSummary = await notifications.authorizationDescription()
    }

    func refreshPairingStatus() async {
        do {
            let pairing = try await bridge.fetchPairingStatus()
            if let token = pairing.token, bridge.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bridge.pairingToken = token
            }

            let suggestedBridgeURLs = pairing.suggestedBridgeURLs ?? []
            bridge.rememberBridgeCandidates(suggestedBridgeURLs)
            let adoptedPreferredRemoteURL = await bridge.adoptPreferredReachableRemoteBridgeURL(from: suggestedBridgeURLs)
            pairingFilePath = pairing.filePath
            pairingSuggestedBridgeURLs = suggestedBridgeURLs
            pairingSetupURLString = pairing.setupURL
            pairingStatusSummary = adoptedPreferredRemoteURL
                ? "Bridge paired via preferred remote URL"
                : "Bridge paired with \(pairing.tokenHint)"
        } catch {
            pairingSuggestedBridgeURLs = []
            pairingSetupURLString = nil
            pairingStatusSummary = bridge.hasPairingToken ? "Pairing token configured on this device" : "Pairing token required"
        }
    }

    func refreshBackends() async {
        do {
            let response = try await bridge.fetchBackends()
            if availableBackends != response.backends {
                availableBackends = response.backends
            }
            if bridgeDefaultBackendID != response.defaultBackendId {
                bridgeDefaultBackendID = response.defaultBackendId
            }

            if preferredBackendID == nil || !availableBackends.contains(where: { $0.id == preferredBackendID }) {
                preferredBackendID = response.defaultBackendId
                UserDefaults.standard.set(preferredBackendID, forKey: preferredBackendDefaultsKey)
            }
        } catch {
            if availableBackends.isEmpty {
                bridgeDefaultBackendID = nil
            }
        }
    }

    func refreshVoiceProviders() async {
        do {
            let response = try await bridge.fetchVoiceProviders()
            if availableVoiceProviders != response.providers {
                availableVoiceProviders = response.providers
            }
            if bridgeDefaultVoiceProviderID != response.defaultVoiceProviderId {
                bridgeDefaultVoiceProviderID = response.defaultVoiceProviderId
            }

            if preferredVoiceProviderID == nil || !availableVoiceProviders.contains(where: { $0.id == preferredVoiceProviderID }) {
                preferredVoiceProviderID = response.defaultVoiceProviderId
                UserDefaults.standard.set(preferredVoiceProviderID, forKey: preferredVoiceProviderDefaultsKey)
            }
            await refreshVoiceProviderBootstrap()
        } catch {
            if availableVoiceProviders.isEmpty {
                bridgeDefaultVoiceProviderID = nil
            }
        }
    }

    func setPreferredBackendID(_ backendID: String) {
        preferredBackendID = backendID
        UserDefaults.standard.set(backendID, forKey: preferredBackendDefaultsKey)
    }

    func setPreferredVoiceProviderID(_ providerID: String) {
        preferredVoiceProviderID = providerID
        UserDefaults.standard.set(providerID, forKey: preferredVoiceProviderDefaultsKey)

        Task { await refreshVoiceProviderBootstrap() }

        if voiceMode == .openAIRealtime {
            Task { await prepareRealtimeSession() }
        }
    }

    func refreshVoiceProviderBootstrap() async {
        guard let provider = effectiveVoiceProvider else {
            voiceProviderBootstrapSummary = "No voice provider selected."
            voiceProviderBootstrapJSON = ""
            return
        }

        do {
            voiceProviderBootstrapJSON = try await bridge.fetchVoiceProviderBootstrap(
                providerID: provider.id,
                threadID: commandTargetThread?.id,
                backendID: commandTargetBackendSummary?.id,
                style: commandResponseStyle
            )
            voiceProviderBootstrapSummary = "Loaded bootstrap metadata for \(provider.label)."
        } catch {
            voiceProviderBootstrapSummary = bridge.lastError ?? "Voice provider bootstrap unavailable."
            voiceProviderBootstrapJSON = ""
        }
    }

    func readLocalPairing() async {
        let hadToken = bridge.hasPairingToken
        await refreshPairingStatus()
        if bridge.hasPairingToken {
            connectionSummary = "Local pairing loaded"
        } else if !hadToken {
            connectionSummary = "Local pairing not available here"
        }
    }

    func importPairingSetupFromClipboard() async {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            connectionSummary = "Clipboard does not contain a helm setup link"
            return
        }

        await applyPairingSetupLink(raw)
    }

    func applyPairingSetupLink(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionSummary = "That setup link is empty"
            return
        }

        guard let url = URL(string: trimmed) else {
            connectionSummary = "That setup link is invalid"
            return
        }

        await applyPairingSetupURL(url)
    }

    func retryBridgeConnection() async {
        await refreshPairingStatus()
        await refreshSessionSnapshot()
    }

    func refreshSetupStatus() async {
        await refreshPairingStatus()
        await refreshNotificationAuthorization()
        await refreshBackends()
        await refreshVoiceProviders()
        await refreshSessionSnapshot()
    }

    func prepareRealtimeSession() async {
        guard commandTargetSupportsRealtimeCommand, voiceProviderSupportsCurrentLiveCommandTransport else {
            realtimeBootstrap = nil
            realtimeStatusSummary = commandTargetRealtimeSummary
            liveCommandPhase = .failed
            return
        }

        if effectiveVoiceProvider?.id == "personaplex" {
            realtimeBootstrap = RealtimeSessionBootstrap(
                secretValue: "personaplex-native-proxy",
                secretHint: "PersonaPlex bridge proxy",
                expiresAt: nil,
                model: nil,
                voice: "NATF0.pt",
                backendId: commandTargetBackendSummary?.id,
                backendLabel: commandTargetBackendSummary?.label,
                voiceProviderId: effectiveVoiceProvider?.id,
                voiceProviderLabel: effectiveVoiceProvider?.label,
                threadId: commandTargetThread?.id
            )
            realtimeStatusSummary = "PersonaPlex bridge proxy ready • \(commandResponseStyle.title)"
            if !realtimeCaptureActive {
                liveCommandPhase = .idle
            }
            return
        }

        if voiceMode == .openAIRealtime {
            liveCommandPhase = realtimeCaptureActive ? .retargeting : .preparing
        }

        do {
            let bootstrap = try await bridge.fetchRealtimeSessionBootstrap(
                style: commandResponseStyle,
                threadID: commandTargetThread?.id,
                backendID: commandTargetBackendSummary?.id,
                voiceProviderID: effectiveVoiceProvider?.id
            )
            realtimeBootstrap = bootstrap

            var parts = ["Realtime ready", commandResponseStyle.title]
            if let backendLabel = bootstrap.backendLabel {
                parts.append(backendLabel)
            }
            if let voiceProviderLabel = bootstrap.voiceProviderLabel {
                parts.append(voiceProviderLabel)
            }
            if let model = bootstrap.model {
                parts.append(model)
            }
            if let voice = bootstrap.voice {
                parts.append(voice)
            }
            realtimeStatusSummary = parts.joined(separator: " • ")
            scheduleRealtimeBootstrapRefreshIfNeeded()
            if !realtimeCaptureActive {
                liveCommandPhase = .idle
            }
        } catch {
            realtimeBootstrap = nil
            realtimeStatusSummary = bridge.lastError ?? "Realtime bootstrap failed"
            liveCommandPhase = .failed
        }
    }

    func startRealtimeCapture() async {
        HelmLogger.voice.info("Starting realtime capture")
        backgroundSuspendTask?.cancel()
        backgroundSuspendTask = nil
        await prepareCommandSurface()

        guard commandTargetSupportsRealtimeCommand, voiceProviderSupportsCurrentLiveCommandTransport else {
            realtimeCaptureActive = false
            realtimeCaptureSummary = commandTargetRealtimeSummary
            appendRealtimeEvent(title: "Unavailable", detail: commandTargetRealtimeSummary)
            liveCommandPhase = .failed
            return
        }

        if realtimeBootstrap == nil || !realtimeBootstrapMatchesCommandTarget {
            await prepareRealtimeSession()
        }

        guard realtimeBootstrap != nil else {
            realtimeCaptureActive = false
            realtimeCaptureSummary = "Realtime session unavailable"
            appendRealtimeEvent(title: "Unavailable", detail: "Realtime session bootstrap failed.")
            liveCommandPhase = .failed
            return
        }

        realtimeTranscriptPreview = ""
        realtimeCaptureSummary = "Connecting to Realtime transcription"
        realtimeCaptureActive = true
        liveCommandPhase = .preparing
        realtimePlaybackQueue.removeAll()
        realtimeQueuedSpeechCount = 0
        realtimePlaybackActive = false
        appendRealtimeEvent(title: "Connecting", detail: "Opening the Realtime transcription session.")
    }

    func stopRealtimeCapture() {
        HelmLogger.voice.info("Stopping realtime capture")
        realtimeCaptureActive = false
        realtimeBootstrapRefreshTask?.cancel()
        realtimeCaptureSummary = "Realtime capture stopped"
        realtimeTranscriptPreview = ""
        realtimePlaybackRequest = nil
        realtimePlaybackStopToken = UUID()
        realtimePlaybackQueue.removeAll()
        realtimeQueuedSpeechCount = 0
        realtimePlaybackActive = false
        liveCommandPhase = .idle
        appendRealtimeEvent(title: "Stopped", detail: "Realtime transcription session closed.")
        if !isSceneActive {
            scheduleBackgroundSuspendIfNeeded()
        }
    }

    func handleRealtimeTransportState(_ state: String, detail: String?) {
        switch state {
        case "connecting":
            realtimeCaptureSummary = detail ?? "Connecting to Realtime transcription"
            liveCommandPhase = .preparing
        case "connected":
            realtimeCaptureSummary = detail ?? "Realtime transcription connected"
            liveCommandPhase = .preparing
        case "dispatching":
            realtimeCaptureSummary = detail ?? "Sending spoken command"
            liveCommandPhase = .dispatching
        case "listening":
            realtimeCaptureSummary = detail ?? "Listening for Command"
            liveCommandPhase = .listening
        case "playing":
            realtimeCaptureSummary = detail ?? "Speaking"
            realtimePlaybackActive = true
            liveCommandPhase = .responding
        case "disconnected":
            realtimeCaptureSummary = detail ?? "Realtime capture stopped"
            realtimeCaptureActive = false
            realtimeTranscriptPreview = ""
            realtimePlaybackActive = false
            realtimePlaybackQueue.removeAll()
            realtimeQueuedSpeechCount = 0
            liveCommandPhase = .idle
        case "error":
            realtimeCaptureSummary = detail ?? "Realtime capture failed"
            realtimeCaptureActive = false
            realtimePlaybackActive = false
            liveCommandPhase = .failed
        default:
            realtimeCaptureSummary = detail ?? state.capitalized
        }

        appendRealtimeEvent(title: state.capitalized, detail: detail)

        if !isSceneActive {
            scheduleBackgroundSuspendIfNeeded()
        }
    }

    func handleRealtimeTransportEvent(_ title: String, detail: String?) {
        appendRealtimeEvent(title: title, detail: detail)
    }

    func updateRealtimeTranscriptPreview(_ text: String) {
        realtimeTranscriptPreview = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commitRealtimeTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed == lastRealtimeSubmittedTranscript,
           let lastRealtimeSubmittedAt,
           Date().timeIntervalSince(lastRealtimeSubmittedAt) < 2.5
        {
            return
        }

        lastRealtimeSubmittedTranscript = trimmed
        lastRealtimeSubmittedAt = .now
        realtimeTranscriptPreview = trimmed
        appendVoiceEntry(.init(role: .user, text: trimmed, timestamp: .now))
        appendRealtimeEvent(title: "Transcript", detail: trimmed)
        realtimeCaptureSummary = "Sending spoken command"
        liveCommandPhase = .dispatching
    }

    func handleRealtimeCommandExchange(_ payload: RealtimeCommandExchange) {
        realtimeTranscriptPreview = ""
        if let latencyMS = payload.latencyMS {
            lastCommandLatencyMS = latencyMS
        }

        let threadID = payload.threadId ?? commandTargetThread?.id
        if let threadID {
            lastVoiceCommandThreadID = threadID
            lastVoiceCommandAcceptedAt = .now
        }

        let backendLabel = payload.exchange.backendLabel
            ?? commandTargetBackendSummary?.label
            ?? "Codex"

        if realtimeCaptureActive {
            if payload.exchange.spokenResponse == nil {
                realtimeCaptureSummary =
                    payload.exchange.shouldResumeListening
                    ? "Acknowledged. \(backendLabel) is continuing the Command."
                    : "Acknowledged. \(backendLabel) is continuing the Command."
                liveCommandPhase = payload.exchange.shouldResumeListening ? .listening : .responding
            } else {
                realtimeCaptureSummary = "Acknowledged. Speaking."
                liveCommandPhase = .responding
            }
        }

        appendRealtimeEvent(title: "Command Accepted", detail: payload.exchange.displayResponse)
        appendVoiceEntry(.init(role: .assistant, text: payload.exchange.displayResponse, timestamp: .now))
    }

    func handleRealtimeCommandFailure(
        threadID: String?,
        transcript: String,
        detail: String,
        latencyMS: Int?
    ) {
        realtimeTranscriptPreview = ""
        if let latencyMS {
            lastCommandLatencyMS = latencyMS
        }

        let resolvedThreadID = threadID ?? commandTargetThread?.id
        if let resolvedThreadID {
            clearRecentVoiceCommandContext(for: resolvedThreadID)
        }

        if let resolvedThreadID,
           handleVoiceCommandControlConflict(threadID: resolvedThreadID, text: transcript)
        {
            return
        }

        if voiceMode == .openAIRealtime, realtimeCaptureActive {
            realtimeCaptureSummary = "Command dispatch failed"
            liveCommandPhase = .failed
            appendRealtimeEvent(title: "Dispatch Failed", detail: detail)
        }

        let failure = styledAssistantMessage(detail, kind: .failure)
        logAssistantMessage(failure, speak: true)

        if resolvedThreadID != nil {
            Task {
                await refreshSessionSnapshot()
            }
        }
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "helm" else { return }

        if url.host?.lowercased() == "pair" {
            Task {
                await applyPairingSetupURL(url)
            }
            return
        }

        let components = url.pathComponents.filter { $0 != "/" }
        let threadID: String?

        if url.host?.lowercased() == "thread" {
            threadID = components.first
        } else if components.first?.lowercased() == "thread" {
            threadID = components.dropFirst().first
        } else {
            threadID = nil
        }

        guard let threadID, !threadID.isEmpty else { return }

            openSession(threadID)
        selectedSection = .sessions
        Task {
            await refreshSessionSnapshot()
        }
    }

    private func applyPairingSetupURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "helm", url.host?.lowercased() == "pair" else {
            connectionSummary = "That link is not a helm pairing link"
            return
        }

        let setupLink = url.absoluteString

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            connectionSummary = "That setup link is invalid"
            return
        }

        let bridgeURL = components.queryItems?.first(where: { $0.name == "bridge" })?.value
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value

        guard let bridgeURL,
              let token,
              let bridgeURLValue = URL(string: bridgeURL),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            connectionSummary = "That setup link is missing bridge pairing details"
            return
        }

        bridge.baseURL = bridgeURLValue
        bridge.pairingToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        pairingSetupURLString = setupLink
        selectedSection = .settings
        connectionSummary = "Pairing imported"
        await refreshSetupStatus()
    }

    func updateScenePhase(_ isActive: Bool) {
        isSceneActive = isActive
        Task { @MainActor in
            await handleScenePhaseTransition(isActive)
        }
    }

    func consumePendingCommandIntent() async {
        let shouldOpenLiveCommand = CommandIntentInbox.consumeOpenCommand()

        if shouldOpenLiveCommand {
            selectedSection = .command
            await ensureLiveCommandIfNeeded()
        }

        guard let payload = CommandIntentInbox.consume() else { return }

        if threads.isEmpty {
            await refreshSessionSnapshot()
        }

        if let query = payload.threadQuery, !query.isEmpty {
            if let match = threadsMatching(query, backendPreference: payload.runtimeTarget).first {
                selectThread(match.id)
            }
        } else if let runtimeTarget = payload.runtimeTarget,
                  let match = preferredCommandThread(backendPreference: runtimeTarget) {
            selectThread(match.id)
        }

        selectedSection = .command
        await ensureLiveCommandIfNeeded()
        await submitVoiceCommand(payload.command)
    }

    func handleCommandSectionActivated() async {
        guard selectedSection == .command else { return }
        guard commandAutoResumeEnabled else { return }
        await ensureLiveCommandIfNeeded()
    }

    private func handleCommandIntent(_ text: String) async -> Bool {
        switch resolveCommandIntent(text) {
        case .status:
            let summary = styledAssistantMessage(buildStatusSummary(), kind: .status)
            logAssistantMessage(summary, speak: true)
            return true
        case .interrupt:
            await interruptActiveTurn()
            let reply = styledAssistantMessage("Interrupt sent.", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .approve:
            if selectedApprovals.isEmpty {
                if allPendingApprovals.count == 1, let approval = allPendingApprovals.first {
                    selectThread(approval.threadId)
                    await decideApproval(approval, decision: "accept")
                    let reply = styledAssistantMessage("I approved that request.", kind: .acknowledgement)
                    logAssistantMessage(reply, speak: true)
                    return true
                }

                if allPendingApprovals.count > 1 {
                    pendingClarification = .chooseThreadForApproval(
                        decision: "accept",
                        approvals: allPendingApprovals
                    )
                    let reply = styledAssistantMessage(
                        "There are multiple approvals waiting. Which session should I use?",
                        kind: .approval
                    )
                    logAssistantMessage(reply, speak: true)
                    return true
                }

                let reply = styledAssistantMessage(
                    "There is nothing waiting for approval in the selected session.",
                    kind: .failure
                )
                logAssistantMessage(reply, speak: true)
                return true
            }

            guard let approval = selectedApprovals.first else { return true }
            await decideApproval(approval, decision: "accept")
            let reply = styledAssistantMessage("I approved that request.", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .decline:
            if selectedApprovals.isEmpty {
                if allPendingApprovals.count == 1, let approval = allPendingApprovals.first {
                    selectThread(approval.threadId)
                    await decideApproval(approval, decision: "decline")
                    let reply = styledAssistantMessage("I declined that request.", kind: .acknowledgement)
                    logAssistantMessage(reply, speak: true)
                    return true
                }

                if allPendingApprovals.count > 1 {
                    pendingClarification = .chooseThreadForApproval(
                        decision: "decline",
                        approvals: allPendingApprovals
                    )
                    let reply = styledAssistantMessage(
                        "There are multiple approvals waiting. Which session should I use?",
                        kind: .approval
                    )
                    logAssistantMessage(reply, speak: true)
                    return true
                }

                let reply = styledAssistantMessage(
                    "There is nothing waiting for approval in the selected session.",
                    kind: .failure
                )
                logAssistantMessage(reply, speak: true)
                return true
            }

            guard let approval = selectedApprovals.first else { return true }
            await decideApproval(approval, decision: "decline")
            let reply = styledAssistantMessage("I declined that request.", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .takeControl(let force):
            await takeControl(force: force)
            let reply = force ? "I took control of the selected session." : "I claimed control of the selected session."
            logAssistantMessage(styledAssistantMessage(reply, kind: .acknowledgement), speak: true)
            return true
        case .releaseControl:
            await releaseControl()
            let reply = styledAssistantMessage("I released control of the selected session.", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .switchThread(let query, let runtimeTarget):
            let matches = threadsMatching(query, backendPreference: runtimeTarget)

            guard !matches.isEmpty else {
                let reply = styledAssistantMessage(threadLookupFailure(for: query, runtimeTarget: runtimeTarget), kind: .failure)
                logAssistantMessage(reply, speak: true)
                return true
            }

            if matches.count > 1 {
                pendingClarification = .chooseThreadForSwitch(matchIDs: matches.map(\.id))
                let reply = styledAssistantMessage(
                    "I found multiple sessions matching \(query). Which one do you want?",
                    kind: .status
                )
                logAssistantMessage(reply, speak: true)
                return true
            }

            guard let match = matches.first else {
                return true
            }

            selectThread(match.id)
            let reply = styledAssistantMessage("Switched to \(match.name ?? "the selected session").", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .routeCommand(let query, let command, let runtimeTarget):
            let matches = threadsMatching(query, backendPreference: runtimeTarget)

            guard !matches.isEmpty else {
                let reply = styledAssistantMessage(activeThreadLookupFailure(for: query, runtimeTarget: runtimeTarget), kind: .failure)
                logAssistantMessage(reply, speak: true)
                return true
            }

            if matches.count > 1 {
                pendingClarification = .selectThreadForCommand(command: command, runtimeTarget: runtimeTarget)
                let reply = styledAssistantMessage(
                    "I found multiple sessions for \(query). Which one should I use?",
                    kind: .status
                )
                logAssistantMessage(reply, speak: true)
                return true
            }

            guard let match = matches.first else {
                return true
            }

            selectThread(match.id)
            await sendVoiceCommandToSelectedThread(threadID: match.id, text: command)
            return true
        case .createThreadNeedsCwd:
            pendingClarification = .createThreadCwd
            let reply = styledAssistantMessage(
                "Which folder should I use for the new session?",
                kind: .status
            )
            logAssistantMessage(reply, speak: true)
            return true
        case .createThread(let cwd):
            await createThread(at: cwd)
            let reply = styledAssistantMessage("I started a new session in \(cwd).", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .passthrough:
            return false
        }
    }

    private func resolveCommandIntent(_ text: String) -> CommandIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if [
            "status",
            "what's the status",
            "whats the status",
            "what is the status",
            "what's happening",
            "whats happening",
            "summarize active work",
            "give me a status update",
        ].contains(lower) {
            return .status
        }

        if ["interrupt", "stop", "halt", "cancel that", "stop that"].contains(lower) {
            return .interrupt
        }

        if ["approve", "allow", "continue", "yes continue"].contains(lower) {
            return .approve
        }

        if ["deny", "decline", "reject", "do not continue"].contains(lower) {
            return .decline
        }

        if ["take control", "claim control"].contains(lower) {
            return .takeControl(force: false)
        }

        if ["take over", "force control"].contains(lower) {
            return .takeControl(force: true)
        }

        if ["release control", "stop controlling"].contains(lower) {
            return .releaseControl
        }

        if lower.hasPrefix("switch to ") {
            let query = String(trimmed.dropFirst("switch to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? .passthrough : resolveSwitchIntent(from: query)
        }

        if lower.hasPrefix("open ") {
            let query = String(trimmed.dropFirst("open ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? .passthrough : resolveSwitchIntent(from: query)
        }

        if let runtimeIntent = resolveRuntimeTargetIntent(trimmed) {
            return runtimeIntent
        }

        if let scopedIntent = resolveScopedCommandIntent(trimmed) {
            return scopedIntent
        }

        if lower.hasPrefix("start session in ") {
            let cwd = String(trimmed.dropFirst("start session in ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return cwd.isEmpty ? .passthrough : .createThread(cwd: cwd)
        }

        if lower.hasPrefix("create session in ") {
            let cwd = String(trimmed.dropFirst("create session in ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return cwd.isEmpty ? .passthrough : .createThread(cwd: cwd)
        }

        if ["start session", "create session", "new session"].contains(lower) {
            return .createThreadNeedsCwd
        }

        return .passthrough
    }

    private func handlePendingClarification(_ response: String) async -> Bool {
        guard let pendingClarification else { return false }

        switch pendingClarification {
        case .selectThreadForCommand(let command, let runtimeTarget):
            let matches = threadsMatching(response, backendPreference: runtimeTarget)
            guard let match = resolveSingleMatch(matches, noMatch: "I couldn't match that to a session.") else {
                return true
            }

            self.pendingClarification = nil
            selectThread(match.id)
            await sendVoiceCommandToSelectedThread(threadID: match.id, text: command)
            return true
        case .chooseThreadForSwitch(let matchIDs):
            let eligibleMatches = threads.filter { matchIDs.contains($0.id) }
            let matches = eligibleMatches.filter {
                let query = response.lowercased()
                return ($0.name ?? "").lowercased().contains(query)
                    || $0.preview.lowercased().contains(query)
            }

            guard let match = resolveSingleMatch(matches, noMatch: "I couldn't tell which session you meant.") else {
                return true
            }

            self.pendingClarification = nil
            selectThread(match.id)
            let reply = styledAssistantMessage(
                "Switched to \(match.name ?? "the selected session").",
                kind: .acknowledgement
            )
            logAssistantMessage(reply, speak: true)
            return true
        case .chooseThreadForApproval(let decision, let approvals):
            let query = response.lowercased()
            let matches = approvals.filter { approval in
                let threadName = threadDisplayName(for: approval.threadId).lowercased()
                return threadName.contains(query)
            }

            if matches.count > 1 {
                let reply = styledAssistantMessage(
                    "I still see multiple matching sessions. Say the exact session name.",
                    kind: .approval
                )
                logAssistantMessage(reply, speak: true)
                return true
            }

            guard let approval = matches.first else {
                let reply = styledAssistantMessage(
                    "I couldn't match that to a session with a pending approval.",
                    kind: .failure
                )
                logAssistantMessage(reply, speak: true)
                return true
            }

            self.pendingClarification = nil
            selectThread(approval.threadId)
            await decideApproval(approval, decision: decision)
            let reply = styledAssistantMessage(
                decision == "accept" ? "I approved that request." : "I declined that request.",
                kind: .acknowledgement
            )
            logAssistantMessage(reply, speak: true)
            return true
        case .createThreadCwd:
            self.pendingClarification = nil
            await createThread(at: response)
            let reply = styledAssistantMessage("I started a new session in \(response).", kind: .acknowledgement)
            logAssistantMessage(reply, speak: true)
            return true
        case .confirmTakeOver(let threadID, let command, _):
            let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["yes", "yes take over", "take over", "force control", "continue here"].contains(normalized) {
                self.pendingClarification = nil
                selectThread(threadID)
                await takeControl(force: true)
                await sendVoiceCommandToSelectedThread(threadID: threadID, text: command)
                return true
            }

            if ["no", "cancel", "never mind", "stop"].contains(normalized) {
                self.pendingClarification = nil
                let reply = styledAssistantMessage("Okay. I’ll keep observing that session.", kind: .acknowledgement)
                logAssistantMessage(reply, speak: true)
                return true
            }

            let reply = styledAssistantMessage(
                "Say take over to continue here, or say cancel.",
                kind: .status
            )
            logAssistantMessage(reply, speak: true)
            return true
        }
    }

    private func threadsMatching(_ query: String, backendPreference: String? = nil) -> [RemoteThread] {
        let loweredQuery = canonicalThreadLookupQuery(query)
        guard !loweredQuery.isEmpty else { return [] }
        let matches = threads.filter {
            threadLookupValues(for: $0).contains { $0.contains(loweredQuery) }
        }

        guard let backendPreference else {
            return matches
        }

        let backendMatches = matches.filter { matchesBackendPreference($0, backendPreference: backendPreference) }
        return backendMatches.isEmpty ? [] : backendMatches
    }

    private func resolveSingleMatch(_ matches: [RemoteThread], noMatch: String) -> RemoteThread? {
        if matches.count > 1 {
            let reply = styledAssistantMessage(
                "I found multiple matching sessions. Say the exact session name.",
                kind: .status
            )
            logAssistantMessage(reply, speak: true)
            return nil
        }

        guard let match = matches.first else {
            let reply = styledAssistantMessage(noMatch, kind: .failure)
            logAssistantMessage(reply, speak: true)
            return nil
        }

        return match
    }

    private func sendVoiceCommandToSelectedThread(threadID: String, text: String) async {
        guard commandTargetSupportsVoiceCommand else {
            let failure = styledAssistantMessage(
                commandTargetBackendNote ?? "This backend does not currently support spoken Command routing.",
                kind: .failure
            )
            logAssistantMessage(failure, speak: true)
            return
        }

        do {
            let startedAt = Date()
            let exchange = try await bridge.sendVoiceCommand(
                threadID: threadID,
                text: text,
                style: commandResponseStyle
            )
            lastCommandLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastVoiceCommandThreadID = threadID
            lastVoiceCommandAcceptedAt = .now
            if voiceMode == .openAIRealtime, realtimeCaptureActive {
                let backendLabel = exchange.backendLabel ?? commandTargetBackendSummary?.label ?? "Codex"
                realtimeCaptureSummary =
                    exchange.spokenResponse == nil
                    ? "Acknowledged. \(backendLabel) is continuing the Command."
                    : "Acknowledged. Speaking."
                liveCommandPhase = exchange.spokenResponse == nil ? .listening : .responding
                appendRealtimeEvent(title: "Command Accepted", detail: exchange.displayResponse)
            }
            appendVoiceEntry(.init(role: .assistant, text: exchange.displayResponse, timestamp: .now))
            if let spokenResponse = exchange.spokenResponse {
                speak(spokenResponse)
            } else if voiceMode != .openAIRealtime || !realtimeCaptureActive {
                speak(exchange.displayResponse)
            }
        } catch {
            await refreshSessionSnapshot()
            clearRecentVoiceCommandContext(for: threadID)
            if handleVoiceCommandControlConflict(threadID: threadID, text: text) {
                return
            }
            if voiceMode == .openAIRealtime, realtimeCaptureActive {
                realtimeCaptureSummary = "Command dispatch failed"
                liveCommandPhase = .failed
                appendRealtimeEvent(
                    title: "Dispatch Failed",
                    detail: bridge.lastError ?? "I couldn't send that."
                )
            }
            let failure = styledAssistantMessage(
                bridge.lastError ?? "I couldn't send that.",
                kind: .failure
            )
            logAssistantMessage(failure, speak: true)
        }
    }

    private func handleVoiceCommandControlConflict(threadID: String, text: String) -> Bool {
        let message = bridge.lastError ?? ""
        guard message.localizedCaseInsensitiveContains("controlled by") else {
            return false
        }

        let controllerName = conflictingControllerName(from: message)
            ?? threads.first(where: { $0.id == threadID })?.controller?.clientName
            ?? "another client"

        pendingClarification = .confirmTakeOver(
            threadID: threadID,
            command: text,
            controllerName: controllerName
        )

        if voiceMode == .openAIRealtime, realtimeCaptureActive {
            realtimeCaptureSummary = "Command needs control confirmation."
            liveCommandPhase = .failed
            appendRealtimeEvent(
                title: "Control Confirmation",
                detail: "\(controllerName) is controlling this session."
            )
        }

        let reply = styledAssistantMessage(voiceControlConflictPrompt(for: threadID, controllerName: controllerName), kind: .status)
        logAssistantMessage(reply, speak: true)
        return true
    }

    private func handleTypedCommandControlConflict(threadID: String, text: String) -> Bool {
        let message = bridge.lastError ?? ""
        guard message.localizedCaseInsensitiveContains("controlled by") else {
            return false
        }

        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        }

        let controllerName = conflictingControllerName(from: message)
            ?? threads.first(where: { $0.id == threadID })?.controller?.clientName
            ?? "another client"

        appendVoiceEntry(
            .init(
                role: .system,
                text: typedControlConflictPrompt(for: threadID, controllerName: controllerName),
                timestamp: .now
            )
        )
        return true
    }

    private func conflictingControllerName(from message: String) -> String? {
        let marker = "controlled by "
        guard let range = message.range(of: marker, options: [.caseInsensitive]) else {
            return nil
        }

        let suffix = message[range.upperBound...]
        let name = suffix
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return name?.isEmpty == false ? name : nil
    }

    private func voiceControlConflictPrompt(for threadID: String, controllerName: String) -> String {
        if sessionAccess(for: threadID) == "helmManagedShell" {
            return "\(controllerName) is currently controlling this helm-managed session from the CLI. Say take over if you want me to continue here."
        }

        return "\(controllerName) is currently controlling that session. Say take over if you want me to continue here."
    }

    private func typedControlConflictPrompt(for threadID: String, controllerName: String) -> String {
        if sessionAccess(for: threadID) == "helmManagedShell" {
            return "\(controllerName) is actively driving this helm-managed session. Your command is still in the composer. Keep it running there or take over to send it here."
        }

        return "\(controllerName) is currently controlling that session. Your command is still in the composer. Take control to continue here."
    }

    private func sessionAccess(for threadID: String) -> String? {
        if let detailAccess = threadDetailByID[threadID]?.affordances?.sessionAccess {
            return detailAccess
        }

        guard let thread = threads.first(where: { $0.id == threadID }) else {
            return nil
        }

        if thread.isHelmManaged {
            return "helmManagedShell"
        }

        switch thread.sourceKind {
        case "cli":
            return "cliAttach"
        case "vscode", "claude-desktop":
            return "editorResume"
        default:
            return "sharedThread"
        }
    }

    private func buildStatusSummary() -> String {
        let threadName = selectedThread?.name ?? "the selected session"

        if let approval = selectedApprovals.first {
            if let detail = approval.detail {
                return "I need approval in \(threadName). \(detail)"
            }

            return "I need approval in \(threadName)."
        }

        if let runtime = selectedRuntime {
            switch runtime.phase {
            case "running":
                if let title = runtime.title, let detail = runtime.detail {
                    return "I’m working in \(threadName). \(title). \(detail)"
                }

                if let title = runtime.title {
                    return "I’m working in \(threadName). \(title)."
                }

                return "I’m working in \(threadName)."
            case "completed":
                if let detail = runtime.detail {
                    return "I completed the latest work in \(threadName). \(detail)"
                }
                return "I completed the latest work in \(threadName)."
            case "blocked":
                if let detail = runtime.detail {
                    return "I’m blocked in \(threadName). \(detail)"
                }
                return "I’m blocked in \(threadName)."
            default:
                break
            }
        }

        if let latestTurn = selectedThreadDetail?.turns.first {
            if let firstItem = latestTurn.items.first {
                if let detail = firstItem.detail {
                    return "The latest activity in \(threadName) was \(firstItem.title). \(detail)"
                }
                return "The latest activity in \(threadName) was \(firstItem.title)."
            }

            return "The latest turn in \(threadName) is \(latestTurn.status)."
        }

        return "I do not have recent activity for \(threadName) yet."
    }

    private func stripSessionSuffix(from value: String) -> String {
        guard value.lowercased().hasSuffix(" session") else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(value.dropLast(" session".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveScopedCommandIntent(_ text: String) -> CommandIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        for prefix in ["in repo ", "in project ", "in workspace ", "use repo ", "use project ", "use workspace "] {
            if lower.hasPrefix(prefix) {
                let remainder = String(trimmed.dropFirst(prefix.count))
                guard let scoped = splitScopedCommandRemainder(remainder) else {
                    return nil
                }
                return .routeCommand(query: scoped.query, command: scoped.command, runtimeTarget: nil)
            }
        }

        for marker in [" in repo ", " in project ", " in workspace "] {
            guard let range = lower.range(of: marker, options: .backwards) else {
                continue
            }

            let command = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let query = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCommand = normalizeScopedCommand(command)
            let normalizedQuery = canonicalThreadLookupQuery(query)
            guard !normalizedCommand.isEmpty, !normalizedQuery.isEmpty else {
                continue
            }

            let extracted = extractRuntimeDirective(from: normalizedCommand)
            return .routeCommand(
                query: normalizedQuery,
                command: extracted.command,
                runtimeTarget: extracted.runtimeTarget
            )
        }

        return nil
    }

    private func resolveRuntimeTargetIntent(_ text: String) -> CommandIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        for candidate in runtimeIntentCandidates {
            guard lower.hasPrefix(candidate.prefix) else {
                continue
            }

            let remainder = String(trimmed.dropFirst(candidate.prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remainder.isEmpty else {
                return nil
            }

            if let scoped = splitScopedCommandRemainder(remainder) {
                return .routeCommand(query: scoped.query, command: scoped.command, runtimeTarget: candidate.backendID)
            }

            return .switchThread(query: canonicalThreadLookupQuery(remainder), runtimeTarget: candidate.backendID)
        }

        return nil
    }

    private func splitScopedCommandRemainder(_ remainder: String) -> (query: String, command: String)? {
        let separators = [",", ":", " then "]

        for separator in separators {
            if let range = remainder.range(of: separator) {
                let query = canonicalThreadLookupQuery(String(remainder[..<range.lowerBound]))
                let command = normalizeScopedCommand(String(remainder[range.upperBound...]))
                if !query.isEmpty, !command.isEmpty {
                    return (query, command)
                }
            }
        }

        return nil
    }

    private func normalizeScopedCommand(_ command: String) -> String {
        command
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func extractRuntimeDirective(from command: String) -> (command: String, runtimeTarget: String?) {
        let lowered = command.lowercased()
        for directive in [" with claude code", " using claude code", " with claude", " using claude"] {
            if lowered.hasSuffix(directive) {
                let trimmed = String(command.dropLast(directive.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                return (trimmed, "claude-code")
            }
        }

        for directive in [" with codex", " using codex"] {
            if lowered.hasSuffix(directive) {
                let trimmed = String(command.dropLast(directive.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                return (trimmed, "codex")
            }
        }

        return (command, nil)
    }

    private func canonicalThreadLookupQuery(_ query: String) -> String {
        var candidate = stripSessionSuffix(from: query)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

        let prefixes = ["repo ", "repository ", "project ", "workspace ", "session "]
        var loweredCandidate = candidate.lowercased()
        for prefix in prefixes {
            if loweredCandidate.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                loweredCandidate = candidate.lowercased()
                break
            }
        }

        return candidate.lowercased()
    }

    private func threadLookupValues(for thread: RemoteThread) -> [String] {
        let workspacePath = thread.workspacePath ?? ""
        var values = [
            (thread.name ?? "").lowercased(),
            thread.preview.lowercased(),
            thread.cwd.lowercased(),
            workspacePath.lowercased(),
        ]

        let basename = URL(fileURLWithPath: thread.cwd).lastPathComponent.lowercased()
        if !basename.isEmpty {
            values.append(basename)
        }

        if !workspacePath.isEmpty {
            let workspaceURL = URL(fileURLWithPath: workspacePath)
            let workspaceBasename = workspaceURL.lastPathComponent.lowercased()
            if !workspaceBasename.isEmpty {
                values.append(workspaceBasename)
            }

            let workspacePathComponents = workspaceURL.pathComponents
                .filter { $0 != "/" }
                .map { $0.lowercased() }
            values.append(contentsOf: workspacePathComponents)
        }

        let pathComponents = URL(fileURLWithPath: thread.cwd).pathComponents
            .filter { $0 != "/" }
            .map { $0.lowercased() }
        values.append(contentsOf: pathComponents)

        return values.filter { !$0.isEmpty }
    }

    private func resolveSwitchIntent(from query: String) -> CommandIntent {
        let resolved = extractRuntimeFromQuery(query)
        return .switchThread(query: resolved.query, runtimeTarget: resolved.runtimeTarget)
    }

    private func extractRuntimeFromQuery(_ query: String) -> (query: String, runtimeTarget: String?) {
        let normalizedQuery = canonicalThreadLookupQuery(query)
        for runtime in runtimeQueryPrefixes {
            if normalizedQuery == runtime.alias || normalizedQuery.hasPrefix("\(runtime.alias) ") {
                let remainder = normalizedQuery == runtime.alias
                    ? normalizedQuery
                    : String(normalizedQuery.dropFirst(runtime.alias.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                return (remainder.isEmpty ? normalizedQuery : remainder, runtime.backendID)
            }
        }

        return (normalizedQuery, nil)
    }

    private func matchesBackendPreference(_ thread: RemoteThread, backendPreference: String) -> Bool {
        let candidates = [
            thread.backendId?.lowercased(),
            thread.backendKind?.lowercased(),
            thread.backendLabel?.lowercased(),
        ].compactMap { $0 }

        return candidates.contains(where: { $0 == backendPreference || $0.contains(backendPreference) })
    }

    private func threadLookupFailure(for query: String, runtimeTarget: String?) -> String {
        if let runtimeTarget {
            return "I couldn't find a \(runtimeLabel(for: runtimeTarget)) session matching \(query)."
        }

        return "I couldn't find a session matching \(query)."
    }

    private func activeThreadLookupFailure(for query: String, runtimeTarget: String?) -> String {
        if let runtimeTarget {
            return "I couldn't find an active \(runtimeLabel(for: runtimeTarget)) session for \(query)."
        }

        return "I couldn't find an active session for \(query)."
    }

    private func runtimeLabel(for backendID: String) -> String {
        switch backendID {
        case "claude-code":
            return "Claude Code"
        case "codex":
            return "Codex"
        default:
            return backendID
        }
    }

    private var runtimeIntentCandidates: [(prefix: String, backendID: String)] {
        [
            ("use claude code for ", "claude-code"),
            ("use claude for ", "claude-code"),
            ("send claude code to ", "claude-code"),
            ("send claude to ", "claude-code"),
            ("use codex for ", "codex"),
            ("send codex to ", "codex"),
        ]
    }

    private var runtimeQueryPrefixes: [(alias: String, backendID: String)] {
        [
            ("claude code", "claude-code"),
            ("claude", "claude-code"),
            ("codex", "codex"),
        ]
    }

    private func connectRealtime() {
        guard bridge.hasPairingToken else { return }
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
                self.recoverySummary = "Recovering live connection and refreshing session state."
                self.scheduleRealtimeReconnect()
            }
        )
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let controlledThreadIDs = self.threads.compactMap { thread in
                    thread.controller?.clientId == self.bridge.identity.id ? thread.id : nil
                }

                if !controlledThreadIDs.isEmpty {
                    do {
                        try await self.bridge.heartbeat(threadIDs: controlledThreadIDs)
                    } catch {
                        self.connectionSummary = "Heartbeat failed"
                    }
                }

                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    private func handleRealtimeMessage(_ message: BridgeRealtimeMessage) {
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
        case .threadSnapshot(let threads):
            bridgeRealtimeConnected = true
            applyFetchedThreads(threads)
        case .runtimeSnapshot(let threads):
            bridgeRealtimeConnected = true
            recordRealtimeAgeSample(from: threads.map(\.lastUpdatedAt))
            applyRuntimeSnapshot(threads)
            if let selectedThreadID,
               threads.contains(where: { $0.threadId == selectedThreadID }) {
                scheduleSelectedThreadDetailRefresh(force: true)
            }
        case .runtimeThread(let thread):
            bridgeRealtimeConnected = true
            recordRealtimeAgeSample(from: [thread.lastUpdatedAt])
            let previous = runtimeByThreadID[thread.threadId]
            if previous != thread {
                runtimeByThreadID[thread.threadId] = thread
            }
            refreshDismissedActiveSessions()
            processRuntimeUpdate(previous: previous, current: thread)
            if thread.threadId == selectedThreadID {
                scheduleSelectedThreadDetailRefresh(force: true)
            }
        case .threadDetail(let detail):
            bridgeRealtimeConnected = true
            recordRealtimeAgeSample(from: [detail.updatedAt])
            reconcilePendingOutgoingTurns(for: detail.id, against: detail)
            applyThreadDetail(detail, for: detail.id)
        case .controlChanged(let payload):
            guard let index = threads.firstIndex(where: { $0.id == payload.threadId }) else { return }
            let current = threads[index]
            guard current.controller != payload.controller else { return }
            threads[index] = RemoteThread(
                id: current.id,
                name: current.name,
                preview: current.preview,
                cwd: current.cwd,
                workspacePath: current.workspacePath,
                status: current.status,
                updatedAt: current.updatedAt,
                sourceKind: current.sourceKind,
                launchSource: current.launchSource,
                backendId: current.backendId,
                backendLabel: current.backendLabel,
                backendKind: current.backendKind,
                controller: payload.controller
            )
            refreshDismissedActiveSessions()
        }
    }

    private func performPostReconnectRecovery() async {
        let startedAt = Date()
        await refreshSessionSnapshot()
        let latencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)

        if connectionSummary == "Bridge unavailable" || connectionSummary == "Runtime unavailable" || connectionSummary == "Thread detail unavailable" {
            recoverySummary = "Live transport returned, but state refresh still needs attention."
            return
        }

        recoverySummary = "Recovered live state in \(latencyMS) ms."
        connectionSummary = "Connected to bridge"
        scheduleRecoverySummaryClear()
    }

    private func seedRuntimeTracking(from threads: [RemoteRuntimeThread]) {
        seenRuntimeEventIDs = Set(threads.flatMap(\.recentEvents).map(\.id))
        seenApprovalIDs = Set(threads.flatMap(\.pendingApprovals).map(\.requestId))
    }

    private func processRuntimeUpdate(previous: RemoteRuntimeThread?, current: RemoteRuntimeThread) {
        let freshApprovals = current.pendingApprovals.filter { seenApprovalIDs.insert($0.requestId).inserted }
        for approval in freshApprovals {
            let threadName = threadDisplayName(for: approval.threadId)
            let detail = approval.detail ?? "I’m waiting for approval."
            let spoken = styledAssistantMessage("I need approval for \(threadName). \(detail)", kind: .approval)
            logAssistantMessage(
                spoken,
                speak: shouldSpeakUpdate(for: approval.threadId, kind: .approval),
                forceNative: shouldForceNativeSpeech(for: approval.threadId, kind: .approval)
            )

            if notificationsEnabled {
                Task {
                    await notifications.post(
                        title: "Approval needed",
                        body: "\(threadName): \(detail)",
                        threadID: approval.threadId,
                        approvalID: approval.requestId,
                        timeSensitive: true
                    )
                }
            }
        }

        let freshEvents = current.recentEvents
            .reversed()
            .filter { seenRuntimeEventIDs.insert($0.id).inserted }

        for event in freshEvents {
            guard let message = messageForRuntimeEvent(event, threadId: current.threadId) else { continue }
            let kind = messageKind(for: event)
            let styled = styledAssistantMessage(message, kind: kind)
            logAssistantMessage(
                styled,
                speak: shouldSpeakUpdate(for: current.threadId, kind: kind),
                forceNative: shouldForceNativeSpeech(for: current.threadId, kind: kind)
            )

            if notificationsEnabled {
                let title = notificationTitle(for: event.phase)
                Task {
                    await notifications.post(
                        title: title,
                        body: message,
                        threadID: current.threadId,
                        timeSensitive: event.phase == "blocked" || event.phase == "completed"
                    )
                }
            }
        }

        if let previous, previous.phase != current.phase, current.phase == "running", current.title == "Turn started" {
            if shouldSuppressImmediateRuntimeAcknowledgement(for: current.threadId) {
                if voiceMode == .openAIRealtime,
                   realtimeCaptureActive,
                   current.threadId == commandTargetThread?.id
                {
                    realtimeCaptureSummary = "Codex is working in the active session."
                    if !realtimePlaybackActive, realtimePlaybackRequest == nil {
                        liveCommandPhase = .listening
                    }
                }
                return
            }

            let message = styledAssistantMessage("Working on it.", kind: .acknowledgement)
            logAssistantMessage(message, speak: false)
        }

        if current.phase == "completed" || current.phase == "blocked" {
            clearRecentVoiceCommandContext(for: current.threadId)
        }
    }

    private func shouldSpeakUpdate(for threadID: String, kind: CommandMessageKind) -> Bool {
        guard spokenStatusEnabled else { return false }
        if !isSceneActive {
            return shouldForceNativeSpeech(for: threadID, kind: kind)
        }
        guard let thread = threads.first(where: { $0.id == threadID }) else { return selectedThreadID == threadID }
        return selectedThreadID == threadID || thread.controller?.clientId == bridge.identity.id
    }

    private func shouldForceNativeSpeech(for threadID: String, kind: CommandMessageKind) -> Bool {
        guard spokenAlertMode == .backgroundCritical else { return false }
        guard !isSceneActive else { return false }

        switch kind {
        case .approval, .completion, .blocker:
            guard let thread = threads.first(where: { $0.id == threadID }) else { return false }
            return selectedThreadID == threadID || thread.controller?.clientId == bridge.identity.id
        default:
            return false
        }
    }

    private func threadDisplayName(for threadID: String) -> String {
        threads.first(where: { $0.id == threadID })?.name ?? "the active session"
    }

    private func priorityScore(for threadID: String) -> Int {
        switch runtimeByThreadID[threadID]?.phase {
        case "waitingApproval":
            return 5
        case "blocked":
            return 4
        case "running":
            return 3
        case "completed":
            return 2
        default:
            return 1
        }
    }

    private func commandPreferenceScore(for thread: RemoteThread) -> Int {
        var score = priorityScore(for: thread.id) * 100

        if thread.controller?.clientId == bridge.identity.id {
            score += 40
        }

        if thread.isHelmManaged {
            score += 25
        }

        if thread.sourceKind == "cli" {
            score += 10
        }

        return score
    }

    private func priorityThreadPrecedes(_ lhs: RemoteThread, _ rhs: RemoteThread) -> Bool {
        let lhsIsActive = sessionListPlacement(for: lhs) == .active
        let rhsIsActive = sessionListPlacement(for: rhs) == .active
        if lhsIsActive && rhsIsActive {
            return sessionAlphabeticalPrecedes(lhs, rhs)
        }
        if lhsIsActive != rhsIsActive {
            return lhsIsActive
        }

        let lhsScore = priorityScore(for: lhs.id)
        let rhsScore = priorityScore(for: rhs.id)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return sessionAlphabeticalPrecedes(lhs, rhs)
    }

    private func commandPreferencePrecedes(_ lhs: RemoteThread, _ rhs: RemoteThread) -> Bool {
        let lhsIsActive = sessionListPlacement(for: lhs) == .active
        let rhsIsActive = sessionListPlacement(for: rhs) == .active
        if lhsIsActive && rhsIsActive {
            return sessionAlphabeticalPrecedes(lhs, rhs)
        }
        if lhsIsActive != rhsIsActive {
            return lhsIsActive
        }

        let lhsScore = commandPreferenceScore(for: lhs)
        let rhsScore = commandPreferenceScore(for: rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return sessionAlphabeticalPrecedes(lhs, rhs)
    }

    private func preferredCommandThread(backendPreference: String?) -> RemoteThread? {
        let candidates: [RemoteThread]
        if let backendPreference {
            let filtered = threads.filter { matchesBackendPreference($0, backendPreference: backendPreference) }
            candidates = filtered.isEmpty ? threads : filtered
        } else {
            candidates = threads
        }

        return candidates.sorted(by: commandPreferencePrecedes(_:_:)).first
    }

    private func appendRealtimeEvent(title: String, detail: String?) {
        realtimeRecentEvents.insert(
            RealtimeTranscriptEvent(title: title, detail: detail, timestamp: .now),
            at: 0
        )

        if realtimeRecentEvents.count > 8 {
            realtimeRecentEvents.removeLast(realtimeRecentEvents.count - 8)
        }
    }

    private func stopSpeakingOutput() {
        openAISpeechTask?.cancel()
        openAISpeechTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Best-effort only. The audio session may already be inactive.
        }
        realtimePlaybackRequest = nil
        realtimePlaybackStopToken = UUID()
        realtimePlaybackQueue.removeAll()
        realtimeQueuedSpeechCount = 0
        realtimePlaybackActive = false
    }

    func handleRealtimePlaybackFinished() {
        realtimePlaybackActive = false
        realtimePlaybackRequest = nil
        dispatchNextRealtimeSpeechIfNeeded()
        if realtimeCaptureActive && realtimePlaybackRequest == nil {
            liveCommandPhase = .listening
        }
        if !isSceneActive {
            scheduleBackgroundSuspendIfNeeded()
        }
    }

    func handleRealtimePlaybackInterrupted() {
        realtimePlaybackActive = false
        realtimePlaybackRequest = nil
        realtimePlaybackQueue.removeAll()
        realtimeQueuedSpeechCount = 0
        if realtimeCaptureActive {
            liveCommandPhase = .listening
        }
        if !isSceneActive {
            scheduleBackgroundSuspendIfNeeded()
        }
    }

    private func speakWithOpenAI(_ text: String) async {
        do {
            prepareNativeSpeechSession()
            let audio = try await bridge.fetchSpeechAudio(
                text: text,
                threadID: commandTargetThread?.id,
                backendID: commandTargetBackendSummary?.id,
                voiceProviderID: effectiveVoiceProvider?.id,
                style: commandResponseStyle
            )
            if Task.isCancelled { return }

            let player = try AVAudioPlayer(data: audio)
            player.prepareToPlay()
            audioPlayer = player
            player.play()
        } catch {
            if Task.isCancelled { return }

            prepareNativeSpeechSession()
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = 0.48
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            audioPlayer = nil
            synthesizer.speak(utterance)
        }
    }

    private func handleApprovalActionFromNotification(
        approvalID: String,
        decision: String,
        threadID: String?
    ) async {
        if let threadID {
            selectThread(threadID)
        }

        do {
            try await bridge.decideApproval(approvalID: approvalID, decision: decision)
            await refreshThreads()
            await refreshRuntime()
            await refreshSelectedThreadDetail()
            selectedSection = .sessions

            let confirmation =
                decision == "accept"
                ? styledAssistantMessage("I approved that request.", kind: .acknowledgement)
                : styledAssistantMessage("I declined that request.", kind: .acknowledgement)
            logAssistantMessage(confirmation, speak: false)
        } catch {
            let failure = styledAssistantMessage(
                bridge.lastError ?? "I couldn't respond to that approval.",
                kind: .failure
            )
            logAssistantMessage(failure, speak: false)
        }
    }

    private func logAssistantMessage(_ text: String, speak shouldSpeak: Bool, forceNative: Bool = false) {
        appendVoiceEntry(.init(role: .assistant, text: text, timestamp: .now))
        if shouldSpeak {
            speak(text, forceNative: forceNative)
        }
    }

    private func ensureLiveCommandIfNeeded() async {
        guard voiceMode == .openAIRealtime else { return }
        guard !realtimeCaptureActive else { return }
        await startRealtimeCapture()
    }

    private func handleCommandTargetChange(from previousThreadID: String?, to nextThreadID: String?) {
        guard previousThreadID != nextThreadID else { return }

        clearRecentVoiceCommandContext(for: previousThreadID)

        realtimeBootstrap = nil
        realtimeBootstrapRefreshTask?.cancel()

        guard voiceMode == .openAIRealtime else { return }

        if realtimeCaptureActive {
            stopSpeakingOutput()
            realtimeTranscriptPreview = ""
            realtimePlaybackStopToken = UUID()
            realtimeCaptureSummary = "Command target changed. Reattaching Live Command."
            liveCommandPhase = .retargeting
            appendRealtimeEvent(
                title: "Target Changed",
                detail: "Live Command is reattaching to the new shared session."
            )
            Task {
                await prepareRealtimeSession()
            }
        } else {
            realtimeStatusSummary = "Command target changed. Refreshing Realtime for the new session."
        }
    }

    private func scheduleSelectedThreadDetailRefresh(
        delay: Duration = .milliseconds(20),
        allowBridgeOpen: Bool = false,
        force: Bool = false
    ) {
        detailRefreshTask?.cancel()
        detailRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.refreshSelectedThreadDetail(allowBridgeOpen: allowBridgeOpen, force: force)
        }
    }

    private func restartSelectedThreadDetailLiveRefreshLoop() {
        selectedThreadDetailLiveRefreshTask?.cancel()
        selectedThreadDetailLiveRefreshTask = nil

        guard isSceneActive, selectedThreadID != nil else { return }

        selectedThreadDetailLiveRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .milliseconds(Self.activeSelectedThreadDetailRefreshMS))

            while !Task.isCancelled {
                guard self.isSceneActive, let threadID = self.selectedThreadID else { return }
                await self.refreshThreadDetail(threadID: threadID)

                let delay = self.selectedThreadLiveRefreshDelay(for: threadID)
                try? await Task.sleep(for: delay)
            }
        }
    }

    private func stopSelectedThreadDetailLiveRefreshLoop() {
        selectedThreadDetailLiveRefreshTask?.cancel()
        selectedThreadDetailLiveRefreshTask = nil
    }

    private func selectedThreadLiveRefreshDelay(for threadID: String) -> Duration {
        let delayMS = Self.selectedThreadLiveRefreshDelayMS(
            threadStatus: thread(for: threadID)?.status ?? threadDetailByID[threadID]?.status,
            runtimePhase: runtimeByThreadID[threadID]?.phase,
            hasPendingOutgoingTurns: pendingOutgoingTurnsByThreadID[threadID]?.isEmpty == false
        )
        return .milliseconds(delayMS)
    }

    nonisolated static func selectedThreadLiveRefreshDelayMS(
        threadStatus: String?,
        runtimePhase: String?,
        hasPendingOutgoingTurns: Bool
    ) -> Int {
        if hasPendingOutgoingTurns {
            return activeSelectedThreadDetailRefreshMS
        }

        let activeTokens: [String] = [
            "running",
            "thinking",
            "working",
            "reading",
            "pending",
            "waiting",
            "executing",
        ]
        let normalizedStatus = threadStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedPhase = runtimePhase?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if activeTokens.contains(where: { normalizedStatus.contains($0) || normalizedPhase.contains($0) }) {
            return activeSelectedThreadDetailRefreshMS
        }

        return idleSelectedThreadDetailRefreshMS
    }

    nonisolated static func selectedThreadIDAfterFetch(
        current: String?,
        persisted: String?,
        visibleThreadIDs: Set<String>,
        preservedThreadIDs: Set<String>,
        preferred: String?
    ) -> String? {
        if let current,
           visibleThreadIDs.contains(current) || preservedThreadIDs.contains(current) {
            return current
        }

        if let persisted,
           visibleThreadIDs.contains(persisted) || preservedThreadIDs.contains(persisted) {
            return persisted
        }

        return preferred
    }

    private func schedulePendingOutgoingTurnRefresh(for threadID: String, extended: Bool = false) {
        pendingOutgoingTurnRefreshTasksByThreadID[threadID]?.cancel()
        pendingOutgoingTurnRefreshTasksByThreadID[threadID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.pendingOutgoingTurnRefreshTasksByThreadID.removeValue(forKey: threadID)
            }

            let shortDelays: [Duration] = [
                .milliseconds(50),
                .milliseconds(150),
                .milliseconds(350),
                .milliseconds(800),
                .milliseconds(1_600),
            ]
            let extendedDelays: [Duration] = shortDelays + [
                .seconds(6),
                .seconds(12),
                .seconds(24),
                .seconds(45),
                .seconds(90),
                .seconds(150),
            ]
            let delays = extended ? extendedDelays : shortDelays

            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                guard let pending = self.pendingOutgoingTurnsByThreadID[threadID], !pending.isEmpty else { return }
                await self.refreshThreadDetail(threadID: threadID)
            }
        }
    }

    private func scheduleRealtimeBootstrapRefreshIfNeeded() {
        realtimeBootstrapRefreshTask?.cancel()
        guard let expiresAt = realtimeBootstrap?.expiresAt else { return }

        let refreshDate = Date(timeIntervalSince1970: expiresAt).addingTimeInterval(-60)
        let interval = refreshDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        realtimeBootstrapRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            guard self.voiceMode == .openAIRealtime else { return }
            await self.prepareRealtimeSession()
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

            startHeartbeatLoop()
            restartSelectedThreadDetailLiveRefreshLoop()
            if !bridgeRealtimeConnected {
                connectRealtime()
            }

            if shouldRefresh {
                await refreshSessionSnapshot()
            }
            return
        }

        scheduleBackgroundSuspendIfNeeded()
    }

    private func scheduleBackgroundSuspendIfNeeded() {
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        detailRefreshTask?.cancel()
        detailRefreshTask = nil
        stopSelectedThreadDetailLiveRefreshLoop()

        let shouldDelaySuspend = realtimeCaptureActive || realtimePlaybackActive || realtimePlaybackRequest != nil
        if !shouldDelaySuspend {
            suspendLiveServices(reason: "helm paused live services in the background.", stopPlayback: true)
            return
        }

        backgroundSuspendTask?.cancel()
        backgroundSuspendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            guard !self.isSceneActive else { return }
            self.suspendLiveServices(
                reason: "helm paused live services after background grace period.",
                stopPlayback: true
            )
        }
    }

    private func suspendLiveServices(reason: String, stopPlayback: Bool) {
        backgroundSuspendTask?.cancel()
        backgroundSuspendTask = nil
        realtimeReconnectTask?.cancel()
        realtimeReconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopSelectedThreadDetailLiveRefreshLoop()
        bridge.disconnectRealtime()
        bridgeRealtimeConnected = false

        if stopPlayback {
            stopSpeakingOutput()
            realtimeCaptureActive = false
            realtimeCaptureSummary = reason
            realtimeTranscriptPreview = ""
        } else {
            realtimeCaptureSummary = reason
        }
    }

    private func adoptThreadReplacement(from retiredThreadID: String, to canonicalThreadID: String) {
        guard retiredThreadID != canonicalThreadID else { return }

        if selectedThreadID == retiredThreadID {
            selectedThreadID = canonicalThreadID
            UserDefaults.standard.set(canonicalThreadID, forKey: selectedThreadDefaultsKey)
        }
        if pendingBridgeOpenThreadID == retiredThreadID {
            pendingBridgeOpenThreadID = nil
        }
        if let dismissedMarker = dismissedActiveThreadMarkers.removeValue(forKey: retiredThreadID) {
            dismissedActiveThreadMarkers[canonicalThreadID] = dismissedMarker
            persistDismissedActiveThreadMarkers()
        }
        if archivedThreadIDs.remove(retiredThreadID) != nil {
            archivedThreadIDs.insert(canonicalThreadID)
            persistArchivedThreadIDs()
        }

        if let pending = pendingOutgoingTurnsByThreadID.removeValue(forKey: retiredThreadID),
           !pending.isEmpty {
            pendingOutgoingTurnsByThreadID[canonicalThreadID, default: []].append(contentsOf: pending)
        }

        if let task = pendingOutgoingTurnRefreshTasksByThreadID.removeValue(forKey: retiredThreadID) {
            task.cancel()
            if let pending = pendingOutgoingTurnsByThreadID[canonicalThreadID], !pending.isEmpty {
                schedulePendingOutgoingTurnRefresh(for: canonicalThreadID)
            }
        }

        if let detail = threadDetailByID.removeValue(forKey: retiredThreadID),
           threadDetailByID[canonicalThreadID] == nil {
            threadDetailByID[canonicalThreadID] = detail
        }

        if let error = threadDetailErrorByID.removeValue(forKey: retiredThreadID),
           threadDetailErrorByID[canonicalThreadID] == nil {
            threadDetailErrorByID[canonicalThreadID] = error
        }

        runtimeByThreadID.removeValue(forKey: retiredThreadID)

        if let existingIndex = threads.firstIndex(where: { $0.id == retiredThreadID }) {
            threads.remove(at: existingIndex)
        }
    }

    private func applyThreadsSnapshot(_ fetchedThreads: [RemoteThread]) {
        let mergedThreads = mergedThreadSnapshot(fetchedThreads)
        if threads != mergedThreads {
            threads = mergedThreads
        }
        rememberStableThreadTitles(from: mergedThreads)
        refreshDismissedActiveSessions()
        refreshArchivedThreads()
        pruneStaleThreadDetails(keeping: Set(mergedThreads.map(\.id)))
    }

    private func applyArchivedThreadsSnapshot(_ fetchedArchivedThreads: [RemoteThread]) {
        let mergedThreads = orderedUniqueThreads(fetchedArchivedThreads)
            .sorted(by: sessionActivityPrecedes(_:_:))
        if archivedThreads != mergedThreads {
            archivedThreads = mergedThreads
        }
        rememberStableThreadTitles(from: mergedThreads)
    }

    private func promoteArchivedThreadLocally(_ threadID: String) {
        guard let archivedIndex = archivedThreads.firstIndex(where: { $0.id == threadID }) else {
            return
        }

        let thread = archivedThreads.remove(at: archivedIndex)
        if !threads.contains(where: { $0.id == threadID }) {
            threads.append(thread)
            threads.sort(by: sessionActivityPrecedes(_:_:))
        }
    }

    private func applyRuntimeSnapshot(_ runtimeThreads: [RemoteRuntimeThread]) {
        let deduplicatedRuntimeThreads = Self.deduplicatedRuntimeThreadsByID(runtimeThreads)
        let snapshot = Dictionary(uniqueKeysWithValues: deduplicatedRuntimeThreads.map { ($0.threadId, $0) })
        if runtimeByThreadID != snapshot {
            runtimeByThreadID = snapshot
        }
        refreshDismissedActiveSessions()
        seedRuntimeTracking(from: deduplicatedRuntimeThreads)
    }

    private func applyThreadDetail(_ detail: RemoteThreadDetail?, for threadID: String) {
        if let detail {
            let incomingIsLiveTailOnly = Self.isLiveTailOnlyDetailUpdate(detail)
            if let existing = threadDetailByID[threadID],
               let merged = Self.mergedPlaceholderDetail(existing, with: detail) {
                if threadDetailByID[threadID] != merged {
                    threadDetailByID[threadID] = merged
                }
                threadDetailErrorByID.removeValue(forKey: threadID)
                mergeThreadSummary(from: merged, preserveCurrentListSummary: true)
                return
            }
            if let existing = threadDetailByID[threadID],
               let merged = Self.mergedLiveTailDetail(existing, with: detail) {
                if threadDetailByID[threadID] != merged {
                    threadDetailByID[threadID] = merged
                }
                threadDetailErrorByID.removeValue(forKey: threadID)
                mergeThreadSummary(from: merged, preserveCurrentListSummary: incomingIsLiveTailOnly)
                return
            }
            if let existing = threadDetailByID[threadID],
               let merged = Self.mergedPartialCodexAppDetail(existing, with: detail) {
                if threadDetailByID[threadID] != merged {
                    threadDetailByID[threadID] = merged
                }
                threadDetailErrorByID.removeValue(forKey: threadID)
                mergeThreadSummary(from: merged)
                return
            }

            if threadDetailByID[threadID] != detail {
                threadDetailByID[threadID] = detail
            }
            threadDetailErrorByID.removeValue(forKey: threadID)
            mergeThreadSummary(from: detail, preserveCurrentListSummary: incomingIsLiveTailOnly)
            return
        }

        if threadDetailByID[threadID] != nil {
            threadDetailByID.removeValue(forKey: threadID)
        }
    }

    nonisolated static func mergedPlaceholderDetail(
        _ existing: RemoteThreadDetail,
        with incoming: RemoteThreadDetail
    ) -> RemoteThreadDetail? {
        guard incoming.turns.isEmpty, !existing.turns.isEmpty else {
            return nil
        }

        return RemoteThreadDetail(
            id: incoming.id,
            name: preferredNonEmpty(incoming.name, existing.name),
            cwd: preferredNonEmpty(incoming.cwd, existing.cwd) ?? existing.cwd,
            workspacePath: preferredNonEmpty(incoming.workspacePath, existing.workspacePath),
            status: incoming.status,
            updatedAt: max(existing.updatedAt, incoming.updatedAt),
            sourceKind: preferredNonEmpty(incoming.sourceKind, existing.sourceKind),
            launchSource: preferredNonEmpty(incoming.launchSource, existing.launchSource),
            backendId: preferredNonEmpty(incoming.backendId, existing.backendId),
            backendLabel: preferredNonEmpty(incoming.backendLabel, existing.backendLabel),
            backendKind: preferredNonEmpty(incoming.backendKind, existing.backendKind),
            command: incoming.command ?? existing.command,
            affordances: incoming.affordances ?? existing.affordances,
            turns: existing.turns
        )
    }

    nonisolated static func mergedLiveTailDetail(
        _ existing: RemoteThreadDetail,
        with incoming: RemoteThreadDetail
    ) -> RemoteThreadDetail? {
        guard existing.turns.contains(where: { !$0.id.hasPrefix("live-tail-") }),
              incoming.turns.count == 1,
              let liveTailTurn = incoming.turns.first,
              liveTailTurn.id.hasPrefix("live-tail-")
        else {
            return nil
        }

        let preservedTurns = existing.turns.filter { !$0.id.hasPrefix("live-tail-") }
        let mergedTurns = [liveTailTurn] + preservedTurns

        return RemoteThreadDetail(
            id: incoming.id,
            name: preferredNonEmpty(incoming.name, existing.name),
            cwd: preferredNonEmpty(incoming.cwd, existing.cwd) ?? incoming.cwd,
            workspacePath: preferredNonEmpty(incoming.workspacePath, existing.workspacePath),
            status: incoming.status,
            updatedAt: max(existing.updatedAt, incoming.updatedAt),
            sourceKind: preferredNonEmpty(incoming.sourceKind, existing.sourceKind),
            launchSource: preferredNonEmpty(incoming.launchSource, existing.launchSource),
            backendId: preferredNonEmpty(incoming.backendId, existing.backendId),
            backendLabel: preferredNonEmpty(incoming.backendLabel, existing.backendLabel),
            backendKind: preferredNonEmpty(incoming.backendKind, existing.backendKind),
            command: incoming.command ?? existing.command,
            affordances: incoming.affordances ?? existing.affordances,
            turns: mergedTurns
        )
    }

    nonisolated static func mergedPartialCodexAppDetail(
        _ existing: RemoteThreadDetail,
        with incoming: RemoteThreadDetail
    ) -> RemoteThreadDetail? {
        guard existing.id == incoming.id,
              isCodexAppBackedDetail(existing, incoming),
              !existing.turns.isEmpty,
              !incoming.turns.isEmpty,
              incoming.turns.count < existing.turns.count,
              !incoming.turns.allSatisfy({ $0.id.hasPrefix("live-tail-") })
        else {
            return nil
        }

        var mergedTurns = existing.turns
        for incomingTurn in incoming.turns {
            if let index = mergedTurns.firstIndex(where: { $0.id == incomingTurn.id }) {
                mergedTurns[index] = incomingTurn
            } else {
                mergedTurns.append(incomingTurn)
            }
        }

        guard mergedTurns.count > incoming.turns.count else {
            return nil
        }

        return RemoteThreadDetail(
            id: incoming.id,
            name: preferredNonEmpty(incoming.name, existing.name),
            cwd: preferredNonEmpty(incoming.cwd, existing.cwd) ?? existing.cwd,
            workspacePath: preferredNonEmpty(incoming.workspacePath, existing.workspacePath),
            status: incoming.status,
            updatedAt: max(existing.updatedAt, incoming.updatedAt),
            sourceKind: preferredNonEmpty(incoming.sourceKind, existing.sourceKind),
            launchSource: preferredNonEmpty(incoming.launchSource, existing.launchSource),
            backendId: preferredNonEmpty(incoming.backendId, existing.backendId),
            backendLabel: preferredNonEmpty(incoming.backendLabel, existing.backendLabel),
            backendKind: preferredNonEmpty(incoming.backendKind, existing.backendKind),
            command: incoming.command ?? existing.command,
            affordances: incoming.affordances ?? existing.affordances,
            turns: mergedTurns
        )
    }

    nonisolated private static func isCodexAppBackedDetail(
        _ lhs: RemoteThreadDetail,
        _ rhs: RemoteThreadDetail
    ) -> Bool {
        let sourceKind = preferredNonEmpty(rhs.sourceKind, lhs.sourceKind)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard sourceKind == "vscode" || sourceKind == "appserver" else {
            return false
        }

        let backendId = preferredNonEmpty(rhs.backendId, lhs.backendId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let backendKind = preferredNonEmpty(rhs.backendKind, lhs.backendKind)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return backendId == "codex" || backendKind == "codex"
    }

    nonisolated static func isLiveTailOnlyDetailUpdate(_ detail: RemoteThreadDetail) -> Bool {
        guard !detail.turns.isEmpty else { return false }
        return detail.turns.allSatisfy { $0.id.hasPrefix("live-tail-") }
    }

    nonisolated static func deduplicatedThreadsByID(_ threads: [RemoteThread]) -> [RemoteThread] {
        var result: [RemoteThread] = []
        var indexByID: [String: Int] = [:]

        for thread in threads {
            if let index = indexByID[thread.id] {
                if threadShouldReplaceDuplicate(thread, current: result[index]) {
                    result[index] = thread
                }
            } else {
                indexByID[thread.id] = result.count
                result.append(thread)
            }
        }

        return result
    }

    nonisolated static func deduplicatedRuntimeThreadsByID(_ runtimeThreads: [RemoteRuntimeThread]) -> [RemoteRuntimeThread] {
        var result: [RemoteRuntimeThread] = []
        var indexByThreadID: [String: Int] = [:]

        for runtimeThread in runtimeThreads {
            if let index = indexByThreadID[runtimeThread.threadId] {
                if runtimeThreadShouldReplaceDuplicate(runtimeThread, current: result[index]) {
                    result[index] = runtimeThread
                }
            } else {
                indexByThreadID[runtimeThread.threadId] = result.count
                result.append(runtimeThread)
            }
        }

        return result
    }

    nonisolated private static func threadShouldReplaceDuplicate(_ candidate: RemoteThread, current: RemoteThread) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }

        let candidateScore = duplicateThreadCompletenessScore(candidate)
        let currentScore = duplicateThreadCompletenessScore(current)
        if candidateScore != currentScore {
            return candidateScore > currentScore
        }

        return true
    }

    nonisolated private static func runtimeThreadShouldReplaceDuplicate(
        _ candidate: RemoteRuntimeThread,
        current: RemoteRuntimeThread
    ) -> Bool {
        if candidate.lastUpdatedAt != current.lastUpdatedAt {
            return candidate.lastUpdatedAt > current.lastUpdatedAt
        }

        let candidateScore = candidate.pendingApprovals.count + candidate.recentEvents.count
        let currentScore = current.pendingApprovals.count + current.recentEvents.count
        if candidateScore != currentScore {
            return candidateScore > currentScore
        }

        return true
    }

    nonisolated private static func duplicateThreadCompletenessScore(_ thread: RemoteThread) -> Int {
        [
            thread.name,
            thread.preview,
            thread.cwd,
            thread.workspacePath,
            thread.status,
            thread.sourceKind,
            thread.launchSource,
            thread.backendId,
            thread.backendLabel,
            thread.backendKind,
            thread.controller?.clientId,
        ].reduce(0) { score, value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return score + (trimmed.isEmpty ? 0 : 1)
        }
    }

    nonisolated static func shouldPreserveListSummaryForLiveTailChurn(
        incomingPreview: String,
        currentThread: RemoteThread?,
        detail: RemoteThreadDetail?
    ) -> Bool {
        guard let currentThread,
              let detail,
              detail.turns.contains(where: { $0.id.hasPrefix("live-tail-") })
        else {
            return false
        }

        let preview = incomingPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return true }
        return preview == currentThread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func shouldPreserveListSummaryForRunningChurn(
        incomingStatus: String,
        currentThread: RemoteThread?
    ) -> Bool {
        guard let currentThread else { return false }
        let currentPreview = currentThread.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentPreview.isEmpty else { return false }

        switch incomingStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "running":
            return true
        default:
            return false
        }
    }

    nonisolated static func stabilizedThreadSnapshot(
        incoming: RemoteThread,
        currentThread: RemoteThread?,
        detail: RemoteThreadDetail?,
        stableTitle: String?
    ) -> RemoteThread {
        let preserveCurrentSummary = shouldPreserveListSummaryForLiveTailChurn(
            incomingPreview: incoming.preview,
            currentThread: currentThread,
            detail: detail
        ) || shouldPreserveListSummaryForRunningChurn(
            incomingStatus: incoming.status,
            currentThread: currentThread
        )
        let stableName = preferredNonEmpty(
            incoming.name,
            currentThread?.name,
            detail?.name,
            stableTitle
        )
        let stablePreview: String
        if preserveCurrentSummary {
            stablePreview = preferredNonEmpty(
                currentThread?.preview,
                incoming.preview
            ) ?? incoming.preview
        } else {
            stablePreview = preferredNonEmpty(
                incoming.preview,
                currentThread?.preview
            ) ?? incoming.preview
        }
        let stableCWD = preferredNonEmpty(
            incoming.cwd,
            currentThread?.cwd,
            detail?.cwd
        ) ?? incoming.cwd
        let stableWorkspacePath = preferredNonEmpty(
            incoming.workspacePath,
            currentThread?.workspacePath,
            detail?.workspacePath
        )
        let stableStatus = preferredNonEmpty(incoming.status, currentThread?.status) ?? incoming.status
        let stableSourceKind = preferredNonEmpty(
            incoming.sourceKind,
            currentThread?.sourceKind,
            detail?.sourceKind
        )
        let stableLaunchSource = preferredNonEmpty(
            incoming.launchSource,
            currentThread?.launchSource,
            detail?.launchSource
        )
        let stableBackendID = preferredNonEmpty(
            incoming.backendId,
            currentThread?.backendId,
            detail?.backendId
        )
        let stableBackendLabel = preferredNonEmpty(
            incoming.backendLabel,
            currentThread?.backendLabel,
            detail?.backendLabel
        )
        let stableBackendKind = preferredNonEmpty(
            incoming.backendKind,
            currentThread?.backendKind,
            detail?.backendKind
        )

        return RemoteThread(
            id: incoming.id,
            name: stableName,
            preview: stablePreview,
            cwd: stableCWD,
            workspacePath: stableWorkspacePath,
            status: stableStatus,
            updatedAt: preserveCurrentSummary
                ? currentThread?.updatedAt ?? incoming.updatedAt
                : max(incoming.updatedAt, currentThread?.updatedAt ?? incoming.updatedAt),
            sourceKind: stableSourceKind,
            launchSource: stableLaunchSource,
            backendId: stableBackendID,
            backendLabel: stableBackendLabel,
            backendKind: stableBackendKind,
            controller: incoming.controller ?? currentThread?.controller
        )
    }

    nonisolated static func stabilizedThreadSummary(
        detail: RemoteThreadDetail,
        detailPreview: String?,
        currentThread: RemoteThread?,
        stableTitle: String?,
        preserveCurrentListSummary: Bool = false
    ) -> RemoteThread {
        let preserveCurrentSummary = currentThread != nil && (
            preserveCurrentListSummary ||
                shouldPreserveListSummaryForLiveTailChurn(
                    incomingPreview: detailPreview ?? "",
                    currentThread: currentThread,
                    detail: detail
                ) ||
                shouldPreserveListSummaryForRunningChurn(
                    incomingStatus: detail.status,
                    currentThread: currentThread
                )
        )
        let stableName = preferredNonEmpty(
            detail.name,
            currentThread?.name,
            stableTitle
        )
        let stablePreview: String
        if preserveCurrentSummary {
            stablePreview = preferredNonEmpty(
                currentThread?.preview,
                detailPreview
            ) ?? "Codex CLI session"
        } else {
            stablePreview = preferredNonEmpty(
                detailPreview,
                currentThread?.preview
            ) ?? "Codex CLI session"
        }
        let stableCWD = preferredNonEmpty(detail.cwd, currentThread?.cwd) ?? detail.cwd
        let stableWorkspacePath = preferredNonEmpty(detail.workspacePath, currentThread?.workspacePath)
        let stableStatus = preferredNonEmpty(detail.status, currentThread?.status) ?? detail.status
        let stableSourceKind = preferredNonEmpty(detail.sourceKind, currentThread?.sourceKind)
        let stableLaunchSource = preferredNonEmpty(detail.launchSource, currentThread?.launchSource)
        let stableBackendID = preferredNonEmpty(detail.backendId, currentThread?.backendId)
        let stableBackendLabel = preferredNonEmpty(detail.backendLabel, currentThread?.backendLabel)
        let stableBackendKind = preferredNonEmpty(detail.backendKind, currentThread?.backendKind)
        let stableUpdatedAt: Double
        if preserveCurrentSummary, let currentThread {
            stableUpdatedAt = currentThread.updatedAt
        } else {
            stableUpdatedAt = max(detail.updatedAt, currentThread?.updatedAt ?? detail.updatedAt)
        }

        return RemoteThread(
            id: detail.id,
            name: stableName,
            preview: stablePreview,
            cwd: stableCWD,
            workspacePath: stableWorkspacePath,
            status: stableStatus,
            updatedAt: stableUpdatedAt,
            sourceKind: stableSourceKind,
            launchSource: stableLaunchSource,
            backendId: stableBackendID,
            backendLabel: stableBackendLabel,
            backendKind: stableBackendKind,
            controller: currentThread?.controller
        )
    }

    private func pruneStaleThreadDetails(keeping activeThreadIDs: Set<String>) {
        let staleThreadIDs = threadDetailByID.keys.filter { !activeThreadIDs.contains($0) }
        guard !staleThreadIDs.isEmpty else { return }
        for threadID in staleThreadIDs {
            threadDetailByID.removeValue(forKey: threadID)
            threadDetailErrorByID.removeValue(forKey: threadID)
            threadDetailRefreshTasksByID[threadID]?.cancel()
            threadDetailRefreshTasksByID.removeValue(forKey: threadID)
            pendingOutgoingTurnsByThreadID.removeValue(forKey: threadID)
            pendingOutgoingTurnRefreshTasksByThreadID[threadID]?.cancel()
            pendingOutgoingTurnRefreshTasksByThreadID.removeValue(forKey: threadID)
        }
    }

    private func mergeThreadSummary(
        from detail: RemoteThreadDetail,
        preserveCurrentListSummary: Bool = false
    ) {
        rememberStableThreadTitle(from: detail)
        let current = threads.first(where: { $0.id == detail.id })
        let detailPreview = threadPreview(from: detail)
        let shouldPreserveCurrentSummary = preserveCurrentListSummary || Self.shouldPreserveListSummaryForLiveTailChurn(
            incomingPreview: detailPreview ?? "",
            currentThread: current,
            detail: detail
        )
        let updated = threadSummary(
            for: detail.id,
            currentThread: current,
            preserveCurrentListSummary: shouldPreserveCurrentSummary
        ) ?? current
        guard let updated else { return }
        if let index = threads.firstIndex(where: { $0.id == detail.id }) {
            guard threads[index] != updated else { return }
            threads[index] = updated
        } else {
            threads.append(updated)
        }
        threads.sort { $0.updatedAt > $1.updatedAt }
        refreshDismissedActiveSessions()
    }

    private func mergedThreadSnapshot(_ fetchedThreads: [RemoteThread]) -> [RemoteThread] {
        let deduplicatedFetchedThreads = Self.deduplicatedThreadsByID(fetchedThreads)
        var mergedByID = Dictionary(uniqueKeysWithValues: deduplicatedFetchedThreads.map { thread in
            let current = threads.first(where: { $0.id == thread.id })
            return (thread.id, threadByPreservingStableFields(thread, currentThread: current))
        })

        let preservedThreadIDs =
            Set([selectedThreadID].compactMap { $0 })
            .union(threadDetailByID.keys)
            .union(runtimeByThreadID.keys)
            .union(pendingOutgoingTurnsByThreadID.compactMap { key, turns in
                turns.isEmpty ? nil : key
            })

        for threadID in preservedThreadIDs where mergedByID[threadID] == nil {
            guard shouldPreserveThreadSummary(threadID) else { continue }
            let current = threads.first(where: { $0.id == threadID })
            if let preserved = threadSummary(for: threadID, currentThread: current) {
                mergedByID[threadID] = preserved
            }
        }

        return mergedByID.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private func shouldPreserveThreadSummary(_ threadID: String) -> Bool {
        if selectedThreadID == threadID {
            return true
        }

        if let pendingTurns = pendingOutgoingTurnsByThreadID[threadID], !pendingTurns.isEmpty {
            return true
        }

        if let runtime = runtimeByThreadID[threadID] {
            if runtime.phase != "unknown" && runtime.phase != "idle" {
                return true
            }

            if !runtime.pendingApprovals.isEmpty || !runtime.recentEvents.isEmpty {
                return true
            }
        }

        return threadDetailByID[threadID] != nil
    }

    private func threadByPreservingStableFields(
        _ thread: RemoteThread,
        currentThread: RemoteThread?
    ) -> RemoteThread {
        let stabilized = Self.stabilizedThreadSnapshot(
            incoming: thread,
            currentThread: currentThread,
            detail: threadDetailByID[thread.id],
            stableTitle: stableThreadTitlesByID[thread.id]
        )
        return threadByFreezingLiveListPreviewIfNeeded(stabilized, currentThread: currentThread)
    }

    private func threadByFreezingLiveListPreviewIfNeeded(
        _ thread: RemoteThread,
        currentThread: RemoteThread?
    ) -> RemoteThread {
        guard shouldFreezeListPreview(for: thread.id, currentThread: currentThread) else {
            return thread
        }
        guard let currentPreview = nonEmpty(currentThread?.preview) else {
            return thread
        }
        guard thread.preview != currentPreview || thread.updatedAt != currentThread?.updatedAt else {
            return thread
        }
        return RemoteThread(
            id: thread.id,
            name: thread.name,
            preview: currentPreview,
            cwd: thread.cwd,
            workspacePath: thread.workspacePath,
            status: thread.status,
            updatedAt: currentThread?.updatedAt ?? thread.updatedAt,
            sourceKind: thread.sourceKind,
            launchSource: thread.launchSource,
            backendId: thread.backendId,
            backendLabel: thread.backendLabel,
            backendKind: thread.backendKind,
            controller: thread.controller
        )
    }

    private func shouldFreezeListPreview(for threadID: String, currentThread: RemoteThread?) -> Bool {
        guard currentThread != nil else { return false }
        guard let phase = runtimeByThreadID[threadID]?.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return phase != "idle" && phase != "unknown" && phase != "completed"
    }

    private func rememberStableThreadTitles(from threads: [RemoteThread]) {
        for thread in threads {
            rememberStableThreadTitle(from: thread)
        }
    }

    private func rememberStableThreadTitle(from thread: RemoteThread) {
        guard let title = nonEmpty(thread.name) else { return }
        stableThreadTitlesByID[thread.id] = title
    }

    private func rememberStableThreadTitle(from detail: RemoteThreadDetail) {
        guard let title = nonEmpty(detail.name) else { return }
        stableThreadTitlesByID[detail.id] = title
    }

    private func stableThreadTitle(for threadID: String) -> String? {
        if let title = nonEmpty(thread(for: threadID)?.name) {
            stableThreadTitlesByID[threadID] = title
            return title
        }

        if let title = nonEmpty(threadDetail(for: threadID)?.name) {
            stableThreadTitlesByID[threadID] = title
            return title
        }

        return stableThreadTitlesByID[threadID]
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stableThreadWorkspace(for thread: RemoteThread) -> String {
        let workspace = thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !workspace.isEmpty {
            return workspace
        }

        return thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stableDetailWorkspace(for detail: RemoteThreadDetail) -> String {
        let workspace = detail.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !workspace.isEmpty {
            return workspace
        }

        return detail.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayPathComponent(for path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }

        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
    }

    private func shortThreadID(_ id: String) -> String {
        String(id.suffix(5)).uppercased()
    }

    private func threadSummary(
        for threadID: String,
        currentThread: RemoteThread?,
        preserveCurrentListSummary: Bool = false
    ) -> RemoteThread? {
        if let detail = threadDetailByID[threadID] {
            let stabilized = Self.stabilizedThreadSummary(
                detail: detail,
                detailPreview: threadPreview(from: detail),
                currentThread: currentThread,
                stableTitle: stableThreadTitlesByID[threadID],
                preserveCurrentListSummary: preserveCurrentListSummary
            )
            return threadByFreezingLiveListPreviewIfNeeded(stabilized, currentThread: currentThread)
        }

        return currentThread
    }

    nonisolated private static func preferredNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func refreshDismissedActiveSessions() {
        guard !dismissedActiveThreadMarkers.isEmpty else { return }

        let threadsByID = Dictionary(uniqueKeysWithValues: Self.deduplicatedThreadsByID(threads).map { ($0.id, $0) })
        var updatedMarkers = dismissedActiveThreadMarkers
        var changed = false

        for (threadID, dismissedMarker) in dismissedActiveThreadMarkers {
            guard let thread = threadsByID[threadID] else {
                // Missing here can be a stale bridge/list reload gap; keep the marker so an
                // active-to-recent demotion persists if that session reappears unchanged.
                continue
            }

            if !threadWouldAppearActive(thread) || activityMarker(for: thread) > dismissedMarker {
                updatedMarkers.removeValue(forKey: threadID)
                changed = true
            }
        }

        guard changed else { return }
        dismissedActiveThreadMarkers = updatedMarkers
        persistDismissedActiveThreadMarkers()
    }

    private func restoreSessionToDefaultPlacement(_ threadID: String) {
        clearDismissedActiveMarker(threadID)
    }

    private func clearDismissedActiveMarker(_ threadID: String) {
        guard dismissedActiveThreadMarkers.removeValue(forKey: threadID) != nil else { return }
        persistDismissedActiveThreadMarkers()
    }

    private func archiveThreadLocally(_ threadID: String) {
        archivedThreadIDs.insert(threadID)
        persistArchivedThreadIDs()
    }

    private func applyThreadNameLocally(_ name: String, to threadID: String) {
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            let thread = threads[index]
            threads[index] = RemoteThread(
                id: thread.id,
                name: name,
                preview: thread.preview,
                cwd: thread.cwd,
                workspacePath: thread.workspacePath,
                status: thread.status,
                updatedAt: thread.updatedAt,
                sourceKind: thread.sourceKind,
                launchSource: thread.launchSource,
                backendId: thread.backendId,
                backendLabel: thread.backendLabel,
                backendKind: thread.backendKind,
                controller: thread.controller
            )
        }

        if let detail = threadDetailByID[threadID] {
            threadDetailByID[threadID] = RemoteThreadDetail(
                id: detail.id,
                name: name,
                cwd: detail.cwd,
                workspacePath: detail.workspacePath,
                status: detail.status,
                updatedAt: detail.updatedAt,
                sourceKind: detail.sourceKind,
                launchSource: detail.launchSource,
                backendId: detail.backendId,
                backendLabel: detail.backendLabel,
                backendKind: detail.backendKind,
                command: detail.command,
                affordances: detail.affordances,
                turns: detail.turns
            )
        }
    }

    private func unarchiveThreadLocally(_ threadID: String) {
        guard archivedThreadIDs.remove(threadID) != nil else { return }
        persistArchivedThreadIDs()
    }

    private func refreshArchivedThreads() {
        // Thread snapshots can transiently omit provider or runtime rows during bridge reloads.
        // Keep local archive markers until the user explicitly reopens a session; otherwise an
        // archived row or workspace folder can reappear when a later snapshot includes it again.
    }

    private func persistDismissedActiveThreadMarkers() {
        UserDefaults.standard.set(dismissedActiveThreadMarkers, forKey: dismissedActiveThreadMarkersDefaultsKey)
    }

    private func persistArchivedThreadIDs() {
        UserDefaults.standard.set(Array(archivedThreadIDs).sorted(), forKey: archivedThreadIDsDefaultsKey)
    }

    private func sessionListPlacement(for thread: RemoteThread) -> SessionListPlacement {
        let appearsActive = threadWouldAppearActive(thread)
        if archivedThreadIDs.contains(thread.id) {
            return .archived
        }

        guard appearsActive else {
            return .recent
        }

        guard let dismissedMarker = dismissedActiveThreadMarkers[thread.id] else {
            return .active
        }

        return activityMarker(for: thread) > dismissedMarker ? .active : .recent
    }

    private func threadWouldAppearActive(_ thread: RemoteThread) -> Bool {
        if thread.status == "running" {
            return true
        }

        if thread.controller != nil {
            return true
        }

        // A live runtime entry means helm still sees an attached local session,
        // even when the provider only reports idle/unknown between turns.
        if runtimeByThreadID[thread.id] != nil {
            return true
        }

        return false
    }

    private func shouldPromoteArchivedThreadToVisible(_ thread: RemoteThread) -> Bool {
        threadWouldAppearActive(thread)
    }

    private func sessionActivityPrecedes(_ lhs: RemoteThread, _ rhs: RemoteThread) -> Bool {
        let lhsMarker = activityMarker(for: lhs)
        let rhsMarker = activityMarker(for: rhs)
        if lhsMarker != rhsMarker {
            return lhsMarker > rhsMarker
        }
        return sessionAlphabeticalPrecedes(lhs, rhs)
    }

    private func sessionAlphabeticalPrecedes(_ lhs: RemoteThread, _ rhs: RemoteThread) -> Bool {
        let lhsTitle = sessionSortTitle(for: lhs)
        let rhsTitle = sessionSortTitle(for: rhs)
        let titleOrder = lhsTitle.localizedStandardCompare(rhsTitle)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        let lhsWorkspace = sessionSortWorkspace(for: lhs)
        let rhsWorkspace = sessionSortWorkspace(for: rhs)
        let workspaceOrder = lhsWorkspace.localizedStandardCompare(rhsWorkspace)
        if workspaceOrder != .orderedSame {
            return workspaceOrder == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private func sessionSortTitle(for thread: RemoteThread) -> String {
        let trimmedName = thread.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let workspace = sessionSortWorkspace(for: thread)
        if workspace != "workspace" {
            return workspace
        }

        return "Untitled Session"
    }

    private func sessionSortWorkspace(for thread: RemoteThread) -> String {
        let workspacePath = thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !workspacePath.isEmpty {
            return workspacePath
        }

        let cwd = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return cwd.isEmpty ? "workspace" : cwd
    }

    private func activityMarker(for thread: RemoteThread) -> Double {
        var marker = thread.updatedAt

        if let runtime = runtimeByThreadID[thread.id] {
            marker = max(marker, runtime.lastUpdatedAt)
        }

        if let controller = thread.controller {
            marker = max(marker, controller.claimedAt)
        }

        return marker
    }

    @discardableResult
    private func applyOptimisticOutgoingUserTurn(_ text: String, to threadID: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let now = Date().timeIntervalSince1970 * 1000
        let nowID = Int(now.rounded())
        let turnID = "local-turn-\(nowID)-\(UUID().uuidString)"
        let item = RemoteThreadItem(
            id: "local-user-\(nowID)-\(UUID().uuidString)",
            turnId: turnID,
            type: "userMessage",
            title: trimmed,
            detail: trimmed,
            status: "completed",
            rawText: trimmed,
            metadataSummary: nil,
            command: nil,
            cwd: nil,
            exitCode: nil
        )

        let turn = RemoteThreadTurn(
            id: turnID,
            status: "running",
            error: nil,
            items: [item]
        )
        pendingOutgoingTurnsByThreadID[threadID, default: []].append(turn)
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            let thread = threads[index]
            threads[index] = RemoteThread(
                id: thread.id,
                name: thread.name,
                preview: trimmed,
                cwd: thread.cwd,
                workspacePath: thread.workspacePath,
                status: "running",
                updatedAt: now,
                sourceKind: thread.sourceKind,
                launchSource: thread.launchSource,
                backendId: thread.backendId,
                backendLabel: thread.backendLabel,
                backendKind: thread.backendKind,
                controller: thread.controller
            )
            threads.sort { $0.updatedAt > $1.updatedAt }
            refreshDismissedActiveSessions()
        }

        return turnID
    }

    private func removeOptimisticOutgoingUserTurn(_ turnID: String?, from threadID: String) {
        guard let turnID else { return }
        guard var turns = pendingOutgoingTurnsByThreadID[threadID], !turns.isEmpty else { return }
        turns.removeAll { $0.id == turnID }
        if turns.isEmpty {
            pendingOutgoingTurnsByThreadID.removeValue(forKey: threadID)
        } else {
            pendingOutgoingTurnsByThreadID[threadID] = turns
        }
    }

    private func outgoingDisplayText(
        _ text: String,
        imageAttachments: [ComposerImageAttachment],
        fileAttachments: [ComposerFileAttachment]
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentLines =
            imageAttachments.map { attachment in
                "[Image: \(attachment.filename)]"
            } +
            fileAttachments.map { attachment in
                "[File: \(attachment.filename)]"
            }
        if trimmed.isEmpty {
            return attachmentLines.isEmpty ? "" : attachmentLines.joined(separator: "\n")
        }
        guard !attachmentLines.isEmpty else {
            return trimmed
        }
        return ([trimmed] + attachmentLines).joined(separator: "\n")
    }

    private func mergedThreadDetail(_ detail: RemoteThreadDetail, appending pendingTurns: [RemoteThreadTurn]) -> RemoteThreadDetail {
        guard !pendingTurns.isEmpty else { return detail }
        let latestPendingAt = pendingTurns.last.map(latestTimestamp(from:)) ?? detail.updatedAt
        return RemoteThreadDetail(
            id: detail.id,
            name: detail.name,
            cwd: detail.cwd,
            workspacePath: detail.workspacePath,
            status: detail.status == "unknown" ? "running" : detail.status,
            updatedAt: max(detail.updatedAt, latestPendingAt),
            sourceKind: detail.sourceKind,
            launchSource: detail.launchSource,
            backendId: detail.backendId,
            backendLabel: detail.backendLabel,
            backendKind: detail.backendKind,
            command: detail.command,
            affordances: detail.affordances,
            turns: detail.turns + pendingTurns
        )
    }

    private func pendingTurnsForDisplay(
        _ pendingTurns: [RemoteThreadTurn],
        against detail: RemoteThreadDetail
    ) -> [RemoteThreadTurn] {
        pendingTurns.filter { turn in
            guard let pendingText = pendingOutgoingText(from: turn) else { return false }
            return !detailRepresentsOutgoingText(pendingText, in: detail)
        }
    }

    private func detailRepresentsOutgoingText(_ text: String, in detail: RemoteThreadDetail) -> Bool {
        let pendingText = normalizedOutgoingText(text)
        guard !pendingText.isEmpty else { return false }

        var scannedItemCount = 0
        for turn in detail.turns.reversed() {
            for item in turn.items.reversed() {
                guard scannedItemCount < Self.pendingOutgoingReconciliationItemScanLimit else {
                    return false
                }
                scannedItemCount += 1

                if item.type == "userMessage",
                   normalizedOutgoingText(item.rawText ?? item.detail ?? item.title) == pendingText {
                    return true
                }

                if item.type == "commandExecution",
                   item.title == "Live terminal",
                   liveTerminalOutput(item.rawText ?? item.detail, includesQueuedText: pendingText) {
                    return true
                }
            }
        }

        return false
    }

    private func liveTerminalOutput(_ text: String?, includesQueuedText pendingText: String) -> Bool {
        guard let text else { return false }
        let normalizedOutput = normalizedOutgoingTail(
            text,
            minimumCharacterLimit: pendingText.count + 2048
        )
        guard normalizedOutput.contains(pendingText) else { return false }

        return normalizedOutput.contains("queued follow-up messages")
            || normalizedOutput.contains("queued followup messages")
            || normalizedOutput.contains("messages to be submitted after next tool call")
            || normalizedOutput.contains("messages to be submitted after the next tool call")
    }

    private func normalizedOutgoingTail(_ text: String, minimumCharacterLimit: Int = 0) -> String {
        let tailCharacterLimit = max(Self.pendingOutgoingLiveTerminalTailCharacterLimit, minimumCharacterLimit)
        return normalizedOutgoingText(String(text.suffix(tailCharacterLimit)))
    }

    private func pendingOutgoingText(from turn: RemoteThreadTurn) -> String? {
        turn.items
            .compactMap { $0.rawText ?? $0.detail ?? $0.title }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func normalizedOutgoingText(_ text: String?) -> String {
        guard let text else { return "" }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func latestTimestamp(from turn: RemoteThreadTurn) -> Double {
        turn.items
            .compactMap { item in
                item.id
                    .split(separator: "-")
                    .compactMap { Double($0) }
                    .first
            }
            .max() ?? Date().timeIntervalSince1970 * 1000
    }

    private func reconcilePendingOutgoingTurns(for threadID: String, against detail: RemoteThreadDetail?) {
        guard let detail else { return }
        guard let pendingTurns = pendingOutgoingTurnsByThreadID[threadID], !pendingTurns.isEmpty else { return }

        let remaining = pendingTurns.filter { turn in
            let pendingText = pendingOutgoingText(from: turn)
            guard let pendingText else { return false }
            return !detailRepresentsOutgoingText(pendingText, in: detail)
        }

        if remaining.isEmpty {
            pendingOutgoingTurnsByThreadID.removeValue(forKey: threadID)
            pendingOutgoingTurnRefreshTasksByThreadID[threadID]?.cancel()
            pendingOutgoingTurnRefreshTasksByThreadID.removeValue(forKey: threadID)
        } else {
            pendingOutgoingTurnsByThreadID[threadID] = remaining
        }
    }

    private func threadPreview(from detail: RemoteThreadDetail) -> String? {
        var snippets: [String] = []
        var consumedLineCount = 0

        for turn in detail.turns.reversed() {
            for item in turn.items.reversed() where item.type == "userMessage" || item.type == "agentMessage" {
                guard let text = previewText(from: item.rawText ?? item.detail) else { continue }
                if snippets.first == text { continue }
                snippets.insert(text, at: 0)
                consumedLineCount += text.components(separatedBy: "\n").count
                if consumedLineCount >= 3 {
                    return snippets.joined(separator: "\n")
                }
            }
        }

        return snippets.isEmpty ? nil : snippets.joined(separator: "\n")
    }

    private func previewText(from raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let joined = lines.prefix(3).joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        if joined.count <= 280 {
            return joined
        }
        return String(joined.prefix(279)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func appendVoiceEntry(_ entry: VoiceTranscriptEntry) {
        voiceEntries.append(entry)
        if voiceEntries.count > Self.maxVoiceEntries {
            voiceEntries.removeFirst(voiceEntries.count - Self.maxVoiceEntries)
        }
    }

    private func refreshSessionSnapshot(includeSelectedThreadDetail: Bool = true) async {
        let startedAt = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshThreads() }
            group.addTask { await self.refreshRuntime() }
        }
        if includeSelectedThreadDetail {
            await refreshSelectedThreadDetail()
        } else {
            scheduleSelectedThreadDetailRefresh()
        }
        lastSnapshotLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        Self.logResponsivenessSample(
            title: "Session snapshot refresh",
            sampleMS: lastSnapshotLatencyMS ?? 0,
            healthyThresholdMS: Self.healthySnapshotMS,
            warningThresholdMS: Self.warningSnapshotMS
        )
        noteHealthyRecoveryStateIfNeeded()
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

    private func recordRealtimeAgeSample(from timestamps: [Double]) {
        let normalizedTimestamps = timestamps
            .filter { $0 > 0 }
            .map { $0 > 10_000_000_000 ? $0 : $0 * 1_000 }
        guard let newestTimestamp = normalizedTimestamps.max() else { return }
        let nowMS = Date().timeIntervalSince1970 * 1000
        let latencyMS = max(0, Int(nowMS - newestTimestamp))
        guard latencyMS <= 300_000 else { return }
        lastRealtimeMessageAgeMS = latencyMS
        Self.logResponsivenessSample(
            title: "Realtime event age",
            sampleMS: latencyMS,
            healthyThresholdMS: Self.healthyRealtimeAgeMS,
            warningThresholdMS: Self.warningRealtimeAgeMS
        )
    }

    nonisolated private static func logResponsivenessSample(
        title: String,
        sampleMS: Int,
        healthyThresholdMS: Int,
        warningThresholdMS: Int
    ) {
        if sampleMS <= healthyThresholdMS {
            HelmLogger.performance.debug("\(title, privacy: .public) completed in \(sampleMS)ms")
        } else if sampleMS <= warningThresholdMS {
            HelmLogger.performance.warning("\(title, privacy: .public) missed target: \(sampleMS)ms over \(healthyThresholdMS)ms")
        } else {
            HelmLogger.performance.error("\(title, privacy: .public) exceeded ceiling: \(sampleMS)ms over \(warningThresholdMS)ms")
        }
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

    private var realtimeBootstrapMatchesCommandTarget: Bool {
        guard let bootstrap = realtimeBootstrap else {
            return false
        }

        if let threadID = commandTargetThread?.id {
            if let bootstrapThreadID = bootstrap.threadId {
                return bootstrapThreadID == threadID
                    && bootstrap.voiceProviderId == effectiveVoiceProvider?.id
            }

            return bootstrap.backendId == commandTargetBackendSummary?.id
                && bootstrap.voiceProviderId == effectiveVoiceProvider?.id
        }

        return bootstrap.backendId == commandTargetBackendSummary?.id
            && bootstrap.voiceProviderId == effectiveVoiceProvider?.id
    }

    private func enqueueRealtimeSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if realtimePlaybackRequest?.text == trimmed {
            return
        }

        if realtimePlaybackQueue.last == trimmed {
            return
        }

        if realtimePlaybackRequest == nil && !realtimePlaybackActive {
            realtimePlaybackRequest = RealtimePlaybackRequest(text: trimmed)
            realtimePlaybackActive = true
            realtimeQueuedSpeechCount = realtimePlaybackQueue.count
            return
        }

        realtimePlaybackQueue.append(trimmed)
        realtimeQueuedSpeechCount = realtimePlaybackQueue.count
    }

    private func dispatchNextRealtimeSpeechIfNeeded() {
        guard realtimeCaptureActive else {
            realtimePlaybackQueue.removeAll()
            realtimeQueuedSpeechCount = 0
            return
        }

        guard realtimePlaybackRequest == nil, !realtimePlaybackActive else {
            realtimeQueuedSpeechCount = realtimePlaybackQueue.count
            return
        }

        guard !realtimePlaybackQueue.isEmpty else {
            realtimeQueuedSpeechCount = 0
            return
        }

        let next = realtimePlaybackQueue.removeFirst()
        realtimeQueuedSpeechCount = realtimePlaybackQueue.count
        realtimePlaybackRequest = RealtimePlaybackRequest(text: next)
        realtimePlaybackActive = true
    }

    private func prepareNativeSpeechSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Best-effort only. If the session cannot be promoted, fallback playback may still succeed.
        }
    }

    private func shouldSuppressImmediateRuntimeAcknowledgement(for threadID: String) -> Bool {
        guard lastVoiceCommandThreadID == threadID,
              let lastVoiceCommandAcceptedAt
        else {
            return false
        }

        if Date().timeIntervalSince(lastVoiceCommandAcceptedAt) > 8 {
            clearRecentVoiceCommandContext(for: threadID)
            return false
        }

        return true
    }

    private func clearRecentVoiceCommandContext(for threadID: String?) {
        guard let threadID else { return }
        guard lastVoiceCommandThreadID == threadID else { return }
        lastVoiceCommandThreadID = nil
        lastVoiceCommandAcceptedAt = nil
    }

    private func styledAssistantMessage(_ text: String, kind: CommandMessageKind) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        switch commandResponseStyle {
        case .codex:
            return trimmed
        case .concise:
            switch kind {
            case .acknowledgement:
                return trimmed
            default:
                return trimmed
            }
        case .formal:
            switch kind {
            case .acknowledgement, .status:
                return "Understood. \(trimmed)"
            case .failure:
                return "Unable to complete that. \(trimmed)"
            default:
                return trimmed
            }
        case .jarvis:
            switch kind {
            case .acknowledgement:
                return "Right away. \(trimmed)"
            case .status:
                return "Status update. \(trimmed)"
            case .approval:
                return "Confirmation required. \(trimmed)"
            case .completion:
                return "Completed. \(trimmed)"
            case .blocker:
                return "Blocker detected. \(trimmed)"
            case .failure:
                return "I couldn't do that. \(trimmed)"
            }
        }
    }

    private func messageKind(for event: RemoteRuntimeEvent) -> CommandMessageKind {
        switch event.phase {
        case "completed":
            return .completion
        case "blocked":
            return .blocker
        default:
            return .status
        }
    }

    private func notificationTitle(for phase: String) -> String {
        switch phase {
        case "completed":
            return "Task completed"
        case "blocked":
            return "Blocker detected"
        default:
            return "Command update"
        }
    }

    private func messageForRuntimeEvent(_ event: RemoteRuntimeEvent, threadId: String) -> String? {
        let threadName = threadDisplayName(for: threadId)

        switch event.phase {
        case "completed":
            if let detail = event.detail {
                return "I completed work in \(threadName). \(detail)"
            }
            return "I completed work in \(threadName)."
        case "blocked":
            if let detail = event.detail {
                return "I found a blocker in \(threadName). \(detail)"
            }
            return "I found a blocker in \(threadName)."
        default:
            return nil
        }
    }

    private func userFacingMessage(for error: Error, fallback: String) -> String {
        if let helmError = error as? HelmError {
            return helmError.errorDescription ?? fallback
        }

        if let bridgeError = bridge.lastError, !bridgeError.isEmpty {
            return bridgeError
        }

        return fallback
    }

    private func logSummary(for error: Error) -> String {
        if let helmError = error as? HelmError {
            return helmError.logSummary
        }

        return HelmError(error: error).logSummary
    }
}
