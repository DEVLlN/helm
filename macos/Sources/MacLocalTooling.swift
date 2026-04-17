import Foundation

enum MacLocalTooling {
    private static let sourceFileURL = URL(fileURLWithPath: #filePath)

    static var repoRootURL: URL {
        sourceFileURL
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repo root
    }

    static func scriptURL(named name: String) -> URL {
        repoRootURL.appendingPathComponent("scripts/\(name)")
    }

    static func runScript(named name: String, arguments: [String] = []) async throws -> String {
        let scriptURL = scriptURL(named: name)
        return try await runExecutable(scriptURL.path, arguments: arguments, workingDirectory: repoRootURL)
    }

    private static func runExecutable(
        _ executablePath: String,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outText = String(decoding: outData, as: UTF8.self)
                let errText = String(decoding: errData, as: UTF8.self)
                let combined = [outText, errText]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: outText.isEmpty || errText.isEmpty ? "" : "\n")

                if process.terminationStatus == 0 {
                    continuation.resume(returning: combined)
                } else {
                    let message = combined.isEmpty ? "Command failed with exit code \(process.terminationStatus)." : combined
                    continuation.resume(throwing: NSError(
                        domain: "MacLocalTooling",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
