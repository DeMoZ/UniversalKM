import AppKit

/// A small red dot in the corner of the menu bar icon that blinks while a motion camera records
/// (add-android-motion-camera, spec «Значок записи»). It sits on top of whatever image the icon shows (Mac
/// mode or the device input goes to), so the icon itself does not change.
@MainActor
final class RecordingDot: NSView {
    private static let diameter: CGFloat = 6

    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            isHidden = !isRecording
            if isRecording { blink() } else { layer?.removeAllAnimations() }
            superview?.setAccessibilityLabel(isRecording ? String(localized: "UniversalKM: a motion camera is recording") : nil)
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = Self.diameter / 2
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// Bottom right of the button, following its width when the image changes.
    func attach(to button: NSView) {
        let b = button.bounds
        // Low on screen whether or not the button's coordinates are flipped.
        let y = button.isFlipped ? b.maxY - Self.diameter - 2 : b.minY + 2
        frame = NSRect(x: b.maxX - Self.diameter - 1, y: y, width: Self.diameter, height: Self.diameter)
        autoresizingMask = button.isFlipped ? [.minXMargin, .minYMargin] : [.minXMargin, .maxYMargin]
        button.addSubview(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func blink() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.15
        a.duration = 0.6
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(a, forKey: "blink")
    }
}
