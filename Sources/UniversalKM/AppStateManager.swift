import AppKit
import Observation
import os
import UniversalKMCore

/// The app's state for the panel (design D13): transport status, displays, the arrangement, the
/// capture mode. Owns the input manager and the display provider; keeps the arrangement in
/// UserDefaults and hands zones and targets to the input manager whenever something changes.
@MainActor
@Observable
final class AppStateManager {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "state")
    let transport: HIDTransport
    @ObservationIgnored private(set) lazy var input = InputManager(transport: transport)
    @ObservationIgnored private let displaysProvider = DisplayLayoutProvider()
    @ObservationIgnored private var permissionTimer: Timer?

    private(set) var displays: [DisplayInfo] = []
    /// "Встроенный дисплей", "LG HDR WQHD"… by display UUID.
    private(set) var displayNames: [String: String] = [:]
    private(set) var arrangement = DeviceArrangement()
    private(set) var transportStatus = TransportStatus.notConnected
    private(set) var mode = CaptureStateMachine.Mode.local
    private(set) var subscribedPeers: [UInt16] = []
    private(set) var isCaptureRunning = false

    /// The menu bar icon follows the mode (set by AppDelegate).
    @ObservationIgnored var onModeChange: ((PlacedDevice?) -> Void)?

    private static let arrangementKey = "arrangement"

    init(transport: HIDTransport) {
        self.transport = transport
    }

    func start() {
        if let data = UserDefaults.standard.data(forKey: Self.arrangementKey),
           let saved = try? JSONDecoder().decode(DeviceArrangement.self, from: data) {
            arrangement = saved
        }
        displaysChanged(displaysProvider.displays)
        displaysProvider.onChange = { [weak self] displays in self?.displaysChanged(displays) }
        input.onModeChange = { [weak self] mode in self?.modeChanged(mode) }
        startTapWhenPermitted()
    }

    // MARK: Derived

    var layouts: [DeviceLayout] { ArrangementLayout.layout(arrangement, displays: displays) }

    var mainDisplayHeight: Double {
        Double((displays.first(where: \.isMain) ?? displays.first)?.frame.height ?? 1080)
    }

    func isConnected(_ device: PlacedDevice) -> Bool {
        device.hostPeerID.map(subscribedPeers.contains) ?? false
    }

    /// Hosts nobody is bound to while no device waits: the panel offers to add them.
    var unboundHosts: [UInt16] {
        let waiting = arrangement.devices.contains { $0.hostPeerID == nil }
        return subscribedPeers.filter { arrangement.device(boundTo: $0) == nil && (!waiting || notAutoBound.contains($0)) }
    }

    var currentDevice: PlacedDevice? {
        guard case .remote(let id) = mode else { return nil }
        return arrangement.devices.first { $0.id == id }
    }

    // MARK: Editing the arrangement

    func addDevice(kind: DeviceKind, name: String, hostPeerID: UInt16? = nil) {
        guard arrangement.canAddDevice, let rightmost = displays.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var device = PlacedDevice(name: trimmed.isEmpty ? (kind == .phone ? String(localized: "Phone") : String(localized: "Tablet")) : trimmed,
                                  kind: kind, anchorDisplayUUID: rightmost.uuid, side: .right, offset: 0, hostPeerID: hostPeerID)
        let size = ArrangementLayout.size(of: device, on: rightmost)
        let place = ArrangementLayout.defaultPlacement(size: size, displays: displays, occupied: layouts.map(\.rect))
        device.anchorDisplayUUID = place.displayUUID
        device.side = place.side
        device.offset = place.offset
        arrangement.devices.append(device)
        arrangementChanged()
    }

    func removeDevice(_ id: UUID) {
        arrangement.devices.removeAll { $0.id == id }
        arrangementChanged()
    }

    /// "Перепривязать": the device waits for the next host that connects. Hosts connected right now
    /// (the previous one among them) are not bound automatically until they reconnect.
    func rebind(_ id: UUID) {
        arrangement.rebind(id)
        notAutoBound.formUnion(subscribedPeers)
        arrangementChanged()
    }

    /// Hosts left alone by "Перепривязать" until they disconnect.
    @ObservationIgnored private var notAutoBound: Set<UInt16> = []

    /// The only place the orientation changes (design Non-Goals: source .manual; a future device app: .device).
    func setOrientation(_ orientation: DeviceOrientation, of id: UUID, source: OrientationSource = .manual) {
        guard let index = arrangement.devices.firstIndex(where: { $0.id == id }) else { return }
        arrangement.devices[index].orientation = orientation
        // Stay at the same edge; slide along it if the new shape would overlap something.
        if let layout = layouts.first(where: { $0.device.id == id }),
           let snap = snap(id, to: layout.rect) {
            apply(snap, to: index)
        }
        arrangementChanged()
    }

    enum OrientationSource { case manual, device }

    func setPointerSpeed(_ speed: Double, of id: UUID) {
        guard let index = arrangement.devices.firstIndex(where: { $0.id == id }) else { return }
        arrangement.devices[index].pointerSpeed = min(max(speed, PlacedDevice.pointerSpeedRange.lowerBound),
                                                      PlacedDevice.pointerSpeedRange.upperBound)
        arrangementChanged()
    }

    func setReturnThroughEdge(_ on: Bool, of id: UUID) {
        guard let index = arrangement.devices.firstIndex(where: { $0.id == id }) else { return }
        arrangement.devices[index].returnThroughEdge = on
        arrangementChanged()
    }

    /// Screen size of the device in points / pixels (portrait); nil clears it. Proportions follow it.
    func setScreen(points: CGSize?, pixels: CGSize?, of id: UUID) {
        guard let index = arrangement.devices.firstIndex(where: { $0.id == id }) else { return }
        arrangement.devices[index].screenPoints = points
        arrangement.devices[index].screenPixels = pixels
        resnap(index)
        arrangementChanged()
    }

    /// Resizing by the corner: the long side of the rectangle in global points next to its display.
    func resize(_ id: UUID, longSidePoints: Double) {
        guard let index = arrangement.devices.firstIndex(where: { $0.id == id }),
              let display = displays.first(where: { $0.uuid == arrangement.devices[index].anchorDisplayUUID }) else { return }
        arrangement.devices[index].longSideMillimeters =
            ArrangementLayout.longSideMillimeters(forLongSidePoints: longSidePoints, on: display)
        resnap(index)
        arrangementChanged()
    }

    /// The rectangle changed size: stick to the edge again without overlapping anything.
    private func resnap(_ index: Int) {
        let id = arrangement.devices[index].id
        if let layout = layouts.first(where: { $0.device.id == id }), let snap = snap(id, to: layout.rect) {
            apply(snap, to: index)
        }
    }

    /// Where the device dropped at `rect` (global coordinates) would stick.
    func snap(_ id: UUID, to rect: CGRect) -> ArrangementLayout.Snap? {
        let others = layouts.filter { $0.device.id != id }.map(\.rect)
        return ArrangementLayout.snap(rect, displays: displays, occupied: others)
    }

    func drop(_ id: UUID, at rect: CGRect) {
        guard let index = arrangement.devices.firstIndex(where: { $0.id == id }), let snap = snap(id, to: rect) else { return }
        apply(snap, to: index)
        arrangementChanged()
    }

    private func apply(_ snap: ArrangementLayout.Snap, to index: Int) {
        arrangement.devices[index].anchorDisplayUUID = snap.displayUUID
        arrangement.devices[index].side = snap.side
        arrangement.devices[index].offset = snap.offset
    }

    func releaseToMac() {
        input.release(.releaseRequested)
    }

    // MARK: Inputs

    func transportChanged(_ status: TransportStatus) {
        transportStatus = status
        if case .ready(let state) = status {
            subscribedPeers = state.hosts.compactMap { $0.state == .subscribed ? $0.peerID : nil }
        } else {
            subscribedPeers = []
        }
        notAutoBound.formIntersection(subscribedPeers)
        if arrangement.bindHosts(subscribed: subscribedPeers.filter { !notAutoBound.contains($0) }) {
            log.info("bound hosts: \(self.arrangement.devices.map { "\($0.name)=\($0.hostPeerID.map(String.init) ?? "-")" }, privacy: .public)")
            save()
        }
        pushToInput()
    }

    private func displaysChanged(_ new: [DisplayInfo]) {
        displays = new
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid) as String?
            else { continue }
            names[string] = screen.localizedName
        }
        displayNames = names
        pushToInput()
    }

    private func arrangementChanged() {
        save()
        pushToInput()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(arrangement) {
            UserDefaults.standard.set(data, forKey: Self.arrangementKey)
        }
    }

    private func pushToInput() {
        input.update(zones: layouts.flatMap(\.zones), displays: displays)
        let rects = Dictionary(uniqueKeysWithValues: layouts.map { ($0.device.id, $0.rect) })
        input.update(targets: arrangement.devices.compactMap { device in
            guard let peer = device.hostPeerID else { return nil }
            return CaptureTarget(deviceID: device.id, peerID: peer, isConnected: subscribedPeers.contains(peer),
                                 pointerSpeed: device.pointerSpeed, rect: rects[device.id] ?? .zero,
                                 screen: device.screenInPoints, returnThroughEdge: device.isReturnThroughEdgeOn)
        })
    }

    private func modeChanged(_ mode: CaptureStateMachine.Mode) {
        self.mode = mode
        onModeChange?(currentDevice)
    }

    private func startTapWhenPermitted() {
        if input.start() {
            isCaptureRunning = true
            return
        }
        // Shows the system prompt once; then poll until the user enables the switch (design D12).
        // kAXTrustedCheckOptionPrompt is a mutable C global; its value is this constant string.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.input.start() else { return }
                self.isCaptureRunning = true
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    /// "Ускорение мыши на Mac": the global com.apple.mouse.linear setting (design D10, display only).
    var isMacMouseAccelerationOn: Bool {
        !(UserDefaults.standard.object(forKey: "com.apple.mouse.linear") as? Bool ?? false)
    }
}
