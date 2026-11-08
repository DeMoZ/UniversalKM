import CoreGraphics
import Foundation
import Testing
@testable import UniversalKMCore

// MacBook 1512×982 (main) with a 2560×1440 monitor to its right, tops aligned.
private let laptop = DisplayInfo(uuid: "laptop", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isMain: true)
private let monitor = DisplayInfo(uuid: "monitor", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))

private func phone(_ side: DisplaySide, on display: DisplayInfo = laptop, offset: Double = 0.5,
                   orientation: DeviceOrientation = .portrait) -> PlacedDevice {
    PlacedDevice(name: "Pixel", kind: .phone, orientation: orientation, anchorDisplayUUID: display.uuid, side: side, offset: offset)
}

private func zoneLength(_ zone: HandoffZone) -> Double {
    zone.segments.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
}

// MARK: Size and default placement

@Test func phoneAndTabletSizes() {
    let phone = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    #expect(abs(Double(phone.height) - 982.0 / 3) < 0.01)
    #expect(abs(Double(phone.width) - 982.0 / 3 * 9 / 19.5) < 0.01)
    let tablet = ArrangementLayout.size(kind: .tablet, orientation: .landscape, mainDisplayHeight: 982)
    #expect(abs(Double(tablet.width) - 491) < 0.01)
    #expect(abs(Double(tablet.height) - 491 * 0.75) < 0.01)
}

@Test func defaultPlacementIsRightOfRightmostCentred() {
    let size = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    let snap = ArrangementLayout.defaultPlacement(size: size, displays: [laptop, monitor], occupied: [])
    #expect(snap.displayUUID == "monitor")
    #expect(snap.side == .right)
    #expect(snap.rect.minX == monitor.frame.maxX)
    #expect(abs(Double(snap.rect.midY) - Double(monitor.frame.midY)) < 0.5)
}

@Test func secondDeviceDefaultDoesNotOverlapFirst() {
    let size = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    let first = ArrangementLayout.defaultPlacement(size: size, displays: [laptop], occupied: [])
    let second = ArrangementLayout.defaultPlacement(size: size, displays: [laptop], occupied: [first.rect])
    #expect(!second.rect.insetBy(dx: 0.5, dy: 0.5).intersects(first.rect))
    #expect(second.side == .right)   // next to the first one on the same edge
}

// MARK: Zones

@Test func zoneOnEachOfTheFourSides() throws {
    for side in DisplaySide.allCases {
        let device = phone(side, offset: 0.2)
        let layout = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [device]), displays: [laptop]).first)
        #expect(layout.zone.side == side)
        #expect(!layout.zone.isEmpty, "\(side)")
        let extent = side == .left || side == .right ? Double(layout.rect.height) : Double(layout.rect.width)
        #expect(abs(zoneLength(layout.zone) - extent) < 0.01, "\(side)")
    }
}

@Test func portraitAndLandscapeZonesDiffer() throws {
    let portrait = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [phone(.left, offset: 0.1)]), displays: [laptop]).first)
    let landscape = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [phone(.left, offset: 0.1, orientation: .landscape)]), displays: [laptop]).first)
    #expect(zoneLength(portrait.zone) > zoneLength(landscape.zone) * 2)
}

@Test func edgeAdjacentToAnotherDisplayIsExcluded() throws {
    // The monitor's left edge touches the laptop between y 0…982. A tablet at the left of the monitor
    // across that part keeps only the rest of its side as a zone.
    let device = PlacedDevice(name: "P", kind: .tablet, anchorDisplayUUID: "monitor", side: .left, offset: 0.5)
    let layout = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [device]), displays: [laptop, monitor]).first)
    // The tablet spans y 720…1211; the laptop covers 0…982 of that edge → only 982…1211 remains.
    #expect(layout.zone.segments.count == 1)
    #expect(abs(layout.zone.segments[0].lowerBound - 982) < 0.01)
    #expect(abs(layout.zone.segments[0].upperBound - Double(layout.rect.maxY)) < 0.01)
}

@Test func missingAnchorUsesDefaultAndIsTemporary() throws {
    let device = phone(.top, on: monitor)
    let layout = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [device]), displays: [laptop]).first)
    #expect(layout.isTemporary)
    #expect(layout.rect.minX == laptop.frame.maxX)
    #expect(layout.zone.displayUUID == "laptop")
    #expect(layout.device.anchorDisplayUUID == "monitor")   // the model is untouched
}

@Test func twoDevicesOnOneEdgeHaveSeparateZones() throws {
    let a = phone(.right, offset: 0.0)
    let b = phone(.right, offset: 0.6)
    let layouts = ArrangementLayout.layout(DeviceArrangement(devices: [a, b]), displays: [laptop])
    let za = try #require(layouts.first?.zone.segments.first)
    let zb = try #require(layouts.last?.zone.segments.first)
    #expect(za.upperBound <= zb.lowerBound)
}

// MARK: Snapping

@Test func droppedAtEachEdgeSticksFlush() throws {
    let size = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    let left = try #require(ArrangementLayout.snap(CGRect(x: -200, y: 600, width: size.width, height: size.height), displays: [laptop], occupied: []))
    #expect(left.side == .left)
    #expect(left.rect.maxX == laptop.frame.minX)
    #expect(left.rect.maxY <= laptop.frame.maxY)          // slid up to stay on the edge
    let top = try #require(ArrangementLayout.snap(CGRect(x: 600, y: -400, width: size.width, height: size.height), displays: [laptop], occupied: []))
    #expect(top.side == .top)
    #expect(top.rect.maxY == laptop.frame.minY)
}

@Test func droppedOverDisplayMovesToNearestFreeEdge() throws {
    let size = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    // Over the right part of the laptop: the right edge is the monitor, so it cannot go there.
    let snap = try #require(ArrangementLayout.snap(CGRect(x: 1400, y: 300, width: size.width, height: size.height),
                                                   displays: [laptop, monitor], occupied: []))
    #expect(!snap.rect.insetBy(dx: 0.5, dy: 0.5).intersects(laptop.frame))
    #expect(!snap.rect.insetBy(dx: 0.5, dy: 0.5).intersects(monitor.frame))
}

@Test func snapDoesNotOverlapAnotherDevice() throws {
    let size = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    let first = ArrangementLayout.rect(size: size, display: laptop.frame, side: .right, offset: 0.3)
    let snap = try #require(ArrangementLayout.snap(first.offsetBy(dx: 10, dy: 20), displays: [laptop], occupied: [first]))
    #expect(!snap.rect.insetBy(dx: 0.5, dy: 0.5).intersects(first))
    #expect(snap.side == .right)
}

@Test func offsetIsAFractionOfTheEdge() throws {
    let size = ArrangementLayout.size(kind: .phone, orientation: .portrait, mainDisplayHeight: 982)
    let snap = try #require(ArrangementLayout.snap(CGRect(x: 1600, y: 491, width: size.width, height: size.height), displays: [laptop], occupied: []))
    #expect(snap.side == .right)
    #expect((0...1).contains(snap.offset))
    #expect(abs(snap.offset - 491.0 / 982) < 0.01 || snap.rect.maxY == laptop.frame.maxY)
}

// MARK: Model

@Test func jsonRoundTrip() throws {
    var arrangement = DeviceArrangement(devices: [phone(.left, offset: 0.25, orientation: .landscape)])
    arrangement.devices[0].pointerSpeed = 0.5
    arrangement.devices[0].hostPeerID = 3
    let data = try JSONEncoder().encode(arrangement)
    #expect(try JSONDecoder().decode(DeviceArrangement.self, from: data) == arrangement)
}

@Test func newDeviceTakesFirstUnboundHost() {
    var arrangement = DeviceArrangement(devices: [phone(.right)])
    let first = arrangement.bindHosts(subscribed: [5])
    #expect(first)
    #expect(arrangement.devices[0].hostPeerID == 5)
    let again = arrangement.bindHosts(subscribed: [5])
    #expect(!again)                                       // already bound
}

@Test func twoWaitingDevicesBindInOrderOfAdding() {
    let a = phone(.right), b = phone(.left)
    var arrangement = DeviceArrangement(devices: [a, b])
    arrangement.bindHosts(subscribed: [7, 2])
    #expect(arrangement.devices.map(\.hostPeerID) == [7, 2])
}

@Test func rebindResetsAndUnknownHostsAreOffered() {
    var arrangement = DeviceArrangement(devices: [phone(.right)])
    arrangement.bindHosts(subscribed: [1])
    #expect(arrangement.unboundHosts(subscribed: [1, 4]) == [4])
    arrangement.rebind(arrangement.devices[0].id)
    #expect(arrangement.devices[0].hostPeerID == nil)
    #expect(arrangement.unboundHosts(subscribed: [4]).isEmpty)   // a device waits: it will take host 4
}

@Test func atMostThreeDevices() {
    let arrangement = DeviceArrangement(devices: [phone(.right), phone(.left), phone(.top)])
    #expect(!arrangement.canAddDevice)
}

// MARK: Zone detector

@Test func zoneHitOnAllFourSidesMovingOutward() throws {
    for side in DisplaySide.allCases {
        let layout = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [phone(side, offset: 0.3)]), displays: [laptop]).first)
        let mid = (layout.zone.segments[0].lowerBound + layout.zone.segments[0].upperBound) / 2
        let (point, out): (CGPoint, CGVector) = switch side {
        case .right: (CGPoint(x: 1511.5, y: mid), CGVector(dx: 3, dy: 0))
        case .left: (CGPoint(x: 0, y: mid), CGVector(dx: -3, dy: 0))
        case .top: (CGPoint(x: mid, y: 0), CGVector(dx: 0, dy: -3))
        case .bottom: (CGPoint(x: mid, y: 981.5), CGVector(dx: 0, dy: 3))
        }
        #expect(HandoffZoneDetector.device(at: point, delta: out, zones: [layout.zone], displays: [laptop]) == layout.device.id, "\(side)")
        // Along the edge or inward: no hit.
        let along = side == .left || side == .right ? CGVector(dx: 0, dy: 3) : CGVector(dx: 3, dy: 0)
        #expect(HandoffZoneDetector.device(at: point, delta: along, zones: [layout.zone], displays: [laptop]) == nil)
        #expect(HandoffZoneDetector.device(at: point, delta: CGVector(dx: -out.dx, dy: -out.dy), zones: [layout.zone], displays: [laptop]) == nil)
    }
}

@Test func sameEdgeOutsideZoneDoesNotHit() throws {
    let layout = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [phone(.right, offset: 0.6)]), displays: [laptop]).first)
    #expect(HandoffZoneDetector.device(at: CGPoint(x: 1511.5, y: 50), delta: CGVector(dx: 5, dy: 0),
                                       zones: [layout.zone], displays: [laptop]) == nil)
}

@Test func borderBetweenDisplaysDoesNotHit() throws {
    // A tablet left of the monitor: the part of that edge shared with the laptop is not a zone.
    let device = PlacedDevice(name: "T", kind: .tablet, anchorDisplayUUID: "monitor", side: .left, offset: 0.5)
    let layout = try #require(ArrangementLayout.layout(DeviceArrangement(devices: [device]), displays: [laptop, monitor]).first)
    #expect(HandoffZoneDetector.device(at: CGPoint(x: 1512, y: 900), delta: CGVector(dx: -4, dy: 0),
                                       zones: [layout.zone], displays: [laptop, monitor]) == nil)
    #expect(HandoffZoneDetector.device(at: CGPoint(x: 1512, y: 1100), delta: CGVector(dx: -4, dy: 0),
                                       zones: [layout.zone], displays: [laptop, monitor]) == device.id)
}

@Test func pickTheDeviceOfTheZone() throws {
    let right = phone(.right), left = phone(.left)
    let layouts = ArrangementLayout.layout(DeviceArrangement(devices: [right, left]), displays: [laptop])
    let zones = layouts.map(\.zone)
    #expect(HandoffZoneDetector.device(at: CGPoint(x: 0, y: 600), delta: CGVector(dx: -2, dy: 0), zones: zones, displays: [laptop]) == left.id)
    #expect(HandoffZoneDetector.device(at: CGPoint(x: 1511.5, y: 600), delta: CGVector(dx: 2, dy: 0), zones: zones, displays: [laptop]) == right.id)
}
