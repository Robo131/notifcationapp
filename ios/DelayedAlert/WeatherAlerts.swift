import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

struct WxWarning {
    let id: String
    let source: String
    let level: Int      // 0 yellow, 1 amber, 2 red
    let text: String
}

// MARK: - helpers

private func rx(_ pattern: String, _ s: String) -> [String]? {
    guard let r = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
          let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
}

private func allCaptures(_ pattern: String, _ s: String) -> [String] {
    guard let r = try? NSRegularExpression(pattern: pattern) else { return [] }
    return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
        Range($0.range(at: 1), in: s).map { String(s[$0]) }
    }
}

private func plain(_ html: String) -> String {
    var s = html
    for p in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
        s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
    }
    for (a, b) in [("&amp;", "&"), ("&nbsp;", " "), ("&#39;", "'"), ("&#8217;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")] {
        s = s.replacingOccurrences(of: a, with: b)
    }
    return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func levelOf(_ s: String) -> Int {
    let l = s.lowercased()
    return l.contains("red") ? 2 : l.contains("amber") ? 1 : 0
}

private func fetch(_ urlString: String) async throws -> Data {
    guard let url = URL(string: urlString) else { throw URLError(.badURL) }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.setValue("DelayedAlert/1.0 (personal weather alerts)", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return data
}

private final class RSSParser: NSObject, XMLParserDelegate {
    struct Item { var title = "", desc = "", guid = "" }
    var items: [Item] = []
    private var cur: Item?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "item" { cur = Item() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": cur?.title = t
        case "description": cur?.desc = t
        case "guid": cur?.guid = t
        case "item": if let c = cur { items.append(c) }; cur = nil
        default: break
        }
    }
}

/// Wording modelled on phone emergency alerts, e.g.
/// "Met Office: AMBER WARNING – WIND affecting Wales from 18:00 Sat until 15:00 Sun. Be prepared."
private func emergency(_ source: String, _ colour: String, _ hazard: String, _ place: String,
                       _ when: String, _ summary: String) -> String {
    let c = colour.uppercased()
    let advice = c == "RED" ? "Take action." : c == "AMBER" ? "Be prepared." : "Be aware."
    let head = "\(source): \(c) WARNING – \(hazard.uppercased()) \(place)" + (when.isEmpty ? "." : " \(when).")
    return "\(head) \(advice) \(summary)".trimmingCharacters(in: .whitespaces)
}

// MARK: - sources

enum WxSources {
    struct Region: Identifiable {
        let name: String
        let code: String
        var id: String { code }
    }
    static let regions = [
        Region(name: "UK-wide", code: "UK"), Region(name: "North West England", code: "nw"),
        Region(name: "Northern Ireland", code: "ni"), Region(name: "Wales", code: "wl")
    ]

    /// Met Office severe weather warnings (public RSS feed, one per region).
    static func metOffice(region: String) async throws -> [WxWarning] {
        let data = try await fetch("https://www.metoffice.gov.uk/public/data/PWSCache/WarningsRSS/Region/\(region)")
        let p = RSSParser()
        let xml = XMLParser(data: data); xml.delegate = p
        guard xml.parse() else { throw URLError(.cannotParseResponse) }
        return p.items.map { i in
            let desc = plain(i.desc)
            let colour = ["Red", "Amber", "Yellow"].first { i.title.localizedCaseInsensitiveContains($0) } ?? "Yellow"
            let both = rx("(?i)warning of (.+)$", i.title)?[1] ?? i.title
            let parts = both.components(separatedBy: " affecting ")
            let hazard = parts[0]
            let place = parts.count > 1 ? "affecting \(parts[1])" : "in this area"
            var when = ""
            if let m = rx("valid from (.+?) to ([^.]+)", desc) { when = "from \(m[1]) until \(m[2])" }
            let text = emergency("Met Office", colour, hazard, place, when, "")
            return WxWarning(id: "met:" + (i.guid.isEmpty ? i.title : i.guid), source: "Met Office",
                             level: levelOf(i.title), text: String(text.prefix(500)))
        }
    }

    private static func londonDate(_ time: String, _ day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "HH:mm d MMMM yyyy"
        return f.date(from: "\(time) \(day)")
    }

    /// Isle of Man Government warnings (issued by Ronaldsway Met Office), read from gov.im/weather pages.
    static func isleOfMan() async throws -> [WxWarning] {
        let list = String(decoding: try await fetch("https://www.gov.im/weather/"), as: UTF8.self)
        var slugs: [String] = []
        for s in allCaptures("href=\"(?:https://www\\.gov\\.im)?/weather/([a-z0-9\\-]+)/?\"", list) where !slugs.contains(s) {
            slugs.append(s)
        }
        var out: [WxWarning] = []
        for slug in slugs.prefix(12) {
            guard let data = try? await fetch("https://www.gov.im/weather/\(slug)") else { continue }
            let t = plain(String(decoding: data, as: UTF8.self))
            guard t.contains("Colour code"), t.contains("Adverse conditions"),
                  let until = rx("Until (\\d{2}:\\d{2}) (GMT|BST) on \\w+ (\\d{1,2} \\w+ \\d{4})", t),
                  let end = londonDate(until[1], until[3]), end > Date() else { continue }
            let type = rx("Warning type (.+?) Colour code", t)?[1] ?? "Weather warning"
            var colour = "Yellow"
            if let r = t.range(of: "Colour code") {
                colour = rx("(Yellow|Amber|Red)", String(t[r.upperBound...]))?[1] ?? "Yellow"
            }
            let summary = rx("Until \\d{2}:\\d{2} (?:GMT|BST) on \\w+ \\d{1,2} \\w+ \\d{4} (.+?) More information", t)?[1] ?? ""
            let issued = rx("Issued at (\\d{2}:\\d{2} \\w+ on \\w+ \\d{1,2} \\w+ \\d{4})", t)?[1] ?? ""
            let day = "(\\d{2}:\\d{2}) (?:GMT|BST) on (\\w{3})\\w* (\\d{1,2}) (\\w{3})\\w* \\d{4}"
            let untilStr = rx("Until " + day, t).map { "\($0[1]) \($0[2]) \($0[3]) \($0[4])" } ?? "\(until[1])"
            var when = "until \(untilStr)"
            if let f = rx("From " + day, t) { when = "from \(f[1]) \(f[2]) \(f[3]) \(f[4]) until \(untilStr)" }
            let text = emergency("Isle of Man Government", colour, type, "on the Isle of Man", when, summary)
            out.append(WxWarning(id: "iom:\(slug):\(issued)", source: "Isle of Man Government",
                                 level: levelOf(colour), text: String(text.prefix(500))))
        }
        return out
    }
}

// MARK: - checker

@MainActor
final class WeatherAlerts: ObservableObject {
    static let shared = WeatherAlerts()
    @Published var status = "Not checked yet."
    @Published var checking = false

    func check() async {
        let d = UserDefaults.standard
        guard d.bool(forKey: "wx_enabled"), !checking else { return }
        checking = true
        defer { checking = false }
        let minLevel = d.integer(forKey: "wx_level")
        var all: [WxWarning] = []
        var notes: [String] = []

        if d.object(forKey: "wx_met") as? Bool ?? true {
            do { all += try await WxSources.metOffice(region: d.string(forKey: "wx_region") ?? "UK"); notes.append("Met Office OK") }
            catch { notes.append("Met Office unavailable") }
        }
        if d.object(forKey: "wx_iom") as? Bool ?? true {
            do { all += try await WxSources.isleOfMan(); notes.append("Isle of Man OK") }
            catch { notes.append("Isle of Man unavailable") }
        }

        var seen = Set(d.stringArray(forKey: "wx_seen") ?? [])
        let fresh = all.filter { $0.level >= minLevel && !seen.contains($0.id) }
        for w in fresh { await post(w); seen.insert(w.id) }
        d.set(Array(seen.suffix(300)), forKey: "wx_seen")

        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        status = "Checked \(f.string(from: Date())). \(notes.joined(separator: ", ")). \(fresh.count) new."
    }

    private func post(_ w: WxWarning) async {
        let c = UNMutableNotificationContent()
        c.title = "Emergency Alert"
        c.body = w.text
        let sound = AlertSound(rawValue: UserDefaults.standard.string(forKey: "sound") ?? "usa") ?? .usa
        c.sound = UNNotificationSound(named: UNNotificationSoundName(sound.file))
        c.userInfo = ["sound": sound.rawValue]
        var content: UNNotificationContent = c
        if let img = IconStore.loadSaved(), let up = AlertCenter.withAvatar(c, img, name: "Emergency Alert", sound: sound) { content = up }
        let req = UNNotificationRequest(identifier: "wx-" + w.id, content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - background refresh (iOS decides when this actually runs)

enum WxBackground {
    static let id = "com.delayedalert.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await WeatherAlerts.shared.check()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
