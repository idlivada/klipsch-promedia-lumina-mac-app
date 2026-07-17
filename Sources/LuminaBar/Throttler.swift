import Foundation
import CoreBluetooth

/// Per-characteristic write coalescing: leading edge fires immediately, further
/// values within `interval` are coalesced to a single trailing-edge write.
/// `flush` on slider release guarantees the final value lands.
@MainActor
final class Throttler {
    private let interval: TimeInterval
    private let send: (CBUUID, Data) -> Void
    private var lastFire: [CBUUID: Date] = [:]
    private var pending: [CBUUID: Data] = [:]
    private var scheduled: Set<CBUUID> = []

    init(interval: TimeInterval = 0.1, send: @escaping (CBUUID, Data) -> Void) {
        self.interval = interval
        self.send = send
    }

    func submit(_ uuid: CBUUID, _ data: Data) {
        let now = Date()
        if let last = lastFire[uuid], now.timeIntervalSince(last) < interval {
            pending[uuid] = data
            if !scheduled.contains(uuid) {
                scheduled.insert(uuid)
                let delay = interval - now.timeIntervalSince(last)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self?.firePending(uuid)
                }
            }
        } else {
            lastFire[uuid] = now
            send(uuid, data)
        }
    }

    func flush(_ uuid: CBUUID) { firePending(uuid) }

    private func firePending(_ uuid: CBUUID) {
        scheduled.remove(uuid)
        guard let data = pending.removeValue(forKey: uuid) else { return }
        lastFire[uuid] = Date()
        send(uuid, data)
    }
}
