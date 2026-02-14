import SwiftUI
#if DEBUG
import Apus
#endif

@main
struct ExampleApp: App {
    @StateObject private var appState = AppState()

    init() {
        #if DEBUG
        Apus.shared.start(interceptNetwork: true)
        Apus.shared.log("App launched", level: "info", source: "App")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    #if DEBUG
                    Apus.shared.register(appState, id: "appState")
                    #endif
                }
        }
    }
}
