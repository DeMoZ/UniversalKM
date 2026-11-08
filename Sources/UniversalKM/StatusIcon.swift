import AppKit

/// The menu bar icon: a one-colour version of the app icon (scripts/make-icon.swift) — a display,
/// a phone, and the cursor that has crossed onto the phone. Drawn in code as a template image, so it
/// stays sharp at any scale and macOS tints it for light, dark and highlighted menu bars.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            // Display: outlined screen, filled neck and foot.
            ctx.setLineWidth(1.5)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 1.25, y: 2.75, width: 14, height: 9.5),
                               cornerWidth: 1.75, cornerHeight: 1.75, transform: nil))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 7, y: 13))
            ctx.addLine(to: CGPoint(x: 9.5, y: 13))
            ctx.addLine(to: CGPoint(x: 10, y: 15))
            ctx.addLine(to: CGPoint(x: 6.5, y: 15))
            ctx.closePath()
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: CGRect(x: 4.75, y: 14.75, width: 7, height: 1.5),
                               cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
            ctx.fillPath()

            // Phone: outlined.
            ctx.addPath(CGPath(roundedRect: CGRect(x: 17.25, y: 4.75, width: 6, height: 11.5),
                               cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.strokePath()

            // Cursor on the phone, with a cut-out border so it reads over the outline.
            let cursor = cursorPath(tip: CGPoint(x: 19, y: 7.75), height: 7)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(2)
            ctx.addPath(cursor)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(cursor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "UniversalKM"
        return image
    }

    /// Arrow cursor, tip at `tip`, pointing up-left (flipped coordinates, y down).
    private static func cursorPath(tip: CGPoint, height: CGFloat) -> CGPath {
        let s = height / 17
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 15.5), (3.6, 12.2), (6.2, 17.8), (8.6, 16.7),
                                            (6.1, 11.2), (11, 11.2)]
        let path = CGMutablePath()
        for (i, (x, y)) in points.enumerated() {
            let p = CGPoint(x: tip.x + x * s, y: tip.y + y * s)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}
