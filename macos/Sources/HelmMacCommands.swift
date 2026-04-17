import SwiftUI

struct HelmMacCommands: Commands {
    let store: MacSessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("helm") {
            Button("Open Command Panel") {
                Task { await store.openCommandPanelAndPrepare() }
            }
            .keyboardShortcut(.space, modifiers: [.command, .option])

            Button("Listen for Command") {
                Task { await store.openCommandPanelAndPrepare(startListening: true) }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Button("Refresh Sessions") {
                Task { await store.refreshAll() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button("Interrupt Selected Session") {
                Task { await store.interrupt() }
            }
            .keyboardShortcut(".", modifiers: [.command, .option])

            Button("Take Control of Selected Session") {
                Task { await store.takeControl() }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }
    }
}
