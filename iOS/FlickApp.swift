import SwiftUI

@main
struct FlickApp: App {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase
    @State private var benchmark: Benchmark?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .onAppear {
                    RemoteClient.removeLegacyPINs()
                    client.startBrowsing()
                    if ProcessInfo.processInfo.arguments.contains("-bench"), benchmark == nil {
                        let b = Benchmark(client: client)
                        benchmark = b
                        b.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .active && client.showsTrackpad
                    if phase == .active { client.resumeIfNeeded() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        if client.showsTrackpad {
            ControlView(client: client)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
                .statusBarHidden()
                .preferredColorScheme(.dark)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        } else {
            DiscoveryView()
        }
    }
}

// MARK: - Discovery

struct DiscoveryView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var pinFor: RemoteClient.Peer?
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if client.peers.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs running Flick…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(client.peers) { peer in
                        Button {
                            if !client.connect(to: peer) { pin = ""; pinFor = peer }
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(peer.id)
                                Spacer()
                                if case .connecting(let n) = client.phase, n == peer.id { ProgressView() }
                            }
                        }
                        .contextMenu {
                            Button("Pair again with PIN") { pin = ""; pinFor = peer }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if case .failed(let msg) = client.phase { Text(msg).foregroundStyle(.red) }
                        if let note = client.note { Text(note) }
                        Text("Flick controls your Mac through the free Flick for Mac app. Install it from [getflick.net](https://getflick.net) and open it, and your Mac appears here. The pairing PIN is in its menu bar icon.")
                        Text("Your iPhone and Mac connect over the same Wi-Fi, or directly over peer-to-peer Wi-Fi when there's no shared network.")
                    }
                }
            }
            .navigationTitle("Flick")
            .alert("Pair with \(pinFor?.id ?? "")", isPresented: Binding(get: { pinFor != nil }, set: { if !$0 { pinFor = nil } })) {
                TextField("6-digit PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                Button("Connect") { if let p = pinFor { client.pair(with: p, pin: pin) }; pinFor = nil }
                Button("Cancel", role: .cancel) { pinFor = nil }
            } message: {
                Text("Enter the PIN shown in the Flick menu on your Mac.")
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sensitivity") private var sensitivity = 1.6
    @AppStorage("acceleration") private var acceleration = 1.0
    @AppStorage("scrollSpeed") private var scrollSpeed = 1.0
    @AppStorage("naturalScroll") private var naturalScroll = true
    @AppStorage("autoKeyboard") private var autoKeyboard = true
    @AppStorage("motionTransport") private var motionTransport = MotionSender.Mode.both.rawValue
    @AppStorage("peerToPeer") private var peerToPeer = true
    @AppStorage("predictive") private var predictive = false
    @AppStorage("stripSide") private var stripSide = StripSide.left.rawValue
    @AppStorage("seenHints") private var seenHints = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pointer") {
                    LabeledContent("Speed") { Slider(value: $sensitivity, in: 0.5...4) }
                    LabeledContent("Acceleration") { Slider(value: $acceleration, in: 0...3) }
                    Toggle("Predictive pointer", isOn: $predictive)
                }
                Section {
                    Picker("One-hand scroll strip", selection: $stripSide) {
                        ForEach(StripSide.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Button("Show gesture hints again") { seenHints = false }
                } header: { Text("One-handed") } footer: {
                    Text("Swipe up and down along that edge to scroll. Swipe up from the bottom edge for Mission Control; swipe along it to switch Spaces. With the phone on a table: three-finger swipes and a four-finger spread work like a Mac trackpad.")
                }
                Section("Scrolling") {
                    LabeledContent("Speed") { Slider(value: $scrollSpeed, in: 0.3...3) }
                    Toggle("Natural scrolling", isOn: $naturalScroll)
                }
                Section {
                    Toggle("Show keyboard when a text field is focused", isOn: $autoKeyboard)
                }
                Section {
                    Picker("Pointer path", selection: $motionTransport) {
                        ForEach(MotionSender.Mode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Allow peer-to-peer Wi-Fi (AWDL)", isOn: $peerToPeer)
                } header: { Text("Transport") } footer: {
                    Text("Peer-to-peer Wi-Fi lets you connect without a shared network but can add latency spikes. Takes effect after relaunching the app.")
                }
                Section("Connection") {
                    if case .connected(let n) = client.phase { LabeledContent("Mac", value: n) }
                    LabeledContent("Round trip", value: client.rttMs.map { String(format: "%.1f ms", $0) } ?? "—")
                    LabeledContent("Pointer channel", value: client.udpActive ? "UDP" : "TCP (fallback)")
                    Button("Disconnect", role: .destructive) { client.disconnect(); dismiss() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
