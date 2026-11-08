import Foundation

/// HID input events for an Android device, the same bytes on every Android channel (design D4, D5):
/// the report ID of `HIDReportDescriptor.reportMap` followed by the report.
public enum AndroidHIDEvent {
    public static func keyboard(_ report: KeyboardReport) -> [UInt8] { [HIDReportID.keyboard] + report.bytes }
    public static func mouse(_ report: MouseReport) -> [UInt8] { [HIDReportID.mouse] + report.bytes }
    /// Releases every key and button.
    public static let neutral: [[UInt8]] = [keyboard(.neutral), mouse(.neutral)]
}

/// Android Open Accessory 2 HID over USB control requests (design D4). All are vendor requests to
/// the device on endpoint 0; the device stays in its normal USB mode.
public enum AOAHID {
    /// IN, 2 bytes: protocol version, little endian.
    public static let getProtocol: UInt8 = 51
    /// OUT, value = HID id, index = descriptor length.
    public static let registerHID: UInt8 = 54
    /// OUT, value = HID id.
    public static let unregisterHID: UInt8 = 55
    /// OUT, value = HID id, index = offset, data = descriptor bytes.
    public static let setHIDReportDescriptor: UInt8 = 56
    /// OUT, value = HID id, data = event bytes.
    public static let sendHIDEvent: UInt8 = 57

    /// HID support starts with AOA 2.
    public static let minimumProtocol = 2
    /// The one composite keyboard + mouse device the app registers.
    public static let hidID: UInt16 = 1

    /// Protocol version from the GET_PROTOCOL reply, nil for a short reply.
    public static func protocolVersion(_ reply: [UInt8]) -> Int? {
        guard reply.count >= 2 else { return nil }
        return Int(reply[0]) | Int(reply[1]) << 8
    }
}

/// What the app reads about a USB device before deciding to talk AOA to it.
public struct USBDeviceInfo: Hashable, Sendable {
    public struct Interface: Hashable, Sendable {
        public var interfaceClass: UInt8
        public var subclass: UInt8
        public var interfaceProtocol: UInt8
        public var name: String?

        public init(_ interfaceClass: UInt8, _ subclass: UInt8, _ interfaceProtocol: UInt8, name: String? = nil) {
            self.interfaceClass = interfaceClass
            self.subclass = subclass
            self.interfaceProtocol = interfaceProtocol
            self.name = name
        }
    }

    public var vendorID: UInt16
    public var productID: UInt16
    public var serialNumber: String?
    public var productName: String?
    public var locationID: UInt32
    public var interfaces: [Interface]

    public init(vendorID: UInt16, productID: UInt16, serialNumber: String? = nil, productName: String? = nil,
                locationID: UInt32 = 0, interfaces: [Interface] = []) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.productName = productName
        self.locationID = locationID
        self.interfaces = interfaces
    }

    /// Asked only of devices that look like Android (design D4): an ADB, MTP/PTP or RNDIS interface,
    /// or a Google accessory product ID. Never Apple devices or a ChameleonUltra.
    public var looksLikeAndroid: Bool {
        if vendorID == Self.appleVendorID { return false }
        if vendorID == Self.chameleonVendorID && productID == Self.chameleonProductID { return false }
        if vendorID == Self.googleVendorID && Self.googleAccessoryProducts.contains(productID) { return true }
        return interfaces.contains { iface in
            switch (iface.interfaceClass, iface.subclass, iface.interfaceProtocol) {
            case (0xFF, 0x42, 0x01): true                        // ADB
            case (0x06, 0x01, 0x01): true                        // MTP / PTP (still image)
            case (0xE0, 0x01, 0x03), (0xEF, 0x04, 0x01): true    // RNDIS (USB tethering)
            case (0xFF, _, _): iface.name?.uppercased().contains("MTP") ?? false
            default: false
            }
        }
    }

    static let appleVendorID: UInt16 = 0x05AC
    static let chameleonVendorID: UInt16 = 0x6868
    static let chameleonProductID: UInt16 = 0x8686
    static let googleVendorID: UInt16 = 0x18D1
    static let googleAccessoryProducts: ClosedRange<UInt16> = 0x2D00...0x2D05
}
