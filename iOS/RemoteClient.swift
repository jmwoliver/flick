import Foundation
import Network
import CryptoKit
import UIKit

/// Finds Macs over Bonjour (Wi-Fi or AWDL peer-to-peer), connects with TLS ECDHE-PSK,
/// then opens the UDP motion channel. All public API is main-thread.
///
/// Pairing: the first connection to a Mac uses its PIN. The Mac answers with a long-term pairing
/// key, which is kept in the Keychain (this device only) and used for every later connection.
/// The PIN itself is never stored.
final class RemoteClient: ObservableObject {
    struct Peer: Identifiable, Hashable {
        let id: String
        let endpoint: NWEndpoint
    }

    enum Phase: Equatable {
        case browsing
        case connecting(String)
        case connected(String)
        case reconnecting(String)
        case failed(String)
    }

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var phase: Phase = .browsing
    @Published private(set) var rttMs: Double?
    @Published private(set) var udpActive = false
    @Published private(set) var note: String?

    @Published private(set) var dock: [DockApp] = []
    @Published private(set) var frontApp = ""

    /// Fires on every focus change reported by the Mac.
    var onFocus: ((FocusInfo) -> Void)?
    /// Live text around the caret for the focused field (token, text).
    var onContext: ((Int, TextContext) -> Void)?

    /// Something worth showing on the main screen (otherwise the screen stays clean).
    var problem: String? {
        if case .reconnecting = phase { return "Reconnecting…" }
        return note
    }

    /// `-demo`: fake a connected Mac so the UI can be reviewed without a connection.
    let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
    private(set) var lastFocus: FocusInfo?

    private let queue = DispatchQueue(label: "flick.client", qos: .userInteractive)
    private var browser: NWBrowser?
    private var channel: FramedChannel<ClientMessage, ServerMessage>?
    private var udp: NWConnection?
    let motion = MotionSender()
    private var sessionKey: SymmetricKey?
    /// Benchmark hook: round-trip time of each TCP ping, in ms.
    var onPong: ((Double) -> Void)?
    private var inputSeq: UInt32 = 0
    private let encoder = JSONEncoder()
    private var touchDelays: [Double] = []
    private var leads: [Double] = []
    private var movesSent = 0
    private var telemetryTimer: Timer?
    private var currentPeer: Peer?
    /// What the current connection authenticates with. A PIN is kept only in memory, until the
    /// Mac replaces it with a pairing key.
    private var currentCredential: Credential?
    /// Reconnect attempts in a row that never got as far as the Mac's hello.
    private var failedAttempts = 0
    private var wantConnected = false
    private var pingTimer: Timer?
    private var probeTimer: Timer?
    private var reconnectWork: DispatchWorkItem?

    var showsTrackpad: Bool {
        switch phase { case .connected, .reconnecting: true; default: false }
    }

    // MARK: Discovery

    func startBrowsing() {
        if isDemo { startDemo(); return }
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = BB.peerToPeer
        let b = NWBrowser(for: .bonjour(type: BB.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Peer? in
                if case .service(let name, _, _, _) = r.endpoint { return Peer(id: name, endpoint: r.endpoint) }
                return nil
            }.sorted { $0.id < $1.id }
            DispatchQueue.main.async { self?.peersChanged(found) }
        }
        b.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { DispatchQueue.main.async { self?.note = "Browse failed: \(e)" } }
            if case .waiting(let e) = st { DispatchQueue.main.async { self?.note = "Local network: \(e). Check Settings → Privacy → Local Network." } }
        }
        b.start(queue: queue)
        browser = b
    }

    /// Browsing keeps AWDL (peer-to-peer Wi-Fi) busy; stop it once we're connected.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private func peersChanged(_ found: [Peer]) {
        peers = found
        // Auto-connect to the Mac we used last time (or, for benchmarks, any paired Mac).
        let bench = ProcessInfo.processInfo.arguments.contains("-bench")
        let canAuto: Bool
        switch phase {
        case .browsing: canAuto = true
        case .failed: canAuto = bench
        default: canAuto = false
        }
        guard canAuto else { return }
        let last = UserDefaults.standard.string(forKey: "lastPeer")
        if let peer = found.first(where: { $0.id == last }) ?? (bench ? found.first(where: { isPaired(with: $0) }) : nil) {
            _ = connect(to: peer)
        }
    }

    /// Stable per-install identity; the Mac pairs with exactly one of these.
    static let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()

    private static func keychainAccount(_ macName: String) -> String { "mac.\(macName)" }

    private func pairingKey(for name: String) -> Data? { Keychain.data(Self.keychainAccount(name)) }

    func isPaired(with peer: Peer) -> Bool { pairingKey(for: peer.id) != nil }

    /// Older builds stored PINs in UserDefaults. Remove them.
    static func removeLegacyPINs() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("pin.") { d.removeObject(forKey: key) }
    }

    // MARK: Connection

    /// Connect to a Mac this phone is paired with. Returns false if it isn't paired yet.
    @discardableResult
    func connect(to peer: Peer) -> Bool {
        guard let key = pairingKey(for: peer.id) else { return false }
        failedAttempts = 0
        start(peer, .paired(key))
        return true
    }

    /// Pair with a Mac using the PIN from its menu bar.
    func pair(with peer: Peer, pin: String) {
        failedAttempts = 0
        start(peer, .pin(pin))
    }

    private func start(_ peer: Peer, _ credential: Credential) {
        teardown()
        wantConnected = true
        currentPeer = peer
        currentCredential = credential
        UserDefaults.standard.set(peer.id, forKey: "lastPeer")
        if case .reconnecting = phase {} else { phase = .connecting(peer.id) }
        open(peer: peer, credential: credential)
    }

    func disconnect() {
        wantConnected = false
        currentCredential = nil
        UserDefaults.standard.removeObject(forKey: "lastPeer")
        teardown()
        phase = .browsing
    }

    private func stop(showing reason: String) {
        wantConnected = false
        currentCredential = nil
        UserDefaults.standard.removeObject(forKey: "lastPeer")
        teardown()
        phase = .failed(reason)
    }

    /// Call when the app returns to the foreground.
    func resumeIfNeeded() {
        guard wantConnected, channel == nil, let peer = currentPeer, let credential = currentCredential, !credential.isPin else { return }
        phase = .reconnecting(peer.id)
        start(peer, credential)
    }

    private func open(peer: Peer, credential: Credential) {
        let conn = NWConnection(to: peer.endpoint, using: BBSecurity.controlParameters(credential))
        let ch = FramedChannel<ClientMessage, ServerMessage>(conn)
        channel = ch
        ch.onMessage = { [weak self] msg in DispatchQueue.main.async { self?.handle(msg) } }
        ch.onClose = { [weak self, weak ch] err in
            DispatchQueue.main.async {
                guard let self, self.channel === ch else { return }
                self.connectionLost(err)
            }
        }
        conn.stateUpdateHandler = { [weak self, weak ch] st in
            guard let ch else { return }
            switch st {
            case .ready:
                ch.startReceiving()
                ch.send(.hello(deviceName: UIDevice.current.name, deviceID: RemoteClient.deviceID))
            case .waiting(let e), .failed(let e):
                DispatchQueue.main.async { self?.handshakeFailed(ch, peer: peer, credential: credential, error: e) }
            default: break
            }
        }
        conn.start(queue: queue)
        // A Bonjour endpoint can resolve to several addresses. If the handshake fails on one and
        // another just times out, the connection can sit in "preparing" indefinitely, never
        // reporting the TLS error. Give up after a while instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak ch] in
            guard let self, let ch, self.channel === ch else { return }
            if case .ready = ch.connection.state { return }
            self.handshakeFailed(ch, peer: peer, credential: credential, error: nil)
        }
    }

    private func handshakeFailed(_ ch: FramedChannel<ClientMessage, ServerMessage>, peer: Peer, credential: Credential, error: NWError?) {
        guard channel === ch else { return }
        if case .connected = phase {
            // An established session dropped: reconnect (with the pairing key by now).
            ch.cancel()
            return connectionLost(error)
        }
        var wrongKey = false
        if case .tls? = error { wrongKey = true }
        if credential.isPin {
            // One try per PIN entry: retrying would use up the Mac's allowance of wrong PINs.
            stop(showing: wrongKey ? "Wrong PIN for \(peer.id)."
                                   : "Couldn't pair with \(peer.id). Check the PIN in the Flick menu on the Mac and try again.")
        } else if wrongKey {
            // The Mac unpaired this phone, so its pairing key is gone for good.
            Keychain.delete(Self.keychainAccount(peer.id))
            stop(showing: "\(peer.id) no longer recognizes this iPhone. Tap it and enter the PIN from the Flick menu on the Mac to pair again.")
        } else if failedAttempts >= 2, peers.contains(where: { $0.id == peer.id }) {
            // The Mac is advertising but keeps refusing us. Usually that's a refused pairing key
            // whose error got hidden behind a timeout on another address. Stop and say what to do.
            stop(showing: "Couldn't reconnect to \(peer.id). If you unpaired this iPhone on the Mac, touch and hold \(peer.id), then choose Pair again with PIN.")
        } else {
            failedAttempts += 1
            ch.cancel()
            connectionLost(error)
        }
    }

    private func connectionLost(_ err: NWError?) {
        teardown()
        guard wantConnected, let peer = currentPeer else {
            phase = .browsing
            return
        }
        phase = .reconnecting(peer.id)
        note = err.map { "\($0)" }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnected, let credential = self.currentCredential else { return }
            // Only a pairing key is retried automatically, never a PIN.
            guard !credential.isPin else { return self.stop(showing: "Couldn't pair with \(peer.id). Try again.") }
            // Re-resolve by name in case the endpoint changed.
            let target = self.peers.first(where: { $0.id == peer.id }) ?? peer
            self.start(target, credential)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func teardown() {
        reconnectWork?.cancel(); reconnectWork = nil
        pingTimer?.invalidate(); pingTimer = nil
        probeTimer?.invalidate(); probeTimer = nil
        channel?.onClose = nil
        channel?.cancel(); channel = nil
        udp?.cancel(); udp = nil
        udpActive = false
        motion.end()
        telemetryTimer?.invalidate(); telemetryTimer = nil
        rttMs = nil
    }

    private func handle(_ msg: ServerMessage) {
        switch msg {
        case .hello(let mac, let port, let key):
            failedAttempts = 0
            phase = .connected(mac)
            note = nil
            motion.begin(key: SymmetricKey(data: key))
            sessionKey = SymmetricKey(data: key)
            inputSeq = 0
            openMotionChannel(port: port)
            telemetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.flushTelemetry() }
            pingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                // Also keeps the Wi-Fi radio out of deep power-save between gestures.
                self?.channel?.send(.ping(CACurrentMediaTime()))
            }
        case .paired(let key):
            // The Mac accepted our PIN and made us its paired phone. Use the key from now on.
            guard let peer = currentPeer else { return }
            Keychain.set(key, Self.keychainAccount(peer.id))
            currentCredential = .paired(key)
        case .udpOK:
            udpActive = true
            motion.udpActive = true
            probeTimer?.invalidate(); probeTimer = nil
        case .focus(let info):
            lastFocus = info
            onFocus?(info)
        case .pong(let t):
            let sample = (CACurrentMediaTime() - t) * 1000
            onPong?(sample)
            rttMs = rttMs.map { $0 * 0.7 + sample * 0.3 } ?? sample
        case .status(let s):
            note = s
        case .textContext(let token, let ctx):
            onContext?(token, ctx)
        case .dock(let apps, let front):
            dock = apps
            frontApp = front
            let missing = apps.map(\.bundleID).filter { !IconCache.shared.has($0) }
            if !missing.isEmpty { channel?.send(.requestIcons(missing)) }
        case .appIcon(let id, let png):
            IconCache.shared.store(id, png: png)
        case .unpaired(let reason):
            if let peer = currentPeer { Keychain.delete(Self.keychainAccount(peer.id)) }
            stop(showing: reason)
        case .rejected(let reason), .kicked(let reason):
            // The Mac said no (paired with another phone) or ended the session from its menu.
            // Retrying would just fight it, so stop until the user taps the Mac again.
            stop(showing: reason)
        }
    }

    private func openMotionChannel(port: UInt16) {
        guard port != 0, let ch = channel,
              case .hostPort(let host, _)? = ch.connection.currentPath?.remoteEndpoint,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        // `host` is the exact address the TLS channel resolved to (including the %awdl0 /
        // %en0 scope for link-local), so UDP takes the same radio path.
        let conn = NWConnection(host: host, port: nwPort, using: BBSecurity.motionParameters())
        conn.start(queue: queue)
        udp = conn
        motion.attachUDP(conn)
        var tries = 0
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            tries += 1
            if tries > 50 { t.invalidate(); return }   // stay on TCP fallback
            self.motion.probe()
        }
    }

    // MARK: Sending (main thread)

    func move(dx: Double, dy: Double, leadX: Double = 0, leadY: Double = 0) {
        movesSent += 1
        if !motion.move(dx: dx, dy: dy, leadX: leadX, leadY: leadY) { send(.move(dx: dx, dy: dy)) }
    }

    func recordLead(_ ms: Double) { leads.append(ms) }

    /// Time from the touch sample being taken to us handing its packet to the network.
    func recordTouchDelay(_ ms: Double) { touchDelays.append(ms) }

    private func flushTelemetry() {
        guard !touchDelays.isEmpty else { return }
        let rate = Double(movesSent) / 5
        send(.log(String(format: "touch→send ms %@ | %.0f moves/s | mode=%@ udp=%@ ble=%@ bleDropped=%d",
                         Stats.summary(touchDelays, decimals: 2), rate, motion.mode.rawValue,
                         udpActive ? "up" : "down", motion.ble.ready ? "up" : "down", motion.ble.dropped)))
        if !leads.isEmpty { send(.log("prediction lead ms \(Stats.summary(leads, decimals: 2))")) }
        touchDelays.removeAll(); leads.removeAll()
        movesSent = 0
    }

    private func startDemo() {
        phase = .connected("Demo Mac")
        dock = [
            DockApp(bundleID: "com.apple.finder", name: "Finder", running: true, pinned: true),
            DockApp(bundleID: "com.apple.Safari", name: "Safari", running: true, pinned: true),
            DockApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", running: true, pinned: true),
            DockApp(bundleID: "com.apple.mail", name: "Mail", running: false, pinned: true),
            DockApp(bundleID: "com.apple.Terminal", name: "Terminal", running: true, pinned: true),
            DockApp(bundleID: "com.microsoft.VSCode", name: "Code", running: true, pinned: true),
            DockApp(bundleID: "com.apple.Music", name: "Music", running: false, pinned: true),
            DockApp(bundleID: "com.apple.Notes", name: "Notes", running: true, pinned: false),
        ]
        frontApp = "com.tinyspeck.slackmacgap"
        if ProcessInfo.processInfo.arguments.contains("-demoKeyboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                var f = FocusInfo(editable: true, secure: false, app: "Slack", role: "AXTextArea", token: 42)
                f.bundleID = "com.tinyspeck.slackmacgap"; f.kind = .text; f.fieldKey = "demo"; f.invite = true
                f.context = TextContext(before: "Hey! The new build is on my phone now, the trackpad feels so much smoother", selected: "", after: "")
                self.lastFocus = f
                self.onFocus?(f)
            }
        }
    }

    func send(_ msg: ClientMessage) {
        if isDemo { if case .activateApp(let id) = msg { frontApp = id }; return }
        if msg.isInput { sendInput(msg) } else { channel?.send(msg) }
    }

    /// Numbered input over TCP, plus an encrypted copy over Bluetooth unless the user chose Wi-Fi only.
    /// The Mac executes whichever copy arrives first and drops the other.
    func sendInput(_ msg: ClientMessage) {
        guard let channel else { return }
        inputSeq &+= 1
        let wrapped = ClientMessage.input(n: inputSeq, msg)
        channel.send(wrapped)
        if motion.mode != .wifi, motion.ble.ready, let key = sessionKey,
           let json = try? encoder.encode(wrapped), let sealed = BLESeal.seal(json, key: key) {
            motion.ble.sendControl(sealed)
        }
    }
}
