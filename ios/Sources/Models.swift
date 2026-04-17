import Foundation

private func isHelmManagedLaunchSource(_ source: String?) -> Bool {
    source == "helm-runtime-wrapper" || source == "helm-shell-wrapper"
}

enum AppSection: Hashable {
    case sessions
    case command
    case settings
}

struct RemoteThread: Identifiable, Codable, Hashable {
    let id: String
    let name: String?
    let preview: String
    let cwd: String
    let workspacePath: String?
    let status: String
    let updatedAt: Double
    let sourceKind: String?
    let launchSource: String?
    let backendId: String?
    let backendLabel: String?
    let backendKind: String?
    let controller: ThreadController?

    var isHelmManaged: Bool {
        isHelmManagedLaunchSource(launchSource)
    }
}

struct ThreadListResponse: Codable {
    let threads: [RemoteThread]
}

struct RuntimeListResponse: Codable {
    let threads: [RemoteRuntimeThread]
}

struct PairingStatusEnvelope: Codable {
    let pairing: BridgePairingStatus
}

struct ThreadDetailResponse: Codable {
    let thread: RemoteThreadDetail?
}

struct ThreadOpenResponse: Codable {
    let threadId: String
    let previousThreadId: String?
    let replaced: Bool
    let launched: Bool
    let thread: RemoteThreadDetail?
}

struct ThreadCreateResponse: Codable {
    let threadId: String?
    let thread: RemoteThreadDetail?
}

struct TurnDeliveryResponse: Codable, Hashable {
    let ok: Bool?
    let mode: String?
    let threadId: String?
}

enum TurnDeliveryMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case queue
    case interrupt

    var id: String { rawValue }
}

enum TerminalInputKey: String, Codable, Hashable, CaseIterable {
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case enter
    case space
    case tab
    case escape
}

struct TerminalInputResponse: Codable, Hashable {
    let ok: Bool?
    let mode: String?
    let threadId: String?
}

struct SessionLaunchOptionsEnvelope: Codable {
    let options: SessionLaunchOptions
}

struct SessionLaunchOptions: Codable, Hashable {
    let backendId: String
    let modelDefault: String?
    let modelOptions: [String]
    let effortOptions: [String]
    let effortDefault: String?
    let codexFastDefault: Bool?
    let claudeContextOptions: [String]
    let claudeContextDefault: String?
}

struct DirectorySuggestionResponse: Codable {
    let directories: [DirectorySuggestion]
}

struct DirectorySuggestion: Codable, Hashable, Identifiable {
    let path: String
    let displayPath: String
    let isExact: Bool

    var id: String { path }
}

struct FileSuggestionResponse: Codable {
    let files: [FileTagSuggestion]
}

struct FileTagSuggestion: Codable, Hashable, Identifiable {
    let path: String
    let displayPath: String
    let completion: String
    let isDirectory: Bool

    var id: String { path }
}

struct SkillSuggestionResponse: Codable {
    let skills: [SkillSuggestion]
}

struct SkillSuggestion: Codable, Hashable, Identifiable {
    let name: String
    let summary: String
    let path: String

    var id: String { name }
}

enum ClaudeContextMode: String, CaseIterable, Hashable {
    case normal
    case oneMillion = "1m"

    var label: String { rawValue }
}

enum SessionLaunchMode: String, CaseIterable, Hashable, Identifiable {
    case sharedThread
    case managedShell

    var id: String { rawValue }

    var codexPickerLabel: String {
        switch self {
        case .sharedThread:
            return "Codex App"
        case .managedShell:
            return "Codex CLI"
        }
    }

    var codexDescription: String {
        switch self {
        case .sharedThread:
            return "Keeps the new session in Codex.app and uses the shared desktop thread."
        case .managedShell:
            return "Launches a helm-managed Codex terminal session that stays attached to the CLI."
        }
    }
}

struct NewSessionDraft: Hashable {
    var backendId: String?
    var model: String = ""
    var workingDirectory: String = ""
    var reasoningEffort: String?
    var codexFastMode: Bool?
    var claudeContextMode: ClaudeContextMode = .normal
    var launchMode: SessionLaunchMode = .managedShell

    func normalizedModel(for backendId: String?) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard backendId == "claude-code" else {
            return trimmed
        }

        let normalizedBase = trimmed.replacingOccurrences(
            of: "[1m]",
            with: "",
            options: [.caseInsensitive]
        )
        return claudeContextMode == .oneMillion ? "\(normalizedBase)[1m]" : normalizedBase
    }

    var normalizedWorkingDirectory: String {
        workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ThreadController: Codable, Hashable {
    let clientId: String
    let clientName: String
    let claimedAt: Double
    let lastSeenAt: Double
}

struct ClientIdentity {
    let id: String
    let name: String
}

struct BridgePairingStatus: Codable, Hashable {
    let token: String?
    let tokenHint: String
    let filePath: String
    let createdAt: Double
    let rotatedAt: Double
    let suggestedBridgeURLs: [String]?
    let setupURL: String?
}

struct BackendCapabilities: Codable, Hashable {
    let threadListing: Bool
    let threadCreation: Bool
    let turnExecution: Bool
    let turnInterrupt: Bool
    let approvals: Bool
    let planMode: Bool
    let voiceCommand: Bool
    let realtimeVoice: Bool
    let hooksAndSkillsParity: Bool
    let sharedThreadHandoff: Bool
}

struct BackendCommandSemantics: Codable, Hashable {
    let routing: String
    let approvals: String
    let handoff: String
    let voiceInput: String
    let voiceOutput: String
    let supportsCommandFollowups: Bool
    let notes: String
}

struct ThreadCommandAffordances: Codable, Hashable {
    let canSendTurns: Bool
    let canInterrupt: Bool
    let canRespondToApprovals: Bool
    let canUseRealtimeCommand: Bool
    let showsOperationalSnapshot: Bool
    let sessionAccess: String
    let notes: String
}

struct BackendSummary: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let description: String
    let isDefault: Bool
    let available: Bool
    let availabilityDetail: String?
    let capabilities: BackendCapabilities
    let command: BackendCommandSemantics
}

struct BackendListResponse: Codable {
    let defaultBackendId: String
    let backends: [BackendSummary]
}

struct VoiceProviderSummary: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let transport: String?
    let available: Bool
    let availabilityDetail: String?
    let supportsSpeechSynthesis: Bool
    let supportsRealtimeSessions: Bool
    let supportsClientSecrets: Bool
    let supportsNativeBootstrap: Bool?
}

struct VoiceProviderListResponse: Codable {
    let defaultVoiceProviderId: String
    let providers: [VoiceProviderSummary]
}

struct RemoteRuntimeThread: Codable, Hashable, Identifiable {
    let threadId: String
    let phase: String
    let currentTurnId: String?
    let title: String?
    let detail: String?
    let lastUpdatedAt: Double
    let pendingApprovals: [RemotePendingApproval]
    let recentEvents: [RemoteRuntimeEvent]

    var id: String { threadId }
}

struct RemotePendingApproval: Codable, Hashable, Identifiable {
    let requestId: String
    let threadId: String
    let turnId: String?
    let itemId: String?
    let kind: String
    let title: String
    let detail: String?
    let requestedAt: Double
    let canRespond: Bool
    let supportsAcceptForSession: Bool

    var id: String { requestId }
}

struct RemoteRuntimeEvent: Codable, Hashable, Identifiable {
    let id: String
    let threadId: String
    let turnId: String?
    let itemId: String?
    let method: String
    let title: String
    let detail: String?
    let phase: String
    let createdAt: Double
}

struct RemoteThreadDetail: Codable, Hashable, Identifiable {
    let id: String
    let name: String?
    let cwd: String
    let workspacePath: String?
    let status: String
    let updatedAt: Double
    let sourceKind: String?
    let launchSource: String?
    let backendId: String?
    let backendLabel: String?
    let backendKind: String?
    let command: BackendCommandSemantics?
    let affordances: ThreadCommandAffordances?
    let turns: [RemoteThreadTurn]

    var isHelmManaged: Bool {
        isHelmManagedLaunchSource(launchSource)
    }
}

struct RemoteThreadTurn: Codable, Hashable, Identifiable {
    let id: String
    let status: String
    let error: String?
    let items: [RemoteThreadItem]
}

struct RemoteThreadItem: Codable, Hashable, Identifiable {
    let id: String
    let turnId: String?
    let type: String
    let title: String
    let detail: String?
    let status: String?
    let rawText: String?
    let metadataSummary: String?
    let command: String?
    let cwd: String?
    let exitCode: Int?
}

struct ComposerImageAttachment: Hashable, Identifiable {
    let id: String
    let filename: String
    let mimeType: String
    let data: Data

    var byteCount: Int {
        data.count
    }
}

struct ComposerFileAttachment: Hashable, Identifiable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let data: Data

    var byteCount: Int {
        data.count
    }
}

struct BridgeReadyPayload: Codable {
    let message: String
}

struct BridgeReadyEnvelope: Codable {
    let type: String
    let payload: BridgeReadyPayload
}

struct RuntimeSnapshotPayload: Codable {
    let threads: [RemoteRuntimeThread]
}

struct RuntimeSnapshotEnvelope: Codable {
    let type: String
    let payload: RuntimeSnapshotPayload
}

struct ThreadSnapshotPayload: Codable {
    let threads: [RemoteThread]
}

struct ThreadSnapshotEnvelope: Codable {
    let type: String
    let payload: ThreadSnapshotPayload
}

struct RuntimeThreadPayload: Codable {
    let thread: RemoteRuntimeThread
}

struct RuntimeThreadEnvelope: Codable {
    let type: String
    let payload: RuntimeThreadPayload
}

struct ThreadDetailPayload: Codable {
    let thread: RemoteThreadDetail
}

struct ThreadDetailEnvelope: Codable {
    let type: String
    let payload: ThreadDetailPayload
}

struct ControlChangedPayload: Codable {
    let threadId: String
    let controller: ThreadController?
}

struct ControlChangedEnvelope: Codable {
    let type: String
    let payload: ControlChangedPayload
}

struct RealtimeSessionBootstrap: Hashable {
    let secretValue: String
    let secretHint: String
    let expiresAt: Double?
    let model: String?
    let voice: String?
    let backendId: String?
    let backendLabel: String?
    let voiceProviderId: String?
    let voiceProviderLabel: String?
    let threadId: String?
}

struct RealtimeTranscriptEvent: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let detail: String?
    let timestamp: Date
}

struct RealtimePlaybackRequest: Identifiable, Hashable {
    let id = UUID()
    let text: String
}

struct VoiceCommandExchange: Hashable {
    let acknowledgement: String
    let displayResponse: String
    let spokenResponse: String?
    let shouldResumeListening: Bool
    let backendId: String?
    let backendLabel: String?
}

struct RealtimeCommandExchange: Hashable {
    let threadId: String?
    let transcript: String
    let exchange: VoiceCommandExchange
    let latencyMS: Int?
}

enum ResponsivenessBudgetStatus: Int, Hashable {
    case unknown = 0
    case healthy = 1
    case warning = 2
    case critical = 3

    var title: String {
        switch self {
        case .unknown:
            return "Collecting"
        case .healthy:
            return "Healthy"
        case .warning:
            return "Watch"
        case .critical:
            return "Needs Attention"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            return "waveform.path.ecg"
        case .healthy:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "exclamationmark.octagon.fill"
        }
    }
}

struct ResponsivenessBudgetMetric: Identifiable, Hashable {
    let id: String
    let title: String
    let sampleMS: Int?
    let healthyThresholdMS: Int
    let warningThresholdMS: Int

    var status: ResponsivenessBudgetStatus {
        guard let sampleMS else { return .unknown }
        if sampleMS <= healthyThresholdMS { return .healthy }
        if sampleMS <= warningThresholdMS { return .warning }
        return .critical
    }

    var sampleSummary: String {
        guard let sampleMS else { return "No sample yet" }
        return "\(sampleMS) ms"
    }

    var budgetSummary: String {
        "Target \(healthyThresholdMS) ms • soft ceiling \(warningThresholdMS) ms"
    }
}

struct SetupChecklistItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let isComplete: Bool
}

enum SpokenAlertMode: String, CaseIterable, Identifiable {
    case appOnly
    case backgroundCritical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appOnly:
            return "In App Only"
        case .backgroundCritical:
            return "Background Critical"
        }
    }

    var subtitle: String {
        switch self {
        case .appOnly:
            return "Speak only while helm is active on screen."
        case .backgroundCritical:
            return "Also speak approvals, blockers, and completions while helm is backgrounded or the phone is locked."
        }
    }
}

enum CommandResponseStyle: String, CaseIterable, Identifiable {
    case codex
    case concise
    case formal
    case jarvis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .concise:
            return "Concise"
        case .formal:
            return "Formal"
        case .jarvis:
            return "J.A.R.V.I.S."
        }
    }

    var subtitle: String {
        switch self {
        case .codex:
            return "Default. Calm, direct, and brief like normal Codex."
        case .concise:
            return "Even shorter acknowledgements and updates."
        case .formal:
            return "Polished and professional without becoming chatty."
        case .jarvis:
            return "A more stylized assistant cadence for acknowledgements and updates."
        }
    }
}

enum BridgeRealtimeMessage {
    case ready(BridgeReadyPayload)
    case threadSnapshot([RemoteThread])
    case runtimeSnapshot([RemoteRuntimeThread])
    case runtimeThread(RemoteRuntimeThread)
    case threadDetail(RemoteThreadDetail)
    case controlChanged(ControlChangedPayload)
}

struct VoiceTranscriptEntry: Identifiable, Hashable {
    enum Role: String {
        case user
        case assistant
        case system

        var title: String {
            switch self {
            case .user:
                return "You"
            case .assistant:
                return "Codex"
            case .system:
                return "helm"
            }
        }
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
}

enum VoiceRuntimeMode: String, CaseIterable, Identifiable {
    case localSpeech
    case openAIRealtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localSpeech:
            return "On-Device"
        case .openAIRealtime:
            return "OpenAI Realtime"
        }
    }

    var subtitle: String {
        switch self {
        case .localSpeech:
            return "Use Apple speech recognition with local acknowledgements and spoken confirmations."
        case .openAIRealtime:
            return "Use a ChatGPT-style full duplex Command path through the bridge."
        }
    }
}

enum LiveCommandPhase: String, Hashable {
    case idle
    case preparing
    case listening
    case dispatching
    case responding
    case retargeting
    case failed

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .listening:
            return "Listening"
        case .dispatching:
            return "Sending"
        case .responding:
            return "Responding"
        case .retargeting:
            return "Switching"
        case .failed:
            return "Needs Attention"
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "waveform.circle"
        case .preparing:
            return "arrow.triangle.2.circlepath.circle"
        case .listening:
            return "ear.and.waveform"
        case .dispatching:
            return "paperplane.circle"
        case .responding:
            return "speaker.wave.2.circle"
        case .retargeting:
            return "arrow.left.arrow.right.circle"
        case .failed:
            return "exclamationmark.octagon.fill"
        }
    }
}
