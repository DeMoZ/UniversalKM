import Foundation
import IOKit
import UKMUSB
import UniversalKMCore

/// AOA2 HID on one Android device over USB (design D2, D4): vendor control requests through IOKit's
/// device user client, without opening the device. Requests run on the link's own queue, one at a time.
final class AOALink: @unchecked Sendable {
    private let device: OpaquePointer
    private let io = DispatchQueue(label: "ukm.aoa", qos: .userInteractive)
    private static let timeoutMs: UInt32 = 250

    /// kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnAborted, kIOReturnNotAttached: the device is gone.
    static let goneErrors: Set<Int32> = [Int32(bitPattern: 0xE00002C0), Int32(bitPattern: 0xE00002ED),
                                         Int32(bitPattern: 0xE00002EB), Int32(bitPattern: 0xE00002D9)]

    init(service: io_service_t) throws {
        var error: Int32 = 0
        guard let device = ukm_usb_open(service, &error) else { throw AOAError(code: error) }
        self.device = device
    }

    deinit {
        ukm_usb_close(device)
    }

    struct AOAError: Error, CustomStringConvertible {
        let code: Int32
        var description: String { String(format: "IOReturn 0x%08x", UInt32(bitPattern: code)) }
        var isGone: Bool { AOALink.goneErrors.contains(code) }
    }

    /// AOA protocol version, or nil when the device does not answer GET_PROTOCOL. Blocking.
    func protocolVersion() -> Int? {
        io.sync {
            var reply = [UInt8](repeating: 0, count: 2)
            var done: UInt32 = 0
            let kr = reply.withUnsafeMutableBytes {
                ukm_usb_control(device, 0xC0, AOAHID.getProtocol, 0, 0, $0.baseAddress, 2, Self.timeoutMs, &done)
            }
            return kr == 0 ? AOAHID.protocolVersion(Array(reply.prefix(Int(done)))) : nil
        }
    }

    /// Registers the composite keyboard + mouse. A leftover registration from an earlier run is
    /// removed first (its stall is expected when there is none). Blocking.
    func register(descriptor: [UInt8] = HIDReportDescriptor.reportMap) throws {
        try io.sync {
            _ = request(AOAHID.unregisterHID, value: AOAHID.hidID)
            try check(request(AOAHID.registerHID, value: AOAHID.hidID, index: UInt16(descriptor.count)))
            try check(request(AOAHID.setHIDReportDescriptor, value: AOAHID.hidID, data: descriptor))
        }
    }

    /// Removes the registration; errors are ignored (the device may be gone). Blocking.
    func unregister() {
        io.sync { _ = request(AOAHID.unregisterHID, value: AOAHID.hidID) }
    }

    /// Sends one input event on the link's queue; `completion` runs on `queue`.
    func send(_ event: [UInt8], on queue: DispatchQueue, completion: @escaping @Sendable (AOAError?) -> Void) {
        io.async { [self] in
            let kr = request(AOAHID.sendHIDEvent, value: AOAHID.hidID, data: event)
            queue.async { completion(kr == 0 ? nil : AOAError(code: kr)) }
        }
    }

    /// Sends one event and waits for it; errors are ignored (for the neutral reports before removal).
    func sendBlocking(_ event: [UInt8]) {
        io.sync { _ = request(AOAHID.sendHIDEvent, value: AOAHID.hidID, data: event) }
    }

    // On `io` only.
    private func request(_ request: UInt8, value: UInt16, index: UInt16 = 0, data: [UInt8] = []) -> Int32 {
        var bytes = data
        var done: UInt32 = 0
        return bytes.withUnsafeMutableBytes {
            ukm_usb_control(device, 0x40, request, value, index, $0.baseAddress, UInt16($0.count), Self.timeoutMs, &done)
        }
    }

    private func check(_ kr: Int32) throws {
        if kr != 0 { throw AOAError(code: kr) }
    }
}
