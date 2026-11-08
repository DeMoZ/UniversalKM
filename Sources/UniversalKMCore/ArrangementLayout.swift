import CoreGraphics
import Foundation

/// A Mac display in global CG coordinates (origin at the top-left of the main display, y down),
/// as CGDisplayBounds gives it.
public struct DisplayInfo: Equatable, Hashable, Sendable {
    public var uuid: String
    public var frame: CGRect
    public var isMain: Bool

    public init(uuid: String, frame: CGRect, isMain: Bool = false) {
        self.uuid = uuid
        self.frame = frame
        self.isMain = isMain
    }
}

/// Part of a display edge through which the cursor goes to a device (design D8).
public struct HandoffZone: Equatable, Sendable {
    public var deviceID: UUID
    public var displayUUID: String
    public var side: DisplaySide
    /// Segments along the edge in global coordinates (y for left/right, x for top/bottom). Parts
    /// where another display touches the edge are cut out, so there may be several.
    public var segments: [ClosedRange<Double>]

    public var isEmpty: Bool { segments.isEmpty }
}

/// Where a device is drawn and where its zones are.
public struct DeviceLayout: Equatable, Sendable {
    public var device: PlacedDevice
    public var rect: CGRect
    /// Zone on the edge the device is snapped to (the first of `zones`).
    public var zone: HandoffZone
    /// Every display edge the device touches flush, the snapped one first: a device in a corner
    /// between two displays takes input through both.
    public var zones: [HandoffZone]
    /// The anchor display is not connected: the device is shown in the default place for now.
    public var isTemporary: Bool
}

/// Pure geometry of the arrangement (design D8).
public enum ArrangementLayout {
    /// Long side: a third (phone) or a half (tablet) of the main display height; 9:19.5 and 3:4.
    public static func size(kind: DeviceKind, orientation: DeviceOrientation, mainDisplayHeight: Double) -> CGSize {
        let long = mainDisplayHeight * (kind == .phone ? 1.0 / 3.0 : 0.5)
        let short = long * (kind == .phone ? 9.0 / 19.5 : 3.0 / 4.0)
        return orientation == .portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    static func mainHeight(_ displays: [DisplayInfo]) -> Double {
        Double((displays.first(where: \.isMain) ?? displays.first)?.frame.height ?? 1080)
    }

    // MARK: Layout of all devices

    /// Rectangles and zones of every device. Devices whose display is missing go to the default
    /// place (right of the rightmost display) and are marked temporary; the model is not changed.
    public static func layout(_ arrangement: DeviceArrangement, displays: [DisplayInfo]) -> [DeviceLayout] {
        guard !displays.isEmpty else { return [] }
        var placed: [CGRect] = []
        var result: [DeviceLayout] = []
        for device in arrangement.devices {
            let size = size(kind: device.kind, orientation: device.orientation, mainDisplayHeight: mainHeight(displays))
            var placement = device
            var temporary = false
            var rect: CGRect
            if let display = displays.first(where: { $0.uuid == device.anchorDisplayUUID }) {
                rect = self.rect(size: size, display: display.frame, side: device.side, offset: device.offset)
            } else {
                temporary = true
                let snapped = defaultPlacement(size: size, displays: displays, occupied: placed)
                placement.anchorDisplayUUID = snapped.displayUUID
                placement.side = snapped.side
                placement.offset = snapped.offset
                rect = snapped.rect
            }
            placed.append(rect)
            let all = zones(device: placement, rect: rect, displays: displays)
            result.append(DeviceLayout(device: device, rect: rect, zone: all[0], zones: all, isTemporary: temporary))
        }
        return result
    }

    /// Rectangle flush against `side` of the display, starting at `offset` of the edge.
    public static func rect(size: CGSize, display: CGRect, side: DisplaySide, offset: Double) -> CGRect {
        switch side {
        case .right: CGRect(x: display.maxX, y: display.minY + offset * display.height, width: size.width, height: size.height)
        case .left: CGRect(x: display.minX - size.width, y: display.minY + offset * display.height, width: size.width, height: size.height)
        case .top: CGRect(x: display.minX + offset * display.width, y: display.minY - size.height, width: size.width, height: size.height)
        case .bottom: CGRect(x: display.minX + offset * display.width, y: display.maxY, width: size.width, height: size.height)
        }
    }

    // MARK: Zone

    /// The device side's overlap with the anchor display's edge, minus parts where another display
    /// touches that edge (there the cursor simply moves on to that display).
    public static func zone(device: PlacedDevice, rect: CGRect, displays: [DisplayInfo]) -> HandoffZone {
        zone(deviceID: device.id, displayUUID: device.anchorDisplayUUID, side: device.side, rect: rect, displays: displays)
    }

    /// Zones on every display edge the device rectangle is flush against: the snapped edge first,
    /// then the others (a device in the corner between two displays).
    public static func zones(device: PlacedDevice, rect: CGRect, displays: [DisplayInfo]) -> [HandoffZone] {
        var result = [zone(device: device, rect: rect, displays: displays)]
        let epsilon = 0.5
        for display in displays {
            let d = display.frame
            for side in DisplaySide.allCases where !(display.uuid == device.anchorDisplayUUID && side == device.side) {
                let flush: Bool = switch side {
                case .right: abs(rect.minX - d.maxX) < epsilon
                case .left: abs(rect.maxX - d.minX) < epsilon
                case .top: abs(rect.maxY - d.minY) < epsilon
                case .bottom: abs(rect.minY - d.maxY) < epsilon
                }
                guard flush else { continue }
                let extra = zone(deviceID: device.id, displayUUID: display.uuid, side: side, rect: rect, displays: displays)
                if !extra.isEmpty { result.append(extra) }
            }
        }
        return result
    }

    static func zone(deviceID: UUID, displayUUID: String, side: DisplaySide, rect: CGRect, displays: [DisplayInfo]) -> HandoffZone {
        var zone = HandoffZone(deviceID: deviceID, displayUUID: displayUUID, side: side, segments: [])
        guard let display = displays.first(where: { $0.uuid == displayUUID })?.frame else { return zone }
        let (edgeStart, edgeEnd) = edgeRange(display, side)
        let (devStart, devEnd) = side.isVertical ? (Double(rect.minY), Double(rect.maxY)) : (Double(rect.minX), Double(rect.maxX))
        let start = max(edgeStart, devStart), end = min(edgeEnd, devEnd)
        guard end > start else { return zone }
        var segments = [start...end]
        for other in displays where other.frame != display {
            guard let blocked = touchingRange(display, side, other.frame) else { continue }
            segments = segments.flatMap { subtract(blocked, from: $0) }
        }
        zone.segments = segments
        return zone
    }

    static func edgeRange(_ display: CGRect, _ side: DisplaySide) -> (Double, Double) {
        side.isVertical ? (Double(display.minY), Double(display.maxY)) : (Double(display.minX), Double(display.maxX))
    }

    /// Range along the edge where `other` sits flush against `side` of `display`.
    static func touchingRange(_ display: CGRect, _ side: DisplaySide, _ other: CGRect) -> ClosedRange<Double>? {
        let epsilon = 0.5
        let touches: Bool = switch side {
        case .right: abs(other.minX - display.maxX) < epsilon
        case .left: abs(other.maxX - display.minX) < epsilon
        case .top: abs(other.maxY - display.minY) < epsilon
        case .bottom: abs(other.minY - display.maxY) < epsilon
        }
        guard touches else { return nil }
        let (a, b) = side.isVertical ? (Double(other.minY), Double(other.maxY)) : (Double(other.minX), Double(other.maxX))
        let (s, e) = edgeRange(display, side)
        let lo = max(a, s), hi = min(b, e)
        return hi > lo ? lo...hi : nil
    }

    static func subtract(_ cut: ClosedRange<Double>, from range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        guard cut.overlaps(range) else { return [range] }
        var out: [ClosedRange<Double>] = []
        if cut.lowerBound > range.lowerBound { out.append(range.lowerBound...cut.lowerBound) }
        if cut.upperBound < range.upperBound { out.append(cut.upperBound...range.upperBound) }
        return out.filter { $0.upperBound - $0.lowerBound > 0.5 }
    }

    // MARK: Snapping

    public struct Snap: Equatable, Sendable {
        public var displayUUID: String
        public var side: DisplaySide
        public var offset: Double
        public var rect: CGRect
    }

    /// Where a device dropped at `rect` sticks (design D8): flush against the nearest outer edge of a
    /// display, sliding along it so it overlaps neither a display nor another device. Edges are tried
    /// by distance; on a crowded edge the device goes right next to the devices already there.
    public static func snap(_ rect: CGRect, displays: [DisplayInfo], occupied: [CGRect]) -> Snap? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var best: (distance: Double, snap: Snap)?
        for display in displays {
            for side in DisplaySide.allCases {
                for candidate in candidates(for: rect, display: display, side: side, occupied: occupied)
                where isFree(candidate.rect, displays: displays, occupied: occupied) {
                    let distance = hypot(Double(candidate.rect.midX - center.x), Double(candidate.rect.midY - center.y))
                    if best == nil || distance < best!.distance { best = (distance, candidate) }
                }
            }
        }
        return best?.snap
    }

    /// Default place of a new device: right of the rightmost display, vertically centred — or the
    /// nearest free place to it.
    public static func defaultPlacement(size: CGSize, displays: [DisplayInfo], occupied: [CGRect]) -> Snap {
        let rightmost = displays.max { $0.frame.maxX < $1.frame.maxX }!
        let offset = max(0, (Double(rightmost.frame.height) - Double(size.height)) / 2 / Double(rightmost.frame.height))
        let wanted = rect(size: size, display: rightmost.frame, side: .right, offset: offset)
        return snap(wanted, displays: displays, occupied: occupied)
            ?? Snap(displayUUID: rightmost.uuid, side: .right, offset: offset, rect: wanted)
    }

    /// Flush positions on one edge: the dropped position clamped to the edge, and the positions right
    /// before and after each device already on that edge.
    static func candidates(for rect: CGRect, display: DisplayInfo, side: DisplaySide, occupied: [CGRect]) -> [Snap] {
        let frame = display.frame
        let size = rect.size
        let extent = Double(side.isVertical ? size.height : size.width)
        let (edgeStart, edgeEnd) = edgeRange(frame, side)
        let edgeLength = edgeEnd - edgeStart
        func make(_ start: Double) -> Snap {
            let clamped = edgeLength >= extent ? min(max(start, edgeStart), edgeEnd - extent) : edgeStart
            let offset = (clamped - edgeStart) / edgeLength
            return Snap(displayUUID: display.uuid, side: side, offset: offset,
                        rect: self.rect(size: size, display: frame, side: side, offset: offset))
        }
        var starts = [Double(side.isVertical ? rect.minY : rect.minX)]
        let lane = self.rect(size: size, display: frame, side: side, offset: 0)
        for other in occupied {
            // Devices on the same edge share the lane next to it.
            let onEdge = side.isVertical
                ? other.minX < lane.maxX && other.maxX > lane.minX
                : other.minY < lane.maxY && other.maxY > lane.minY
            guard onEdge else { continue }
            if side.isVertical {
                starts += [Double(other.minY) - extent, Double(other.maxY)]
            } else {
                starts += [Double(other.minX) - extent, Double(other.maxX)]
            }
        }
        return starts.map(make)
    }

    static func isFree(_ rect: CGRect, displays: [DisplayInfo], occupied: [CGRect]) -> Bool {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        return !displays.contains { $0.frame.intersects(inset) } && !occupied.contains { $0.intersects(inset) }
    }
}

/// Does a mouse event push into a handoff zone? (design D8)
public enum HandoffZoneDetector {
    /// The device whose zone the point is in while the motion goes outward; nil otherwise.
    public static func device(at point: CGPoint, delta: CGVector, zones: [HandoffZone], displays: [DisplayInfo]) -> UUID? {
        zone(at: point, delta: delta, zones: zones, displays: displays)?.deviceID
    }

    /// The zone the point is in while the motion goes outward; nil otherwise.
    /// The point must be on the last pixel of the zone's side, inside one of its segments, and the
    /// delta must point away from the display — a cursor merely resting at the edge does not count.
    public static func zone(at point: CGPoint, delta: CGVector, zones: [HandoffZone], displays: [DisplayInfo]) -> HandoffZone? {
        for zone in zones where !zone.isEmpty {
            guard let display = displays.first(where: { $0.uuid == zone.displayUUID })?.frame else { continue }
            let x = Double(point.x), y = Double(point.y)
            let atEdge: Bool, outward: Bool, along: Double
            switch zone.side {
            case .right: atEdge = x >= Double(display.maxX) - 1 && x < Double(display.maxX) + 1; outward = delta.dx > 0; along = y
            case .left: atEdge = x <= Double(display.minX) && x > Double(display.minX) - 1; outward = delta.dx < 0; along = y
            case .top: atEdge = y <= Double(display.minY) && y > Double(display.minY) - 1; outward = delta.dy < 0; along = x
            case .bottom: atEdge = y >= Double(display.maxY) - 1 && y < Double(display.maxY) + 1; outward = delta.dy > 0; along = x
            }
            if atEdge && outward && zone.segments.contains(where: { $0.contains(along) }) {
                return zone
            }
        }
        return nil
    }
}
