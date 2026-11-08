import Foundation

/// Mac / Device mode switching (design D11). A pure state machine: the app feeds events and performs
/// the returned effects. Hide/show of the cursor are kept paired: hide is never issued twice.
public struct CaptureStateMachine: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case local
        /// Input goes to this device (its bound Bluetooth host).
        case remote(UUID)
    }

    public enum Event: Equatable, Sendable {
        /// The cursor pushed into a device's handoff zone. `hostConnected`: the device's host is
        /// connected and subscribed (nil device = no device there).
        case zoneHit(device: UUID?, hostConnected: Bool)
        case hotkey
        case hostDisconnected(UUID)
        case deviceRemoved(UUID)
        case permissionLost
        case tapDisabled
        case quit
        case releaseRequested
    }

    public enum Effect: Equatable, Sendable {
        case hideCursor
        case showCursor
        case lockCursor
        case unlockCursor
        case sendNeutralReports(UUID)
        case notifyUI
    }

    public private(set) var mode: Mode = .local
    public private(set) var isCursorHidden = false

    public init() {}

    public var remoteDevice: UUID? {
        if case .remote(let device) = mode { return device }
        return nil
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (mode, event) {
        case (.local, .zoneHit(let device?, true)):
            mode = .remote(device)
            var effects: [Effect] = []
            if !isCursorHidden {
                isCursorHidden = true
                effects.append(.hideCursor)
            }
            effects += [.lockCursor, .notifyUI]
            return effects

        case (.remote(let current), .hostDisconnected(let device)),
             (.remote(let current), .deviceRemoved(let device)):
            return device == current ? release(current) : []

        case (.remote(let current), .hotkey),
             (.remote(let current), .permissionLost),
             (.remote(let current), .tapDisabled),
             (.remote(let current), .quit),
             (.remote(let current), .releaseRequested):
            return release(current)

        default:
            // Local: everything except a zone hit with a connected host is ignored (the hotkey passes
            // through to macOS). Remote: further zone hits are ignored.
            return []
        }
    }

    private mutating func release(_ device: UUID) -> [Effect] {
        mode = .local
        var effects: [Effect] = [.sendNeutralReports(device), .unlockCursor]
        if isCursorHidden {
            isCursorHidden = false
            effects.append(.showCursor)
        }
        effects.append(.notifyUI)
        return effects
    }
}
