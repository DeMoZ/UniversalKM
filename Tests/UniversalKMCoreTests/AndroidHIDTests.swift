import Foundation
import Testing
@testable import UniversalKMCore

// MARK: Events

@Test func androidEventsStartWithTheReportID() {
    let key = AndroidHIDEvent.keyboard(KeyboardReport(modifiers: .leftShift, keys: [0x04]))
    #expect(key == [1, 0x02, 0, 0x04, 0, 0, 0, 0, 0])
    let mouse = AndroidHIDEvent.mouse(MouseReport(buttons: .left, dx: -1, dy: 300, wheel: 1))
    #expect(mouse == [2, 0x01, 0xFF, 0xFF, 0x2C, 0x01, 0x01, 0x00])
    #expect(AndroidHIDEvent.neutral == [[1, 0, 0, 0, 0, 0, 0, 0, 0], [2, 0, 0, 0, 0, 0, 0, 0]])
}

@Test func aoaProtocolVersionIsLittleEndian() {
    #expect(AOAHID.protocolVersion([2, 0]) == 2)
    #expect(AOAHID.protocolVersion([1, 1]) == 257)
    #expect(AOAHID.protocolVersion([2]) == nil)
}

// MARK: Which USB devices are asked

private let samsungMTP = USBDeviceInfo(vendorID: 0x04E8, productID: 0x6860, serialNumber: "R28M303RHET",
                                       interfaces: [.init(0x06, 0x01, 0x01, name: "MTP"), .init(0x02, 0x02, 0x01)])
private let samsungADB = USBDeviceInfo(vendorID: 0x04E8, productID: 0x6860,
                                       interfaces: [.init(0xFF, 0x42, 0x01, name: "ADB Interface")])

@Test func androidDevicesAreRecognised() {
    #expect(samsungMTP.looksLikeAndroid)
    #expect(samsungADB.looksLikeAndroid)
    #expect(USBDeviceInfo(vendorID: 0x18D1, productID: 0x2D01).looksLikeAndroid)
    #expect(USBDeviceInfo(vendorID: 0x2717, productID: 0xFF40, interfaces: [.init(0xFF, 0xFF, 0x00, name: "mtp")]).looksLikeAndroid)
    #expect(USBDeviceInfo(vendorID: 0x04E8, productID: 0x6863, interfaces: [.init(0xE0, 0x01, 0x03)]).looksLikeAndroid)
}

@Test func otherDevicesAreNotAsked() {
    // AirPods case: HID only, and Apple anyway.
    #expect(!USBDeviceInfo(vendorID: 0x05AC, productID: 0x139F, interfaces: [.init(0x03, 0x00, 0x00)]).looksLikeAndroid)
    // An iPhone shows a PTP interface but is never asked.
    #expect(!USBDeviceInfo(vendorID: 0x05AC, productID: 0x12A8, interfaces: [.init(0x06, 0x01, 0x01)]).looksLikeAndroid)
    // ChameleonUltra: CDC ACM.
    #expect(!USBDeviceInfo(vendorID: 0x6868, productID: 0x8686, interfaces: [.init(0x02, 0x02, 0x01), .init(0x0A, 0, 0)]).looksLikeAndroid)
    // USB mouse and a card reader.
    #expect(!USBDeviceInfo(vendorID: 0x1EA7, productID: 0x0066, interfaces: [.init(0x03, 0x01, 0x02)]).looksLikeAndroid)
    #expect(!USBDeviceInfo(vendorID: 0x05E3, productID: 0x0749, interfaces: [.init(0x08, 0x06, 0x50)]).looksLikeAndroid)
    // A vendor interface without "MTP" in its name.
    #expect(!USBDeviceInfo(vendorID: 0x1234, productID: 0x0001, interfaces: [.init(0xFF, 0x00, 0x00, name: "Debug")]).looksLikeAndroid)
}

// MARK: hid tool commands

private func json(_ line: String) throws -> [String: Any] {
    #expect(line.hasSuffix("\n"))
    #expect(!line.dropLast().contains("\n"))
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

@Test func hidRegisterCarriesTheReportMap() throws {
    let object = try json(HidCommand.register())
    #expect(object["command"] as? String == "register")
    #expect(object["id"] as? Int == 1)
    #expect(object["name"] as? String == "UniversalKM")
    #expect(object["vid"] as? Int == 0x1209)
    #expect(object["bus"] as? String == "bluetooth")
    #expect((object["descriptor"] as? [Int])?.map(UInt8.init) == HIDReportDescriptor.reportMap)

    let old = try json(HidCommand.register(withBus: false))
    #expect(old["bus"] == nil)
    #expect((old["descriptor"] as? [Int])?.count == HIDReportDescriptor.reportMap.count)
}

@Test func hidReportIsOneLine() throws {
    let object = try json(HidCommand.report(AndroidHIDEvent.mouse(MouseReport(dx: 10))))
    #expect(object["command"] as? String == "report")
    #expect(object["report"] as? [Int] == [2, 0, 10, 0, 0, 0, 0, 0])
}

// MARK: Peer IDs

@Test func androidPeerIDsAreStable() throws {
    var registry = AndroidPeerRegistry()
    let phoneID = registry.peerID(for: "R28M303RHET")
    let tabletID = registry.peerID(for: "TAB123")
    let phone = try #require(phoneID)
    let tablet = try #require(tabletID)
    #expect(phone == 0x8000)
    #expect(tablet == 0x8001)
    #expect(registry.peerID(for: "R28M303RHET") == phone)
    #expect(registry.key(for: tablet) == "TAB123")
    #expect(registry.peerID(for: "") == nil)

    let data = try JSONEncoder().encode(registry)
    var decoded = try JSONDecoder().decode(AndroidPeerRegistry.self, from: data)
    #expect(decoded == registry)
    #expect(decoded.peerID(for: "TAB123") == tablet)
    #expect(decoded.existingPeerID(for: "unknown") == nil)
}

@Test func androidPeerRangeRunsOut() {
    var registry = AndroidPeerRegistry()
    for index in 0..<AndroidPeerRegistry.range.count {
        #expect(registry.peerID(for: "dev\(index)") != nil)
    }
    #expect(registry.peerID(for: "one-more") == nil)
}

@Test func chameleonPeersAreNotAndroid() {
    #expect(!AndroidPeerRegistry.isAndroidPeer(0))
    #expect(!AndroidPeerRegistry.isAndroidPeer(0x7FFF))
    #expect(!AndroidPeerRegistry.isAndroidPeer(0xFFFF))
    #expect(AndroidPeerRegistry.isAndroidPeer(0x8000))
    #expect(AndroidPeerRegistry.isAndroidPeer(0x80FE))
    #expect(AndroidPeerRegistry.usbLocationKey(0x00120000) == "usb-loc:120000")
}
