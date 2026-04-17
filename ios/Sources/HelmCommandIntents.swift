import AppIntents

enum HelmCommandRuntimeTarget: String, AppEnum {
    case automatic
    case codex
    case claudeCode

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Runtime")
    static let caseDisplayRepresentations: [HelmCommandRuntimeTarget: DisplayRepresentation] = [
        .automatic: "Automatic",
        .codex: "Codex",
        .claudeCode: "Claude Code",
    ]

    var backendID: String? {
        switch self {
        case .automatic:
            return nil
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude-code"
        }
    }
}

struct HelmCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Send helm Command"
    static let description = IntentDescription("Open helm and send a spoken command into the active session.")
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: String

    @Parameter(title: "Session", description: "Optional session name to target inside helm")
    var session: String?

    @Parameter(title: "Runtime", description: "Optionally prefer a specific active runtime.")
    var runtime: HelmCommandRuntimeTarget?

    static var parameterSummary: some ParameterSummary {
        Summary("Send Command \(\.$command)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CommandIntentInbox.enqueue(
            command: command,
            threadQuery: session,
            runtimeTarget: runtime?.backendID
        )
        return .result(dialog: "Opening helm and sending that Command.")
    }
}

struct OpenHelmCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Open helm Command"
    static let description = IntentDescription("Open helm directly to the Command tab.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        CommandIntentInbox.enqueueOpenCommand()
        return .result(dialog: "Opening helm Command.")
    }
}

struct HelmAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        let commandShortcut = AppShortcut(
            intent: HelmCommandIntent(),
            phrases: [
                "Send a Command with \(.applicationName)",
                "Open \(.applicationName) and send a Command",
            ],
            shortTitle: "Send Command",
            systemImageName: "waveform.and.mic"
        )

        let openShortcut = AppShortcut(
            intent: OpenHelmCommandIntent(),
            phrases: [
                "Open \(.applicationName) Command",
                "Show \(.applicationName) Command",
            ],
            shortTitle: "Open Command",
            systemImageName: "mic.circle"
        )

        return [commandShortcut, openShortcut]
    }
}
