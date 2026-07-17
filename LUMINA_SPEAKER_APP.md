# Klipsch ProMedia Lumina — LED control app for macOS

**Handoff document.** Everything needed to build a standalone macOS menu bar app
that controls the RGB lighting on Klipsch ProMedia Lumina 2.1 speakers over
Bluetooth LE. The protocol below was reverse-engineered and **verified against
real hardware** (firmware `1.0.1`, model `1073451`) on 2026-07-17: every
characteristic listed was confirmed by diffing GATT reads against changes made
in the official Klipsch Control mobile app, then by writing values back and
visually observing the speakers.

---

## 1. Protocol findings (verified)

### Discovery / connection

- The speaker advertises as **`ProMedia Lumina`** with advertised service UUID
  **`FFC0`**. (Note: another nearby device may also advertise `FFC0`; match on
  the local name, or on the vendor service below after connecting.)
- **The speaker accepts only ONE BLE central at a time.** While the phone app is
  connected, the speaker stops advertising and the Mac cannot connect — and vice
  versa: while the Mac holds the link, the phone app cannot connect. It
  re-advertises within a few seconds of a disconnect.
- No pairing/bonding is required — plain GATT connect and write works.
- All vendor characteristics live under the base UUID pattern
  **`da6d0fXX-0d18-442c-babe-f85b5baa6f11`** — the same scheme as Klipsch The
  Fives / Sevens / Nines (see [Nixer1337/KlipschRemote](https://github.com/Nixer1337/KlipschRemote)
  for that family's audio protocol, which largely carries over).
- Lighting characteristics have properties Read / Write (with response) /
  Notify. Notifications fire when state changes from any source (e.g. the pod's
  physical button) — subscribe to keep UI in sync.

### Lighting characteristics (all under service `da6d0fe1-0d18-442c-babe-f85b5baaf611`*)

*Base suffix is `-0d18-442c-babe-f85b5baa6f11` throughout; full service UUID is
`da6d0fe1-0d18-442c-babe-f85b5baa6f11`.

#### `da6d0ff2` — lighting mode / power (1 byte)

| Value | Meaning | Verified by |
|------:|---------|-------------|
| `0x01` | Rainbow (spectrum cycle) | write + user observation |
| `0x02` | Breathe (fade in/out) | write + user observation |
| `0x03` | Static (solid color) | app diff + write |
| `0x04` | Aurora (multi-color pattern) | write + user observation |
| `0x05` | Music-reactive | write + user observation |
| `0x06` | **Lights off** | app diff (app's "Lights: Off" writes this) |

- Writing `0x00` is **rejected** — the device keeps its previous value.
- There is no separate on/off characteristic: "off" is mode `0x06`. To toggle
  lights, remember the last active mode and restore it on "on".

#### `da6d0fea` — brightness (2 bytes)

- Format: two bytes, each **percent `0x00`–`0x64`** (0–100). The app writes both
  bytes to the same value (e.g. 50% → `3232`). Write both bytes identical.
- **Only affects the animated modes** (Rainbow, Breathe, Aurora, Music). In
  Static mode brightness has no visible effect — dim a static color by scaling
  the RGB value instead.
- The pod's physical button tap cycles 100 → 66 → 33 → 0 (`6464`, `4242`,
  `2121`, `0000`) and pushes each change as a notification on this
  characteristic.

#### `da6d0ff3` — static color (6 bytes)

- Format: two RGB triplets, `RR GG BB RR GG BB`.
- The device shows the **first triplet on both satellites** (writing red+green
  produced two red satellites). The second triplet's role is unconfirmed —
  the factory value was `ff0000 0000ff`. **Write the same triplet twice.**
- Only visually meaningful in Static mode (`ff2 = 0x03`).

### ⚠️ Read-back is stale — trust writes and notifications, not reads

Reading a characteristic immediately after writing it frequently returns the
**old** value (observed repeatedly on `fea`; writes were visually confirmed
applied while reads still returned the previous value, sometimes for minutes).
The device seems to update its GATT read cache lazily. Consequences for the app:

- Treat local state as authoritative after a write (optimistic UI).
- Use **notifications** for external changes (pod button, phone app).
- A read on connect is fine for initial sync, but don't "verify" writes by
  reading back.

### Device information service (standard `180A`) — for identification

| Char | Example value |
|------|---------------|
| `2A24` Model Number | `1073451` |
| `2A25` Serial Number | `108009025410790` |
| `2A26` Firmware Revision | `1.0.1` |
| `2A29` Manufacturer | `Klipsch Group, Inc.` |

### Out of scope but present (do not touch blindly)

The full Fives-family audio GATT table is exposed: volume `da6d0fa2`, mute
`da6d0fa3`, EQ `da6d0f02/03/04`, input select `da6d0fd2`, device name
`da6d0fe6`, transport `da6d0fb2/b3/b4`, and more. **Never write to `da6d0fe8`**
— in this family it is factory reset. Several unidentified write-only
characteristics exist (`da6d0fa5`, `da6d0fa6`, `da6d0fe3`, `da6d0fc6` —
`c6` is likely firmware-update related); leave them alone. The empty
`da6d0fef/f0/f1` characteristics and the separate `da6d0ff1` *service*
(chars `f9`–`ff`, all read empty) are likely the Screen React / streaming
channel — unexplored.

### USB (dead end, for the record)

The speakers also connect via USB (VID `0x18B5`, PID `0x0070`): USB Audio + a
HID interface that is only consumer-control media keys, plus two unclaimed
endpoint-less HID interfaces (presumably the Windows 11 Dynamic Lighting /
LampArray path — macOS does not bind them). BLE is the practical channel on
macOS.

---

## 2. macOS implementation gotchas (learned the hard way)

1. **TCC will SIGABRT any non-bundled process that touches CoreBluetooth.**
   Python/bleak scripts and bare Swift CLIs launched from a terminal get killed
   (exit 134) with no prompt. CoreBluetooth requires a **bundled .app** with
   `NSBluetoothAlwaysUsageDescription` in its Info.plist, launched via
   LaunchServices (`open`), so it is its own TCC principal and gets the
   permission prompt. This applies to test scripts too — use the probe app in
   the appendix rather than bleak.
2. **Single central**: design for connection contention with the phone app (see
   §3, connection strategy).
3. Match the peripheral by advertised name `ProMedia Lumina` (or connect and
   check the DIS model number `1073451`); the advertised `FFC0` UUID is not
   unique to Klipsch.
4. `CBCentralManagerScanOptionAllowDuplicatesKey` is unnecessary; the speaker
   advertises frequently when disconnected. Cache `peripheral.identifier` in
   `UserDefaults` and use `retrievePeripherals(withIdentifiers:)` for instant
   reconnect without scanning.

---

## 3. Implementation plan (new repo, menu bar app)

Model it on the WizControl app pattern (SwiftUI `MenuBarExtra`, SPM-only, no
Xcode project): a `build.sh` that runs `swift build -c release`, assembles
`build/<App>.app` with a copied `Resources/Info.plist`, and ad-hoc codesigns.

### Info.plist requirements

- `LSUIElement` = true (menu-bar only, no Dock icon)
- `NSBluetoothAlwaysUsageDescription` — required or TCC kills the app
- Usual bundle keys (`CFBundleIdentifier`, `CFBundleExecutable`, …)

### Suggested structure

```
Sources/App/
  LuminaApp.swift        @main MenuBarExtra(.window) → PopoverView
  AppState.swift         @MainActor @Observable — single source of truth
  LuminaClient.swift     CoreBluetooth: scan/connect/write/notify
  Models.swift           LightMode enum, RGB, snapshot types
  Views/PopoverView.swift
Resources/Info.plist
build.sh
```

### LuminaClient (CoreBluetooth)

- `CBCentralManager` + `CBPeripheralDelegate`. On `.poweredOn`: try
  `retrievePeripherals(withIdentifiers:)` with the cached identifier, else scan
  and match on name `ProMedia Lumina`; cache the identifier on first connect.
- On connect: discover the `da6d0fe1` service, grab `ff2`/`fea`/`ff3`
  characteristics, read all three once for initial sync, subscribe to notify on
  all three.
- Writes: `.withResponse` (that's what the device advertises and accepts).
- Auto-reconnect: on disconnect, call `connect` again (CoreBluetooth queues it
  until the peripheral reappears) — this makes reconnection automatic when the
  phone app releases the link.
- **Connection strategy** (single-central contention): simplest and best UX is
  hold-forever (the pending-connect above reconnects whenever the speaker is
  free). Tradeoff: while the Mac app runs, the phone app can't connect. That's
  acceptable — the Mac app replaces the phone app for lighting — but consider a
  "Disconnect" menu item to hand the link back to the phone without quitting.

### State & control model (AppState)

- `connected: Bool`, `lightsOn: Bool`, `mode: LightMode`, `brightness: Double`
  (0–100), `staticColor: RGB`, plus `lastActiveMode` for the on/off toggle.
- `enum LightMode: UInt8 { rainbow = 1, breathe = 2, staticColor = 3, aurora = 4, music = 5 }`;
  off = raw byte `0x06`, not a mode.
- Actions mutate local state immediately (optimistic UI) and send the write:
  - `setLights(on:)` → write `ff2` = lastActiveMode.rawValue or `0x06`
  - `setMode(_:)` → write `ff2`, remember as lastActiveMode
  - `setBrightness(_:)` → write `fea` = `[p, p]` — **throttle slider drags**
    (coalesce to ≤1 write per ~100 ms, trailing edge) like WizControl does for
    UDP
  - `setStaticColor(_:)` → write `ff3` = triplet twice — throttled likewise
- Notification handler updates local state from `ff2`/`fea`/`ff3` (this is how
  pod-button and phone-app changes stay in sync). Ignore notify echoes of your
  own recent writes to avoid slider fighting.

### UI (popover)

- Header with connection status dot ("Connected" / "Searching…").
- Lights on/off toggle (switch).
- Mode picker (segmented control: Rainbow · Breathe · Static · Aurora · Music).
- Brightness slider — enabled for animated modes; hidden or repurposed in
  Static (where it should scale the RGB value locally instead, since `fea`
  does nothing there).
- Color wheel + swatches shown only in Static mode. (WizControl's
  `ColorWheelView`/`ColorMath` and swatch grid can be copied over nearly
  verbatim — they operate on a plain `RGB {r,g,b}` struct.)
- Optional: preset slots snapshotting `{lightsOn, mode, brightness, staticColor}`
  to UserDefaults as JSON, same pattern as WizControl's `PresetStore`.

### Verification checklist

1. `./build.sh && open build/<App>.app` → Bluetooth permission prompt appears;
   approve.
2. App connects (status dot green) with the phone app closed.
3. Toggle off → LEDs go dark; toggle on → previous mode returns.
4. Cycle all five modes from the picker; speakers follow.
5. Drag brightness in Rainbow mode → visible dimming, no BLE flood (throttled).
6. Static mode: pick colors on the wheel; both satellites follow.
7. Tap the pod's physical button → app slider updates from the notification.
8. Quit app → phone app can connect again. Relaunch → auto-reconnects.

---

## Appendix: BLE probe tool (working, tested)

A minimal bundled probe app used for all the discovery above. Rebuild it in the
new repo for protocol experiments (`scan` / `dump` / `write` / `listen`).
Remember: it must run as a bundled app via `open` (see §2.1).

`Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "probe", path: "Sources/probe")]
)
```

`Info.plist`: as in §3 (LSUIElement, NSBluetoothAlwaysUsageDescription,
CFBundleExecutable = probe).

`run.sh` (build, bundle, launch via LaunchServices, tail the result file):

```sh
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -3
APP=out/LuminaProbe.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/probe "$APP/Contents/MacOS/probe"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null
OUT="$PWD/out/result.txt"; rm -f "$OUT"
open -n "$APP" --args "$@" --out "$OUT"
for _ in $(seq 1 90); do
    sleep 1
    grep -q '===DONE===' "$OUT" 2>/dev/null && break
done
cat "$OUT" 2>/dev/null || echo "(no output file)"
```

Usage:

```sh
./run.sh scan 10                 # list BLE advertisements
./run.sh dump lumina             # connect + enumerate + read everything
./run.sh write lumina DA6D0FF2-0D18-442C-BABE-F85B5BAA6F11 03   # set static mode
./run.sh listen lumina 60       # subscribe to all notify chars, log changes
```

`Sources/probe/main.swift`:

```swift
import Foundation
import CoreBluetooth

let args = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let outPath = argValue("--out") ?? "/tmp/probe-out.txt"
let positional = args.dropFirst().filter { !$0.hasPrefix("--") && $0 != argValue("--out") }

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
        log("VALUE char=\(characteristic.uuid.uuidString) hex=\(v)")
        if command == "dump" {
            pendingCharReads -= 1
            if pendingCharReads == 0 && servicesWithCharsDone == discoveredServices { finish(0) }
        } else if command == "write" {
            finish(0)
        }
    }

    func doWrite(_ peripheral: CBPeripheral) {
        guard params.count >= 3 else { log("write needs <namePrefix> <charUUID> <hex>"); finish(8) }
        let charUUID = CBUUID(string: params[1])
        guard let data = Data(hex: params[2]) else { log("bad hex"); finish(8) }
        guard let c = peripheral.services?.flatMap({ $0.characteristics ?? [] }).first(where: { $0.uuid == charUUID }) else {
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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        log("write ack: \(error.map(String.init(describing:)) ?? "OK")")
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
```
