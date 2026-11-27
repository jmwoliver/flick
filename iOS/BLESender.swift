import Foundation
import CoreBluetooth

/// iPhone side of the Bluetooth LE motion path. The phone acts as a GATT peripheral with a custom
/// service (allowed for apps; the HID service is not). Pointer packets go out as notifications;
/// the Mac writes echo replies back for latency measurement.
final class BLESender: NSObject, CBPeripheralManagerDelegate {
    var onWrite: ((Data) -> Void)?
    var onState: ((String) -> Void)?

    private let q = DispatchQueue(label: "flick.ble", qos: .userInteractive)
    private var pm: CBPeripheralManager?
    private var motionChar: CBMutableCharacteristic?
    private var controlChar: CBMutableCharacteristic?
    private var maxLen = 0
    private var subscribers: [CBCentral] = []
    private let lock = NSLock()
    private var _ready = false
    private(set) var dropped = 0

    /// True once a Mac is subscribed with an MTU big enough for a whole packet.
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }

    func start() {
        q.async {
            guard self.pm == nil else { return }
            self.pm = CBPeripheralManager(delegate: self, queue: self.q)
        }
    }

    func send(_ data: Data) {
        q.async {
            guard let pm = self.pm, let ch = self.motionChar else { return }
            // false = the outgoing queue is full. Dropping is fine: packets carry cumulative position.
            if !pm.updateValue(data, for: ch, onSubscribedCentrals: nil) { self.dropped += 1 }
        }
    }

    /// Sends a sealed input message. Returns false if Bluetooth can't carry it (TCP still does).
    @discardableResult
    func sendControl(_ data: Data) -> Bool {
        lock.lock(); let ok = _ready && data.count <= maxLen; lock.unlock()
        guard ok else { return false }
        q.async {
            guard let pm = self.pm, let ch = self.controlChar else { return }
            if !pm.updateValue(data, for: ch, onSubscribedCentrals: nil) { self.dropped += 1 }
        }
        return true
    }

    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        onState?("bluetooth state=\(pm.state.rawValue)")
        guard pm.state == .poweredOn, motionChar == nil else { return }
        let motion = CBMutableCharacteristic(type: CBUUID(string: BB.bleMotionChar), properties: [.notify],
                                             value: nil, permissions: [.readable])
        let echo = CBMutableCharacteristic(type: CBUUID(string: BB.bleEchoChar), properties: [.writeWithoutResponse],
                                           value: nil, permissions: [.writeable])
        let control = CBMutableCharacteristic(type: CBUUID(string: BB.bleControlChar), properties: [.notify],
                                              value: nil, permissions: [.readable])
        let service = CBMutableService(type: CBUUID(string: BB.bleService), primary: true)
        service.characteristics = [motion, echo, control]
        motionChar = motion
        controlChar = control
        pm.add(service)
    }

    func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BB.bleService)],
                             CBAdvertisementDataLocalNameKey: "Flick"])
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didSubscribeTo ch: CBCharacteristic) {
        subscribers.append(central)
        // Ask for the shortest connection interval iOS allows a peripheral to request.
        pm.setDesiredConnectionLatency(.low, for: central)
        let fits = central.maximumUpdateValueLength >= MotionPacket.size
        lock.lock(); _ready = fits; maxLen = central.maximumUpdateValueLength; lock.unlock()
        onState?("ble subscribed, max update \(central.maximumUpdateValueLength) bytes, usable=\(fits)")
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom ch: CBCharacteristic) {
        subscribers.removeAll { $0.identifier == central.identifier }
        lock.lock(); _ready = !subscribers.isEmpty; lock.unlock()
        onState?("ble unsubscribed")
    }

    func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {}

    func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests { if let v = r.value { onWrite?(v) } }
    }
}
