import SwiftUI

@main
struct HelmApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(sessionStore)
                .onOpenURL { url in
                    sessionStore.handleIncomingURL(url)
                }
                .task {
                    await sessionStore.start()
                    if scenePhase == .active {
                        await sessionStore.consumePendingCommandIntent()
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            sessionStore.updateScenePhase(newPhase == .active)
            guard newPhase == .active else { return }
            Task {
                await sessionStore.consumePendingCommandIntent()
            }
        }
    }
}
