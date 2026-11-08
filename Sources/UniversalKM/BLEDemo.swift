import Foundation
import os
import UniversalKMCore

/// `UniversalKM --ble-demo` (task 1.12): checks the whole chain Mac → Chameleon or Android → phone
/// without the event tap; every available Android device is bound for it. Each host that subscribes
/// to reports gets, one host at a time: a square drawn with the
/// pointer, a left click, "hello" typed, then neutral reports. A host that reconnects gets it again.
@MainActor
final class BLEDemo {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "demo")
    private let transport: HIDTransport
    private var subscribed: Set<UInt16> = []
    private var waiting: [UInt16] = []
    private var running = false

    init(transport: HIDTransport) {
        self.transport = transport
    }

    /// Hosts that take reports right now: Chameleon subscribers and registered Android devices.
    func peersChanged(_ peers: [UInt16]) {
        let now = Set(peers)
        for peer in now.subtracting(subscribed).sorted() where !waiting.contains(peer) {
            log.info("host \(peer) subscribed: demo queued")
            waiting.append(peer)
        }
        waiting.removeAll { !now.contains($0) }
        subscribed = now
        runNext()
    }

    private func runNext() {
        guard !running, !waiting.isEmpty else { return }
        let peer = waiting.removeFirst()
        running = true
        Task {
            await run(on: peer)
            running = false
            runNext()
        }
    }

    private func run(on peer: UInt16) async {
        log.info("demo on host \(peer): square, click, hello")
        // A host that just reconnected refuses notifications for a few hundred ms after it re-subscribes.
        try? await Task.sleep(for: .milliseconds(1500))
        let step = 12.0
        for (dx, dy) in [(step, 0.0), (0.0, step), (-step, 0.0), (0.0, -step)] {
            for _ in 0..<20 {
                guard subscribed.contains(peer) else { return }
                transport.moveMouse(dx: dx, dy: dy, to: peer)
                try? await Task.sleep(for: .milliseconds(15))
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        transport.setButtons(.left, to: peer)
        try? await Task.sleep(for: .milliseconds(60))
        transport.setButtons([], to: peer)
        try? await Task.sleep(for: .milliseconds(500))
        // h e l l o (HID usages of the Keyboard/Keypad page).
        for usage: UInt8 in [0x0B, 0x08, 0x0F, 0x0F, 0x12] {
            transport.key(usage: usage, isDown: true, to: peer)
            try? await Task.sleep(for: .milliseconds(40))
            transport.key(usage: usage, isDown: false, to: peer)
            try? await Task.sleep(for: .milliseconds(40))
        }
        transport.sendNeutral(to: peer)
        log.info("demo on host \(peer) done")
    }
}
