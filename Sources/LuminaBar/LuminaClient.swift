import Foundation
import CoreBluetooth
import LuminaProtocol

enum LuminaEvent {
    case connected
    case disconnected
    case value(CBUUID, Data)
}

/// CoreBluetooth lifecycle: cached-identifier fast reconnect, name-match scan
/// fallback, notify subscriptions, one initial read for sync (read-back is
/// stale on this device — never read to verify a write), FIFO write queue with
/// one in-flight write and same-characteristic replacement.
final class LuminaClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onEvent: ((LuminaEvent) -> Void)?
    private(set) var holdConnection = true

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var writeQueue: [(uuid: CBUUID, data: Data)] = []
    private var inFlight = false
    private let idKey = "lumina.peripheral.id"
    private let deviceName = "ProMedia Lumina"

    /// Characteristics we map, subscribe to, and initially read.
    private let table: [CBUUID] = [
        Lumina.lightMode, Lumina.brightness, Lumina.staticColor,
        Lumina.volume, Lumina.mute, Lumina.subGain,
        Lumina.nightMode, Lumina.eqBlob, Lumina.soundMode, Lumina.input,
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Connection strategy (single central — phone app and Mac are mutually exclusive)

    func release() {
        holdConnection = false
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func reconnect() {
        holdConnection = true
        if central.state == .poweredOn { startConnecting() }
    }

    private func startConnecting() {
        guard holdConnection else { return }
        if let s = UserDefaults.standard.string(forKey: idKey),
           let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else {
            central.scanForPeripherals(withServices: nil)
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        // CoreBluetooth keeps this pending until the peripheral appears, which
        // makes reconnection automatic when the phone app releases the link.
        central.connect(p)
    }

    // MARK: Writes

    func write(_ uuid: CBUUID, _ data: Data) {
        guard !Lumina.writeDenylist.contains(uuid) else {
            assertionFailure("attempted write to denylisted characteristic \(uuid)")
            return
        }
        guard chars[uuid] != nil else { return }  // not connected/mapped; initial reads resync on connect
        if let i = writeQueue.firstIndex(where: { $0.uuid == uuid }) {
            writeQueue[i] = (uuid, data)
        } else {
            writeQueue.append((uuid, data))
        }
        pump()
    }

    private func pump() {
        guard !inFlight, let p = peripheral else { return }
        while let next = writeQueue.first {
            guard let c = chars[next.uuid] else { writeQueue.removeFirst(); continue }
            writeQueue.removeFirst()
            inFlight = true
            p.writeValue(next.data, for: c, type: .withResponse)
            return
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startConnecting() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name == deviceName else { return }
        central.stopScan()
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: idKey)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if holdConnection { connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        chars.removeAll()
        writeQueue.removeAll()
        inFlight = false
        onEvent?(.disconnected)
        if holdConnection { connect(peripheral) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where table.contains(c.uuid) {
            chars[c.uuid] = c
            if c.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.properties.contains(.read) {
                peripheral.readValue(for: c)  // initial sync only — reads are stale after writes
            }
        }
        if chars[Lumina.lightMode] != nil, service.uuid == Lumina.lightingService {
            onEvent?(.connected)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, error == nil else { return }
        onEvent?(.value(characteristic.uuid, data))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        inFlight = false
        pump()
    }
}
