#if os(iOS)
import SwiftUI

@main
struct PrisWubiIOSApp: App {
    @StateObject private var bridge = WubiBridge.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSHostRootView(bridge: bridge)
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        bridge.loadConfigAndUser()
                    } else if newPhase == .background {
                        bridge.flushUserDataIfNeeded()
                    }
                }
        }
    }
}
#endif
