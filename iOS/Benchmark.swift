import Foundation
import QuartzCore

/// On-device latency benchmark. Launch the app with `-bench` and it connects to the Mac, measures
/// every transport, and streams the results into the Mac's perf log
/// (~/Library/Logs/Flick/perf.log).
///
/// Hypotheses it separates:
///  H1  AWDL (peer-to-peer Wi-Fi) adds spikes       → UDP with the Bonjour browser running vs stopped
///                                                   (and the -nop2p launch flag for a p2p-free run)
///  H2  Wi-Fi power save hurts sparse traffic        → 5 Hz vs 120 Hz echo
///  H3  Bluetooth, or racing BLE vs Wi-Fi, is better → BLE echo + a race of real move packets
///  TCP control channel (clicks, keys)               → 120 Hz ping
final class Benchmark {
    private let client: RemoteClient
    private let q = DispatchQueue(label: "flick.bench", qos: .userInteractive)
    private let lock = NSLock()
    private var sentAt: [UInt32: Double] = [:]
    private var rtts: [Double] = []

    init(client: RemoteClient) { self.client = client }

    func start() {
        q.async { self.run() }
    }

    private func log(_ s: String) {
        DispatchQueue.main.async { self.client.send(.log("bench: \(s)")) }
    }

    private func onMain<T>(_ f: @escaping () -> T) -> T { DispatchQueue.main.sync(execute: f) }

    private func run() {
        // Wait for the session, UDP, and (if available) Bluetooth.
        var waited = 0.0
        while waited < 30 {
            let ok = onMain { () -> Bool in if case .connected = self.client.phase { return self.client.udpActive } else { return false } }
            if ok && (client.motion.ble.ready || waited > 15) { break }
            Thread.sleep(forTimeInterval: 0.25); waited += 0.25
        }
        client.motion.onEcho = { [weak self] _, seq in self?.gotEcho(seq) }
        client.onPong = { [weak self] ms in self?.lock.lock(); self?.rtts.append(ms); self?.lock.unlock() }
        let udp = onMain { self.client.udpActive }
        let ble = client.motion.ble.ready
        log("begin p2p=\(BB.peerToPeer) udp=\(udp) ble=\(ble) waited=\(waited)s")
        Thread.sleep(forTimeInterval: 1)

        echo(.udp, hz: 5, count: 40, label: "udp 5Hz (sparse, browser running)")
        echo(.udp, hz: 120, count: 1200, label: "udp 120Hz (active, browser running)")
        if ble {
            echo(.ble, hz: 5, count: 40, label: "ble 5Hz (sparse)")
            echo(.ble, hz: 120, count: 1200, label: "ble 120Hz (active)")
        }
        tcp(hz: 120, count: 600)

        // Race: real (zero-length) move packets over both paths; the Mac logs who won and by how much.
        client.motion.override(.both)
        DispatchQueue.main.sync { self.client.send(.log("flush")) }
        pace(hz: 120, count: 1200) { _ = self.client.motion.move(dx: 0, dy: 0) }
        Thread.sleep(forTimeInterval: 0.5)
        DispatchQueue.main.sync { self.client.send(.log("flush")) }
        log("race done (see mac motion stats above)")

        // Control race: numbered no-op inputs (pings) over TCP + encrypted BLE.
        DispatchQueue.main.sync { self.client.send(.log("flush")) }
        pace(hz: 60, count: 600) {
            DispatchQueue.main.async { self.client.sendInput(.ping(CACurrentMediaTime())) }
        }
        Thread.sleep(forTimeInterval: 0.5)
        DispatchQueue.main.sync { self.client.send(.log("flush")) }
        log("control race done (see mac input stats above)")
        client.motion.override(nil)

        // H1: stop Bonjour browsing (which keeps AWDL busy) and repeat the Wi-Fi tests.
        DispatchQueue.main.sync { self.client.stopBrowsing() }
        Thread.sleep(forTimeInterval: 3)
        echo(.udp, hz: 5, count: 40, label: "udp 5Hz (sparse, browser stopped)")
        echo(.udp, hz: 120, count: 1200, label: "udp 120Hz (active, browser stopped)")
        tcp(hz: 120, count: 600, label: "tcp 120Hz (browser stopped)")
        log("done")
    }

    private func pace(hz: Double, count: Int, _ body: () -> Void) {
        let interval = 1.0 / hz
        let start = CACurrentMediaTime()
        for i in 0..<count {
            body()
            let next = start + Double(i + 1) * interval
            let wait = next - CACurrentMediaTime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    private func echo(_ t: MotionTransport, hz: Double, count: Int, label: String) {
        lock.lock(); sentAt.removeAll(); rtts.removeAll(); lock.unlock()
        pace(hz: hz, count: count) {
            let now = CACurrentMediaTime()
            if let s = client.motion.echo(via: t) { lock.lock(); sentAt[s] = now; lock.unlock() }
        }
        Thread.sleep(forTimeInterval: 1)
        lock.lock(); let r = rtts; let sent = sentAt.count + r.count; lock.unlock()
        log("\(label): rtt ms \(Stats.summary(r, decimals: 2)) lost=\(sent - r.count)/\(sent)")
    }

    private func gotEcho(_ seq: UInt32) {
        let now = CACurrentMediaTime()
        lock.lock()
        if let t = sentAt.removeValue(forKey: seq) { rtts.append((now - t) * 1000) }
        lock.unlock()
    }

    private func tcp(hz: Double, count: Int, label: String = "tcp 120Hz (control channel)") {
        lock.lock(); rtts.removeAll(); lock.unlock()
        pace(hz: hz, count: count) {
            DispatchQueue.main.async { self.client.send(.ping(CACurrentMediaTime())) }
        }
        Thread.sleep(forTimeInterval: 1)
        lock.lock(); let r = rtts; lock.unlock()
        log("\(label): rtt ms \(Stats.summary(r, decimals: 2)) lost=\(max(0, count - r.count))/\(count) (includes background pings)")
    }
}
