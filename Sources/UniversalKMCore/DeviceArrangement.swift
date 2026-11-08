import CoreGraphics
import Foundation

public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case phone, tablet
}

public enum DeviceOrientation: String, Codable, Sendable {
    case portrait, landscape

    public var rotated: DeviceOrientation { self == .portrait ? .landscape : .portrait }
}

/// Side of a display the device touches.
public enum DisplaySide: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    var isVertical: Bool { self == .left || self == .right }
}

/// A device on the arrangement (design D8).
public struct PlacedDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DeviceKind
    public var orientation: DeviceOrientation
    /// CGDisplayCreateUUIDFromDisplayID string: survives reconnection, unlike CGDirectDisplayID.
    public var anchorDisplayUUID: String
    public var side: DisplaySide
    /// Start of the device along the edge, as a fraction of the edge length (0…1).
    public var offset: Double
    /// Multiplier of the pointer motion sent to this device (0.25…4).
    public var pointerSpeed: Double
    /// Peer ID of the bound Bluetooth host (design D6); nil while the device waits for one.
    public var hostPeerID: UInt16?

    public static let pointerSpeedRange = 0.25...4.0

    public init(id: UUID = UUID(), name: String, kind: DeviceKind, orientation: DeviceOrientation = .portrait,
                anchorDisplayUUID: String, side: DisplaySide, offset: Double, pointerSpeed: Double = 1,
                hostPeerID: UInt16? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.orientation = orientation
        self.anchorDisplayUUID = anchorDisplayUUID
        self.side = side
        self.offset = offset
        self.pointerSpeed = pointerSpeed
        self.hostPeerID = hostPeerID
    }
}

/// The devices on the arrangement, at most `maxDevices` (as many hosts as the Chameleon keeps).
public struct DeviceArrangement: Codable, Hashable, Sendable {
    public static let maxDevices = 3

    public var devices: [PlacedDevice]

    public init(devices: [PlacedDevice] = []) {
        self.devices = devices
    }

    public var canAddDevice: Bool { devices.count < Self.maxDevices }

    public func device(boundTo peerID: UInt16) -> PlacedDevice? {
        devices.first { $0.hostPeerID == peerID }
    }

    /// Binds each subscribed host that no device has yet to the earliest-added device waiting for a
    /// host (design D6). Returns true when something changed.
    @discardableResult
    public mutating func bindHosts(subscribed peerIDs: [UInt16]) -> Bool {
        var changed = false
        for peer in peerIDs where device(boundTo: peer) == nil {
            guard let index = devices.firstIndex(where: { $0.hostPeerID == nil }) else { break }
            devices[index].hostPeerID = peer
            changed = true
        }
        return changed
    }

    /// Subscribed hosts bound to no device while no device waits: the panel offers to add them.
    public func unboundHosts(subscribed peerIDs: [UInt16]) -> [UInt16] {
        guard !devices.contains(where: { $0.hostPeerID == nil }) else { return [] }
        return peerIDs.filter { device(boundTo: $0) == nil }
    }

    /// "Перепривязать": the device waits for the next unbound host.
    public mutating func rebind(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].hostPeerID = nil
    }
}
