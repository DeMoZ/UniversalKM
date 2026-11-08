import Foundation

/// Peer IDs of Android hosts (design D3). An Android device is known by its serial number, which is
/// the same over USB (iSerialNumber) and over ADB (`ro.serialno`), so it keeps one peer ID, and one
/// place in the arrangement, on any channel. The IDs live in a range ChameleonUltra never uses.
public struct AndroidPeerRegistry: Codable, Equatable, Sendable {
    public static let range: ClosedRange<UInt16> = 0x8000...0x80FE

    /// Serial number (or `usb-loc:` key) → peer ID.
    public private(set) var peers: [String: UInt16]

    public init(peers: [String: UInt16] = [:]) {
        self.peers = peers
    }

    public static func isAndroidPeer(_ peerID: UInt16) -> Bool { range.contains(peerID) }

    /// Key for a USB device without a serial number: tied to the port it is plugged into.
    public static func usbLocationKey(_ locationID: UInt32) -> String {
        "usb-loc:" + String(locationID, radix: 16)
    }

    /// The peer ID of a device, given out on first sight; nil when the range is used up or the key is empty.
    public mutating func peerID(for key: String) -> UInt16? {
        guard !key.isEmpty else { return nil }
        if let known = peers[key] { return known }
        let used = Set(peers.values)
        guard let free = Self.range.first(where: { !used.contains($0) }) else { return nil }
        peers[key] = free
        return free
    }

    public func existingPeerID(for key: String) -> UInt16? { peers[key] }

    public func key(for peerID: UInt16) -> String? {
        peers.first { $0.value == peerID }?.key
    }
}
