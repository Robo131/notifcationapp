import SwiftUI

@main
struct DelayedAlertApp: App {
    @StateObject private var alerts = AlertCenter()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(alerts)
                .preferredColorScheme(.dark)
        }
    }
}
