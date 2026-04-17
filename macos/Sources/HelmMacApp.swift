import SwiftUI

@main
struct HelmMacApp: App {
    @State private var store: MacSessionStore

    init() {
        let store = MacSessionStore()
        _store = State(initialValue: store)
        Task { @MainActor in
            await store.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("helm", systemImage: store.menuBarSymbolName) {
            MenuBarRoot()
                .environment(store)
        }

        Window("helm Command", id: "command-panel") {
            CommandPanelView()
                .environment(store)
        }

        Settings {
            MacSettingsView()
                .environment(store)
        }
        .commands {
            HelmMacCommands(store: store)
        }
    }
}
