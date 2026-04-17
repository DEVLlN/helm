import Foundation

private func isHelmManagedLaunchSource(_ source: String?) -> Bool {
    source == "helm-runtime-wrapper" || source == "helm-shell-wrapper"
}

struct MacRemoteThread: Identifiable, Codable, Hashable {
    let id: String
    let name: String?
    let preview: String
    let cwd: String
    let status: String
    let updatedAt: Double
    let sourceKind: String?
    let launchSource: String?
    let backendId: String?
    let backendLabel: String?
    let backendKind: String?
    let controller: MacThreadController?

    var isHelmManaged: Bool {
        isHelmManagedLaunchSource(launchSource)
    }
}

struct MacThreadListResponse: Codable {
    let threads: [MacRemoteThread]
}

struct MacRuntimeListResponse: Codable {
    let threads: [MacRuntimeThread]
}

struct MacThreadController: Codable, Hashable {
    let clientId: String
    let clientName: String
    let claimedAt: Double
    let lastSeenAt: Double
}

struct MacClientIdentity {
    let id: String
    let name: String
}

struct MacPairingStatusEnvelope: Codable {
    let pairing: MacBridgePairingStatus
}

struct MacBridgePairingStatus: Codable, Hashable {
    let token: String?
    let tokenHint: String
    let filePath: String
    let createdAt: Double
    let rotatedAt: Double
    let suggestedBridgeURLs: [String]?
    let setupURL: String?
}

struct MacBackendCapabilities: Codable, Hashable {
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

struct MacBackendCommandSemantics: Codable, Hashable {
    let routing: String
    let approvals: String
    let handoff: String
    let voiceInput: String
    let voiceOutput: String
    let supportsCommandFollowups: Bool
    let notes: String
}

struct MacThreadCommandAffordances: Codable, Hashable {
    let canSendTurns: Bool
    let canInterrupt: Bool
    let canRespondToApprovals: Bool
    let canUseRealtimeCommand: Bool
    let showsOperationalSnapshot: Bool
    let sessionAccess: String
    let notes: String
}

struct MacBackendSummary: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let description: String
    let isDefault: Bool
    let available: Bool
    let availabilityDetail: String?
    let capabilities: MacBackendCapabilities
    let command: MacBackendCommandSemantics
}

struct MacBackendListResponse: Codable {
    let defaultBackendId: String
    let backends: [MacBackendSummary]
}

struct MacVoiceProviderSummary: Codable, Hashable, Identifiable {
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

struct MacVoiceProviderListResponse: Codable {
    let defaultVoiceProviderId: String
    let providers: [MacVoiceProviderSummary]
}

struct MacRuntimeThread: Codable, Hashable, Identifiable {
    let threadId: String
    let phase: String
    let currentTurnId: String?
    let title: String?
    let detail: String?
    let lastUpdatedAt: Double
    let pendingApprovals: [MacPendingApproval]
    let recentEvents: [MacRuntimeEvent]

    var id: String { threadId }
}

struct MacPendingApproval: Codable, Hashable, Identifiable {
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

struct MacRuntimeEvent: Codable, Hashable, Identifiable {
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

struct MacThreadDetailResponse: Codable {
    let thread: MacThreadDetail?
}

struct MacThreadDetail: Codable, Hashable, Identifiable {
    let id: String
    let name: String?
    let cwd: String
    let status: String
    let updatedAt: Double
    let sourceKind: String?
    let launchSource: String?
    let backendId: String?
    let backendLabel: String?
    let backendKind: String?
    let command: MacBackendCommandSemantics?
    let affordances: MacThreadCommandAffordances?
    let turns: [MacThreadTurn]

    var isHelmManaged: Bool {
        isHelmManagedLaunchSource(launchSource)
    }
}

struct MacThreadTurn: Codable, Hashable, Identifiable {
    let id: String
    let status: String
    let error: String?
    let items: [MacThreadItem]
}

struct MacThreadItem: Codable, Hashable, Identifiable {
    let id: String
    let type: String
    let title: String
    let detail: String?
    let status: String?
}

struct MacApprovalDecisionResponse: Codable {
    let ok: Bool
}

struct MacBridgeReadyPayload: Codable {
    let message: String
}

struct MacBridgeReadyEnvelope: Codable {
    let type: String
    let payload: MacBridgeReadyPayload
}

struct MacRuntimeSnapshotPayload: Codable {
    let threads: [MacRuntimeThread]
}

struct MacRuntimeSnapshotEnvelope: Codable {
    let type: String
    let payload: MacRuntimeSnapshotPayload
}

struct MacRuntimeThreadPayload: Codable {
    let thread: MacRuntimeThread
}

struct MacRuntimeThreadEnvelope: Codable {
    let type: String
    let payload: MacRuntimeThreadPayload
}

struct MacThreadDetailPayload: Codable {
    let thread: MacThreadDetail
}

struct MacThreadDetailEnvelope: Codable {
    let type: String
    let payload: MacThreadDetailPayload
}

struct MacControlChangedPayload: Codable {
    let threadId: String
    let controller: MacThreadController?
}

struct MacControlChangedEnvelope: Codable {
    let type: String
    let payload: MacControlChangedPayload
}

enum MacResponsivenessBudgetStatus: Int, Hashable {
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

struct MacResponsivenessBudgetMetric: Identifiable, Hashable {
    let id: String
    let title: String
    let sampleMS: Int?
    let healthyThresholdMS: Int
    let warningThresholdMS: Int

    var status: MacResponsivenessBudgetStatus {
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

enum MacBridgeRealtimeMessage {
    case ready(MacBridgeReadyPayload)
    case runtimeSnapshot([MacRuntimeThread])
    case runtimeThread(MacRuntimeThread)
    case threadDetail(MacThreadDetail)
    case controlChanged(MacControlChangedPayload)
}
