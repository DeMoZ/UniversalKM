import Foundation
import IOKit
import IOKit.serial

/// Finds ChameleonUltra serial ports (USB 6868:8686) and reports them appearing and disappearing
/// (design D5). Watches IOSerialBSDClient services and keeps those whose USB device ancestor has the
/// Chameleon VID/PID. Callbacks run on the given queue.
final class ChameleonDeviceWatcher: @unchecked Sendable {
    static let vendorID = 0x6868
    static let productID = 0x8686

    private let queue: DispatchQueue
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    /// Callout path ("/dev/cu.usbmodem…") by registry entry ID, for the terminated notification.
    private var known: [UInt64: String] = [:]

    var onAppear: ((String) -> Void)?
    var onDisappear: ((String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Call on the queue.
    func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        var appeared: io_iterator_t = 0
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(kIOSerialBSDServiceValue), { context, iterator in
            Unmanaged<ChameleonDeviceWatcher>.fromOpaque(context!).takeUnretainedValue().drain(iterator, appeared: true)
        }, context, &appeared)
        var terminated: io_iterator_t = 0
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(kIOSerialBSDServiceValue), { context, iterator in
            Unmanaged<ChameleonDeviceWatcher>.fromOpaque(context!).takeUnretainedValue().drain(iterator, appeared: false)
        }, context, &terminated)
        iterators = [appeared, terminated]
        // Arms the notifications and reports ports that are already there.
        drain(appeared, appeared: true)
        drain(terminated, appeared: false)
    }

    func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
        known = [:]
    }

    private func drain(_ iterator: io_iterator_t, appeared: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if appeared {
                guard isChameleon(service),
                      let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String
                else { continue }
                known[entryID] = path
                onAppear?(path)
            } else if let path = known.removeValue(forKey: entryID) {
                onDisappear?(path)
            }
        }
    }

    private func isChameleon(_ service: io_object_t) -> Bool {
        func number(_ key: String) -> Int? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int
        }
        return number("idVendor") == Self.vendorID && number("idProduct") == Self.productID
    }
}
