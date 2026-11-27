import Foundation
import Network
import CryptoKit

/// Sends pointer packets over UDP and/or Bluetooth LE. Thread-safe: called from the touch handler
/// (main thread) and from the benchmark queue.
final class MotionSender {
    enum Mode: String, CaseIterable {
        case both   // race Wi-Fi and Bluetooth; the Mac keeps whichever copy lands first
        case wifi
        case ble
        var label: String {
            switch self { case .both: "Wi-Fi + Bluetooth (fastest wins)"; case .wifi: "Wi-Fi only"; case .ble: "Bluetooth only" }
        }
    }

    let ble = BLESender()
    /// (transport, seq) for an echo that came back.
    var onEcho: ((MotionTransport, UInt32) -> Void)?

    private let lock = NSLock()
    private var key: SymmetricKey?
    private var udp: NWConnection?
    private var _udpActive = false
    private var seq: UInt32 = 0
    private var x = 0.0, y = 0.0
    private var _modeOverride: Mode?

    init() {
        ble.onWrite = { [weak self] data in self?.receivedEcho(data, via: .ble) }
    }

    var mode: Mode {
        lock.lock(); defer { lock.unlock() }
        return _modeOverride ?? Mode(rawValue: UserDefaults.standard.string(forKey: "motionTransport") ?? "") ?? .both
    }

    /// Benchmark uses this to force a mode temporarily.
    func override(_ m: Mode?) { lock.lock(); _modeOverride = m; lock.unlock() }

    var udpActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _udpActive }
        set { lock.lock(); _udpActive = newValue; lock.unlock() }
    }

    func begin(key: SymmetricKey) {
        lock.lock(); self.key = key; seq = 0; x = 0; y = 0; _udpActive = false; lock.unlock()
        ble.start()
    }

    func attachUDP(_ conn: NWConnection) {
        lock.lock(); udp = conn; lock.unlock()
        receiveUDP(conn)
    }

    func end() {
        lock.lock(); key = nil; udp = nil; _udpActive = false; lock.unlock()
    }

    /// Returns false when no fast path is up, so the caller falls back to a TCP delta.
    @discardableResult
    func move(dx: Double, dy: Double, leadX: Double = 0, leadY: Double = 0) -> Bool {
        let m = mode
        lock.lock()
        x += dx; y += dy
        let useUDP = _udpActive && m != .ble
        let useBLE = ble.ready && m != .wifi
        guard let key, useUDP || useBLE else { lock.unlock(); return false }
        seq &+= 1
        let pkt = MotionPacket.encode(kind: .move, seq: seq, ts: nowMicros(), x: x + leadX, y: y + leadY, key: key)
        let conn = udp
        lock.unlock()
        if useUDP { conn?.send(content: pkt, completion: .idempotent) }
        if useBLE { ble.send(pkt) }
        return true
    }

    func probe() {
        lock.lock()
        guard let key, let conn = udp else { lock.unlock(); return }
        seq &+= 1
        let pkt = MotionPacket.encode(kind: .probe, seq: seq, ts: nowMicros(), x: x, y: y, key: key)
        lock.unlock()
        conn.send(content: pkt, completion: .idempotent)
    }

    /// Sends a latency probe the Mac bounces straight back. Returns its sequence number.
    func echo(via t: MotionTransport) -> UInt32? {
        lock.lock()
        guard let key else { lock.unlock(); return nil }
        seq &+= 1
        let s = seq
        let pkt = MotionPacket.encode(kind: .echo, seq: s, ts: nowMicros(), x: x, y: y, key: key)
        let conn = udp
        lock.unlock()
        switch t {
        case .udp: guard let conn else { return nil }; conn.send(content: pkt, completion: .idempotent)
        case .ble: guard ble.ready else { return nil }; ble.send(pkt)
        case .tcp: return nil
        }
        return s
    }

    private func receiveUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            if let data { self?.receivedEcho(data, via: .udp) }
            if error == nil, let conn { self?.receiveUDP(conn) }
        }
    }

    private func receivedEcho(_ data: Data, via t: MotionTransport) {
        lock.lock(); let key = self.key; lock.unlock()
        guard let key, let pkt = MotionPacket.decode(data, key: key), pkt.kind == .echo else { return }
        onEcho?(t, pkt.seq)
    }
}
