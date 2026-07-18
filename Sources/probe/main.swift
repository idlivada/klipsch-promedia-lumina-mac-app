import Foundation
import CoreBluetooth
import LuminaProtocol

// BLE probe for protocol discovery. MUST run as a bundled .app via `open`
// (TCC kills bare binaries that touch CoreBluetooth). Use scripts/probe.sh.
//
// Commands:
//   scan [secs]                       list BLE advertisements
//   dump <namePrefix>                 connect + enumerate + read everything
//   read <namePrefix> <char>          read one characteristic
//   write <namePrefix> <char> <hex>   write hex bytes (refuses denylisted chars)
//   seq <namePrefix> <char>=<hex>...  several writes over ONE connection, in order
//   listen <namePrefix> [secs]        subscribe to all notify chars, log timestamped changes
//
// <char> accepts a full UUID or a 3-hex-digit short id like "ff2".

let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let outPath = argValue("--out") ?? "/tmp/probe-out.txt"
// Positional = tokens that are neither a --flag nor the value immediately
// following one, so a flag value (e.g. --watch 5) can't leak in and corrupt
// seq parsing.
let positional: [String] = {
    var result: [String] = []
    let all = Array(args.dropFirst())
    var i = 0
    while i < all.count {
        let tok = all[i]
        if tok == "--wor" {
            i += 1  // valueless boolean flag
        } else if tok.hasPrefix("--") {
            i += 2  // skip the flag and its value
        } else {
            result.append(tok)
            i += 1
        }
    }
    return result
}()

let outURL = URL(fileURLWithPath: outPath)
FileManager.default.createFile(atPath: outPath, contents: nil)
let outHandle = try! FileHandle(forWritingTo: outURL)

func log(_ s: String) {
    outHandle.write((s + "\n").data(using: .utf8)!)
    try? outHandle.synchronize()
}

func finish(_ code: Int32) -> Never {
    log("===DONE=== exit=\(code)")
    exit(code)
}

let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()
func ts() -> String { tsFormatter.string(from: Date()) }

func expandChar(_ s: String) -> CBUUID {
    s.count == 3 ? Lumina.uuid(s) : CBUUID(string: s)
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let command: String
    let params: [String]
    var central: CBCentralManager!
    var target: CBPeripheral?
    var seen: Set<UUID> = []
    var pendingCharReads = 0
    var discoveredServices = 0
    var servicesWithCharsDone = 0
    var writeChar: CBCharacteristic?
    var seqWrites: [(uuid: CBUUID, data: Data)] = []
    var seqIndex = 0

    init(command: String, params: [String]) {
        self.command = command
        self.params = params
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state: \(central.state.rawValue)")
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { log("UNAUTHORIZED"); finish(2) }
            if central.state == .poweredOff { log("Bluetooth is OFF"); finish(3) }
            return
        }
        central.scanForPeripherals(withServices: nil)
        let secs = command == "scan" ? Double(params.first ?? "10") ?? 10 : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            if self.command == "scan" || self.target == nil {
                log(self.command == "scan" ? "scan complete" : "TIMEOUT: target not found")
                finish(self.command == "scan" ? 0 : 4)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        if command == "scan" {
            if seen.contains(peripheral.identifier) { return }
            seen.insert(peripheral.identifier)
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
            log("FOUND \(peripheral.identifier)  rssi=\(RSSI)  name='\(name)'  svc=\(uuids)")
            return
        }
        guard target == nil, let prefix = params.first,
              name.lowercased().contains(prefix.lowercased()) else { return }
        log("MATCH \(peripheral.identifier) name='\(name)' — connecting")
        target = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("connect FAILED: \(String(describing: error))"); finish(5)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error.map(String.init(describing:)) ?? "clean")"); finish(6)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { log("no services"); finish(7) }
        discoveredServices = services.count
        log("services: \(services.count)")
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        servicesWithCharsDone += 1
        for c in service.characteristics ?? [] {
            log("CHAR svc=\(service.uuid.uuidString) char=\(c.uuid.uuidString) props=\(c.properties.desc)")
        }
        if command == "dump" {
            for c in service.characteristics ?? [] where c.properties.contains(.read) {
                pendingCharReads += 1
                peripheral.readValue(for: c)
            }
            if servicesWithCharsDone == discoveredServices && pendingCharReads == 0 { finish(0) }
        } else if command == "write", servicesWithCharsDone == discoveredServices {
            doWrite(peripheral)
        } else if command == "read", servicesWithCharsDone == discoveredServices {
            doRead(peripheral)
        } else if command == "seq", servicesWithCharsDone == discoveredServices {
            startSeq(peripheral)
        } else if command == "listen" {
            for c in service.characteristics ?? [] where c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
            if servicesWithCharsDone == discoveredServices {
                let secs = Double(params.count > 1 ? params[1] : "40") ?? 40
                log("LISTENING for \(Int(secs))s — trigger changes now")
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) { finish(0) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let v = characteristic.value?.hexString ?? "nil"
        if command == "listen" {
            log("[\(ts())] VALUE char=\(characteristic.uuid.uuidString) hex=\(v)")
            return
        }
        log("VALUE char=\(characteristic.uuid.uuidString) hex=\(v)")
        if command == "dump" {
            pendingCharReads -= 1
            if pendingCharReads == 0 && servicesWithCharsDone == discoveredServices { finish(0) }
        } else if command == "read" || command == "write" {
            finish(0)
        }
    }

    func findChar(_ peripheral: CBPeripheral, _ uuid: CBUUID) -> CBCharacteristic? {
        peripheral.services?.flatMap { $0.characteristics ?? [] }.first { $0.uuid == uuid }
    }

    func doRead(_ peripheral: CBPeripheral) {
        guard params.count >= 2 else { log("read needs <namePrefix> <charUUID>"); finish(8) }
        let uuid = expandChar(params[1])
        guard let c = findChar(peripheral, uuid) else { log("char \(uuid) not found"); finish(9) }
        guard c.properties.contains(.read) else { log("char \(uuid) is not readable"); finish(9) }
        peripheral.readValue(for: c)
    }

    func doWrite(_ peripheral: CBPeripheral) {
        guard params.count >= 3 else { log("write needs <namePrefix> <charUUID> <hex>"); finish(8) }
        let charUUID = expandChar(params[1])
        if Lumina.writeDenylist.contains(charUUID) {
            log("REFUSED: \(charUUID.uuidString) is denylisted (factory reset / unknown write-only)")
            finish(10)
        }
        guard let data = Data(hex: params[2]) else { log("bad hex"); finish(8) }
        guard let c = findChar(peripheral, charUUID) else {
            log("char \(charUUID) not found"); finish(9)
        }
        writeChar = c
        var type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        if args.contains("--wor") { type = .withoutResponse }
        log("WRITING \(params[2]) to \(charUUID.uuidString)")
        peripheral.writeValue(data, for: c, type: type)
        if type == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.readBack(peripheral) }
        }
    }

    func startSeq(_ peripheral: CBPeripheral) {
        for p in params.dropFirst() {
            let parts = p.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let data = Data(hex: String(parts[1])) else {
                log("bad seq item '\(p)' — expected <char>=<hex>"); finish(8)
            }
            let uuid = expandChar(String(parts[0]))
            if Lumina.writeDenylist.contains(uuid) {
                log("REFUSED: \(uuid.uuidString) is denylisted"); finish(10)
            }
            seqWrites.append((uuid, data))
        }
        guard !seqWrites.isEmpty else { log("seq needs <char>=<hex> items"); finish(8) }
        nextSeqWrite(peripheral)
    }

    func nextSeqWrite(_ peripheral: CBPeripheral) {
        guard seqIndex < seqWrites.count else {
            let linger = Double(argValue("--watch") ?? "2") ?? 2
            log("seq complete (\(seqWrites.count) writes, one connection) — watching \(Int(linger))s")
            // Keep the connection open and log any notifications (e.g. fea
            // mirroring a brightness change) so writes can be attributed.
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) { finish(0) }
            return
        }
        let w = seqWrites[seqIndex]
        guard let c = findChar(peripheral, w.uuid) else {
            log("char \(w.uuid) not found"); finish(9)
        }
        log("[\(ts())] SEQ \(seqIndex + 1)/\(seqWrites.count) write \(w.data.hexString) -> \(w.uuid.uuidString)")
        seqIndex += 1
        peripheral.writeValue(w.data, for: c, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        log("write ack: \(error.map(String.init(describing:)) ?? "OK")")
        if command == "seq" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.nextSeqWrite(peripheral) }
            return
        }
        readBack(peripheral)
    }

    func readBack(_ peripheral: CBPeripheral) {
        guard let c = writeChar, c.properties.contains(.read) else { finish(0) }
        peripheral.readValue(for: c)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }
}

extension CBCharacteristicProperties {
    var desc: String {
        var p: [String] = []
        if contains(.read) { p.append("R") }
        if contains(.write) { p.append("W") }
        if contains(.writeWithoutResponse) { p.append("w") }
        if contains(.notify) { p.append("N") }
        if contains(.indicate) { p.append("I") }
        return p.joined()
    }
}

guard let cmd = positional.first else { log("no command"); finish(1) }
log("probe start: \(positional.joined(separator: " "))")
let probe = Probe(command: cmd, params: Array(positional.dropFirst()))
RunLoop.main.run()
