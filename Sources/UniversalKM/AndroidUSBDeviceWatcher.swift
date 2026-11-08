import Foundation
import IOKit
import IOKit.usb
import UniversalKMCore

/// Finds USB devices that look like Android (design D2, D4) and reports them appearing and
/// disappearing. Watches IOUSBHostDevice services; the interfaces of a new device are enumerated a
/// moment after the device itself, so it is inspected after a short delay (and again if it shows no
/// interfaces yet). Callbacks run on the given queue; the service handed to `onAppear` stays valid
/// until `onDisappear` for the same entry ID.
final class AndroidUSBDeviceWatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    /// Retained services of devices reported to `onAppear`, by registry entry ID.
    private var known: [UInt64: io_service_t] = [:]
    /// Services waiting for their interfaces.
    private var pending: [UInt64: io_service_t] = [:]

    var onAppear: ((UInt64, io_service_t, USBDeviceInfo) -> Void)?
    var onDisappear: ((UInt64) -> Void)?

    private static let inspectDelay: TimeInterval = 0.4
    private static let inspectAttempts = 4

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
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { context, iterator in
            Unmanaged<AndroidUSBDeviceWatcher>.fromOpaque(context!).takeUnretainedValue().drain(iterator, appeared: true)
        }, context, &appeared)
        var terminated: io_iterator_t = 0
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { context, iterator in
            Unmanaged<AndroidUSBDeviceWatcher>.fromOpaque(context!).takeUnretainedValue().drain(iterator, appeared: false)
        }, context, &terminated)
        iterators = [appeared, terminated]
        drain(appeared, appeared: true)
        drain(terminated, appeared: false)
    }

    func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
        (Array(known.values) + Array(pending.values)).forEach { IOObjectRelease($0) }
        known = [:]
        pending = [:]
    }

    private func drain(_ iterator: io_iterator_t, appeared: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if appeared {
                pending[entryID] = service    // keeps the reference from IOIteratorNext
                inspect(entryID, attempt: 1)
            } else {
                IOObjectRelease(service)
                if let waiting = pending.removeValue(forKey: entryID) { IOObjectRelease(waiting) }
                if let service = known.removeValue(forKey: entryID) {
                    IOObjectRelease(service)
                    onDisappear?(entryID)
                }
            }
        }
    }

    private func inspect(_ entryID: UInt64, attempt: Int) {
        queue.asyncAfter(deadline: .now() + Self.inspectDelay) { [weak self] in
            guard let self, let service = self.pending[entryID] else { return }
            let info = Self.info(of: service)
            if info.looksLikeAndroid {
                self.pending[entryID] = nil
                self.known[entryID] = service
                self.onAppear?(entryID, service, info)
            } else if info.interfaces.isEmpty && attempt < Self.inspectAttempts && info.vendorID != 0x05AC {
                self.inspect(entryID, attempt: attempt + 1)
            } else {
                self.pending[entryID] = nil
                IOObjectRelease(service)
            }
        }
    }

    static func info(of service: io_service_t) -> USBDeviceInfo {
        func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func string(_ entry: io_registry_entry_t, _ keys: [String]) -> String? {
            for key in keys {
                if let value = property(entry, key) as? String, !value.isEmpty { return value }
            }
            return nil
        }
        var interfaces: [USBDeviceInfo.Interface] = []
        func collect(_ entry: io_registry_entry_t) {
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                // Devices behind a hub are separate devices, not interfaces of this one.
                if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { continue }
                if let cls = property(child, "bInterfaceClass") as? Int,
                   let sub = property(child, "bInterfaceSubClass") as? Int {
                    let proto = property(child, "bInterfaceProtocol") as? Int ?? 0
                    interfaces.append(.init(UInt8(truncatingIfNeeded: cls), UInt8(truncatingIfNeeded: sub),
                                            UInt8(truncatingIfNeeded: proto), name: string(child, ["kUSBString", "USB Interface Name"])))
                } else {
                    collect(child)
                }
            }
        }
        collect(service)
        return USBDeviceInfo(
            vendorID: UInt16(truncatingIfNeeded: property(service, "idVendor") as? Int ?? 0),
            productID: UInt16(truncatingIfNeeded: property(service, "idProduct") as? Int ?? 0),
            serialNumber: string(service, ["kUSBSerialNumberString", "USB Serial Number"]),
            productName: string(service, ["kUSBProductString", "USB Product Name"]),
            locationID: UInt32(truncatingIfNeeded: property(service, "locationID") as? Int ?? 0),
            interfaces: interfaces
        )
    }
}
