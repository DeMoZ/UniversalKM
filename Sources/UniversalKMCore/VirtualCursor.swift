import CoreGraphics
import Foundation

/// Estimate of the pointer position on the device, for returning to the Mac by moving back through the
/// edge (design D11a). The host accelerates the pointer itself and never reports where it is, so this
/// adds up the motion sent and clamps it to the device screen, the way the real pointer stops at the
/// edges: pushing against an edge re-aligns the estimate.
public struct VirtualCursor: Equatable, Sendable {
    /// Outward push beyond the Mac-facing edge that returns input to the Mac.
    public static let returnPush = 40.0

    /// Typical screens (points, portrait) when the user has not entered one.
    public static func defaultScreen(for kind: DeviceKind) -> CGSize {
        kind == .phone ? CGSize(width: 393, height: 852) : CGSize(width: 820, height: 1180)
    }

    /// Screen in device points, in the current orientation.
    public let screen: CGSize
    /// The display side the device is on: input came in through it and returns through it.
    public let side: DisplaySide
    public private(set) var x: Double
    public private(set) var y: Double
    private var push = 0.0

    /// `fraction`: where along the zone the cursor crossed (0…1, from the zone's top or left end).
    public init(screen: CGSize, side: DisplaySide, entryFraction fraction: Double) {
        self.screen = screen
        self.side = side
        let f = min(max(fraction, 0), 1)
        let w = Double(screen.width), h = Double(screen.height)
        switch side {
        case .right: (x, y) = (0, f * h)        // the device is right of the Mac: enter at its left edge
        case .left: (x, y) = (w, f * h)
        case .bottom: (x, y) = (f * w, 0)       // below the Mac: enter at its top edge
        case .top: (x, y) = (f * w, h)
        }
    }

    /// Adds a motion sent to the device. True when the cursor was pushed back through the Mac-facing edge.
    public mutating func move(dx: Double, dy: Double) -> Bool {
        let w = Double(screen.width), h = Double(screen.height)
        let nx = x + dx, ny = y + dy
        let overshoot: Double = switch side {
        case .right: -nx            // returns through x = 0
        case .left: nx - w
        case .bottom: -ny
        case .top: ny - h
        }
        x = min(max(nx, 0), w)
        y = min(max(ny, 0), h)
        if overshoot > 0 {
            push += overshoot
        } else {
            push = 0
        }
        return push >= Self.returnPush
    }

    /// Where along the Mac-facing edge the cursor is (0…1), to put the Mac cursor at the same place.
    public var exitFraction: Double {
        switch side {
        case .right, .left: screen.height > 0 ? y / Double(screen.height) : 0.5
        case .top, .bottom: screen.width > 0 ? x / Double(screen.width) : 0.5
        }
    }
}
