import Foundation
import OSLog

enum HelmLogger {
    private static let subsystem = "com.devlin.helm"

    static let bridge   = Logger(subsystem: subsystem, category: "bridge")
    static let sessions = Logger(subsystem: subsystem, category: "sessions")
    static let command  = Logger(subsystem: subsystem, category: "command")
    static let voice    = Logger(subsystem: subsystem, category: "voice")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
    static let pairing  = Logger(subsystem: subsystem, category: "pairing")
    static let performance = Logger(subsystem: subsystem, category: "performance")

    static let sessionsSignposter = OSSignposter(logger: sessions)
    static let uiSignposter = OSSignposter(logger: ui)
}
