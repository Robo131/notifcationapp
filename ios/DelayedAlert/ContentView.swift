import SwiftUI
import PhotosUI

private let amber = Color(red: 1.0, green: 0.78, blue: 0.17)
private let panel = Color(red: 0.08, green: 0.09, blue: 0.11)

struct ContentView: View {
    @EnvironmentObject var alerts: AlertCenter
    @State private var title = ""
    @State private var subtitle = ""
    @State private var message = ""
    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 10
    @AppStorage("sound") private var soundRaw = AlertSound.usa.rawValue
    @StateObject private var icon = IconStore()
    @State private var pickerItem: PhotosPickerItem?
    @ObservedObject private var wx = WeatherAlerts.shared
    @AppStorage("wx_enabled") private var wxOn = false
    @AppStorage("wx_met") private var wxMet = true
    @AppStorage("wx_iom") private var wxIoM = true
    @AppStorage("wx_level") private var wxLevel = 0
    @AppStorage("wx_region") private var wxRegion = "UK"
    @State private var previewing = false
    @State private var confirmation = ""
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var sound: AlertSound { AlertSound(rawValue: soundRaw) ?? .usa }
    private var total: TimeInterval { TimeInterval(hours * 3600 + minutes * 60 + seconds) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Delayed Alert").font(.largeTitle.bold())

                if alerts.allowed == false { deniedBanner }

                section("Notification") {
                    field("Title", text: $title)
                    field("Subtitle (optional)", text: $subtitle)
                    TextField("Message", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12).background(panel).cornerRadius(10)
                }

                section("Notification image") {
                    HStack(spacing: 14) {
                        Image(uiImage: icon.image ?? (UIImage(contentsOfFile: Bundle.main.path(forResource: "warning", ofType: "png") ?? "") ?? UIImage()))
                            .resizable().scaledToFill().frame(width: 56, height: 56)
                            .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Text(icon.image == nil ? "Choose image" : "Change image").foregroundColor(amber)
                            }
                            Button("Reset to default", role: .destructive) { icon.remove() }
                                .disabled(icon.image == nil)
                        }
                        Spacer()
                    }
                    .padding(12).background(panel).cornerRadius(10)
                    Text(icon.image == nil ? "Using the default icon." : "Custom image selected.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                section("Sound") {
                    Picker("Sound", selection: $soundRaw) {
                        ForEach(AlertSound.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.menu).tint(amber)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(panel).cornerRadius(10)
                    Button(previewing ? "Stop preview" : "Preview sound") {
                        if previewing { SoundPlayer.shared.stop() } else { SoundPlayer.shared.play(sound) }
                        previewing.toggle()
                    }.foregroundColor(amber)
                }

                section("Send after") {
                    HStack(spacing: 0) {
                        wheel("hours", 0...23, $hours)
                        wheel("min", 0...59, $minutes)
                        wheel("sec", 0...59, $seconds)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            preset("10 s", 0, 0, 10); preset("1 min", 0, 1, 0); preset("5 min", 0, 5, 0)
                            preset("15 min", 0, 15, 0); preset("1 hour", 1, 0, 0)
                        }
                    }
                }

                Button(action: send) {
                    Text("Schedule alert").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(canSend ? amber : Color.gray.opacity(0.3))
                        .foregroundColor(.black).cornerRadius(12)
                }
                .disabled(!canSend)
                if !confirmation.isEmpty { Text(confirmation).font(.footnote).foregroundColor(.secondary) }

                section("Pending") {
                    if alerts.pending.isEmpty {
                        Text("Nothing scheduled.").foregroundColor(.secondary)
                    } else {
                        ForEach(alerts.pending) { item in pendingRow(item) }
                        Button("Cancel all", role: .destructive) { alerts.cancelAll() }
                            .padding(.top, 4)
                    }
                }

                section("Weather alerts") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Send weather warnings", isOn: $wxOn).tint(amber)
                            .onChange(of: wxOn) { on in
                                if on {
                                    alerts.requestPermission { _ in }
                                    WxBackground.schedule()
                                    Task { await wx.check() }
                                }
                            }
                        if wxOn {
                            Toggle("Met Office", isOn: $wxMet).tint(amber)
                            if wxMet {
                                Picker("Region", selection: $wxRegion) {
                                    ForEach(WxSources.regions, id: \.code) { Text($0.name).tag($0.code) }
                                }.pickerStyle(.menu).tint(amber)
                            }
                            Toggle("Isle of Man Government", isOn: $wxIoM).tint(amber)
                            Picker("Minimum level", selection: $wxLevel) {
                                Text("Yellow+").tag(0); Text("Amber+").tag(1); Text("Red only").tag(2)
                            }.pickerStyle(.segmented)
                            Button(wx.checking ? "Checking…" : "Check now") { Task { await wx.check() } }
                                .foregroundColor(amber).disabled(wx.checking)
                            Text(wx.status).font(.footnote).foregroundColor(.secondary)
                        }
                        Text("Uses the sound and image chosen above. iOS decides when apps may refresh in the background, so warnings can arrive late. Not an official service; always check the Met Office and gov.im.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(12).background(panel).cornerRadius(10)
                }

                Text("Sound plays unless your iPhone is on silent. On silent, the phone vibrates if Settings > Sounds & Haptics > Vibrate on Silent is on.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self) { icon.set(d) }
                pickerItem = nil
            }
        }
        .background(Color(red: 0.043, green: 0.051, blue: 0.063).ignoresSafeArea())
        .onReceive(tick) { _ in alerts.refresh(); if previewing && !SoundPlayer.shared.isPlaying { previewing = false } }
        .onAppear { alerts.refresh(); alerts.checkPermission() }
    }

    private var canSend: Bool {
        total >= 1 && !(title.trimmingCharacters(in: .whitespaces).isEmpty && message.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func send() {
        let go = {
            alerts.schedule(title: title.isEmpty ? "Alert" : title, subtitle: subtitle, body: message, seconds: total, sound: sound, avatar: icon.image)
            confirmation = "Scheduled for \(Self.clock(Date().addingTimeInterval(total)))."
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        if alerts.allowed == true { go() }
        else { alerts.requestPermission { ok in if ok { go() } } }
    }

    private var deniedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notifications are turned off").font(.headline)
            Text("Turn them on for Delayed Alert in Settings to receive alerts.").font(.subheadline).foregroundColor(.secondary)
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }.foregroundColor(amber)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(panel).cornerRadius(10)
    }

    private func pendingRow(_ item: PendingAlert) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Alert" : item.title).font(.headline)
                if !item.body.isEmpty { Text(item.body).font(.subheadline).foregroundColor(.secondary).lineLimit(2) }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Sends in \(Self.remaining(item.fireDate.timeIntervalSince(ctx.date)))")
                        .font(.footnote.monospacedDigit()).foregroundColor(amber)
                }
            }
            Spacer()
            Button("Cancel", role: .destructive) { alerts.cancel(item.id) }.buttonStyle(.bordered)
        }
        .padding(12).background(panel).cornerRadius(10)
    }

    private func section<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            content()
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text).padding(12).background(panel).cornerRadius(10)
    }

    private func wheel(_ label: String, _ range: ClosedRange<Int>, _ value: Binding<Int>) -> some View {
        VStack(spacing: 0) {
            Picker(label, selection: value) {
                ForEach(Array(range), id: \.self) { Text("\($0)").tag($0) }
            }.pickerStyle(.wheel).frame(height: 110).clipped()
            Text(label).font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func preset(_ label: String, _ h: Int, _ m: Int, _ s: Int) -> some View {
        Button(label) { hours = h; minutes = m; seconds = s }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(panel).foregroundColor(.primary).cornerRadius(18)
    }

    static func remaining(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium; f.dateStyle = .none
        return f.string(from: d)
    }
}
