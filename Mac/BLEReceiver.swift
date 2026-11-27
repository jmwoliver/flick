import Foundation
import CoreBluetooth

/// Bluetooth LE path for pointer packets. The iPhone is a GATT peripheral exposing a custom
/// service (custom services are allowed; only the HID service is blocked for apps). The Mac
/// subscribes to the motion characteristic and writes echo replies back without response.
/// Runs its delegate callbacks on the server's network queue, so no locking is needed.
final class BLEReceiver: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onPacket: ((Data, _ reply: @escaping (Data) -> Void) -> Void)?
    var onControl: ((Data) -> Void)?
    var onState: ((String) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var echoChars: [UUID: CBCharacteristic] = [:]
    private let service = CBUUID(string: BB.bleService)
    private let motion = CBUUID(string: BB.bleMotionChar)
    private let echo = CBUUID(string: BB.bleEchoChar)
    private let control = CBUUID(string: BB.bleControlChar)

    init(queue: DispatchQueue) {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    var connectedCount: Int { echoChars.count }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        onState?("bluetooth \(c.state.rawValue == 5 ? "on" : "state=\(c.state.rawValue)")")
        if c.state == .poweredOn { scan() }
    }

    private func scan() {
        central.scanForPeripherals(withServices: [service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard peripherals[p.identifier] == nil else { return }
        peripherals[p.identifier] = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        onState?("ble connected \(p.name ?? "?")")
        p.discoverServices([service])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        peripherals[p.identifier] = nil
        scan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        onState?("ble disconnected \(p.name ?? "?")")
        peripherals[p.identifier] = nil
        echoChars[p.identifier] = nil
        scan()
    }

    /// When the iPhone app relaunches, iOS keeps the radio link but replaces the GATT service.
    /// Re-discover so we re-subscribe to the new instance.
    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        echoChars[p.identifier] = nil
        onState?("ble services changed on \(p.name ?? "?"), re-subscribing")
        p.discoverServices([service])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == service {
            p.discoverCharacteristics([motion, echo, control], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == motion || ch.uuid == control { p.setNotifyValue(true, for: ch) }
            if ch.uuid == echo { echoChars[p.identifier] = ch }
        }
        onState?("ble ready \(p.name ?? "?") mtu=\(p.maximumWriteValueLength(for: .withoutResponse))")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        if ch.uuid == control { onControl?(data); return }
        guard ch.uuid == motion else { return }
        onPacket?(data) { [weak self, weak p] reply in
            guard let p, let echo = self?.echoChars[p.identifier] else { return }
            p.writeValue(reply, for: echo, type: .withoutResponse)
        }
    }
}
