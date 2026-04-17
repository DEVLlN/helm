import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class BridgeClient {
    private static let baseURLDefaultsKey = "helm.bridge.base-url"
    private static let pairingTokenDefaultsKey = "helm.bridge.pairing-token"
    private static let candidateURLsDefaultsKey = "helm.bridge.candidate-urls"

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
    var candidateBridgeURLs: [String] {
        didSet {
            UserDefaults.standard.set(candidateBridgeURLs, forKey: Self.candidateURLsDefaultsKey)
        }
    }
    var lastError: String?
    let identity: ClientIdentity
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?

    init(
        baseURL: URL? = nil,
        pairingToken: String? = nil,
        identity: ClientIdentity = BridgeClient.makeIdentity()
    ) {
        let defaults = UserDefaults.standard
        let storedURL = defaults.string(forKey: Self.baseURLDefaultsKey).flatMap(URL.init(string:))
        let storedCandidateURLs = defaults.stringArray(forKey: Self.candidateURLsDefaultsKey) ?? []
        self.session = Self.makeSession()
        self.baseURL = baseURL ?? storedURL ?? URL(string: "http://127.0.0.1:8787")!
        self.pairingToken = pairingToken ?? defaults.string(forKey: Self.pairingTokenDefaultsKey) ?? ""
        self.candidateBridgeURLs = Self.normalizedBridgeURLStrings(storedCandidateURLs)
        self.identity = identity
    }

    var hasPairingToken: Bool {
        !pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fetchThreads() async throws -> [RemoteThread] {
        let response: ThreadListResponse = try await request(path: "/api/threads", method: "GET")
        return response.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func fetchArchivedThreads() async throws -> [RemoteThread] {
        let response: ThreadListResponse = try await request(path: "/api/threads/archived", method: "GET")
        return response.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    func fetchRuntime() async throws -> [RemoteRuntimeThread] {
        let response: RuntimeListResponse = try await request(path: "/api/runtime", method: "GET")
        return response.threads
    }

    func fetchThreadDetail(threadID: String) async throws -> RemoteThreadDetail? {
        let response: ThreadDetailResponse = try await request(
            path: "/api/threads/\(threadID)",
            method: "GET",
            timeoutInterval: 20
        )
        return response.thread
    }

    func openThread(threadID: String) async throws -> ThreadOpenResponse {
        try await request(
            path: "/api/threads/\(threadID)/open",
            method: "POST",
            timeoutInterval: 30
        )
    }

    func fetchPairingStatus() async throws -> BridgePairingStatus {
        let response: PairingStatusEnvelope = try await request(path: "/api/pairing", method: "GET")
        return response.pairing
    }

    func rememberBridgeCandidates(_ urls: [String]) {
        let merged = urls + candidateBridgeURLs + [baseURL.absoluteString]
        candidateBridgeURLs = Self.normalizedBridgeURLStrings(merged)
    }

    @discardableResult
    func adoptPreferredReachableRemoteBridgeURL(from urls: [String]) async -> Bool {
        let candidates = urls.isEmpty ? candidateBridgeURLs : urls
        guard let preferred = Self.sortedBridgeCandidateURLs(candidates).first(where: Self.isTailscaleBridgeURL) else {
            return false
        }

        guard !Self.bridgeURLsMatch(preferred, baseURL) else {
            return false
        }

        guard await probeBridgeHealth(at: preferred) else {
            return false
        }

        baseURL = preferred
        return true
    }

    func useReachableCandidateBridgeURL() async -> Bool {
        for candidate in Self.sortedBridgeCandidateURLs(candidateBridgeURLs) {
            guard !Self.bridgeURLsMatch(candidate, baseURL) else { continue }
            guard await probeBridgeHealth(at: candidate) else { continue }
            baseURL = candidate
            lastError = nil
            return true
        }

        return false
    }

    func fetchBackends() async throws -> BackendListResponse {
        try await request(path: "/api/backends", method: "GET")
    }

    func fetchVoiceProviders() async throws -> VoiceProviderListResponse {
        try await request(path: "/api/voice/providers", method: "GET")
    }

    func fetchVoiceProviderBootstrap(
        providerID: String,
        threadID: String?,
        backendID: String?,
        style: CommandResponseStyle
    ) async throws -> String {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/voice/providers/\(providerID)/bootstrap"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }

        var queryItems = [URLQueryItem(name: "style", value: style.rawValue)]
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
            let message = decodeServerError(from: payload) ?? "Request failed"
            let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
            lastError = error.errorDescription
            throw error
        }

        lastError = nil
        return prettyPrintedJSON(from: payload) ?? (String(data: payload, encoding: .utf8) ?? "")
    }

    func fetchSessionLaunchOptions(backendID: String?) async throws -> SessionLaunchOptions {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/session-launch/options"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        if let backendID, !backendID.isEmpty {
            components.queryItems = [URLQueryItem(name: "backendId", value: backendID)]
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        applyAuthorization(to: &request)

        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = decodeServerError(from: payload) ?? "Request failed"
            let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
            lastError = error.errorDescription
            throw error
        }

        do {
            lastError = nil
            return try JSONDecoder().decode(SessionLaunchOptionsEnvelope.self, from: payload).options
        } catch {
            let helmError = HelmError.decodingFailed(type: "SessionLaunchOptions", detail: nil)
            lastError = helmError.errorDescription
            throw helmError
        }
    }

    func fetchDirectorySuggestions(prefix: String) async throws -> [DirectorySuggestion] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/fs/directory-suggestions"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "prefix", value: prefix)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        applyAuthorization(to: &request)

        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = decodeServerError(from: payload) ?? "Request failed"
            let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
            lastError = error.errorDescription
            throw error
        }

        do {
            lastError = nil
            return try JSONDecoder().decode(DirectorySuggestionResponse.self, from: payload).directories
        } catch {
            let helmError = HelmError.decodingFailed(type: "DirectorySuggestionResponse", detail: nil)
            lastError = helmError.errorDescription
            throw helmError
        }
    }

    func fetchFileTagSuggestions(cwd: String, prefix: String) async throws -> [FileTagSuggestion] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/fs/file-suggestions"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "cwd", value: cwd),
            URLQueryItem(name: "prefix", value: prefix),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        applyAuthorization(to: &request)

        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = decodeServerError(from: payload) ?? "Request failed"
            let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
            lastError = error.errorDescription
            throw error
        }

        do {
            lastError = nil
            return try JSONDecoder().decode(FileSuggestionResponse.self, from: payload).files
        } catch {
            let helmError = HelmError.decodingFailed(type: "FileSuggestionResponse", detail: nil)
            lastError = helmError.errorDescription
            throw helmError
        }
    }

    func fetchSkillSuggestions(prefix: String, cwd: String?) async throws -> [SkillSuggestion] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/skills/suggestions"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "prefix", value: prefix),
            URLQueryItem(name: "cwd", value: cwd ?? ""),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        applyAuthorization(to: &request)

        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = decodeServerError(from: payload) ?? "Request failed"
            let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
            lastError = error.errorDescription
            throw error
        }

        do {
            lastError = nil
            return try JSONDecoder().decode(SkillSuggestionResponse.self, from: payload).skills
        } catch {
            let helmError = HelmError.decodingFailed(type: "SkillSuggestionResponse", detail: nil)
            lastError = helmError.errorDescription
            throw helmError
        }
    }

    func createThread(draft: NewSessionDraft) async throws -> ThreadCreateResponse {
        var body: [String: Any] = [
            "cwd": draft.normalizedWorkingDirectory,
            "clientId": identity.id,
            "clientName": identity.name,
            "launchMode": draft.launchMode.rawValue,
        ]
        if let backendID = draft.backendId, !backendID.isEmpty {
            body["backendId"] = backendID
        }
        if let model = draft.normalizedModel(for: draft.backendId), !model.isEmpty {
            body["model"] = model
        }
        if let effort = draft.reasoningEffort, !effort.isEmpty {
            body["reasoningEffort"] = effort
        }
        if let codexFastMode = draft.codexFastMode {
            body["codexFastMode"] = codexFastMode
        }
        if draft.backendId == "claude-code" {
            body["claudeContextMode"] = draft.claudeContextMode.rawValue
        }

        return try await request(
            path: "/api/threads",
            method: "POST",
            body: body
        )
    }

    func archiveThread(threadID: String) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/archive",
            method: "POST",
            body: [
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )
    }

    func unarchiveThread(threadID: String) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/unarchive",
            method: "POST",
            body: [
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )
    }

    func renameThread(threadID: String, name: String) async throws {
        _ = try await requestRaw(
            path: "/api/threads/\(threadID)/name",
            method: "POST",
            body: [
                "name": name,
            ]
        )
    }

    func sendTurn(
        threadID: String,
        text: String,
        deliveryMode: TurnDeliveryMode = .queue,
        imageAttachments: [ComposerImageAttachment] = [],
        fileAttachments: [ComposerFileAttachment] = []
    ) async throws -> TurnDeliveryResponse? {
        var body: [String: Any] = [
            "text": text,
            "deliveryMode": deliveryMode.rawValue,
            "clientId": identity.id,
            "clientName": identity.name,
        ]
        if !imageAttachments.isEmpty {
            body["imageAttachments"] = imageAttachments.map { attachment in
                [
                    "id": attachment.id,
                    "filename": attachment.filename,
                    "mimeType": attachment.mimeType,
                    "data": attachment.data.base64EncodedString(),
                ]
            }
        }
        if !fileAttachments.isEmpty {
            body["fileAttachments"] = fileAttachments.map { attachment in
                [
                    "id": attachment.id,
                    "filename": attachment.filename,
                    "mimeType": attachment.mimeType,
                    "data": attachment.data.base64EncodedString(),
                ]
            }
        }

        let payload = try await requestRaw(
            path: "/api/threads/\(threadID)/turns",
            method: "POST",
            body: body,
            timeoutInterval: imageAttachments.isEmpty && fileAttachments.isEmpty ? nil : 30
        )
        return try? JSONDecoder().decode(TurnDeliveryResponse.self, from: payload)
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

    func sendTerminalInput(threadID: String, key: TerminalInputKey) async throws -> TerminalInputResponse? {
        return try await sendTerminalInputs(threadID: threadID, keys: [key])
    }

    func sendTerminalInputs(threadID: String, keys: [TerminalInputKey]) async throws -> TerminalInputResponse? {
        let payload = try await requestRaw(
            path: "/api/threads/\(threadID)/input",
            method: "POST",
            body: [
                "inputs": keys.map(\.rawValue),
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )
        return try? JSONDecoder().decode(TerminalInputResponse.self, from: payload)
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

    func sendVoiceCommand(
        threadID: String,
        text: String,
        style: CommandResponseStyle
    ) async throws -> VoiceCommandExchange {
        let payload = try await requestRaw(
            path: "/api/voice/command",
            method: "POST",
            body: [
                "threadId": threadID,
                "text": text,
                "style": style.rawValue,
                "clientId": identity.id,
                "clientName": identity.name,
            ]
        )

        guard
            let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return VoiceCommandExchange(
                acknowledgement: "On it.",
                displayResponse: "On it.",
                spokenResponse: "On it.",
                shouldResumeListening: true,
                backendId: nil,
                backendLabel: nil
            )
        }

        let backend = json["backend"] as? [String: Any]
        let acknowledgement = (json["acknowledgement"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayResponse = (json["displayResponse"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenResponse = (json["spokenResponse"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitSpokenResponse = json.keys.contains("spokenResponse")

        let fallback = acknowledgement?.isEmpty == false ? acknowledgement! : "On it."
        return VoiceCommandExchange(
            acknowledgement: fallback,
            displayResponse: displayResponse?.isEmpty == false ? displayResponse! : fallback,
            spokenResponse: hasExplicitSpokenResponse
                ? (spokenResponse?.isEmpty == false ? spokenResponse : nil)
                : fallback,
            shouldResumeListening: json["shouldResumeListening"] as? Bool ?? true,
            backendId: backend?["id"] as? String,
            backendLabel: backend?["label"] as? String
        )
    }

    func fetchSpeechAudio(
        text: String,
        threadID: String? = nil,
        backendID: String? = nil,
        voiceProviderID: String? = nil,
        style: CommandResponseStyle? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/voice/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)
        var payload: [String: Any] = ["text": text]
        if let threadID, !threadID.isEmpty {
            payload["threadId"] = threadID
        } else if let backendID, !backendID.isEmpty {
            payload["backendId"] = backendID
        }
        if let style {
            payload["style"] = style.rawValue
        }
        if let voiceProviderID, !voiceProviderID.isEmpty {
            payload["voiceProviderId"] = voiceProviderID
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = decodeServerError(from: data) ?? "Request failed"
            let error = HelmError.voiceSessionFailed(reason: message)
            lastError = error.errorDescription
            throw error
        }

        lastError = nil
        return data
    }

    func decideApproval(approvalID: String, decision: String) async throws {
        _ = try await requestRaw(
            path: "/api/approvals/\(approvalID)/decision",
            method: "POST",
            body: ["decision": decision]
        )
    }

    func fetchRealtimeSessionBootstrap(
        style: CommandResponseStyle,
        threadID: String?,
        backendID: String?,
        voiceProviderID: String?
    ) async throws -> RealtimeSessionBootstrap {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/realtime/client-secret"),
            resolvingAgainstBaseURL: false
        ) else {
            throw URLError(.badURL)
        }
        var queryItems = [
            URLQueryItem(name: "style", value: style.rawValue),
        ]
        if let threadID, !threadID.isEmpty {
            queryItems.append(URLQueryItem(name: "threadId", value: threadID))
        } else if let backendID, !backendID.isEmpty {
            queryItems.append(URLQueryItem(name: "backendId", value: backendID))
        }
        if let voiceProviderID, !voiceProviderID.isEmpty {
            queryItems.append(URLQueryItem(name: "voiceProviderId", value: voiceProviderID))
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
            let message = decodeServerError(from: payload) ?? "Request failed"
            let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
            lastError = error.errorDescription
            throw error
        }

        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            let error = HelmError.decodingFailed(type: "realtime bootstrap", detail: nil)
            lastError = error.errorDescription
            throw error
        }

        let session = json["session"] as? [String: Any]
        let clientSecret = json["client_secret"] as? [String: Any]
        let backend = json["backend"] as? [String: Any]
        let voiceProvider = json["voiceProvider"] as? [String: Any]
        let secretValue =
            (clientSecret?["value"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !secretValue.isEmpty else {
            let error = HelmError.decodingFailed(type: "realtime client secret", detail: "Realtime bootstrap did not include a client secret.")
            lastError = error.errorDescription
            throw error
        }

        let secretHint: String
        if secretValue.count > 12 {
            secretHint = "\(secretValue.prefix(8))...\(secretValue.suffix(4))"
        } else {
            secretHint = secretValue
        }

        lastError = nil
        return RealtimeSessionBootstrap(
            secretValue: secretValue,
            secretHint: secretHint,
            expiresAt: clientSecret?["expires_at"] as? Double,
            model: session?["model"] as? String,
            voice: ((session?["audio"] as? [String: Any])?["output"] as? [String: Any])?["voice"] as? String,
            backendId: backend?["id"] as? String,
            backendLabel: backend?["label"] as? String,
            voiceProviderId: voiceProvider?["id"] as? String,
            voiceProviderLabel: voiceProvider?["label"] as? String,
            threadId: threadID
        )
    }

    func connectRealtime(
        onMessage: @escaping @MainActor (BridgeRealtimeMessage) -> Void,
        onDisconnect: @escaping @MainActor (String?) -> Void
    ) {
        disconnectRealtime()

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            onDisconnect(HelmError.bridgeUnreachable(url: baseURL.absoluteString).errorDescription)
            return
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws/mobile"

        guard let wsURL = components.url else {
            onDisconnect(HelmError.bridgeUnreachable(url: baseURL.absoluteString).errorDescription)
            return
        }

        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 10
        applyAuthorization(to: &request)

        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        webSocketTask = task
        task.resume()

        receiveNextMessage(task: task, onMessage: onMessage, onDisconnect: onDisconnect)
    }

    func disconnectRealtime() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: [String: Any]? = nil,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> T {
        let data = try await requestRaw(
            path: path,
            method: method,
            body: body,
            timeoutInterval: timeoutInterval
        )
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let helmError = HelmError.decodingFailed(type: String(describing: T.self), detail: nil)
            lastError = helmError.errorDescription
            throw helmError
        }
    }

    private func requestRaw(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval ?? 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        func execute(_ request: URLRequest) async throws -> Data {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let message = decodeServerError(from: data) ?? "Request failed"
                let error = HelmError.bridgeRequestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, detail: message)
                lastError = error.errorDescription
                throw error
            }

            lastError = nil
            return data
        }

        do {
            return try await execute(request)
        } catch {
            if method.uppercased() == "GET", Self.isTransientNetworkError(error) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                do {
                    return try await execute(request)
                } catch {
                    let helmError = HelmError(error: error)
                    lastError = helmError.errorDescription
                    throw helmError
                }
            }

            let helmError = HelmError(error: error)
            lastError = helmError.errorDescription
            throw helmError
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 18
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.multipathServiceType = .handover
        return URLSession(configuration: configuration)
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: nsError.code) {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .timedOut:
            return true
        default:
            return false
        }
    }

    private func probeBridgeHealth(at url: URL) async -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func normalizedBridgeURLStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for string in strings {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), isUsableBridgeURL(url) else { continue }
            let normalized = normalizedBridgeURLString(url)
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }

        return Array(result.prefix(12))
    }

    private static func sortedBridgeCandidateURLs(_ strings: [String]) -> [URL] {
        let urls = normalizedBridgeURLStrings(strings).compactMap(URL.init(string:))
        return urls.sorted { lhs, rhs in
            bridgeCandidateScore(lhs) < bridgeCandidateScore(rhs)
        }
    }

    private static func bridgeCandidateScore(_ url: URL) -> Int {
        if isTailscaleBridgeURL(url) { return 0 }
        guard let host = url.host?.lowercased() else { return 3 }
        if host == "127.0.0.1" || host == "localhost" || host == "::1" { return 3 }
        return 1
    }

    private static func isUsableBridgeURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }

        guard let host = url.host, !host.isEmpty else {
            return false
        }

        return host != "0.0.0.0" && host != "::"
    }

    private static func isTailscaleBridgeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        if host.hasSuffix(".ts.net") || host.hasSuffix(".beta.tailscale.net") {
            return true
        }

        if host.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func bridgeURLsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedBridgeURLString(lhs) == normalizedBridgeURLString(rhs)
    }

    private static func normalizedBridgeURLString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? url.absoluteString
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
        onMessage: @escaping @MainActor (BridgeRealtimeMessage) -> Void,
        onDisconnect: @escaping @MainActor (String?) -> Void
    ) {
        Task {
            do {
                let message = try await task.receive()
                guard webSocketTask === task else { return }

                let decoded: BridgeRealtimeMessage?
                switch message {
                case .string(let text):
                    decoded = try Self.decodeRealtimeMessage(from: text)
                case .data(let data):
                    decoded = try Self.decodeRealtimeMessage(from: data)
                @unknown default:
                    decoded = nil
                }

                if let decoded {
                    onMessage(decoded)
                }

                receiveNextMessage(task: task, onMessage: onMessage, onDisconnect: onDisconnect)
            } catch {
                guard webSocketTask === task else { return }
                webSocketTask = nil
                let helmError = HelmError(error: error)
                lastError = helmError.errorDescription
                onDisconnect(helmError.errorDescription)
            }
        }
    }

    nonisolated private static func decodeRealtimeMessage(from text: String) throws -> BridgeRealtimeMessage? {
        try decodeRealtimeMessage(from: Data(text.utf8))
    }

    nonisolated private static func decodeRealtimeMessage(from data: Data) throws -> BridgeRealtimeMessage? {
        let envelope = try JSONDecoder().decode(BaseEnvelope.self, from: data)

        switch envelope.type {
        case "bridge.ready":
            let ready = try JSONDecoder().decode(BridgeReadyEnvelope.self, from: data)
            return .ready(ready.payload)
        case "helm.runtime.snapshot":
            let snapshot = try JSONDecoder().decode(RuntimeSnapshotEnvelope.self, from: data)
            return .runtimeSnapshot(snapshot.payload.threads)
        case "helm.threads.snapshot":
            let snapshot = try JSONDecoder().decode(ThreadSnapshotEnvelope.self, from: data)
            return .threadSnapshot(snapshot.payload.threads)
        case "helm.runtime.thread":
            let update = try JSONDecoder().decode(RuntimeThreadEnvelope.self, from: data)
            return .runtimeThread(update.payload.thread)
        case "helm.thread.detail":
            let update = try JSONDecoder().decode(ThreadDetailEnvelope.self, from: data)
            return .threadDetail(update.payload.thread)
        case "helm.control.changed":
            let control = try JSONDecoder().decode(ControlChangedEnvelope.self, from: data)
            return .controlChanged(control.payload)
        default:
            return nil
        }
    }

    private static func makeIdentity() -> ClientIdentity {
        let defaults = UserDefaults.standard
        let key = "helm.client.id"
        let storedID = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(storedID, forKey: key)

        let deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "helm iPad" : "helm iPhone"
        let clientName = "\(deviceName) (\(UIDevice.current.name))"
        return ClientIdentity(id: storedID, name: clientName)
    }
}

private struct BaseEnvelope: Codable {
    let type: String
}
