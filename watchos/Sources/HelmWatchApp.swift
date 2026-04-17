import SwiftUI

@main
struct HelmWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchSessionStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .task {
                    await store.start()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            store.updateScenePhase(newPhase == .active)
        }
    }
}
