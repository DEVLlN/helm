import Foundation
import Observation
import AVFoundation
import UserNotifications
import Speech
import AppKit

@MainActor
@Observable
final class MacSessionStore {
    private enum CommandIntent {
        case switchThread(query: String, runtimeTarget: String?)
        case routeCommand(query: String, command: String, runtimeTarget: String?)
        case passthrough
    }

    private enum PendingCommandClarification {
        case selectThreadForCommand(command: String, runtimeTarget: String?)
        case chooseThreadForSwitch(matchIDs: [String])
    }

    var bridge = MacBridgeClient()
    var threads: [MacRemoteThread] = []
    var runtimeByThreadID: [String: MacRuntimeThread] = [:]
    var threadDetailByID: [String: MacThreadDetail] = [:]
    var selectedThreadID: String?
    var availableBackends: [MacBackendSummary] = []
    var bridgeDefaultBackendID: String?
    var preferredBackendID: String?
    var availableVoiceProviders: [MacVoiceProviderSummary] = []
    var bridgeDefaultVoiceProviderID: String?
    var preferredVoiceProviderID: String?
    var voiceProviderBootstrapSummary = "No voice provider bootstrap loaded yet."
    var voiceProviderBootstrapJSON = ""
    var draft = ""
    var isBusy = false
    var connectionSummary = "Bridge disconnected"
    var recoverySummary: String?
    var pairingStatusSummary = "Pairing token required"
    var pairingFilePath: String?
    var pairingSuggestedBridgeURLs: [String] = []
    var pairingSetupURLString: String?
    var notificationsEnabled: Bool
    var spokenStatusEnabled: Bool
    var notificationAuthorizationSummary = "Unknown"
    var speechAuthorizationSummary = "Unknown"
    var microphoneAuthorizationSummary = "Unknown"
    var commandCaptureActive = false
    var commandCaptureSummary = "Speech capture idle"
    var commandTranscriptPreview = ""
    var standbyListeningEnabled: Bool
    var attentionWakeEnabled: Bool
    var attentionAutoListenEnabled: Bool
    var commandPanelAutoListenEnabled: Bool
    var continuousListeningEnabled: Bool
    var commandPanelOpener: (() -> Void)?
    var localSetupBusy = false
    var localSetupSummary = "Local CLI setup has not run yet."
    var localSetupOutput = ""

    private let selectedThreadDefaultsKey = "helm.mac.selected-thread-id"
    private let preferredBackendDefaultsKey = "helm.mac.preferred-backend-id"
    private let preferredVoiceProviderDefaultsKey = "helm.mac.preferred-voice-provider-id"
    private let notificationsEnabledDefaultsKey = "helm.mac.notifications-enabled"
    private let spokenStatusDefaultsKey = "helm.mac.spoken-status-enabled"
    private let standbyListeningEnabledDefaultsKey = "helm.mac.standby-listening-enabled"
    private let attentionWakeEnabledDefaultsKey = "helm.mac.attention-wake-enabled"
    private let attentionAutoListenEnabledDefaultsKey = "helm.mac.attention-auto-listen-enabled"
    private let commandPanelAutoListenEnabledDefaultsKey = "helm.mac.command-panel-auto-listen-enabled"
    private let continuousListeningEnabledDefaultsKey = "helm.mac.continuous-listening-enabled"
    private let onboardingDismissedDefaultsKey = "helm.mac.onboarding-dismissed"
    private let synthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = MacCommandSpeechRecognizer()
    private let notifications = MacNotificationCoordinator.shared
    private var seenRuntimeEventIDs = Set<String>()
    private var seenApprovalIDs = Set<String>()
    private var pendingCommandClarification: PendingCommandClarification?
    private var heartbeatTask: Task<Void, Never>?
    private var standbyRestartTask: Task<Void, Never>?
    private var realtimeReconnectTask: Task<Void, Never>?
    private var recoverySummaryClearTask: Task<Void, Never>?
    private var realtimeReconnectAttempt = 0
    private var realtimeReconnectStartedAt: Date?
    private var detailRefreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var manualCaptureStopRequested = false
    private var awaitingRecoveryRefresh = false
    private let launchStartedAt = Date()
    private(set) var lastSnapshotLatencyMS: Int?
    private(set) var lastCommandLatencyMS: Int?
    private(set) var lastApprovalLatencyMS: Int?
    private(set) var lastLaunchReadyLatencyMS: Int?
    private(set) var lastReconnectLatencyMS: Int?
    var onboardingDismissed: Bool

    init() {
        let defaults = UserDefaults.standard
        notificationsEnabled = defaults.object(forKey: notificationsEnabledDefaultsKey) as? Bool ?? true
        spokenStatusEnabled = defaults.object(forKey: spokenStatusDefaultsKey) as? Bool ?? true
        standbyListeningEnabled = defaults.object(forKey: standbyListeningEnabledDefaultsKey) as? Bool ?? false
        attentionWakeEnabled = defaults.object(forKey: attentionWakeEnabledDefaultsKey) as? Bool ?? true
        attentionAutoListenEnabled = defaults.object(forKey: attentionAutoListenEnabledDefaultsKey) as? Bool ?? true
        commandPanelAutoListenEnabled = defaults.object(forKey: commandPanelAutoListenEnabledDefaultsKey) as? Bool ?? false
        continuousListeningEnabled = defaults.object(forKey: continuousListeningEnabledDefaultsKey) as? Bool ?? false
        onboardingDismissed = defaults.object(forKey: onboardingDismissedDefaultsKey) as? Bool ?? false
        selectedThreadID = UserDefaults.standard.string(forKey: selectedThreadDefaultsKey)
        preferredBackendID = defaults.string(forKey: preferredBackendDefaultsKey)
        preferredVoiceProviderID = defaults.string(forKey: preferredVoiceProviderDefaultsKey)
        speechRecognizer.onPartialTranscript = { [weak self] transcript in
            self?.commandTranscriptPreview = transcript
            self?.commandCaptureSummary = transcript.isEmpty ? "Listening for Command on this Mac." : transcript
        }
        speechRecognizer.onFinalTranscript = { [weak self] transcript in
            guard let self else { return }
            self.commandCaptureActive = false
            self.commandTranscriptPreview = transcript
            self.commandCaptureSummary = transcript.isEmpty ? "Speech capture idle" : "Captured spoken Command."
            Task { @MainActor in
                await self.submitRecognizedCommand(transcript)
            }
        }
        speechRecognizer.onStateChanged = { [weak self] summary in
            self?.commandCaptureSummary = summary
        }
        speechRecognizer.onStopped = { [weak self] in
            self?.handleSpeechCaptureStopped()
        }
    }

    var selectedThread: MacRemoteThread? {
        threads.first(where: { $0.id == selectedThreadID })
    }

    var selectedRuntime: MacRuntimeThread? {
        guard let selectedThreadID else { return nil }
        return runtimeByThreadID[selectedThreadID]
    }

    var selectedThreadDetail: MacThreadDetail? {
        guard let selectedThreadID else { return nil }
        return threadDetailByID[selectedThreadID]
    }

    var selectedApprovals: [MacPendingApproval] {
        selectedRuntime?.pendingApprovals ?? []
    }

    var selectedEvents: [MacRuntimeEvent] {
        selectedRuntime?.recentEvents ?? []
    }

    var selectedThreadControllerSummary: String {
        guard let selectedThread else {
            return "Select a session."
        }

        guard let controller = selectedThread.controller else {
            if selectedThreadDetail?.isHelmManaged ?? selectedThread.isHelmManaged {
                return "Available. This session was launched through helm integration and can be resumed from the CLI or another helm client."
            }
            return "Available. No client currently controls this thread."
        }

        if controller.clientId == bridge.identity.id {
            return "Controlling from this Mac."
        }

        return "Observing only. Controlled by \(controller.clientName)."
    }

    var selectedThreadHandoffSummary: String {
        guard let thread = selectedThread else {
            return "helm, the CLI, and your other devices all attach to the same shared session state."
        }

        let backendLabel = thread.backendLabel ?? "Codex"

        if let controller = thread.controller {
            if controller.clientId == bridge.identity.id {
                return "This Mac currently has control. iPhone, Apple Watch, CarPlay, and the CLI can still observe the same thread and resume later."
            }

            return "\(controller.clientName) is currently driving this shared \(backendLabel) thread. You can observe here or take control if needed."
        }

        if selectedThreadDetail?.isHelmManaged ?? thread.isHelmManaged {
            return "This session was launched through helm integration. You can keep working in the CLI, attach here from the Mac, then resume it later from either side."
        }

        switch thread.sourceKind {
        case "cli":
            return "This thread started in the CLI. You can attach here without closing the terminal, then resume it later from the CLI or another helm client."
        case "vscode", "claude-desktop":
            return "This thread started from another desktop surface. helm can continue the same \(backendLabel) work here without breaking thread continuity."
        default:
            return "This thread is idle and shared. You can continue it from this Mac, the iPhone, Apple Watch, CarPlay, or the CLI."
        }
    }

    var effectiveCreateBackend: MacBackendSummary? {
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

    var effectiveVoiceProvider: MacVoiceProviderSummary? {
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
            if provider.supportsNativeBootstrap == true {
                return "\(provider.label) has a helm bridge-native session path, but helm Mac does not drive that transport yet."
            }

            return "\(provider.label) is selected, but it does not expose the current helm Mac Live Command transport."
        }

        return "\(provider.label) is selected for Live Command speech and Realtime."
    }

    var diagnosticsSummary: String {
        var parts: [String] = []

        if let lastLaunchReadyLatencyMS {
            parts.append("Launch \(lastLaunchReadyLatencyMS) ms")
        }

        if let lastSnapshotLatencyMS {
            parts.append("Snapshot \(lastSnapshotLatencyMS) ms")
        }

        if let lastCommandLatencyMS {
            parts.append("Command ack \(lastCommandLatencyMS) ms")
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

    var diagnosticsMetrics: [MacResponsivenessBudgetMetric] {
        [
            MacResponsivenessBudgetMetric(id: "launch", title: "Launch", sampleMS: lastLaunchReadyLatencyMS, healthyThresholdMS: 1200, warningThresholdMS: 2500),
            MacResponsivenessBudgetMetric(id: "snapshot", title: "Snapshot", sampleMS: lastSnapshotLatencyMS, healthyThresholdMS: 800, warningThresholdMS: 1500),
            MacResponsivenessBudgetMetric(id: "command", title: "Command Ack", sampleMS: lastCommandLatencyMS, healthyThresholdMS: 900, warningThresholdMS: 1800),
            MacResponsivenessBudgetMetric(id: "approval", title: "Approval", sampleMS: lastApprovalLatencyMS, healthyThresholdMS: 1200, warningThresholdMS: 2500),
            MacResponsivenessBudgetMetric(id: "reconnect", title: "Reconnect", sampleMS: lastReconnectLatencyMS, healthyThresholdMS: 1500, warningThresholdMS: 3200)
        ]
    }

    var diagnosticsHealthStatus: MacResponsivenessBudgetStatus {
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

    var setupChecklistItems: [(title: String, detail: String, isComplete: Bool)] {
        [
            (
                title: "Bridge URL",
                detail: bridge.baseURL.absoluteString,
                isComplete: !bridge.baseURL.absoluteString.isEmpty
            ),
            (
                title: "Pairing token",
                detail: bridge.hasPairingToken
                    ? "helm can authenticate with the bridge."
                    : "Read local pairing or paste the token from the bridge host.",
                isComplete: bridge.hasPairingToken
            ),
            (
                title: "Notifications",
                detail: notificationAuthorizationSummary,
                isComplete: notificationsEnabled && notificationAuthorizationSummary == "Enabled"
            ),
            (
                title: "Speech capture",
                detail: "\(speechAuthorizationSummary) • \(microphoneAuthorizationSummary)",
                isComplete: speechAuthorizationSummary == "Authorized" && microphoneAuthorizationSummary == "Authorized"
            ),
            (
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

    var onboardingHighlights: [String] {
        [
            "helm Mac, iPhone, Apple Watch, CarPlay, and the CLI all attach to shared thread state.",
            "Pair the Mac app to the local bridge once, then keep Command, approvals, and runtime state aligned.",
            "Use Settings for pairing, alerts, desktop listening behavior, and backend defaults."
        ]
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        heartbeatTask?.cancel()
        realtimeReconnectTask?.cancel()
        await refreshPairingStatus()
        await refreshBackends()
        await refreshVoiceProviders()
        await refreshAll()
        await refreshNotificationAuthorization()
        await refreshSpeechAuthorization()
        if notificationsEnabled {
            let _ = await notifications.requestAuthorizationIfNeeded()
            notificationAuthorizationSummary = await notifications.authorizationDescription()
        }
        startHeartbeatLoop()
        connectRealtime()
        if standbyListeningEnabled, !commandCaptureActive {
            await startVoiceCommandCapture()
        }
        lastLaunchReadyLatencyMS = Int(Date().timeIntervalSince(launchStartedAt) * 1000)
    }

    func refreshAll() async {
        let startedAt = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshThreads() }
            group.addTask { await self.refreshRuntime() }
        }
        await refreshSelectedThreadDetail()
        lastSnapshotLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        noteHealthyRecoveryStateIfNeeded()
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
                threadID: selectedThreadID,
                backendID: selectedThread?.backendId ?? effectiveCreateBackend?.id,
                style: "codex"
            )
            voiceProviderBootstrapSummary = "Loaded bootstrap metadata for \(provider.label)."
        } catch {
            voiceProviderBootstrapSummary = bridge.lastError ?? "Voice provider bootstrap unavailable."
            voiceProviderBootstrapJSON = ""
        }
    }

    func refreshThreads() async {
        isBusy = true
        defer { isBusy = false }

        do {
            let fetchedThreads = try await bridge.fetchThreads()
            applyThreadsSnapshot(fetchedThreads)
            if let current = selectedThreadID, threads.contains(where: { $0.id == current }) {
                // keep selection
            } else {
                selectedThreadID = preferredCommandThread?.id
            }

            if let selectedThreadID {
                UserDefaults.standard.set(selectedThreadID, forKey: selectedThreadDefaultsKey)
            }

            connectionSummary = "Connected to bridge"
        } catch {
            connectionSummary = bridge.hasPairingToken ? "Bridge unavailable" : "Bridge needs pairing"
        }
    }

    func refreshRuntime() async {
        do {
            let runtime = try await bridge.fetchRuntime()
            applyRuntimeSnapshot(runtime)
        } catch {
            if connectionSummary != "Bridge unavailable" {
                connectionSummary = "Runtime unavailable"
            }
        }
    }

    func refreshSelectedThreadDetail() async {
        guard let selectedThreadID else { return }

        do {
            let detail = try await bridge.fetchThreadDetail(threadID: selectedThreadID)
            applyThreadDetail(detail, for: selectedThreadID)
        } catch {
            connectionSummary = "Thread detail unavailable"
        }
    }

    func refreshPairingStatus() async {
        do {
            let pairing = try await bridge.fetchPairingStatus()
            if let token = pairing.token, bridge.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bridge.pairingToken = token
            }

            pairingStatusSummary = "Bridge paired with \(pairing.tokenHint)"
            pairingFilePath = pairing.filePath
            pairingSuggestedBridgeURLs = pairing.suggestedBridgeURLs ?? []
            pairingSetupURLString = pairing.setupURL
        } catch {
            pairingSuggestedBridgeURLs = []
            pairingSetupURLString = nil
            pairingStatusSummary = bridge.hasPairingToken ? "Pairing token configured on this Mac" : "Pairing token required"
        }
    }

    func selectThread(_ id: String) {
        selectedThreadID = id
        UserDefaults.standard.set(id, forKey: selectedThreadDefaultsKey)
        scheduleSelectedThreadDetailRefresh()
    }

    func takeControl(force: Bool = false) async {
        guard let threadID = selectedThreadID else { return }
        do {
            try await bridge.takeControl(threadID: threadID, force: force)
            await refreshThreads()
            speak(force ? "Control taken over." : "Control claimed.")
        } catch {
            connectionSummary = bridge.lastError ?? "Failed to claim control"
        }
    }

    func releaseControl() async {
        guard let threadID = selectedThreadID else { return }
        do {
            try await bridge.releaseControl(threadID: threadID)
            await refreshThreads()
            speak("Control released.")
        } catch {
            connectionSummary = bridge.lastError ?? "Failed to release control"
        }
    }

    func interrupt() async {
        guard let threadID = selectedThreadID else { return }
        do {
            try await bridge.interrupt(threadID: threadID)
            connectionSummary = "Interrupt sent"
            speak("Interrupt sent.")
        } catch {
            connectionSummary = bridge.lastError ?? "Interrupt failed"
        }
    }

    func sendDraft() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if await handlePendingCommandClarification(trimmed) {
            draft = ""
            return
        }

        if await handleCommandIntent(trimmed) {
            draft = ""
            return
        }

        if selectedThreadID == nil {
            selectPriorityThreadIfNeeded()
        }

        guard let threadID = selectedThreadID else { return }
        draft = ""
        await dispatchCommand(trimmed, threadID: threadID)
    }

    func sendQuickCommand(_ text: String) async {
        guard let threadID = selectedThreadID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await dispatchCommand(trimmed, threadID: threadID)
    }

    private func dispatchCommand(_ trimmed: String, threadID: String) async {
        do {
            let startedAt = Date()
            try await bridge.sendTurn(threadID: threadID, text: trimmed)
            lastCommandLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            connectionSummary = "On it. Full output stays in the live session."
            await refreshAll()
        } catch {
            await refreshAll()
            if handleTypedCommandControlConflict(threadID: threadID, text: trimmed) {
                return
            }
            connectionSummary = bridge.lastError ?? "Failed to send command"
        }
    }

    func decideApproval(_ approval: MacPendingApproval, decision: String) async {
        do {
            let startedAt = Date()
            try await bridge.decideApproval(approvalID: approval.requestId, decision: decision)
            lastApprovalLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            await refreshRuntime()
        } catch {
            connectionSummary = bridge.lastError ?? "Approval response failed"
        }
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

    func setStandbyListeningEnabled(_ enabled: Bool) {
        standbyListeningEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: standbyListeningEnabledDefaultsKey)

        if enabled {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.commandCaptureActive else { return }
                self.commandCaptureSummary = "Standby listening enabled."
                await self.startVoiceCommandCapture()
            }
        } else {
            standbyRestartTask?.cancel()
            standbyRestartTask = nil
            if commandCaptureActive {
                stopVoiceCommandCapture()
            }
        }
    }

    func setAttentionWakeEnabled(_ enabled: Bool) {
        attentionWakeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: attentionWakeEnabledDefaultsKey)
    }

    func setAttentionAutoListenEnabled(_ enabled: Bool) {
        attentionAutoListenEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: attentionAutoListenEnabledDefaultsKey)
    }

    func setCommandPanelAutoListenEnabled(_ enabled: Bool) {
        commandPanelAutoListenEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: commandPanelAutoListenEnabledDefaultsKey)
    }

    func openCommandPanelAndPrepare(startListening: Bool? = nil) async {
        commandPanelOpener?()
        await prepareForCommandPanel()

        let shouldStartListening = startListening ?? autoListenOnCommandPanelOpen
        guard shouldStartListening else { return }
        guard !commandCaptureActive else { return }
        await startVoiceCommandCapture()
    }

    func setContinuousListeningEnabled(_ enabled: Bool) {
        continuousListeningEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: continuousListeningEnabledDefaultsKey)
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

    func refreshSpeechAuthorization() async {
        let authorization = await speechRecognizer.authorizationSnapshot()
        speechAuthorizationSummary = authorization.speech
        microphoneAuthorizationSummary = authorization.microphone
    }

    func refreshSetupStatus() async {
        await refreshPairingStatus()
        await refreshNotificationAuthorization()
        await refreshSpeechAuthorization()
        await refreshBackends()
        await refreshVoiceProviders()
        await refreshAll()
    }

    func installCLIHelpers() async {
        await runLocalSetupTask(summaryPrefix: "CLI helpers installed") {
            try await MacLocalTooling.runScript(named: "install-helm-cli.sh")
        }
    }

    func enableShellAutoinjection() async {
        await runLocalSetupTask(summaryPrefix: "Runtime wrapping enabled") {
            try await MacLocalTooling.runScript(named: "install-helm-shell-integration.sh")
        }
    }

    func runFullCLISetup() async {
        await runLocalSetupTask(summaryPrefix: "CLI setup, runtime wrapping, and pairing are ready") {
            let installOutput = try await MacLocalTooling.runScript(named: "install-helm-cli.sh")
            let autoinjectionOutput = try await MacLocalTooling.runScript(named: "install-helm-shell-integration.sh")
            let bridgeOutput = try await MacLocalTooling.runScript(named: "prototype-up.sh", arguments: ["--lan"])
            return [installOutput, autoinjectionOutput, bridgeOutput]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        await refreshSetupStatus()
    }

    func startBridgeForPairing() async {
        await runLocalSetupTask(summaryPrefix: "Bridge started for pairing") {
            try await MacLocalTooling.runScript(named: "prototype-up.sh", arguments: ["--lan"])
        }
        await refreshSetupStatus()
    }

    private func runLocalSetupTask(
        summaryPrefix: String,
        operation: @escaping () async throws -> String
    ) async {
        guard !localSetupBusy else { return }
        localSetupBusy = true
        defer { localSetupBusy = false }

        do {
            let output = try await operation()
            localSetupOutput = output
            localSetupSummary = summaryPrefix
        } catch {
            let message = error.localizedDescription
            localSetupOutput = message
            localSetupSummary = "Local setup failed"
        }
    }

    func startVoiceCommandCapture() async {
        manualCaptureStopRequested = false
        standbyRestartTask?.cancel()
        standbyRestartTask = nil
        await refreshSpeechAuthorization()
        do {
            try await speechRecognizer.start()
            commandCaptureActive = true
            commandTranscriptPreview = ""
            commandCaptureSummary = "Listening for Command on this Mac."
        } catch {
            commandCaptureActive = false
            commandCaptureSummary = error.localizedDescription
            if standbyListeningEnabled {
                scheduleVoiceCommandRestart(reason: "Retrying standby listening.")
            }
        }
    }

    func stopVoiceCommandCapture() {
        manualCaptureStopRequested = true
        standbyRestartTask?.cancel()
        standbyRestartTask = nil
        speechRecognizer.stop()
        commandCaptureActive = false
        if commandTranscriptPreview.isEmpty {
            commandCaptureSummary = "Speech capture stopped."
        }
    }

    func toggleVoiceCommandCapture() async {
        if commandCaptureActive {
            stopVoiceCommandCapture()
        } else {
            await startVoiceCommandCapture()
        }
    }

    var selectedThreadStatusSummary: String {
        let threadName = selectedThread?.name ?? "the selected session"

        if let approval = selectedApprovals.first {
            if let detail = approval.detail {
                return "Approval needed in \(threadName): \(detail)"
            }

            return "Approval needed in \(threadName)."
        }

        if let runtime = selectedRuntime {
            switch runtime.phase {
            case "running":
                if let title = runtime.title {
                    return "Working now: \(title)"
                }
                return "Working now."
            case "blocked":
                if let detail = runtime.detail {
                    return "Blocked: \(detail)"
                }
                return "Blocked."
            case "completed":
                if let detail = runtime.detail {
                    return "Completed: \(detail)"
                }
                return "Completed recent work."
            case "waitingApproval":
                return "Waiting for approval."
            default:
                break
            }
        }

        if let latestTurn = selectedThreadDetail?.turns.first {
            return "Latest turn is \(latestTurn.status)."
        }

        return "No recent activity."
    }

    var menuBarSymbolName: String {
        switch highestPriorityPhase {
        case "waitingApproval":
            return "exclamationmark.bubble.fill"
        case "blocked":
            return "xmark.circle.fill"
        case "completed":
            return "checkmark.circle.fill"
        case "running":
            return "waveform.circle.fill"
        default:
            return "waveform.circle"
        }
    }

    var menuBarSubtitle: String {
        switch highestPriorityPhase {
        case "waitingApproval":
            return "Needs approval"
        case "blocked":
            return "Blocked"
        case "completed":
            return "Task completed"
        case "running":
            return "Active"
        default:
            return "Standing by"
        }
    }

    var globalAttentionSummary: String {
        guard let thread = priorityThread else {
            return "No sessions need attention."
        }

        let name = thread.name ?? "Selected Session"
        switch highestPriorityPhase {
        case "waitingApproval":
            return "\(name) needs approval."
        case "blocked":
            return "\(name) is blocked."
        case "completed":
            return "\(name) completed recent work."
        case "running":
            return "\(name) is running."
        default:
            return "No sessions need attention."
        }
    }

    var autoListenOnCommandPanelOpen: Bool {
        commandPanelAutoListenEnabled
    }

    func prepareForCommandPanel() async {
        await refreshAll()
        selectPriorityThreadIfNeeded()
    }

    private var highestPriorityPhase: String? {
        priorityThread.flatMap { runtimeByThreadID[$0.id]?.phase }
    }

    private var priorityThread: MacRemoteThread? {
        let ranked = threads.sorted { lhs, rhs in
            priorityScore(for: lhs.id) > priorityScore(for: rhs.id)
        }
        return ranked.first
    }

    private var preferredCommandThread: MacRemoteThread? {
        threads.max { lhs, rhs in
            commandPreferenceScore(for: lhs) < commandPreferenceScore(for: rhs)
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

    private func commandPreferenceScore(for thread: MacRemoteThread) -> Int {
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

    private func selectPriorityThreadIfNeeded() {
        if let selectedThreadID, threads.contains(where: { $0.id == selectedThreadID }) {
            return
        }

        if let preferredCommandThread {
            selectThread(preferredCommandThread.id)
        }
    }

    private func speak(_ text: String) {
        guard spokenStatusEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.48
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    private func submitRecognizedCommand(_ transcript: String) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            commandCaptureSummary = "No spoken Command detected."
            return
        }

        if await handlePendingCommandClarification(trimmed) {
            finalizeRecognizedCommandCycle()
            return
        }

        if await handleCommandIntent(trimmed) {
            finalizeRecognizedCommandCycle()
            return
        }

        if selectedThreadID == nil {
            selectPriorityThreadIfNeeded()
        }

        draft = trimmed
        await sendDraft()
        finalizeRecognizedCommandCycle()
    }

    private func finalizeRecognizedCommandCycle() {
        commandTranscriptPreview = ""

        if !draft.isEmpty {
            commandCaptureSummary = "Command held. Resolve control here or take over."
        } else if pendingCommandClarification == nil && commandCaptureSummary == "Listening for Command on this Mac." {
            let shouldResume = continuousListeningEnabled || standbyListeningEnabled
            commandCaptureSummary = shouldResume ? "Sent spoken Command. Listening again." : "Sent spoken Command."
        }

        let shouldResume = continuousListeningEnabled || standbyListeningEnabled
        guard shouldResume else { return }
        scheduleVoiceCommandRestart(reason: standbyListeningEnabled ? "Standby listening active." : "Listening again.")
    }

    private func handleCommandIntent(_ text: String) async -> Bool {
        switch resolveCommandIntent(text) {
        case .switchThread(let query, let runtimeTarget):
            let matches = threadsMatching(query, backendPreference: runtimeTarget)

            guard !matches.isEmpty else {
                let message = threadLookupFailure(for: query, runtimeTarget: runtimeTarget)
                connectionSummary = message
                commandCaptureSummary = message
                speak(message)
                return true
            }

            if matches.count > 1 {
                pendingCommandClarification = .chooseThreadForSwitch(matchIDs: matches.map(\.id))
                let message = "I found multiple matching sessions. Say the exact session name."
                connectionSummary = message
                commandCaptureSummary = message
                speak(message)
                return true
            }

            guard let match = matches.first else {
                return true
            }

            pendingCommandClarification = nil
            selectThread(match.id)
            let message = "Switched to \(match.name ?? "the selected session")."
            connectionSummary = message
            commandCaptureSummary = message
            speak(message)
            return true
        case .routeCommand(let query, let command, let runtimeTarget):
            let matches = threadsMatching(query, backendPreference: runtimeTarget)

            guard !matches.isEmpty else {
                let message = activeThreadLookupFailure(for: query, runtimeTarget: runtimeTarget)
                connectionSummary = message
                commandCaptureSummary = message
                speak(message)
                return true
            }

            if matches.count > 1 {
                pendingCommandClarification = .selectThreadForCommand(command: command, runtimeTarget: runtimeTarget)
                let message = "I found multiple sessions for \(query). Which one should I use?"
                connectionSummary = message
                commandCaptureSummary = message
                speak(message)
                return true
            }

            guard let match = matches.first else {
                return true
            }

            pendingCommandClarification = nil
            selectThread(match.id)
            await dispatchCommand(command, threadID: match.id)
            return true
        case .passthrough:
            return false
        }
    }

    private func resolveCommandIntent(_ text: String) -> CommandIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

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

        return .passthrough
    }

    private func handlePendingCommandClarification(_ response: String) async -> Bool {
        guard let pendingCommandClarification else { return false }
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if ["cancel", "never mind", "stop", "forget it"].contains(normalized) {
            self.pendingCommandClarification = nil
            let message = "Okay. I cancelled that Command."
            connectionSummary = message
            commandCaptureSummary = message
            speak(message)
            return true
        }

        switch pendingCommandClarification {
        case .selectThreadForCommand(let command, let runtimeTarget):
            let matches = threadsMatching(response, backendPreference: runtimeTarget)
            guard let match = resolveSingleMatch(matches, noMatch: "I couldn't match that to a session.") else {
                return true
            }

            self.pendingCommandClarification = nil
            selectThread(match.id)
            await dispatchCommand(command, threadID: match.id)
            return true
        case .chooseThreadForSwitch(let matchIDs):
            let eligibleMatches = threads.filter { matchIDs.contains($0.id) }
            let query = response.lowercased()
            let matches = eligibleMatches.filter {
                threadLookupValues(for: $0).contains { $0.contains(query) }
            }

            guard let match = resolveSingleMatch(matches, noMatch: "I couldn't tell which session you meant.") else {
                return true
            }

            self.pendingCommandClarification = nil
            selectThread(match.id)
            let message = "Switched to \(match.name ?? "the selected session")."
            connectionSummary = message
            commandCaptureSummary = message
            speak(message)
            return true
        }
    }

    private func threadsMatching(_ query: String, backendPreference: String? = nil) -> [MacRemoteThread] {
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

    private func resolveSingleMatch(_ matches: [MacRemoteThread], noMatch: String) -> MacRemoteThread? {
        if matches.count > 1 {
            let message = "I found multiple matching sessions. Say the exact session name."
            connectionSummary = message
            commandCaptureSummary = message
            speak(message)
            return nil
        }

        guard let match = matches.first else {
            connectionSummary = noMatch
            commandCaptureSummary = noMatch
            speak(noMatch)
            return nil
        }

        return match
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

        connectionSummary = typedControlConflictPrompt(for: threadID, controllerName: controllerName)
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
        command.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
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

    private func threadLookupValues(for thread: MacRemoteThread) -> [String] {
        var values = [
            (thread.name ?? "").lowercased(),
            thread.preview.lowercased(),
            thread.cwd.lowercased(),
        ]

        let basename = URL(fileURLWithPath: thread.cwd).lastPathComponent.lowercased()
        if !basename.isEmpty {
            values.append(basename)
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

    private func matchesBackendPreference(_ thread: MacRemoteThread, backendPreference: String) -> Bool {
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

    private func handleSpeechCaptureStopped() {
        commandCaptureActive = false

        if manualCaptureStopRequested {
            manualCaptureStopRequested = false
            if commandTranscriptPreview.isEmpty {
                commandCaptureSummary = "Speech capture stopped."
            }
            return
        }

        if commandTranscriptPreview.isEmpty {
            commandCaptureSummary = standbyListeningEnabled ? "Standby listening paused. Re-arming." : "Speech capture idle."
        }

        guard standbyListeningEnabled else { return }
        scheduleVoiceCommandRestart(reason: "Standby listening active.")
    }

    private func scheduleVoiceCommandRestart(reason: String) {
        standbyRestartTask?.cancel()
        standbyRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard self.standbyListeningEnabled || self.continuousListeningEnabled else { return }
            guard !self.commandCaptureActive else { return }
            self.commandCaptureSummary = reason
            await self.startVoiceCommandCapture()
        }
    }

    private func connectRealtime() {
        if realtimeReconnectAttempt > 0 {
            realtimeReconnectStartedAt = .now
        }
        bridge.connectRealtime(
            onMessage: { [weak self] message in
                self?.realtimeReconnectTask?.cancel()
                self?.realtimeReconnectAttempt = 0
                self?.handleRealtimeMessage(message)
            },
            onDisconnect: { [weak self] message in
                guard let self else { return }
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

    private func handleRealtimeMessage(_ message: MacBridgeRealtimeMessage) {
        if let realtimeReconnectStartedAt {
            lastReconnectLatencyMS = Int(Date().timeIntervalSince(realtimeReconnectStartedAt) * 1000)
            self.realtimeReconnectStartedAt = nil
        }

        switch message {
        case .ready(let payload):
            connectionSummary = payload.message
            if awaitingRecoveryRefresh {
                awaitingRecoveryRefresh = false
                Task { @MainActor in
                    await performPostReconnectRecovery()
                }
            }
        case .runtimeSnapshot(let threads):
            applyRuntimeSnapshot(threads)
            if selectedThreadID != nil {
                scheduleSelectedThreadDetailRefresh()
            }
        case .runtimeThread(let thread):
            let previous = runtimeByThreadID[thread.threadId]
            if previous != thread {
                runtimeByThreadID[thread.threadId] = thread
            }
            processRuntimeUpdate(previous: previous, current: thread)
            if thread.threadId == selectedThreadID {
                scheduleSelectedThreadDetailRefresh()
            }
        case .threadDetail(let detail):
            applyThreadDetail(detail, for: detail.id)
        case .controlChanged(let payload):
            guard let index = threads.firstIndex(where: { $0.id == payload.threadId }) else { return }
            let current = threads[index]
            guard current.controller != payload.controller else { return }
            threads[index] = MacRemoteThread(
                id: current.id,
                name: current.name,
                preview: current.preview,
                cwd: current.cwd,
                status: current.status,
                updatedAt: current.updatedAt,
                sourceKind: current.sourceKind,
                launchSource: current.launchSource,
                backendId: current.backendId,
                backendLabel: current.backendLabel,
                backendKind: current.backendKind,
                controller: payload.controller
            )
        }
    }

    private func performPostReconnectRecovery() async {
        let startedAt = Date()
        await refreshAll()
        let latencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)

        if connectionSummary == "Bridge unavailable" || connectionSummary == "Runtime unavailable" || connectionSummary == "Thread detail unavailable" {
            recoverySummary = "Live transport returned, but state refresh still needs attention."
            return
        }

        recoverySummary = "Recovered live state in \(latencyMS) ms."
        connectionSummary = "Connected to bridge"
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

    private func seedRuntimeTracking(from threads: [MacRuntimeThread]) {
        seenRuntimeEventIDs = Set(threads.flatMap(\.recentEvents).map(\.id))
        seenApprovalIDs = Set(threads.flatMap(\.pendingApprovals).map(\.requestId))
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
        realtimeReconnectAttempt += 1
        let seconds = min(pow(2.0, Double(max(realtimeReconnectAttempt - 1, 0))), 30.0)
        realtimeReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.connectRealtime()
        }
    }

    private func applyThreadsSnapshot(_ fetchedThreads: [MacRemoteThread]) {
        if threads != fetchedThreads {
            threads = fetchedThreads
        }
        pruneStaleThreadDetails(keeping: Set(fetchedThreads.map(\.id)))
    }

    private func applyRuntimeSnapshot(_ runtimeThreads: [MacRuntimeThread]) {
        let snapshot = Dictionary(uniqueKeysWithValues: runtimeThreads.map { ($0.threadId, $0) })
        if runtimeByThreadID != snapshot {
            runtimeByThreadID = snapshot
        }
        seedRuntimeTracking(from: runtimeThreads)
    }

    private func applyThreadDetail(_ detail: MacThreadDetail?, for threadID: String) {
        if let detail {
            if threadDetailByID[threadID] != detail {
                threadDetailByID[threadID] = detail
            }
            mergeThreadSummary(from: detail)
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

    private func mergeThreadSummary(from detail: MacThreadDetail) {
        guard let index = threads.firstIndex(where: { $0.id == detail.id }) else { return }
        let current = threads[index]
        let updated = MacRemoteThread(
            id: current.id,
            name: detail.name,
            preview: threadPreview(from: detail) ?? current.preview,
            cwd: detail.cwd,
            status: detail.status,
            updatedAt: detail.updatedAt,
            sourceKind: detail.sourceKind,
            launchSource: detail.launchSource,
            backendId: detail.backendId,
            backendLabel: detail.backendLabel,
            backendKind: detail.backendKind,
            controller: current.controller
        )
        guard threads[index] != updated else { return }
        threads[index] = updated
        threads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func threadPreview(from detail: MacThreadDetail) -> String? {
        var snippets: [String] = []

        for turn in detail.turns.reversed() {
            for item in turn.items.reversed() where item.type == "userMessage" || item.type == "agentMessage" {
                guard let text = previewText(from: item.detail) else { continue }
                if snippets.first == text { continue }
                snippets.insert(text, at: 0)
                if snippets.count >= 2 {
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
        let joined = lines.prefix(2).joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        if joined.count <= 280 {
            return joined
        }
        return String(joined.prefix(279)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func processRuntimeUpdate(previous: MacRuntimeThread?, current: MacRuntimeThread) {
        let freshApprovals = current.pendingApprovals.filter { seenApprovalIDs.insert($0.requestId).inserted }
        for approval in freshApprovals {
            let threadName = threadDisplayName(for: approval.threadId)
            let detail = approval.detail ?? "I need approval before I can continue."
            let message = "I need approval for \(threadName). \(detail)"
            speak(message)
            wakeCommandPanelIfNeeded(threadID: approval.threadId, reason: "Approval needed: \(threadName)")

            if notificationsEnabled {
                Task {
                    await notifications.post(
                        title: "Approval needed",
                        body: "\(threadName): \(detail)",
                        threadID: approval.threadId
                    )
                }
            }
        }

        let freshEvents = current.recentEvents
            .reversed()
            .filter { seenRuntimeEventIDs.insert($0.id).inserted }

        for event in freshEvents {
            guard let message = messageForRuntimeEvent(event, threadId: current.threadId) else { continue }
            speak(message)

            if event.phase == "blocked" {
                wakeCommandPanelIfNeeded(threadID: current.threadId, reason: "Blocker detected: \(threadDisplayName(for: current.threadId))")
            }

            if notificationsEnabled {
                let title = notificationTitle(for: event.phase)
                Task {
                    await notifications.post(title: title, body: message, threadID: current.threadId)
                }
            }
        }

        if let previous, previous.phase != current.phase, current.phase == "running", current.title == "Turn started" {
            speak("Working on it.")
        }
    }

    private func threadDisplayName(for threadID: String) -> String {
        threads.first(where: { $0.id == threadID })?.name ?? "the active session"
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

    private func messageForRuntimeEvent(_ event: MacRuntimeEvent, threadId: String) -> String? {
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

    private func wakeCommandPanelIfNeeded(threadID: String, reason: String) {
        guard attentionWakeEnabled else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectThread(threadID)
            self.commandCaptureSummary = reason
            self.commandPanelOpener?()
            NSApp.activate(ignoringOtherApps: true)
            await self.refreshSelectedThreadDetail()
            if self.attentionAutoListenEnabled, !self.commandCaptureActive {
                try? await Task.sleep(for: .milliseconds(500))
                guard !self.commandCaptureActive else { return }
                await self.startVoiceCommandCapture()
            }
        }
    }
}
