import SwiftUI

@main
struct DelayedAlertApp: App {
    @StateObject private var alerts = AlertCenter()
    @Environment(\.scenePhase) private var phase

    init() { WxBackground.register() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(alerts)
                .preferredColorScheme(.dark)
        }
        .onChange(of: phase) { p in
            if p == .background { WxBackground.schedule() }
            if p == .active { Task { await WeatherAlerts.shared.check() } }
        }
    }
}
