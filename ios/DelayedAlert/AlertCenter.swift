import SwiftUI
import UserNotifications
import UIKit
import AVFoundation

enum AlertSound: String, CaseIterable, Identifiable {
    case usa, uk
    var id: String { rawValue }
    var label: String { self == .usa ? "Notification Sound USA" : "Notification Sound UK" }
    var file: String { "alert_\(rawValue).wav" }
}

/// Plays the full sound in-app. Uses the ambient category so the silent switch is respected.
final class SoundPlayer {
    static let shared = SoundPlayer()
    private var player: AVAudioPlayer?
    var isPlaying: Bool { player?.isPlaying ?? false }
    func play(_ s: AlertSound) {
        guard let url = Bundle.main.url(forResource: "alert_\(s.rawValue)", withExtension: "wav") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
    func stop() { player?.stop() }
}

struct PendingAlert: Identifiable {
    let id: String
    let title: String
    let body: String
    let fireDate: Date
}

final class AlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var pending: [PendingAlert] = []
    @Published var allowed: Bool? = nil   // nil = not asked yet
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        checkPermission()
        refresh()
    }

    func checkPermission() {
        center.getNotificationSettings { s in
            DispatchQueue.main.async {
                switch s.authorizationStatus {
                case .notDetermined: self.allowed = nil
                case .denied: self.allowed = false
                default: self.allowed = true
                }
            }
        }
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async { self.allowed = ok; done(ok) }
        }
    }

    func schedule(title: String, subtitle: String, body: String, seconds: TimeInterval, sound: AlertSound) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = subtitle
        c.body = body
        c.sound = UNNotificationSound(named: UNNotificationSoundName(sound.file))
        c.userInfo = ["sound": sound.rawValue]
        // Transparent picture shown on the right of the notification.
        if let src = Bundle.main.url(forResource: "warning", withExtension: "png") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try? FileManager.default.copyItem(at: src, to: tmp)
            if let a = try? UNNotificationAttachment(identifier: "icon", url: tmp, options: nil) { c.attachments = [a] }
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: trigger)
        center.add(req) { _ in DispatchQueue.main.async { self.refresh() } }
    }

    func refresh() {
        center.getPendingNotificationRequests { reqs in
            let items = reqs.compactMap { r -> PendingAlert? in
                guard let t = r.trigger as? UNTimeIntervalNotificationTrigger,
                      let d = t.nextTriggerDate() else { return nil }
                return PendingAlert(id: r.identifier, title: r.content.title, body: r.content.body, fireDate: d)
            }.sorted { $0.fireDate < $1.fireDate }
            DispatchQueue.main.async { self.pending = items }
        }
    }

    func cancel(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        refresh()
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        refresh()
    }

    // Show banner + play sound even when the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let raw = notification.request.content.userInfo["sound"] as? String ?? "usa"
        DispatchQueue.main.async {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            SoundPlayer.shared.play(AlertSound(rawValue: raw) ?? .usa)   // full-length playback while the app is open
            self.refresh()
        }
        handler([.banner, .list])
    }
}
