import AppKit
import SwiftUI
import UniversalKMCore

/// One style table for every visual state of the arrangement (design D14), so states never drift apart.
enum ArrangementStyle {
    // Mac displays: look-only.
    static let displaySaturation = 0.35
    static let displayOpacity = 0.6
    static let displayBorder = Color.secondary.opacity(0.5)
    static let displayCorner = 4.0
    static let menuBarHeight = 4.0
    // Devices: interactive.
    static let deviceBorder = 1.5
    static let deviceSelectedBorder = 3.0
    static let deviceRing = 2.0
    static let deviceRingOpacity = 0.35
    static let deviceHoverOpacity = 0.12
    static let deviceCorner = 6.0
    static let dragScale = 1.04
    static let dragOpacity = 0.85
    static let zoneWidth = 3.0
}

/// The arrangement of Mac displays and devices (design D14). Displays follow the system arrangement
/// and cannot be moved; devices are dragged to any outer edge and snap there.
struct ArrangementView: View {
    @Bindable var state: AppStateManager
    @Binding var selection: UUID?

    @State private var dragging: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var hovered: UUID?
    /// Resizing by the bottom-right corner: the device and its long side in global points while it moves.
    @State private var resizing: (id: UUID, longSide: Double)?
    @State private var wallpapers = WallpaperCache()

    var body: some View {
        GeometryReader { geometry in
            let map = Mapping(state: state, size: geometry.size)
            ZStack(alignment: .topLeading) {
                // Click on empty space: no selection.
                Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil }

                ForEach(state.displays, id: \.uuid) { display in
                    displayView(display, map: map)
                }
                ForEach(state.layouts, id: \.device.id) { layout in
                    ForEach(Array(layout.zones.enumerated()), id: \.offset) { _, zone in
                        zoneView(zone, map: map, dashed: false)
                    }
                }
                if let id = dragging, let preview = dragPreview(id, map: map) {
                    ghostView(preview, map: map)
                }
                ForEach(state.layouts, id: \.device.id) { layout in
                    deviceView(layout, map: map)
                }
            }
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .underPageBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Displays

    private func displayView(_ display: DisplayInfo, map: Mapping) -> some View {
        let rect = map.view(display.frame)
        return ZStack(alignment: .top) {
            Group {
                if let image = wallpapers.thumbnail(for: display.uuid) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.4)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .saturation(ArrangementStyle.displaySaturation)
            .opacity(ArrangementStyle.displayOpacity)
            .clipped()
            if display.isMain {
                Rectangle().fill(Color.white.opacity(0.7)).frame(height: ArrangementStyle.menuBarHeight)
            }
            Text(state.displayNames[display.uuid] ?? String(localized: "Display"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 3)
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: ArrangementStyle.displayCorner))
        .overlay(RoundedRectangle(cornerRadius: ArrangementStyle.displayCorner).stroke(ArrangementStyle.displayBorder, lineWidth: 1))
        .help("Change the display arrangement in macOS Settings → Displays")
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(true)   // only for the tooltip: no gestures, no selection
    }

    // MARK: Zones

    private func zoneView(_ zone: HandoffZone, map: Mapping, dashed: Bool) -> some View {
        Path { path in
            guard let display = state.displays.first(where: { $0.uuid == zone.displayUUID })?.frame else { return }
            for segment in zone.segments {
                let (a, b): (CGPoint, CGPoint) = switch zone.side {
                case .right: (CGPoint(x: display.maxX, y: segment.lowerBound), CGPoint(x: display.maxX, y: segment.upperBound))
                case .left: (CGPoint(x: display.minX, y: segment.lowerBound), CGPoint(x: display.minX, y: segment.upperBound))
                case .top: (CGPoint(x: segment.lowerBound, y: display.minY), CGPoint(x: segment.upperBound, y: display.minY))
                case .bottom: (CGPoint(x: segment.lowerBound, y: display.maxY), CGPoint(x: segment.upperBound, y: display.maxY))
                }
                // Half a line inside the display, so the device border does not cover it.
                let inset = ArrangementStyle.zoneWidth / 2 + 0.5
                let shift: CGSize = switch zone.side {
                case .right: CGSize(width: -inset, height: 0)
                case .left: CGSize(width: inset, height: 0)
                case .top: CGSize(width: 0, height: inset)
                case .bottom: CGSize(width: 0, height: -inset)
                }
                let pa = map.view(a), pb = map.view(b)
                path.move(to: CGPoint(x: pa.x + shift.width, y: pa.y + shift.height))
                path.addLine(to: CGPoint(x: pb.x + shift.width, y: pb.y + shift.height))
            }
        }
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: ArrangementStyle.zoneWidth, lineCap: .round,
                                                     dash: dashed ? [4, 3] : []))
        .allowsHitTesting(false)
    }

    // MARK: Resizing

    private func resizedRect(_ layout: DeviceLayout) -> CGRect {
        guard let resizing, resizing.id == layout.device.id else { return layout.rect }
        let long = max(layout.rect.width, layout.rect.height)
        let factor = resizing.longSide / Double(long)
        return CGRect(origin: layout.rect.origin,
                      size: CGSize(width: layout.rect.width * factor, height: layout.rect.height * factor))
    }

    private func resizeHandle(_ layout: DeviceLayout, map: Mapping) -> some View {
        let long = Double(max(layout.rect.width, layout.rect.height))
        let alongHeight = layout.rect.height >= layout.rect.width
        return Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Color.accentColor))
            .help("Drag to resize")
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // The long side follows the drag along it (the handle is the bottom-right corner).
                        let delta = alongHeight ? value.translation.height : value.translation.width
                        resizing = (layout.device.id, max(30, long + Double(delta) / map.scale))
                    }
                    .onEnded { _ in
                        if let resizing {
                            withAnimation(.easeOut(duration: 0.15)) { state.resize(resizing.id, longSidePoints: resizing.longSide) }
                        }
                        resizing = nil
                    }
            )
    }

    // MARK: Dragging

    private func draggedRect(_ id: UUID, map: Mapping) -> CGRect? {
        guard let layout = state.layouts.first(where: { $0.device.id == id }) else { return nil }
        return layout.rect.offsetBy(dx: dragTranslation.width / map.scale, dy: dragTranslation.height / map.scale)
    }

    private func dragPreview(_ id: UUID, map: Mapping) -> (snap: ArrangementLayout.Snap, device: PlacedDevice)? {
        guard let rect = draggedRect(id, map: map), let snap = state.snap(id, to: rect),
              var device = state.arrangement.devices.first(where: { $0.id == id }) else { return nil }
        device.anchorDisplayUUID = snap.displayUUID
        device.side = snap.side
        device.offset = snap.offset
        return (snap, device)
    }

    private func ghostView(_ preview: (snap: ArrangementLayout.Snap, device: PlacedDevice), map: Mapping) -> some View {
        let rect = map.view(preview.snap.rect)
        let zones = ArrangementLayout.zones(device: preview.device, rect: preview.snap.rect, displays: state.displays)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: ArrangementStyle.deviceCorner)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            ForEach(Array(zones.enumerated()), id: \.offset) { _, zone in
                zoneView(zone, map: map, dashed: true)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Devices

    private func deviceView(_ layout: DeviceLayout, map: Mapping) -> some View {
        let device = layout.device
        let isDragging = dragging == device.id
        let isSelected = selection == device.id
        let rect = map.view(isDragging ? (draggedRect(device.id, map: map) ?? layout.rect) : resizedRect(layout))
        let connected = state.isConnected(device)
        let small = min(rect.width, rect.height)

        return ZStack {
            RoundedRectangle(cornerRadius: ArrangementStyle.deviceCorner)
                .fill(Color(nsColor: .controlBackgroundColor))
            if hovered == device.id {
                RoundedRectangle(cornerRadius: ArrangementStyle.deviceCorner)
                    .fill(Color.accentColor.opacity(ArrangementStyle.deviceHoverOpacity))
            }
            VStack(spacing: 2) {
                Image(systemName: device.kind == .tablet ? "ipad" : "iphone")
                    .font(.system(size: max(9, small * 0.32)))
                    .rotationEffect(.degrees(device.orientation == .landscape ? 90 : 0))
                    .foregroundStyle(.tint)
                if rect.height > 48 {
                    Text(device.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .padding(2)
            // Connection dot.
            Circle()
                .fill(connected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(4)
            // Resize handle (bottom-right corner): keeps the proportions.
            if isSelected && !isDragging {
                resizeHandle(layout, map: map)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(2)
            }
            // Rotate.
            if isSelected && !isDragging {
                Button {
                    state.setOrientation(device.orientation.rotated, of: device.id)
                } label: {
                    Image(systemName: "rotate.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Rotate")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(3)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .overlay(RoundedRectangle(cornerRadius: ArrangementStyle.deviceCorner)
            .stroke(Color.accentColor, lineWidth: isSelected ? ArrangementStyle.deviceSelectedBorder : ArrangementStyle.deviceBorder))
        .overlay(RoundedRectangle(cornerRadius: ArrangementStyle.deviceCorner + 3)
            .stroke(Color.accentColor.opacity(isSelected ? ArrangementStyle.deviceRingOpacity : 0), lineWidth: ArrangementStyle.deviceRing)
            .padding(-3))
        .scaleEffect(isDragging ? ArrangementStyle.dragScale : 1)
        .shadow(color: .black.opacity(isDragging ? 0.3 : 0), radius: isDragging ? 6 : 0, y: isDragging ? 3 : 0)
        .opacity(isDragging ? ArrangementStyle.dragOpacity : 1)
        .help(connected ? String(localized: "\(device.displayName): connected — drag next to a display edge") : String(localized: "\(device.displayName): waiting for connection — drag next to a display edge"))
        .offset(x: rect.minX, y: rect.minY)
        .onHover { inside in
            hovered = inside ? device.id : (hovered == device.id ? nil : hovered)
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { selection = device.id }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragging != device.id {
                        dragging = device.id
                        selection = device.id
                        NSCursor.closedHand.push()
                    }
                    dragTranslation = value.translation
                }
                .onEnded { _ in
                    if let rect = draggedRect(device.id, map: map) {
                        withAnimation(.easeOut(duration: 0.15)) { state.drop(device.id, at: rect) }
                    }
                    dragging = nil
                    dragTranslation = .zero
                    NSCursor.pop()
                }
        )
    }
}

/// Global CG coordinates ↔ view points: displays and devices fitted with one scale.
private struct Mapping {
    let origin: CGPoint
    let scale: Double
    let inset: CGPoint

    @MainActor
    init(state: AppStateManager, size: CGSize) {
        var union = state.displays.reduce(CGRect.null) { $0.union($1.frame) }
        for layout in state.layouts { union = union.union(layout.rect) }
        if union.isNull || union.isEmpty { union = CGRect(x: 0, y: 0, width: 1440, height: 900) }
        let margin = 12.0
        let scale = min((size.width - 2 * margin) / union.width, (size.height - 2 * margin) / union.height)
        self.scale = scale
        origin = union.origin
        inset = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
    }

    func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * scale + inset.x, y: (point.y - origin.y) * scale + inset.y)
    }

    func view(_ rect: CGRect) -> CGRect {
        let o = view(rect.origin)
        return CGRect(x: o.x, y: o.y, width: rect.width * scale, height: rect.height * scale)
    }
}

/// Small, cached wallpaper thumbnails of the displays (design D14); refreshed when Spaces change.
@MainActor
@Observable
final class WallpaperCache {
    // Not observed: filled lazily while the view draws.
    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cache = [:] }
        }
    }

    func thumbnail(for displayUUID: String) -> NSImage? {
        if let image = cache[displayUUID] { return image }
        guard let screen = NSScreen.screens.first(where: { Self.uuid(of: $0) == displayUUID }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)
        else { return nil }
        let size = NSSize(width: 240, height: 240 * image.size.height / max(image.size.width, 1))
        let thumbnail = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        cache[displayUUID] = thumbnail
        return thumbnail
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
