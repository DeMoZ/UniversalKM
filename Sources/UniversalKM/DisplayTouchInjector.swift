import CoreGraphics
import Foundation
import os
import UniversalKMCore

/// Mouse events on the virtual display for the touches on the device (openspec/changes/add-android-second-display,
/// design D6). The events go in below the app's own event tap (`cgSessionEventTap`), so the keyboard and mouse
/// handoff never sees them. The Mac's cursor is on the display only while a finger touches it: when the
/// finger lifts, it goes back to where it was.
@MainActor
final class DisplayTouchInjector {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private var saved: CGPoint?
    private var restore: Task<Void, Never>?
    private var lastDown: (time: TimeInterval, point: CGPoint, count: Int64)?
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "display")

    /// `origin` is the top left of the virtual display in global points.
    func inject(_ events: [SecondDisplay.MouseEvent], origin: CGPoint) {
        for event in events { post(event, origin: origin) }
    }

    func finish() {
        restore?.cancel()
        restoreCursor()
    }

    private func point(_ x: Int, _ y: Int, _ origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y))
    }

    private func take(_ p: CGPoint) {
        restore?.cancel()
        if saved == nil { saved = CGEvent(source: nil)?.location }
        CGWarpMouseCursorPosition(p)
    }

    private func scheduleRestore() {
        restore?.cancel()
        restore = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.restoreCursor()
        }
    }

    private func restoreCursor() {
        guard let saved else { return }
        CGWarpMouseCursorPosition(saved)
        self.saved = nil
    }

    private func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cgSessionEventTap)
    }

    private func post(_ event: SecondDisplay.MouseEvent, origin: CGPoint) {
        switch event {
        case let .leftDown(x, y):
            let p = point(x, y, origin)
            take(p)
            // A second touch near the first one soon after is a double click.
            let now = ProcessInfo.processInfo.systemUptime
            var count: Int64 = 1
            if let last = lastDown, now - last.time < 0.4, hypot(p.x - last.point.x, p.y - last.point.y) < 24 {
                count = last.count + 1
            }
            lastDown = (now, p, count)
            mouse(.leftMouseDown, p, clicks: count)
        case let .leftDragged(x, y):
            let p = point(x, y, origin)
            take(p)
            mouse(.leftMouseDragged, p)
        case let .leftUp(x, y):
            let p = point(x, y, origin)
            mouse(.leftMouseUp, p, clicks: lastDown?.count ?? 1)
            scheduleRestore()
        case let .rightClick(x, y):
            let p = point(x, y, origin)
            take(p)
            mouse(.rightMouseDown, p, button: .right)
            mouse(.rightMouseUp, p, button: .right)
            scheduleRestore()
        case let .scroll(x, y, dx, dy):
            let p = point(x, y, origin)
            take(p)
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy),
                               wheel2: Int32(dx), wheel3: 0) {
                e.location = p
                e.post(tap: .cgSessionEventTap)
            }
            scheduleRestore()
        }
    }
}
