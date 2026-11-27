// Shared wire protocol between the iPhone (client) and the Mac (server).
//
// Transport layout
// ----------------
//  * Control channel: TCP + TLS 1.2 ECDHE-PSK, TCP_NODELAY, length-prefixed JSON frames.
//    Carries clicks, scroll, keys, text, focus state. The PSK is the 6-digit PIN shown on the Mac
//    only for the first connection; the Mac then hands the phone a random 256-bit pairing key,
//    and every later connection uses that instead (see `Credential`).
//  * Motion channel: UDP, binary 22-byte packets authenticated with a truncated HMAC using a
//    per-session key handed out over the TLS channel. Carries pointer deltas only, so a lost
//    packet never stalls anything behind it (no head-of-line blocking).
//  * Both use Network.framework with `includePeerToPeer = true`, which lets the OS use AWDL
//    (the same Apple Wireless Direct Link radio path AirDrop / Sidecar / Universal Control use)
//    when the two devices aren't on the same Wi-Fi.

import Foundation
import Network
import CryptoKit

enum BB {
    static let serviceType = "_flick._tcp"
    static let maxFrame = 64 * 1024
    /// Allow AWDL (peer-to-peer Wi-Fi). AWDL makes the radio hop channels periodically, which can
    /// add latency spikes on normal Wi-Fi, so it's switchable for A/B testing.
    static var peerToPeer: Bool = {
        let env = ProcessInfo.processInfo.environment["FLICK_P2P"]
        if let env { return env != "0" }
        if ProcessInfo.processInfo.arguments.contains("-nop2p") { return false }
        return UserDefaults.standard.object(forKey: "peerToPeer") as? Bool ?? true
    }()

    // Custom BLE GATT service (allowed for apps, unlike the HID service).
    static let bleService = "B7E1A0C0-5E3B-4C1A-9F2E-0B11B00B0001"
    static let bleMotionChar = "B7E1A0C0-5E3B-4C1A-9F2E-0B11B00B0002"  // phone → Mac, notify
    static let bleEchoChar = "B7E1A0C0-5E3B-4C1A-9F2E-0B11B00B0003"    // Mac → phone, write w/o response
    static let bleControlChar = "B7E1A0C0-5E3B-4C1A-9F2E-0B11B00B0004" // phone → Mac, notify (encrypted inputs)
}

/// Input messages sent over Bluetooth are sealed with the per-session key (ChaCha20-Poly1305),
/// so keystrokes never cross the air in plaintext. Replays are dropped by the input sequence number.
enum BLESeal {
    static func seal(_ d: Data, key: SymmetricKey) -> Data? { try? ChaChaPoly.seal(d, using: key).combined }
    static func open(_ d: Data, key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: d) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }
}

/// Monotonic microseconds (same clock base for every transport on a device).
func nowMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

enum MotionTransport: String, Codable, CaseIterable { case udp, ble, tcp }

enum Stats {
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }
    /// "n=… p50=… p90=… p99=… max=… mean=…"
    static func summary(_ xs: [Double], decimals: Int = 1) -> String {
        guard !xs.isEmpty else { return "n=0" }
        let s = xs.sorted()
        let f = "%.\(decimals)f"
        func v(_ x: Double) -> String { String(format: f, x) }
        return "n=\(s.count) p50=\(v(percentile(s, 0.5))) p90=\(v(percentile(s, 0.9))) p99=\(v(percentile(s, 0.99))) max=\(v(s.last!)) mean=\(v(s.reduce(0, +) / Double(s.count)))"
    }
}

// MARK: - Messages

enum MouseButton: String, Codable { case left, right, middle }

enum SpecialKey: String, Codable, CaseIterable {
    case returnKey, tab, space, delete, forwardDelete, escape
    case left, right, up, down, home, end, pageUp, pageDown
}

struct Modifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt8
    static let command = Modifiers(rawValue: 1 << 0)
    static let option  = Modifiers(rawValue: 1 << 1)
    static let control = Modifiers(rawValue: 1 << 2)
    static let shift   = Modifiers(rawValue: 1 << 3)
}

/// NSEvent-style scroll phases. Real trackpads tag scroll events with these and apps use
/// them for rubber-banding / momentum, so we forward them.
enum ScrollPhase: UInt8, Codable { case none = 0, began = 1, changed = 2, ended = 4 }
enum MomentumPhase: UInt8, Codable { case none = 0, begin = 1, `continue` = 2, end = 3 }

/// macOS actions that the trackpad's system gestures map to.
enum SystemAction: String, Codable, CaseIterable {
    case spaceLeft, spaceRight, missionControl, appExpose, showDesktop, spotlight
    var title: String {
        switch self {
        case .spaceLeft: "Previous Space"
        case .spaceRight: "Next Space"
        case .missionControl: "Mission Control"
        case .appExpose: "App Windows"
        case .showDesktop: "Show Desktop"
        case .spotlight: "Spotlight"
        }
    }
}

enum SwipePhase: String, Codable { case began, changed, ended, cancelled }

enum ClientMessage: Codable {
    /// deviceID is a per-install UUID; the Mac pairs with exactly one.
    case hello(deviceName: String, deviceID: String)
    case move(dx: Double, dy: Double)                     // fallback when UDP isn't up
    case scroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase)
    case button(MouseButton, down: Bool)
    case click(MouseButton)
    case text(String)
    case key(SpecialKey, mods: Modifiers, count: Int)
    case shortcut(String, mods: Modifiers)                // e.g. "c" + .command
    case activateApp(bundleID: String)
    /// Press-and-hold started: the Mac picks a word-selecting drag over text, a plain drag otherwise.
    case holdBegin
    case system(SystemAction)
    /// Interactive Space swipe, streamed while the finger moves, like a trackpad.
    /// progress: cumulative, +1 = a full Space toward the next (right) Space. velocity: progress/s.
    case spaceSwipe(SwipePhase, progress: Double, velocity: Double)
    /// Ask for the text around the caret of the focused field (after Return, on keyboard open…).
    case requestContext
    /// Ask for app icons the phone hasn't cached yet.
    case requestIcons([String])
    case ping(Double)
    /// Performance telemetry / benchmark results, written to the Mac's perf log.
    case log(String)
    /// A numbered input, sent over TCP *and* (encrypted) Bluetooth. The Mac runs each number once,
    /// in order, from whichever path delivers it first.
    indirect case input(n: UInt32, ClientMessage)

    /// Messages that change the Mac's state and benefit from racing both paths.
    var isInput: Bool {
        switch self {
        case .move, .scroll, .button, .click, .text, .key, .shortcut, .activateApp, .system, .holdBegin, .spaceSwipe: true
        default: false
        }
    }
}

/// What kind of text input has focus, so the phone can pick the right keyboard behaviour.
enum FieldKind: String, Codable, CaseIterable {
    case text, code, terminal, url, search, email, number, secure
    var title: String {
        switch self {
        case .text: "Text"
        case .code: "Code"
        case .terminal: "Terminal"
        case .url: "URL"
        case .search: "Search"
        case .email: "Email"
        case .number: "Number"
        case .secure: "Password"
        }
    }
}

/// Text around the caret in the Mac's focused field. Never sent for secure fields.
struct TextContext: Codable, Equatable {
    var before: String
    var selected: String
    var after: String
}

struct FocusInfo: Codable, Equatable {
    var editable: Bool
    var secure: Bool
    var app: String
    var role: String
    /// Changes whenever a *different* element gets focus, so the phone can tell
    /// "same text field, user dismissed keyboard" from "new text field".
    var token: Int
    var kind: FieldKind = .text
    var bundleID: String = ""
    /// Identifies "this kind of field in this app" (app + role + hints) for per-field overrides.
    var fieldKey: String = ""
    /// True when this report follows a click, even if focus didn't change.
    var clicked: Bool = false
    /// The user asked for this field: they clicked inside it, or a keyboard action (⌘L, Tab,
    /// Spotlight…) moved focus here. Apps moving focus on their own (Slack after a channel click)
    /// don't invite the keyboard.
    var invite: Bool = false
    var context: TextContext? = nil

    /// Equality for change detection ignores the click flag and the live text.
    func sameField(as o: FocusInfo) -> Bool {
        editable == o.editable && secure == o.secure && app == o.app && role == o.role &&
        token == o.token && kind == o.kind && fieldKey == o.fieldKey
    }
}

struct DockApp: Codable, Equatable, Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    var running: Bool
    let pinned: Bool
}

enum ServerMessage: Codable {
    case hello(macName: String, udpPort: UInt16, sessionKey: Data)
    /// Sent once, right after a PIN-authenticated phone becomes the paired one: the long-term
    /// key to use instead of the PIN from now on.
    case paired(key: Data)
    case udpOK
    case focus(FocusInfo)
    /// Live text for the focused field (token = FocusInfo.token).
    case textContext(token: Int, TextContext)
    case dock([DockApp], front: String)
    case appIcon(bundleID: String, png: Data)
    case pong(Double)
    case status(String)
    /// Connection refused (e.g. the Mac is paired with another phone). Don't auto-retry.
    case rejected(String)
    /// The Mac ended the session (Disconnect in its menu). Don't auto-retry.
    case kicked(String)
    /// The Mac unpaired this phone: its pairing key no longer works.
    case unpaired(String)
}

// MARK: - Security

/// What the control channel's TLS pre-shared key is made from.
///
/// * `.pin`: only while the Mac has no paired phone. A 6-digit PIN is low-entropy, so the Mac
///   limits wrong guesses (see `Server`), and the ECDHE key exchange stops anyone who merely
///   records the traffic from brute-forcing the PIN offline and decrypting it.
/// * `.paired`: a random 256-bit key the Mac sends over the first PIN-authenticated session.
///   Both sides keep it in the Keychain. From then on the PIN isn't accepted at all.
enum Credential: Equatable {
    case pin(String)
    case paired(Data)

    var isPin: Bool { if case .pin = self { true } else { false } }

    fileprivate var identity: String {
        switch self {
        case .pin: "flick-pin-v2"
        case .paired: "flick-paired-v2"
        }
    }

    fileprivate var psk: Data {
        let secret: Data
        switch self {
        case .pin(let pin): secret = Data(pin.utf8)
        case .paired(let key): secret = key
        }
        return Data(HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: SymmetricKey(data: secret)))
    }

    static func newPairingKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
}

enum BBSecurity {
    /// TLS 1.2 ECDHE-PSK with ChaCha20-Poly1305. A wrong key fails the handshake, everything on
    /// the control channel (including keystrokes) is encrypted, and the ephemeral ECDH share
    /// gives forward secrecy.
    static func tlsOptions(_ credential: Credential) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let psk = credential.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(credential.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(sec, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return tls
    }

    static func controlParameters(_ credential: Credential) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: tlsOptions(credential), tcp: tcp)
        params.includePeerToPeer = BB.peerToPeer
        params.serviceClass = .responsiveData
        return params
    }

    static func motionParameters() -> NWParameters {
        let params = NWParameters.udp
        params.includePeerToPeer = BB.peerToPeer
        // Maps to the Wi-Fi WMM "voice" access category: the lowest-latency queue the radio has.
        params.serviceClass = .interactiveVoice
        return params
    }
}

// MARK: - Motion packets (UDP and BLE)

/// Pointer packets carry the *cumulative* pointer position since the session started, not a delta.
/// A lost, duplicated or late packet can't lose or double motion: the Mac applies
/// (latest cumulative − last applied cumulative). That is what makes it safe to send every packet
/// over Wi-Fi *and* Bluetooth at once and keep whichever copy arrives first.
///
/// [0] 'B'  [1] kind  [2-5] seq UInt32  [6-13] sender timestamp µs UInt64
/// [14-21] x Float64  [22-29] y Float64  [30-37] first 8 bytes of HMAC-SHA256(sessionKey, 0..<30)
enum MotionPacket {
    static let size = 38
    enum Kind: UInt8 {
        case probe = 0   // UDP reachability check
        case move = 1    // pointer position
        case echo = 2    // latency probe: the Mac sends it straight back on the same transport
    }
    struct Decoded { let kind: Kind; let seq: UInt32; let ts: UInt64; let x: Double; let y: Double }

    static func encode(kind: Kind, seq: UInt32, ts: UInt64, x: Double, y: Double, key: SymmetricKey) -> Data {
        var d = Data(capacity: size)
        d.append(0x42); d.append(kind.rawValue)
        withUnsafeBytes(of: seq.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: ts.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: x.bitPattern.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: y.bitPattern.bigEndian) { d.append(contentsOf: $0) }
        let mac = HMAC<SHA256>.authenticationCode(for: d, using: key)
        d.append(contentsOf: Data(mac).prefix(8))
        return d
    }

    static func decode(_ d: Data, key: SymmetricKey) -> Decoded? {
        guard d.count == size else { return nil }
        let b = [UInt8](d)
        guard b[0] == 0x42, let kind = Kind(rawValue: b[1]) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(b[0..<30]), using: key)
        guard Data(mac).prefix(8) == Data(b[30..<38]) else { return nil }
        func u(_ i: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 << 8 | UInt64(b[i + $1]) } }
        return Decoded(kind: kind, seq: UInt32(u(2, 4)), ts: u(6, 8),
                       x: Double(bitPattern: u(14, 8)), y: Double(bitPattern: u(22, 8)))
    }
}

// MARK: - Framed JSON over a stream connection

/// 4-byte big-endian length prefix + JSON body.
final class FramedChannel<Outgoing: Encodable, Incoming: Decodable> {
    let connection: NWConnection
    var onMessage: ((Incoming) -> Void)?
    var onClose: ((NWError?) -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ message: Outgoing) {
        guard !closed, let body = try? encoder.encode(message) else { return }
        var frame = Data(capacity: body.count + 4)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] err in
            if let err { self?.fail(err) }
        })
    }

    func startReceiving() { readHeader() }

    func cancel() { closed = true; connection.cancel() }

    /// Deliver a final message, then close once it has been handed to the network.
    func sendAndClose(_ message: Outgoing) {
        guard !closed, let body = try? encoder.encode(message) else { return cancel() }
        var frame = Data(capacity: body.count + 4)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        closed = true
        connection.send(content: frame, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.fail(error) }
            guard let data, data.count == 4 else { return self.fail(nil) }
            let len = data.reduce(0) { $0 << 8 | Int($1) }
            guard len > 0, len <= BB.maxFrame else { return self.fail(nil) }
            self.readBody(len)
            _ = isComplete
        }
    }

    private func readBody(_ len: Int) {
        connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.fail(error) }
            guard let data, data.count == len else { return self.fail(nil) }
            if let msg = try? self.decoder.decode(Incoming.self, from: data) { self.onMessage?(msg) }
            self.readHeader()
        }
    }

    private func fail(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?(error)
    }
}
