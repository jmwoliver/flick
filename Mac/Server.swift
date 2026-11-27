import AppKit
import Network
import CryptoKit

/// Advertises over Bonjour (Wi-Fi + AWDL peer-to-peer) and serves exactly one paired phone.
///
/// Session rules:
///  * The Mac remembers one paired device (by its per-install UUID). The first phone to connect
///    with the right PIN becomes the paired one and receives a random 256-bit pairing key.
///    From then on the listener only accepts that key; the PIN stops working until "Unpair".
///  * While unpaired, wrong PINs are rate-limited: every 5 failed handshakes pause pairing,
///    for 30 s and then twice as long each time, so the 10^6 PINs can't be tried online.
///  * Any other phone is refused with `.rejected` and is told not to retry — it never kicks the
///    active phone. (Previously "newest wins" made two phones knock each other off forever.)
///  * The same phone reconnecting replaces its own stale session.
///  * Nothing is accepted from a connection until its hello has been checked.
///  * "Disconnect" ends the session (phone stops auto-reconnecting); "Unpair" also forgets the
///    phone and rotates the PIN so its saved PIN stops working.
final class Server {
    enum State: Equatable { case starting, listening, connected(String), failed(String) }
    struct PairedDevice: Equatable { let id: String; var name: String; let key: Data }

    var onStateChange: ((State) -> Void)?
    var onPairedChange: ((PairedDevice?) -> Void)?
    var onNotice: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "flick.net", qos: .userInteractive)
    private let injector = InputInjector()
    let focus = FocusWatcher()
    let dock = DockProvider()

    private var controlListener: NWListener?
    private var motionListener: NWListener?
    private typealias Channel = FramedChannel<ServerMessage, ClientMessage>
    private var active: Channel?
    private var pending: [ObjectIdentifier: Channel] = [:]
    private var paired: PairedDevice?
    private var sessionKey = SymmetricKey(size: .bits256)
    private var lastSeq: UInt32 = 0
    private var udpConfirmed = false
    private lazy var ble: BLEReceiver = {
        let b = BLEReceiver(queue: queue)
        b.onPacket = { [weak self] data, reply in self?.ingestMotion(data, via: .ble, reply: reply) }
        b.onState = { PerfLog.write("mac: \($0)") }
        b.onControl = { [weak self] data in
            guard let self, self.active != nil, let json = BLESeal.open(data, key: self.sessionKey),
                  case .input(let n, let inner)? = try? self.jsonDecoder.decode(ClientMessage.self, from: json) else { return }
            self.ingestInput(n, inner, via: .ble)
        }
        return b
    }()

    // Motion state (cumulative position protocol) and performance stats.
    private var appliedX = 0.0, appliedY = 0.0       // latest position received (target)
    private var presentedX = 0.0, presentedY = 0.0   // where the cursor has actually been moved to
    private var glideTimer: DispatchSourceTimer?
    private var glides = 0
    // Session-long clock baseline for "is this packet late?", relaxed slowly to absorb clock drift.
    private var baseRaw: Int64?
    private var baseSetAt: UInt64 = 0
    private var minRawOWD: Int64?                      // min(macNow − phoneSendTs) across transports
    private var owd: [MotionTransport: [Double]] = [:] // excess one-way delay samples, ms
    private var wins: [MotionTransport: Int] = [:]
    private var effective: [Double] = []               // excess delay of the copy that won (what you feel)
    private var lateBy: [MotionTransport: [Double]] = [:]
    private var winnerArrival: [UInt32: UInt64] = [:]
    private var injectMicros: [Double] = []


    // Numbered inputs raced over TCP + BLE: run each once, in order.
    private var nextInput: UInt32 = 1
    private var inputBuffer: [UInt32: ClientMessage] = [:]
    private var inputFirstArrival: [UInt32: UInt64] = [:]
    private var inputWins: [MotionTransport: Int] = [:]
    private var inputLateBy: [MotionTransport: [Double]] = [:]
    private let jsonDecoder = JSONDecoder()
    private var statsTimer: DispatchSourceTimer?
    private var pin: String
    /// Credential each not-yet-active connection authenticated with.
    private var pendingCredential: [ObjectIdentifier: Credential] = [:]
    private var failedPINs = 0
    private var lockouts = 0
    private var lockedUntil: Date?
    private static let maxPINFailures = 5

    private var credential: Credential { paired.map { .paired($0.key) } ?? .pin(pin) }
    private var advertised = false
    private let macName = Host.current().localizedName ?? "Mac"

    init(pin: String) {
        self.pin = pin
        let d = UserDefaults.standard
        // A pairing from before pairing keys existed has no key: the phone pairs again with the PIN.
        if let id = d.string(forKey: "pairedDeviceID"), let key = Keychain.data("pairedKey") {
            paired = PairedDevice(id: id, name: d.string(forKey: "pairedDeviceName") ?? "iPhone", key: key)
        } else if d.string(forKey: "pairedDeviceID") != nil {
            d.removeObject(forKey: "pairedDeviceID"); d.removeObject(forKey: "pairedDeviceName")
        }
        focus.onChange = { [weak self] info in
            if info.editable {
                PerfLog.write("focus: \(info.app) \(info.role) → \(info.kind.rawValue)\(info.clicked ? " (click)" : "") key=\(info.fieldKey) ctx=\(info.context.map { "\($0.before.count)+\($0.selected.count)+\($0.after.count) chars" } ?? "none")")
            }
            self?.queue.async { self?.active?.send(.focus(info)) }
        }
        focus.onContext = { [weak self] token, ctx in
            self?.queue.async { self?.active?.send(.textContext(token: token, ctx)) }
        }
        dock.onChange = { [weak self] apps, front in
            self?.queue.async { self?.active?.send(.dock(apps, front: front)) }
        }
    }

    var pairedDevice: PairedDevice? { queue.sync { paired } }

    func start() {
        DispatchQueue.main.async { self.focus.start(); self.dock.start() }
        #if DEBUG
        // Debug-only: `flick.debug.space` with object "left"/"right" switches a Space, for testing
        // without the phone.
        DistributedNotificationCenter.default().addObserver(forName: .init("flick.debug.space"), object: nil, queue: .main) { n in
            let ok = SpaceSwitcher.switchSpace(right: (n.object as? String) == "right")
            PerfLog.write("debug space \(n.object ?? "?") → \(ok)")
        }
        // `flick.debug.swipe` "dir,maxProgress,steps,stepMs,velocity"
        DistributedNotificationCenter.default().addObserver(forName: .init("flick.debug.swipe"), object: nil, queue: .main) { n in
            let f = ((n.object as? String) ?? "").split(separator: ",").map(String.init)
            guard f.count == 5, let mp = Double(f[1]), let st = Int(f[2]), let ms = Double(f[3]), let v = Double(f[4]) else { return }
            SpaceSwitcher.experiment(right: f[0] == "right", maxProgress: mp, steps: st, stepMs: ms, velocity: v)
            PerfLog.write("debug swipe \(f)")
        }
        #endif
        queue.async {
            PerfLog.write("mac: start p2p=\(BB.peerToPeer)")
            self.startListeners()
            _ = self.ble
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.flushStats(reason: "periodic") }
            t.resume()
            self.statsTimer = t
        }
    }

    /// End the current session; the phone stays paired but won't auto-reconnect.
    func disconnect() {
        queue.async {
            guard let ch = self.active else { return }
            ch.sendAndClose(.kicked("Disconnected from \(self.macName). Tap it to reconnect."))
            self.deactivate(ch)
        }
    }

    /// Forget the paired phone (and its key) and switch to a new PIN.
    func unpair(newPin: String) {
        queue.async {
            if let ch = self.active {
                ch.sendAndClose(.unpaired("\(self.macName) unpaired this iPhone. Tap it and enter the PIN from the Flick menu on the Mac to pair again."))
                self.deactivate(ch)
            }
            self.setPaired(nil)
            self.resetLockout()
            self.restartListeners(pin: newPin)
        }
    }

    /// New pairing PIN. Only matters while no phone is paired.
    func setPin(_ pin: String) {
        queue.async {
            self.pin = pin
            if self.paired == nil { self.resetLockout(); self.restartListeners(pin: pin) }
        }
    }

    private func restartListeners(pin: String) {
        self.pin = pin
        if let ch = active { ch.cancel(); deactivate(ch) }
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        pendingCredential.removeAll()
        controlListener?.cancel(); motionListener?.cancel()
        startListeners()
    }

    private func setState(_ s: State) {
        DispatchQueue.main.async { self.onStateChange?(s) }
    }

    private func notice(_ s: String?) {
        DispatchQueue.main.async { self.onNotice?(s) }
    }

    private func setPaired(_ p: PairedDevice?) {
        paired = p
        let d = UserDefaults.standard
        if let p {
            Keychain.set(p.key, "pairedKey")
            d.set(p.id, forKey: "pairedDeviceID"); d.set(p.name, forKey: "pairedDeviceName")
        } else {
            Keychain.delete("pairedKey")
            d.removeObject(forKey: "pairedDeviceID"); d.removeObject(forKey: "pairedDeviceName")
        }
        DispatchQueue.main.async { self.onPairedChange?(p) }
    }

    // MARK: Listeners

    private func startListeners() {
        setState(.starting)
        do {
            let motion = try NWListener(using: BBSecurity.motionParameters())
            motion.newConnectionHandler = { [weak self] conn in self?.acceptMotion(conn) }
            motion.stateUpdateHandler = { [weak self] st in
                if case .ready = st { self?.startControlListener() }
                if case .failed(let e) = st { self?.setState(.failed("UDP: \(e)")) }
            }
            motion.start(queue: queue)
            motionListener = motion
        } catch {
            setState(.failed("\(error)"))
        }
    }

    /// Swap the control listener's credential (PIN ↔ pairing key). Accepted connections,
    /// including the active session, are independent of the listener and stay up.
    private func restartControlListener() {
        controlListener?.cancel(); controlListener = nil
        startControlListener()
    }

    private func startControlListener() {
        if let until = lockedUntil, until > Date() { return }
        do {
            let listener = try NWListener(using: BBSecurity.controlParameters(credential))
            let listenerCredential = credential
            listener.service = NWListener.Service(name: macName, type: BB.serviceType)
            listener.newConnectionHandler = { [weak self] conn in self?.acceptControl(conn, credential: listenerCredential) }
            advertised = false
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self else { return }
                if case .add = change {
                    self.advertised = true
                    if self.active == nil { self.setState(.listening) }
                }
            }
            listener.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    // Bonjour registration silently never happens if Local Network access is denied.
                    self?.queue.asyncAfter(deadline: .now() + 3) {
                        guard let self, !self.advertised, self.active == nil else { return }
                        self.setState(.failed("Not discoverable. Allow Flick under System Settings › Privacy & Security › Local Network, then relaunch."))
                    }
                case .failed(let e): self?.setState(.failed("TCP: \(e)"))
                default: break
                }
            }
            listener.start(queue: queue)
            controlListener = listener
        } catch {
            setState(.failed("\(error)"))
        }
    }

    // MARK: Control channel

    private func acceptControl(_ conn: NWConnection, credential: Credential) {
        let ch = Channel(conn)
        let key = ObjectIdentifier(ch)
        pending[key] = ch
        pendingCredential[key] = credential

        ch.onMessage = { [weak self, weak ch] msg in
            guard let self, let ch else { return }
            if self.active === ch { self.handle(msg) } else { self.handshake(ch, msg) }
        }
        ch.onClose = { [weak self, weak ch] _ in
            guard let self, let ch else { return }
            self.connectionEnded(ch)
        }
        conn.stateUpdateHandler = { [weak self, weak ch] st in
            guard let self, let ch else { return }
            switch st {
            case .ready:
                ch.startReceiving()
                // Clients that never say hello (e.g. an old build) don't get to linger.
                self.queue.asyncAfter(deadline: .now() + 3) { [weak ch] in
                    guard let ch, self.pending[ObjectIdentifier(ch)] != nil else { return }
                    self.pending[ObjectIdentifier(ch)] = nil
                    self.pendingCredential[ObjectIdentifier(ch)] = nil
                    ch.cancel()
                }
            case .failed(let e):
                // "Bad MAC" before the session started = a wrong PIN. A phone still holding an old
                // pairing key fails with "unknown PSK identity" instead and isn't counted, so it
                // can't lock out pairing a new phone by retrying in the background.
                if case .tls(let status) = e, status == errSSLBadRecordMac,
                   self.pendingCredential[key]?.isPin == true { self.wrongPIN() }
                self.connectionEnded(ch)
            case .cancelled:
                self.connectionEnded(ch)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func handshake(_ ch: Channel, _ msg: ClientMessage) {
        let id = ObjectIdentifier(ch)
        guard pending.removeValue(forKey: id) != nil, let via = pendingCredential.removeValue(forKey: id),
              case .hello(let name, let deviceID) = msg else { return }

        if let p = paired, p.id != deviceID {
            ch.sendAndClose(.rejected("\(macName) is paired with \(p.name). Unpair it from the Flick menu on the Mac to use this phone."))
            notice("Refused \(name): \(macName) is paired with \(p.name)")
            return
        }
        if let p = paired {
            if p.name != name { setPaired(PairedDevice(id: p.id, name: name, key: p.key)) }
        } else {
            setPaired(PairedDevice(id: deviceID, name: name, key: Credential.newPairingKey()))
        }
        // Same phone reconnecting: its old session is stale.
        if let old = active { old.cancel(); deactivate(old) }
        if via.isPin, let p = paired {
            // Paired over the PIN: hand over the long-term key and stop accepting the PIN.
            ch.send(.paired(key: p.key))
            resetLockout()
            restartControlListener()
        }
        activate(ch, name: name)
    }

    // MARK: Wrong-PIN rate limit

    private func wrongPIN() {
        failedPINs += 1
        guard failedPINs >= Self.maxPINFailures else { return }
        failedPINs = 0
        lockouts += 1
        let seconds = min(30 * pow(2, Double(lockouts - 1)), 3600)
        lockedUntil = Date().addingTimeInterval(seconds)
        controlListener?.cancel(); controlListener = nil
        pending.values.forEach { $0.cancel() }
        pending.removeAll(); pendingCredential.removeAll()
        notice("Too many wrong PINs. Pairing is paused for \(Int(seconds)) s.")
        PerfLog.write("mac: \(Self.maxPINFailures) wrong PINs, pairing paused \(Int(seconds)) s")
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.controlListener == nil, let until = self.lockedUntil, until <= Date() else { return }
            self.lockedUntil = nil
            self.notice(nil)
            self.startControlListener()
        }
    }

    private func resetLockout() {
        failedPINs = 0; lockouts = 0; lockedUntil = nil
    }

    private func activate(_ ch: Channel, name: String) {
        active = ch
        injector.releaseAll()
        sessionKey = SymmetricKey(size: .bits256)
        lastSeq = 0
        udpConfirmed = false
        appliedX = 0; appliedY = 0; presentedX = 0; presentedY = 0
        baseRaw = nil
        glideTimer?.cancel(); glideTimer = nil
        nextInput = 1; inputBuffer.removeAll(); inputFirstArrival.removeAll()
        minRawOWD = nil
        winnerArrival.removeAll()
        PerfLog.write("mac: session start \(name)")
        let port = motionListener?.port?.rawValue ?? 0
        let key = sessionKey.withUnsafeBytes { Data($0) }
        ch.send(.hello(macName: macName, udpPort: port, sessionKey: key))
        setState(.connected(name))
        DispatchQueue.main.async {
            let trusted = AXIsProcessTrusted()
            self.focus.evaluate()
            let info = self.focus.current
            self.queue.async {
                guard self.active === ch else { return }
                if !trusted { ch.send(.status("Mac needs Accessibility permission")) }
                ch.send(.focus(info))
            }
            DispatchQueue.main.async {
                self.dock.refresh()
                let apps = self.dock.apps, front = self.dock.front
                self.queue.async { if self.active === ch { ch.send(.dock(apps, front: front)) } }
            }
        }
    }

    private func deactivate(_ ch: Channel) {
        guard active === ch else { return }
        active = nil
        injector.releaseAll()
        sessionKey = SymmetricKey(size: .bits256)   // stale UDP packets now fail auth
        setState(advertised ? .listening : .starting)
    }

    private func connectionEnded(_ ch: Channel) {
        pending[ObjectIdentifier(ch)] = nil
        pendingCredential[ObjectIdentifier(ch)] = nil
        deactivate(ch)
    }

    private func handle(_ msg: ClientMessage) {
        switch msg {
        case .hello:
            break
        case .move(let dx, let dy):
            // TCP fallback still sends deltas; keep the cumulative baseline in step with them.
            appliedX += dx; appliedY += dy
            present(x: presentedX + dx, y: presentedY + dy)
        case .scroll(let dx, let dy, let phase, let momentum):
            injector.scroll(dx: dx, dy: dy, phase: phase, momentum: momentum)
        case .button(let b, let down):
            if down { noteClick() }
            injector.button(b, isDown: down)
            if !down { DispatchQueue.main.async { self.focus.checkAfterClick() } }
        case .click(let b):
            noteClick()
            injector.click(b)
            DispatchQueue.main.async { self.focus.checkAfterClick() }
        case .activateApp(let id):
            DispatchQueue.main.async { self.dock.activate(id); self.focus.checkSoon() }
        case .system(let a) where a == .spaceLeft || a == .spaceRight:
            DispatchQueue.main.async {
                let ok = SpaceSwitcher.switchSpace(right: a == .spaceRight)
                if !ok { PerfLog.write("space: \(a.rawValue) — no more Spaces that way") }
            }
        case .system(let a):
            noteKeyAction()
            injector.system(a)
            DispatchQueue.main.async { self.focus.checkSoon() }
        case .spaceSwipe(let phase, let progress, let velocity):
            DispatchQueue.main.async { SpaceSwitcher.interactive(phase, progress: progress, velocity: velocity) }
        case .holdBegin:
            noteClick()
            DispatchQueue.main.async {
                let wordSelect = self.pointerIsOverText()
                self.queue.async {
                    if wordSelect { self.injector.wordDragBegin() } else { self.injector.button(.left, isDown: true) }
                }
            }
        case .requestContext:
            DispatchQueue.main.async { self.focus.sendContextNow() }
        case .requestIcons(let ids):
            DispatchQueue.main.async {
                for id in ids.prefix(64) {
                    guard let png = self.dock.icon(for: id) else { continue }
                    self.queue.async { self.active?.send(.appIcon(bundleID: id, png: png)) }
                }
            }
        case .text(let s):
            injector.type(s)
        case .key(let k, let mods, let count):
            if k == .tab || !mods.isEmpty { noteKeyAction() }
            injector.key(k, mods: mods, count: count)
            if k == .tab || k == .escape || k == .returnKey { DispatchQueue.main.async { self.focus.checkSoon() } }
        case .shortcut(let s, let mods):
            noteKeyAction()
            injector.shortcut(s, mods: mods)
            DispatchQueue.main.async { self.focus.checkSoon() }
        case .ping(let t):
            active?.send(.pong(t))
        case .input(let n, let inner):
            ingestInput(n, inner, via: .tcp)
        case .log(let line):
            if line == "flush" { flushStats(reason: "phone request") } else { PerfLog.write("phone: \(line)") }
        }
    }

    // MARK: Motion (UDP + BLE)

    private func acceptMotion(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveMotion(conn)
    }

    private func receiveMotion(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                self.ingestMotion(data, via: .udp) { reply in conn.send(content: reply, completion: .idempotent) }
            }
            if error == nil { self.receiveMotion(conn) } else { conn.cancel() }
        }
    }

    /// Every transport funnels through here (on `queue`). The first copy of each sequence number wins.
    private func ingestMotion(_ data: Data, via transport: MotionTransport, reply: @escaping (Data) -> Void) {
        let arrival = nowMicros()
        guard active != nil, let pkt = MotionPacket.decode(data, key: sessionKey) else { return }
        switch pkt.kind {
        case .echo:
            reply(data)   // latency probe: bounce straight back on the same path
        case .probe:
            if transport == .udp, !udpConfirmed { udpConfirmed = true; active?.send(.udpOK) }
        case .move:
            let raw = Int64(bitPattern: arrival &- pkt.ts)
            if minRawOWD == nil || raw < minRawOWD! { minRawOWD = raw }
            owd[transport, default: []].append(Double(raw - minRawOWD!) / 1000)
            if pkt.seq > lastSeq {
                lastSeq = pkt.seq
                wins[transport, default: 0] += 1
                effective.append(Double(raw - minRawOWD!) / 1000)
                winnerArrival[pkt.seq] = arrival
                if winnerArrival.count > 2048 { winnerArrival = winnerArrival.filter { $0.key > pkt.seq &- 1024 } }
                appliedX = pkt.x; appliedY = pkt.y
                if lateness(raw: raw, now: arrival) > 12 || glideTimer != nil {
                    // Arrived late (Wi-Fi spike): glide to the new position instead of jumping.
                    startGlide()
                } else if appliedX != presentedX || appliedY != presentedY {
                    present(x: appliedX, y: appliedY)
                    injectMicros.append(Double(nowMicros() - arrival))
                }
            } else if let first = winnerArrival[pkt.seq] {
                lateBy[transport, default: []].append(Double(arrival - first) / 1000)
            }
        }
    }

    private func ingestInput(_ n: UInt32, _ msg: ClientMessage, via t: MotionTransport) {
        let now = nowMicros()
        if let first = inputFirstArrival[n] {               // the other path already delivered it
            inputLateBy[t, default: []].append(Double(now - first) / 1000)
            return
        }
        guard n >= nextInput else { return }                 // old or replayed
        inputFirstArrival[n] = now
        if inputFirstArrival.count > 2048 { inputFirstArrival = inputFirstArrival.filter { $0.key > n &- 1024 } }
        inputWins[t, default: 0] += 1
        inputBuffer[n] = msg
        drainInputs()
        if !inputBuffer.isEmpty {
            // Both paths are in-order and TCP carries everything, so a gap fills itself quickly.
            // Safety net: never stall input for more than 300 ms.
            let stuckAt = nextInput
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.nextInput == stuckAt, let lowest = self.inputBuffer.keys.min() else { return }
                PerfLog.write("mac: input gap at \(stuckAt), skipping to \(lowest)")
                self.nextInput = lowest
                self.drainInputs()
            }
        }
    }

    private func drainInputs() {
        while let m = inputBuffer.removeValue(forKey: nextInput) {
            nextInput &+= 1
            handle(m)
        }
    }

    private func noteClick() {
        let p = CGEvent(source: nil)?.location ?? .zero
        DispatchQueue.main.async { self.focus.noteClick(at: p) }
    }

    private func noteKeyAction() {
        DispatchQueue.main.async { self.focus.noteKeyAction() }
    }

    // MARK: Hold to select

    /// Is the pointer over selectable text (not a link, button, file icon or image)?
    private func pointerIsOverText() -> Bool {
        guard AXIsProcessTrusted(), let loc = CGEvent(source: nil)?.location else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(loc.x), Float(loc.y), &el) == .success, let el else { return false }
        func role(_ e: AXUIElement) -> String {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v)
            return v as? String ?? ""
        }
        func parent(_ e: AXUIElement) -> AXUIElement? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &v) == .success, let v,
                  CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        let r = role(el)
        guard ["AXStaticText", "AXTextArea", "AXTextField", "AXTextView"].contains(r) else { return false }
        // Text inside a link or button should drag/click as that control.
        var p = parent(el)
        for _ in 0..<3 {
            guard let cur = p else { break }
            if ["AXLink", "AXButton", "AXMenuItem", "AXPopUpButton"].contains(role(cur)) { return false }
            p = parent(cur)
        }
        return true
    }

    /// How late (ms) a packet is versus the best one-way delay seen this session.
    private func lateness(raw: Int64, now: UInt64) -> Double {
        // Allow the baseline to creep up 0.1 ms/s so phone/Mac clock drift can't build up.
        let relaxed = baseRaw.map { $0 + Int64(Double(now &- baseSetAt) * 0.0001) }
        if relaxed == nil || raw < relaxed! { baseRaw = raw; baseSetAt = now; return 0 }
        return Double(raw - relaxed!) / 1000
    }

    private func present(x: Double, y: Double) {
        let dx = x - presentedX, dy = y - presentedY
        presentedX = x; presentedY = y
        if dx != 0 || dy != 0 { injector.move(dx: dx, dy: dy) }
    }

    /// 240 Hz catch-up: close ~35% of the remaining gap per tick (time constant ≈ 10 ms).
    private func startGlide() {
        guard glideTimer == nil else { return }
        glides += 1
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .microseconds(4167), leeway: .microseconds(250))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let ex = self.appliedX - self.presentedX, ey = self.appliedY - self.presentedY
            if hypot(ex, ey) < 1 {
                self.present(x: self.appliedX, y: self.appliedY)
                self.glideTimer?.cancel(); self.glideTimer = nil
            } else {
                self.present(x: self.presentedX + ex * 0.35, y: self.presentedY + ey * 0.35)
            }
        }
        t.resume()
        glideTimer = t
    }

    private func flushStats(reason: String) {
        let total = wins.values.reduce(0, +)
        guard total > 0 || !owd.isEmpty || !inputWins.isEmpty else { return }
        var lines = ["mac: motion stats (\(reason)), packets applied=\(total), ble links=\(ble.connectedCount)"]
        for t in MotionTransport.allCases where owd[t] != nil || wins[t] != nil {
            lines.append("  \(t.rawValue): one-way excess ms \(Stats.summary(owd[t] ?? [])) | won \(wins[t] ?? 0) | when lost, late by ms \(Stats.summary(lateBy[t] ?? []))")
        }
        lines.append("  EFFECTIVE (winner) one-way excess ms \(Stats.summary(effective))")
        lines.append("  late-packet glides: \(glides)")
        glides = 0
        lines.append("  inject µs \(Stats.summary(injectMicros, decimals: 0))")
        for t in MotionTransport.allCases where inputWins[t] != nil || inputLateBy[t] != nil {
            lines.append("  input via \(t.rawValue): won \(inputWins[t] ?? 0) | when lost, late by ms \(Stats.summary(inputLateBy[t] ?? []))")
        }
        PerfLog.write(lines.joined(separator: "\n"))
        owd.removeAll(); wins.removeAll(); effective.removeAll(); lateBy.removeAll(); injectMicros.removeAll()
        inputWins.removeAll(); inputLateBy.removeAll()
        // Re-base the clock offset each window so slow clock drift can't skew results.
        minRawOWD = nil
    }
}
