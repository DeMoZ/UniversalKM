import AppKit
import CoreGraphics
import os
import UniversalKMCore

/// Where input goes when the cursor pushes into a device's zone.
struct CaptureTarget: Equatable, Sendable {
    var deviceID: UUID
    var peerID: UInt16
    var isConnected: Bool
    var pointerSpeed: Double
    /// The device rectangle on the arrangement (global coordinates) and its screen in device points.
    var rect: CGRect
    var screen: CGSize
    var returnThroughEdge: Bool
}

/// The global event tap (design D7, D9, D10, D11).
///
/// - The tap runs on its own thread with its own CFRunLoop; its callback must answer synchronously, so
///   everything it reads (mode, zones, hotkey, targets) is in one small lock-protected state.
/// - The hotkey is checked first, before anything else, so input can never get stuck on a device.
/// - Remote mode: the Mac cursor is hidden and frozen (CGAssociateMouseAndMouseCursorPosition(0)),
///   every event is swallowed and turned into HID reports for the device's host.
final class InputManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "input")
    private let transport: HIDTransport
    /// Mode changes for the UI, on the main actor.
    var onModeChange: (@MainActor @Sendable (CaptureStateMachine.Mode) -> Void)?

    private struct Shared {
        var machine = CaptureStateMachine()
        var zones: [HandoffZone] = []
        var displays: [DisplayInfo] = []
        var hotkey = Hotkey.default
        var targets: [UUID: CaptureTarget] = [:]
        var captureOrigin: CGPoint?
        /// The zone the cursor went through: the cursor waits at that edge.
        var captureZone: HandoffZone?
        /// Estimate of the pointer on the device, for the return through the edge (design D11a).
        var virtualCursor: VirtualCursor?
        var swallowKeyUp: UInt16?
        var buttons: MouseButtons = []
        var scrollRemainder = (vertical: 0.0, horizontal: 0.0)
        // Acceleration check (task 2.7): motion summed per second while remote.
        var motionSum = (dx: 0.0, dy: 0.0)
        var motionWindowStart = Date()
    }

    private let state = OSAllocatedUnfairLock(initialState: Shared())
    private var tap: CFMachPort?
    private var thread: Thread?

    /// Points of scroll per wheel click sent to the device (trackpad / continuous scrolling).
    private static let scrollPointsPerClick = 10.0

    init(transport: HIDTransport) {
        self.transport = transport
    }

    // MARK: Configuration (any thread)

    func update(zones: [HandoffZone], displays: [DisplayInfo]) {
        state.withLock {
            $0.zones = zones
            $0.displays = displays
        }
    }

    func update(hotkey: Hotkey) {
        state.withLock { $0.hotkey = hotkey }
    }

    /// Devices that can take input, by device ID. A remote device whose host is gone releases at once.
    func update(targets: [CaptureTarget]) {
        let effects: [CaptureStateMachine.Effect] = state.withLock { shared in
            shared.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.deviceID, $0) })
            guard let current = shared.machine.remoteDevice else { return [] }
            if let target = shared.targets[current] {
                return target.isConnected ? [] : shared.machine.handle(.hostDisconnected(current))
            }
            return shared.machine.handle(.deviceRemoved(current))
        }
        perform(effects)
    }

    /// Back to the Mac from the app (menu, quit, permission lost…). Thread-safe.
    func release(_ event: CaptureStateMachine.Event = .releaseRequested) {
        let effects = state.withLock { $0.machine.handle(event) }
        perform(effects)
    }

    // MARK: Tap

    var isRunning: Bool { tap != nil }

    /// The device input goes to, nil in Mac mode.
    var currentDeviceID: UUID? { state.withLock { $0.machine.remoteDevice } }

    /// Creates the event tap. False without Accessibility permission (tapCreate returns nil).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            let manager = Unmanaged<InputManager>.fromOpaque(context!).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }, userInfo: context) else {
            log.error("event tap not created: no Accessibility permission")
            return false
        }
        self.tap = tap
        let thread = Thread { [weak self] in
            guard let tap = self?.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "ukm.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        log.info("event tap running")
        return true
    }

    // MARK: Callback (tap thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system turned the tap off (callback too slow, or secure input): back on, and never stay remote.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.error("event tap was disabled (\(type.rawValue)), re-enabled")
            release(.tapDisabled)
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let location = event.location
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        enum Decision { case pass, swallow, released([CaptureStateMachine.Effect]), captured(UUID, [CaptureStateMachine.Effect]) }

        let decision: Decision = state.withLock { shared in
            // 1. The hotkey, first of all.
            if shared.machine.remoteDevice != nil, type == .keyDown,
               shared.hotkey.matches(keyCode: keyCode, cgEventFlags: flags) {
                shared.swallowKeyUp = keyCode
                return .released(shared.machine.handle(.hotkey))
            }
            if type == .keyUp, shared.swallowKeyUp == keyCode {
                shared.swallowKeyUp = nil
                return .swallow
            }
            // 2. Local: only look for a push into a zone.
            guard shared.machine.remoteDevice == nil else { return .swallow }
            guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged else {
                return .pass
            }
            guard let zone = HandoffZoneDetector.zone(at: location, delta: delta, zones: shared.zones, displays: shared.displays)
            else { return .pass }
            let device = zone.deviceID
            let connected = shared.targets[device]?.isConnected ?? false
            let effects = shared.machine.handle(.zoneHit(device: device, hostConnected: connected))
            guard shared.machine.remoteDevice == device else { return .pass }
            shared.captureOrigin = location
            shared.captureZone = zone
            if let target = shared.targets[device], target.returnThroughEdge, target.rect.width > 0, target.rect.height > 0 {
                let fraction = zone.side.isVertical
                    ? Double((location.y - target.rect.minY) / target.rect.height)
                    : Double((location.x - target.rect.minX) / target.rect.width)
                shared.virtualCursor = VirtualCursor(screen: target.screen, side: zone.side, entryFraction: fraction)
            } else {
                shared.virtualCursor = nil
            }
            shared.buttons = []
            shared.scrollRemainder = (0, 0)
            shared.motionSum = (0, 0)
            shared.motionWindowStart = Date()
            return .captured(device, effects)
        }

        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .released(let effects):
            perform(effects)
            return nil
        case .captured(let device, let effects):
            log.info("captured → device \(device.uuidString.prefix(8), privacy: .public)")
            perform(effects)
            return nil
        case .swallow:
            forward(type: type, event: event, keyCode: keyCode)
            return nil
        }
    }

    /// Remote mode: turn the event into reports for the current device.
    private func forward(type: CGEventType, event: CGEvent, keyCode: UInt16) {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let snapshot: (target: CaptureTarget, buttons: MouseButtons)? = state.withLock { shared in
            guard let device = shared.machine.remoteDevice, let target = shared.targets[device] else { return nil }
            switch type {
            case .leftMouseDown: shared.buttons.insert(.left)
            case .leftMouseUp: shared.buttons.remove(.left)
            case .rightMouseDown: shared.buttons.insert(.right)
            case .rightMouseUp: shared.buttons.remove(.right)
            case .otherMouseDown, .otherMouseUp:
                let button: MouseButtons = switch buttonNumber {
                case 2: .middle
                case 3: .back
                case 4: .forward
                default: []
                }
                if type == .otherMouseDown { shared.buttons.formUnion(button) } else { shared.buttons.subtract(button) }
            default: break
            }
            return (target, shared.buttons)
        }
        guard let (target, buttons) = snapshot else { return }
        let peer = target.peerID

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Deltas here already went through the macOS pointer speed and acceleration (design D10).
            let dx = event.getDoubleValueField(.mouseEventDeltaX) * target.pointerSpeed
            let dy = event.getDoubleValueField(.mouseEventDeltaY) * target.pointerSpeed
            transport.moveMouse(dx: dx, dy: dy, to: peer)
            logMotion(dx: dx, dy: dy, location: event.location)
            if returnedThroughEdge(dx: dx, dy: dy, target: target) {
                log.info("back to the Mac through the edge")
                release(.releaseRequested)
                return
            }
            holdCursor()
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            transport.setButtons(buttons, to: peer)
        case .scrollWheel:
            let (wheel, pan) = scrollClicks(event)
            if wheel != 0 || pan != 0 { transport.scroll(wheel: wheel, pan: pan, to: peer) }
        case .keyDown, .keyUp:
            // The host repeats held keys itself.
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            guard let usage = KeyCodeMap.usage(forKeyCode: keyCode) else { return }
            transport.key(usage: usage, isDown: type == .keyDown, to: peer)
        case .flagsChanged:
            guard let usage = KeyCodeMap.usage(forKeyCode: keyCode) else { return }
            if keyCode == 0x39 {
                // Caps Lock arrives once per toggle: a tap of the key.
                transport.key(usage: usage, isDown: true, to: peer)
                transport.key(usage: usage, isDown: false, to: peer)
            } else if let mask = Self.deviceModifierMasks[keyCode] {
                transport.key(usage: usage, isDown: event.flags.rawValue & mask != 0, to: peer)
            }
        default:
            break
        }
    }

    /// Device-dependent (left/right) modifier bits of CGEventFlags (NX_DEVICE*KEYMASK).
    private static let deviceModifierMasks: [UInt16: UInt64] = [
        0x3B: 0x0000_0001, // left control
        0x38: 0x0000_0002, // left shift
        0x3C: 0x0000_0004, // right shift
        0x37: 0x0000_0008, // left command
        0x36: 0x0000_0010, // right command
        0x3A: 0x0000_0020, // left option
        0x3D: 0x0000_0040, // right option
        0x3E: 0x0000_2000, // right control
    ]

    /// Wheel clicks for the HID report: continuous (trackpad, Magic Mouse) scrolling sums points,
    /// a classic wheel gives whole lines. Sign as the user sees it on the Mac (natural scrolling included).
    private func scrollClicks(_ event: CGEvent) -> (Double, Double) {
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            return (Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                    -Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)))
        }
        let vertical = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / Self.scrollPointsPerClick
        let horizontal = -event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) / Self.scrollPointsPerClick
        return (vertical, horizontal)   // fractions carry over in the transport's MouseAccumulator
    }

    private func logMotion(dx: Double, dy: Double, location: CGPoint) {
        let line: String? = state.withLock { shared in
            shared.motionSum.dx += abs(dx)
            shared.motionSum.dy += abs(dy)
            guard Date().timeIntervalSince(shared.motionWindowStart) >= 1 else { return nil }
            defer {
                shared.motionSum = (0, 0)
                shared.motionWindowStart = Date()
            }
            guard shared.motionSum.dx + shared.motionSum.dy > 0 else { return nil }
            return String(format: "motion per second: |dx| %.0f, |dy| %.0f; Mac cursor at %.0f,%.0f (held at %.0f,%.0f)",
                          shared.motionSum.dx, shared.motionSum.dy, location.x, location.y,
                          shared.captureOrigin?.x ?? -1, shared.captureOrigin?.y ?? -1)
        }
        // Remote-mode diagnostics: the Mac cursor must stay hidden and frozen at the capture point.
        if let line { log.info("\(line, privacy: .public)") }
    }

    // MARK: Effects

    private func perform(_ effects: [CaptureStateMachine.Effect]) {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .lockCursor:
                lockCursor()
            case .unlockCursor:
                unlockCursor()
            case .hideCursor:
                Task { @MainActor in CursorVisibility.hide() }
            case .showCursor:
                Task { @MainActor in CursorVisibility.show() }
            case .sendNeutralReports(let device):
                if let peer = state.withLock({ $0.targets[device]?.peerID }) {
                    transport.sendNeutral(to: peer)
                }
            case .notifyUI:
                let mode = state.withLock { $0.machine.mode }
                if mode == .local { log.info("released → Mac") }
                if let onModeChange { Task { @MainActor in onModeChange(mode) } }
            }
        }
    }

    /// Moves the estimate of the device pointer; when it was pushed back through the Mac-facing edge, the
    /// Mac cursor is set to the matching place of that display edge and true is returned (design D11a).
    private func returnedThroughEdge(dx: Double, dy: Double, target: CaptureTarget) -> Bool {
        state.withLock { shared in
            guard var cursor = shared.virtualCursor, let zone = shared.captureZone,
                  let display = shared.displays.first(where: { $0.uuid == zone.displayUUID })?.frame else { return false }
            let back = cursor.move(dx: dx, dy: dy)
            shared.virtualCursor = cursor
            guard back else { return false }
            let rect = target.rect
            var along = zone.side.isVertical
                ? Double(rect.minY) + cursor.exitFraction * Double(rect.height)
                : Double(rect.minX) + cursor.exitFraction * Double(rect.width)
            // Stay inside the zone (the cursor enters the display through it).
            let lo = zone.segments.map(\.lowerBound).min() ?? along, hi = zone.segments.map(\.upperBound).max() ?? along
            along = min(max(along, lo + 1), hi - 1)
            shared.captureOrigin = switch zone.side {
            case .right: CGPoint(x: display.maxX - 3, y: along)
            case .left: CGPoint(x: display.minX + 2, y: along)
            case .top: CGPoint(x: along, y: display.minY + 2)
            case .bottom: CGPoint(x: along, y: display.maxY - 3)
            }
            shared.virtualCursor = nil
            return true
        }
    }

    /// CGAssociateMouseAndMouseCursorPosition(0) holds only while the app is active, and a menu bar agent
    /// cannot take the focus on macOS 14+ (checked: the cursor kept moving). So after every motion event in
    /// remote mode the cursor goes back to where it is held. Warping would otherwise mute local events for
    /// 0.25 s; the event source's suppression interval is set to 0 once.
    private func holdCursor() {
        guard let point = state.withLock({ $0.captureOrigin }) else { return }
        CGWarpMouseCursorPosition(point)
    }

    private static let noSuppression: Void = {
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
    }()

    /// Freezes the cursor 2 points inside the display from the zone edge; deltas keep coming (design D9).
    private func lockCursor() {
        let (origin, zone, displays) = state.withLock { shared -> (CGPoint?, HandoffZone?, [DisplayInfo]) in
            return (shared.captureOrigin, shared.captureZone, shared.displays)
        }
        guard var point = origin else { return }
        if let zone, let frame = displays.first(where: { $0.uuid == zone.displayUUID })?.frame {
            switch zone.side {
            case .right: point.x = frame.maxX - 3
            case .left: point.x = frame.minX + 2
            case .top: point.y = frame.minY + 2
            case .bottom: point.y = frame.maxY - 3
            }
        }
        // The cursor comes back here: next to the capture point, not on the edge (no instant re-capture).
        let returnPoint = point
        state.withLock { $0.captureOrigin = returnPoint }
        _ = Self.noSuppression
        CGWarpMouseCursorPosition(returnPoint)
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    /// Back to where the capture happened.
    private func unlockCursor() {
        CGAssociateMouseAndMouseCursorPosition(1)
        if let origin = state.withLock({ $0.captureOrigin }) {
            CGWarpMouseCursorPosition(origin)
        }
    }
}

/// Hiding the cursor from a background menu bar agent (design D9, variant c, approved by the user):
/// WindowServer hides the cursor only for the active application, and an agent cannot become active on
/// macOS 14+. The private connection property "SetsCursorInBackground" lifts that. If a future macOS drops
/// it, the cursor just stays visible; capture keeps working.
@MainActor
enum CursorVisibility {
    private static var hidden = false
    private static var allowedInBackground = false

    private typealias ConnectionID = Int32
    @_silgen_name("_CGSDefaultConnection") private static func defaultConnection() -> ConnectionID
    @_silgen_name("CGSSetConnectionProperty")
    private static func setConnectionProperty(_ cid: ConnectionID, _ target: ConnectionID, _ key: CFString, _ value: CFTypeRef) -> CGError

    static func hide() {
        guard !hidden else { return }
        hidden = true
        if !allowedInBackground {
            let cid = defaultConnection()
            let result = setConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            allowedInBackground = result == .success
            Logger(subsystem: "com.universalkm.UniversalKM", category: "input")
                .info("SetsCursorInBackground: \(result.rawValue)")
        }
        CGDisplayHideCursor(CGMainDisplayID())
    }

    static func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
    }
}
