import SwiftUI

@main
struct DelayedAlertApp: App {
    @StateObject private var alerts = AlertCenter()

    init() { WxBackground.register() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(alerts)
                .preferredColorScheme(.dark)
        }
    }
}
