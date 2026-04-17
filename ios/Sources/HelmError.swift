import Foundation

enum HelmError: LocalizedError {
    case bridgeUnreachable(url: String)
    case bridgeRequestFailed(status: Int, detail: String?)
    case pairingFailed(reason: String)
    case threadNotFound(id: String)
    case threadOperationFailed(operation: String, detail: String?)
    case approvalFailed(decision: String, detail: String?)
    case voiceSessionFailed(reason: String)
    case decodingFailed(type: String, detail: String?)
    case unknown(detail: String?)

    init(error: Error) {
        if let helmError = error as? HelmError {
            self = helmError
            return
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                self = .bridgeUnreachable(url: "timed out")
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                self = .bridgeUnreachable(url: "network unavailable")
            case .userAuthenticationRequired, .userCancelledAuthentication:
                self = .pairingFailed(reason: "Bridge pairing is missing or no longer valid.")
            case .cannotDecodeContentData:
                self = .decodingFailed(type: "bridge response", detail: nil)
            default:
                self = .unknown(detail: urlError.localizedDescription)
            }
            return
        }

        self = .unknown(detail: error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .bridgeUnreachable(let url):
            return "Cannot reach bridge at \(url)"
        case .bridgeRequestFailed(let status, let detail):
            return "Bridge returned \(status)\(detail.map { ": \($0)" } ?? "")"
        case .pairingFailed(let reason):
            return "Pairing failed: \(reason)"
        case .threadNotFound(let id):
            return "Session \(id) not found"
        case .threadOperationFailed(let op, let detail):
            return "\(op) failed\(detail.map { ": \($0)" } ?? "")"
        case .approvalFailed(let decision, let detail):
            return "Approval \(decision) failed\(detail.map { ": \($0)" } ?? "")"
        case .voiceSessionFailed(let reason):
            return "Voice session failed: \(reason)"
        case .decodingFailed(let type, let detail):
            return "Failed to decode \(type)\(detail.map { ": \($0)" } ?? "")"
        case .unknown(let detail):
            return detail ?? "An unknown error occurred"
        }
    }

    var logSummary: String {
        switch self {
        case .bridgeUnreachable:
            return "bridge_unreachable"
        case .bridgeRequestFailed(let status, _):
            return "bridge_request_failed_\(status)"
        case .pairingFailed:
            return "pairing_failed"
        case .threadNotFound:
            return "thread_not_found"
        case .threadOperationFailed(let operation, _):
            return "thread_operation_failed_\(operation)"
        case .approvalFailed(let decision, _):
            return "approval_failed_\(decision)"
        case .voiceSessionFailed:
            return "voice_session_failed"
        case .decodingFailed(let type, _):
            return "decoding_failed_\(type)"
        case .unknown:
            return "unknown_error"
        }
    }
}
