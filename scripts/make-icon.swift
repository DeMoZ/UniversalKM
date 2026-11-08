#!/usr/bin/env swift
// Draws the app icon and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// The picture: a Mac display on the left, a phone on the right, and the mouse cursor
// crossing from the display's edge to the phone. The menu bar icon (StatusIcon.swift)
// is a one-colour version of the same picture.
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Classic arrow cursor, tip at `tip`, pointing up-left, `h` tall (CG coordinates, y up).
func cursorPath(tip: CGPoint, h: CGFloat) -> CGPath {
    let s = h / 17
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -15.5), (3.6, -12.2), (6.2, -17.8), (8.6, -16.7),
                                     (6.1, -11.2), (11, -11.2)]
    let p = CGMutablePath()
    for (i, (x, y)) in pts.enumerated() {
        let pt = CGPoint(x: tip.x + x * s, y: tip.y + y * s)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

/// Draws the icon into a 1024×1024 context (y up).
func drawIcon(_ ctx: CGContext) {
    // Background: macOS icon grid, 824 pt squircle-ish rounded square with a soft drop shadow.
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = rounded(bg, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(bgPath)
    ctx.setFillColor(rgb(0x3B47D6))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, bgPath, [rgb(0x6A7BFF), rgb(0x3A3FC8), rgb(0x24207F)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Soft light at the top.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: 900), endRadius: 620, options: [])
    ctx.restoreGState()

    let frame = [rgb(0xFFFFFF), rgb(0xD9DEF5)]
    let screen = [rgb(0x1C2050), rgb(0x2E3A8C)]

    // Display.
    let display = CGRect(x: 168, y: 392, width: 480, height: 330)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x0A0A40, 0.45))
    // Stand: neck and foot.
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 370, y: 392))
    neck.addLine(to: CGPoint(x: 446, y: 392))
    neck.addLine(to: CGPoint(x: 462, y: 318))
    neck.addLine(to: CGPoint(x: 354, y: 318))
    neck.closeSubpath()
    ctx.setFillColor(rgb(0xC9CFEE))
    ctx.addPath(neck)
    ctx.fillPath()
    ctx.addPath(rounded(CGRect(x: 300, y: 296, width: 216, height: 30), 15))
    ctx.fillPath()
    ctx.addPath(rounded(display, 34))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, rounded(display, 34), frame, from: CGPoint(x: 0, y: display.maxY), to: CGPoint(x: 0, y: display.minY))
    let displayScreen = display.insetBy(dx: 22, dy: 22)
    linear(ctx, rounded(displayScreen, 14), screen,
           from: CGPoint(x: 0, y: displayScreen.maxY), to: CGPoint(x: 0, y: displayScreen.minY))

    // Phone.
    let phone = CGRect(x: 690, y: 286, width: 196, height: 380)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x0A0A40, 0.45))
    ctx.addPath(rounded(phone, 40))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, rounded(phone, 40), frame, from: CGPoint(x: 0, y: phone.maxY), to: CGPoint(x: 0, y: phone.minY))
    let phoneScreen = phone.insetBy(dx: 16, dy: 16)
    linear(ctx, rounded(phoneScreen, 26), screen,
           from: CGPoint(x: 0, y: phoneScreen.maxY), to: CGPoint(x: 0, y: phoneScreen.minY))
    // Dynamic island.
    ctx.addPath(rounded(CGRect(x: phone.midX - 30, y: phoneScreen.maxY - 30, width: 60, height: 16), 8))
    ctx.setFillColor(rgb(0x0B0D26))
    ctx.fillPath()

    // Path of the cursor: dotted arc from the display screen over the gap to the phone.
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(14)
    ctx.setLineDash(phase: 0, lengths: [0.1, 30])
    ctx.setStrokeColor(rgb(0x8FE3FF))
    let trail = CGMutablePath()
    trail.move(to: CGPoint(x: 380, y: 540))
    trail.addQuadCurve(to: CGPoint(x: 738, y: 556), control: CGPoint(x: 580, y: 720))
    ctx.addPath(trail)
    ctx.strokePath()
    ctx.restoreGState()

    // Cursor on the phone screen.
    let cursor = cursorPath(tip: CGPoint(x: 752, y: 546), h: 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.5))
    ctx.addPath(cursor)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(cursor)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(9)
    ctx.setStrokeColor(rgb(0x111433))
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview = ProcessInfo.processInfo.environment["PREVIEW"] {
    try png(size: 1024).write(to: URL(fileURLWithPath: preview))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
