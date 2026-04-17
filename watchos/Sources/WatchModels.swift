import Foundation

struct WatchRemoteThread: Identifiable, Codable, Hashable {
    let id: String
    let name: String?
    let preview: String
    let cwd: String
    let status: String
    let updatedAt: Double
    let sourceKind: String?
    let backendId: String?
    let backendLabel: String?
    let backendKind: String?
    let controller: WatchThreadController?
}

struct WatchThreadListResponse: Codable {
    let threads: [WatchRemoteThread]
}

struct WatchThreadController: Codable, Hashable {
    let clientId: String
    let clientName: String
    let claimedAt: Double
    let lastSeenAt: Double
}

struct WatchClientIdentity {
    let id: String
    let name: String
}

struct WatchRuntimeListResponse: Codable {
    let threads: [WatchRuntimeThread]
}

struct WatchBackendCommandSemantics: Codable, Hashable {
    let routing: String
    let approvals: String
    let handoff: String
    let voiceInput: String
    let voiceOutput: String
    let supportsCommandFollowups: Bool
    let notes: String
}

struct WatchThreadCommandAffordances: Codable, Hashable {
    let canSendTurns: Bool
    let canInterrupt: Bool
    let canRespondToApprovals: Bool
    let canUseRealtimeCommand: Bool
    let showsOperationalSnapshot: Bool
    let notes: String
}

struct WatchRuntimeThread: Codable, Hashable, Identifiable {
    let threadId: String
    let phase: String
    let currentTurnId: String?
    let title: String?
    let detail: String?
    let lastUpdatedAt: Double
    let pendingApprovals: [WatchPendingApproval]

    var id: String { threadId }
}

struct WatchThreadDetailResponse: Codable {
    let thread: WatchRemoteThreadDetail?
}

struct WatchRemoteThreadDetail: Codable, Hashable, Identifiable {
    let id: String
    let name: String?
    let cwd: String
    let status: String
    let updatedAt: Double
    let backendId: String?
    let backendLabel: String?
    let backendKind: String?
    let command: WatchBackendCommandSemantics?
    let affordances: WatchThreadCommandAffordances?
}

struct WatchPendingApproval: Codable, Hashable, Identifiable {
    let requestId: String
    let threadId: String
    let title: String
    let detail: String?
    let canRespond: Bool

    var id: String { requestId }
}

struct WatchBridgePairingStatus: Codable, Hashable {
    let token: String?
    let tokenHint: String
    let filePath: String
}

struct WatchPairingStatusEnvelope: Codable {
    let pairing: WatchBridgePairingStatus
}

struct WatchAttentionEvent: Identifiable, Hashable {
    let id = UUID()
    let threadId: String
    let title: String
    let detail: String?
    let timestamp: Date
}

enum WatchResponsivenessBudgetStatus: Int, Hashable {
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

struct WatchResponsivenessBudgetMetric: Identifiable, Hashable {
    let id: String
    let title: String
    let sampleMS: Int?
    let healthyThresholdMS: Int
    let warningThresholdMS: Int

    var status: WatchResponsivenessBudgetStatus {
        guard let sampleMS else { return .unknown }
        if sampleMS <= healthyThresholdMS { return .healthy }
        if sampleMS <= warningThresholdMS { return .warning }
        return .critical
    }

    var sampleSummary: String {
        guard let sampleMS else { return "No sample yet" }
        return "\(sampleMS) ms"
    }
}

struct WatchBridgeReadyPayload: Codable {
    let message: String
}

struct WatchBridgeReadyEnvelope: Codable {
    let type: String
    let payload: WatchBridgeReadyPayload
}

struct WatchRuntimeSnapshotPayload: Codable {
    let threads: [WatchRuntimeThread]
}

struct WatchRuntimeSnapshotEnvelope: Codable {
    let type: String
    let payload: WatchRuntimeSnapshotPayload
}

struct WatchRuntimeThreadPayload: Codable {
    let thread: WatchRuntimeThread
}

struct WatchRuntimeThreadEnvelope: Codable {
    let type: String
    let payload: WatchRuntimeThreadPayload
}

enum WatchBridgeRealtimeMessage {
    case ready(WatchBridgeReadyPayload)
    case runtimeSnapshot([WatchRuntimeThread])
    case runtimeThread(WatchRuntimeThread)
}
