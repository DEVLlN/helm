import Foundation

struct PendingCommandIntentPayload: Codable, Hashable {
    let id: UUID
    let command: String
    let threadQuery: String?
    let runtimeTarget: String?
    let createdAt: Double
}

enum CommandIntentInbox {
    private static let defaultsKey = "helm.pending-command-intent"
    private static let openCommandDefaultsKey = "helm.pending-open-command"

    static func enqueue(command: String, threadQuery: String?, runtimeTarget: String?) throws {
        let payload = PendingCommandIntentPayload(
            id: UUID(),
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            threadQuery: threadQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
            runtimeTarget: runtimeTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date.now.timeIntervalSince1970
        )

        let data = try JSONEncoder().encode(payload)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func consume() -> PendingCommandIntentPayload? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return try? JSONDecoder().decode(PendingCommandIntentPayload.self, from: data)
    }

    static func enqueueOpenCommand() {
        UserDefaults.standard.set(true, forKey: openCommandDefaultsKey)
    }

    static func consumeOpenCommand() -> Bool {
        let shouldOpen = UserDefaults.standard.bool(forKey: openCommandDefaultsKey)
        if shouldOpen {
            UserDefaults.standard.removeObject(forKey: openCommandDefaultsKey)
        }
        return shouldOpen
    }
}
