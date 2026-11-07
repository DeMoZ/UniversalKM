import Foundation

/// Collects mouse motion and scroll while the BLE channel is busy and turns it into
/// reports without losing movement (design D5):
/// - motion and scroll are summed as `Double`; a report carries the integer part,
///   the fractional part and anything above the field range stay for the next report;
/// - a button change starts a new segment, so motion made before the change is sent
///   with the old buttons and the click does not move.
public struct MouseAccumulator: Sendable {
    struct Segment: Sendable {
        var buttons: MouseButtons
        var dx = 0.0
        var dy = 0.0
        var wheel = 0.0
        var pan = 0.0
    }

    private var segments: [Segment]
    public private(set) var lastSentButtons: MouseButtons = []

    public init() {
        segments = [Segment(buttons: [])]
    }

    /// Buttons that are pressed after all queued changes.
    public var currentButtons: MouseButtons { segments[segments.count - 1].buttons }

    public mutating func addMotion(dx: Double, dy: Double) {
        segments[segments.count - 1].dx += dx
        segments[segments.count - 1].dy += dy
    }

    public mutating func addScroll(wheel: Double, pan: Double) {
        segments[segments.count - 1].wheel += wheel
        segments[segments.count - 1].pan += pan
    }

    public mutating func setButtons(_ buttons: MouseButtons) {
        guard buttons != currentButtons else { return }
        segments.append(Segment(buttons: buttons))
    }

    /// True when `nextReport()` would return a report.
    public var hasPendingReport: Bool {
        var copy = self
        return copy.nextReport() != nil
    }

    /// Takes the next report to send, or nil when nothing is pending.
    public mutating func nextReport() -> MouseReport? {
        while true {
            var segment = segments[0]
            let ix = Self.whole(segment.dx, in: MouseReport.axisRange)
            let iy = Self.whole(segment.dy, in: MouseReport.axisRange)
            let iw = Self.whole(segment.wheel, in: MouseReport.scrollRange)
            let ip = Self.whole(segment.pan, in: MouseReport.scrollRange)
            let hasMotion = ix != 0 || iy != 0 || iw != 0 || ip != 0

            if !hasMotion && segment.buttons == lastSentButtons {
                guard segments.count > 1 else { return nil }
                // Segment is used up: carry its fractions into the next one.
                segments.removeFirst()
                segments[0].dx += segment.dx
                segments[0].dy += segment.dy
                segments[0].wheel += segment.wheel
                segments[0].pan += segment.pan
                continue
            }

            segment.dx -= Double(ix)
            segment.dy -= Double(iy)
            segment.wheel -= Double(iw)
            segment.pan -= Double(ip)
            segments[0] = segment
            lastSentButtons = segment.buttons
            return MouseReport(buttons: segment.buttons, dx: ix, dy: iy, wheel: iw, pan: ip)
        }
    }

    /// Drops everything pending and forgets pressed buttons (used with a neutral report).
    public mutating func reset() {
        segments = [Segment(buttons: [])]
        lastSentButtons = []
    }

    /// Integer part toward zero, clamped to the field range. A tiny epsilon keeps
    /// sums like 0.1 + 0.2 + … from landing just below a whole number.
    static func whole(_ value: Double, in range: ClosedRange<Int>) -> Int {
        let epsilon = 1e-9
        let adjusted = value >= 0 ? value + epsilon : value - epsilon
        guard adjusted.isFinite else { return 0 }
        let truncated = adjusted.rounded(.towardZero)
            .clamped(to: Double(range.lowerBound)...Double(range.upperBound))
        return Int(truncated)
    }
}
