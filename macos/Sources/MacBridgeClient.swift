import Foundation
import Observation

@MainActor
@Observable
final class MacBridgeClient {
    private static let baseURLDefaultsKey = "helm.mac.bridge.base-url"
    private static let pairingTokenDefaultsKey = "helm.mac.bridge.pairing-token"

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
    let identity: MacClientIdentity
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?

    init(baseURL: URL? = nil, pairingToken: String? = nil, identity: MacClientIdentity = MacBridgeClient.makeIdentity()) {
        let defaults = UserDefaults.standard
        let storedURL = defaults.string(forKey: Self.baseURLDefaultsKey).flatMap(URL.init(string:))
        self.session = Self.makeSession()
        self.baseURL = baseURL ?? storedURL ?? URL(string: "http://127.0.0.1:8787")!
        self.pairingToken = pairingToken ?? defaults.string(forKey: Self.pairingTokenDefaultsKey) ?? ""
        self.identity = identity
    }

    var hasPairingToken: Bool {
        !pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fetchThreads() async throws -> [MacRemoteThread] {
        let response: MacThreadListResponse = try await request(path: "/api/threads", method: "GET")
        return response.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func fetchPairingStatus() async throws -> MacBridgePairingStatus {
        let response: MacPairingStatusEnvelope = try await request(path: "/api/pairing", method: "GET")
        return response.pairing
    }

    func fetchBackends() async throws -> MacBackendListResponse {
        try await request(path: "/api/backends", method: "GET")
    }

    func fetchVoiceProviders() async throws -> MacVoiceProviderListResponse {
        try await request(path: "/api/voice/providers", method: "GET")
    }

    func fetchVoiceProviderBootstrap(
        providerID: String,
        threadID: String?,
        backendID: String?,
        style: String
    ) async throws -> String {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/voice/providers/\(providerID)/bootstrap"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }

        var queryItems = [URLQueryItem(name: "style", value: style)]
        if let threadID, !threadID.isEmpty {
            queryItems.append(URLQueryItem(name: "threadId", value: threadID))
        } else if let backendID, !backendID.isEmpty {
            queryItems.append(URLQueryItem(name: "backendId", value: backendID))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        applyAuthorization(to: &request)

        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            lastError = decodeServerError(from: payload) ?? "Request failed"
            throw URLError(.badServerResponse)
        }

        lastError = nil
        return prettyPrintedJSON(from: payload) ?? (String(data: payload, encoding: .utf8) ?? "")
    }

    func fetchRuntime() async throws -> [MacRuntimeThread] {
        let response: MacRuntimeListResponse = try await request(path: "/api/runtime", method: "GET")
        return response.threads
    }

    func fetchThreadDetail(threadID: String) async throws -> MacThreadDetail? {
        let response: MacThreadDetailResponse = try await request(path: "/api/threads/\(threadID)", method: "GET")
        return response.thread
    }

    func sendTurn(threadID: String, text: String) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/turns",
            method: "POST",
            body: [
                "text": text,
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )
    }

    func interrupt(threadID: String) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/interrupt",
            method: "POST",
            body: [
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )
    }

    func takeControl(threadID: String, force: Bool) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/control/take",
            method: "POST",
            body: [
                "clientId": identity.id,
                "clientName": identity.name,
                "force": force,
            ]
        )
    }

    func releaseControl(threadID: String) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/control/release",
            method: "POST",
            body: [
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )
    }

    func heartbeat(threadIDs: [String]) async throws {
        guard !threadIDs.isEmpty else { return }

        _ = try await requestRaw(
            path: "/api/control/heartbeat",
            method: "POST",
            body: [
                "clientId": identity.id,
                "clientName": identity.name,
                "threadIds": threadIDs,
            ]
        )
    }

    func decideApproval(approvalID: String, decision: String) async throws {
        _ = try await requestRaw(
            path: "/api/approvals/\(approvalID)/decision",
            method: "POST",
            body: ["decision": decision]
        )
    }

    func connectRealtime(
        onMessage: @escaping @MainActor (MacBridgeRealtimeMessage) -> Void,
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
        applyAuthorization(to: &request)

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        receiveNextMessage(task: task, onMessage: onMessage, onDisconnect: onDisconnect)
    }

    func disconnectRealtime() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func request<T: Decodable>(path: String, method: String) async throws -> T {
        let data = try await requestRaw(path: path, method: method, body: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestRaw(path: String, method: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)

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

    private func prettyPrintedJSON(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: pretty, encoding: .utf8)
        else {
            return nil
        }

        return text
    }

    private func applyAuthorization(to request: inout URLRequest) {
        let token = pairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func receiveNextMessage(
        task: URLSessionWebSocketTask,
        onMessage: @escaping @MainActor (MacBridgeRealtimeMessage) -> Void,
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
        onMessage: @escaping @MainActor (MacBridgeRealtimeMessage) -> Void
    ) throws {
        let data = Data(text.utf8)
        let envelope = try JSONDecoder().decode(MacBaseEnvelope.self, from: data)

        switch envelope.type {
        case "bridge.ready":
            let ready = try JSONDecoder().decode(MacBridgeReadyEnvelope.self, from: data)
            Task { @MainActor in onMessage(.ready(ready.payload)) }
        case "helm.runtime.snapshot":
            let snapshot = try JSONDecoder().decode(MacRuntimeSnapshotEnvelope.self, from: data)
            Task { @MainActor in onMessage(.runtimeSnapshot(snapshot.payload.threads)) }
        case "helm.runtime.thread":
            let update = try JSONDecoder().decode(MacRuntimeThreadEnvelope.self, from: data)
            Task { @MainActor in onMessage(.runtimeThread(update.payload.thread)) }
        case "helm.thread.detail":
            let update = try JSONDecoder().decode(MacThreadDetailEnvelope.self, from: data)
            Task { @MainActor in onMessage(.threadDetail(update.payload.thread)) }
        case "helm.control.changed":
            let control = try JSONDecoder().decode(MacControlChangedEnvelope.self, from: data)
            Task { @MainActor in onMessage(.controlChanged(control.payload)) }
        default:
            break
        }
    }

    private static func makeIdentity() -> MacClientIdentity {
        let defaults = UserDefaults.standard
        let key = "helm.mac.client.id"
        let storedID = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(storedID, forKey: key)
        return MacClientIdentity(id: storedID, name: "helm Mac (\(Host.current().localizedName ?? "Mac"))")
    }
}

private struct MacBaseEnvelope: Codable {
    let type: String
}
