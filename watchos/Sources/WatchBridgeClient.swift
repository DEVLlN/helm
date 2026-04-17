import Foundation
import Observation

@MainActor
@Observable
final class WatchBridgeClient {
    private static let baseURLDefaultsKey = "helm.watch.bridge.base-url"
    private static let pairingTokenDefaultsKey = "helm.watch.bridge.pairing-token"

    var baseURL: URL {
        didSet {
            UserDefaults.standard.set(baseURL.absoluteString, forKey: Self.baseURLDefaultsKey)
        }
    }

    var pairingToken: String {
        didSet {
            UserDefaults.standard.set(pairingToken, forKey: Self.pairingTokenDefaultsKey)
        }
    }

    var lastError: String?
    let identity: WatchClientIdentity
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?

    init(
        baseURL: URL? = nil,
        pairingToken: String? = nil,
        identity: WatchClientIdentity = WatchBridgeClient.makeIdentity()
    ) {
        let defaults = UserDefaults.standard
        let storedURL = defaults.string(forKey: Self.baseURLDefaultsKey).flatMap(URL.init(string:))
        self.session = Self.makeSession()
        self.baseURL = baseURL ?? storedURL ?? URL(string: "http://127.0.0.1:8787")!
        self.pairingToken = pairingToken ?? defaults.string(forKey: Self.pairingTokenDefaultsKey) ?? ""
        self.identity = identity
    }

    func fetchThreads() async throws -> [WatchRemoteThread] {
        let response: WatchThreadListResponse = try await request(path: "/api/threads")
        return response.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func fetchRuntime() async throws -> [WatchRuntimeThread] {
        let response: WatchRuntimeListResponse = try await request(path: "/api/runtime")
        return response.threads
    }

    func fetchThreadDetail(threadID: String) async throws -> WatchRemoteThreadDetail? {
        let response: WatchThreadDetailResponse = try await request(path: "/api/threads/\(threadID)")
        return response.thread
    }

    func fetchPairingStatus() async throws -> WatchBridgePairingStatus {
        let response: WatchPairingStatusEnvelope = try await request(path: "/api/pairing")
        return response.pairing
    }

    func decideApproval(_ approvalID: String, decision: String) async throws {
        _ = try await requestRaw(
            path: "/api/approvals/\(approvalID)/decision",
            method: "POST",
            body: ["decision": decision]
        )
    }

    func sendVoiceCommand(threadID: String, text: String) async throws -> String {
        let data = try await requestRaw(
            path: "/api/voice/command",
            method: "POST",
            body: [
                "threadId": threadID,
                "text": text,
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let acknowledgement = json["acknowledgement"] as? String
        else {
            return "On it."
        }

        return acknowledgement
    }

    func connectRealtime(
        onMessage: @escaping @MainActor (WatchBridgeRealtimeMessage) -> Void,
        onDisconnect: @escaping @MainActor (String?) -> Void
    ) {
        disconnectRealtime()

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            onDisconnect("Invalid bridge URL")
            return
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/mobile"

        guard let wsURL = components.url else {
            onDisconnect("Invalid bridge websocket URL")
            return
        }

        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 10
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveNextMessage(task: task, onMessage: onMessage, onDisconnect: onDisconnect)
    }

    func disconnectRealtime() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func request<T: Decodable>(path: String) async throws -> T {
        let data = try await requestRaw(path: path, method: "GET", body: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestRaw(path: String, method: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = decodeServerError(from: data) ?? "Request failed"
                throw URLError(.badServerResponse)
            }

            lastError = nil
            return data
        } catch {
            lastError = normalizeError(error)
            throw error
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 16
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private func normalizeError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Bridge request timed out. Check reachability."
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return "Bridge unreachable. Check the bridge host and network path."
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return "Bridge pairing is missing or no longer valid."
            default:
                break
            }
        }

        return error.localizedDescription
    }

    private func decodeServerError(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return error
        }

        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        return nil
    }

    private func receiveNextMessage(
        task: URLSessionWebSocketTask,
        onMessage: @escaping @MainActor (WatchBridgeRealtimeMessage) -> Void,
        onDisconnect: @escaping @MainActor (String?) -> Void
    ) {
        Task {
            do {
                let message = try await task.receive()
                guard webSocketTask === task else { return }

                switch message {
                case .string(let text):
                    try handleRealtimeText(text, onMessage: onMessage)
                case .data(let data):
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    try handleRealtimeText(text, onMessage: onMessage)
                @unknown default:
                    break
                }

                receiveNextMessage(task: task, onMessage: onMessage, onDisconnect: onDisconnect)
            } catch {
                guard webSocketTask === task else { return }
                webSocketTask = nil
                let message = normalizeError(error)
                lastError = message
                onDisconnect(message)
            }
        }
    }

    private func handleRealtimeText(
        _ text: String,
        onMessage: @escaping @MainActor (WatchBridgeRealtimeMessage) -> Void
    ) throws {
        let data = Data(text.utf8)
        let envelope = try JSONDecoder().decode(WatchBaseEnvelope.self, from: data)

        switch envelope.type {
        case "bridge.ready":
            let ready = try JSONDecoder().decode(WatchBridgeReadyEnvelope.self, from: data)
            Task { @MainActor in onMessage(.ready(ready.payload)) }
        case "helm.runtime.snapshot":
            let snapshot = try JSONDecoder().decode(WatchRuntimeSnapshotEnvelope.self, from: data)
            Task { @MainActor in onMessage(.runtimeSnapshot(snapshot.payload.threads)) }
        case "helm.runtime.thread":
            let update = try JSONDecoder().decode(WatchRuntimeThreadEnvelope.self, from: data)
            Task { @MainActor in onMessage(.runtimeThread(update.payload.thread)) }
        default:
            break
        }
    }

    private static func makeIdentity() -> WatchClientIdentity {
        let defaults = UserDefaults.standard
        let idKey = "helm.watch.client-id"
        let nameKey = "helm.watch.client-name"

        let id = defaults.string(forKey: idKey) ?? UUID().uuidString
        defaults.set(id, forKey: idKey)

        let name = defaults.string(forKey: nameKey) ?? "helm Watch"
        defaults.set(name, forKey: nameKey)

        return WatchClientIdentity(id: id, name: name)
    }
}

private struct WatchBaseEnvelope: Codable {
    let type: String
}
