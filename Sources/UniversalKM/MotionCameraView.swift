import AppKit
import SwiftUI
import UniversalKMCore

/// The "Motion Camera" section of the panel (add-android-motion-camera design D8): one short row per Android
/// device with adb or with the camera installed earlier. Everything else is in the camera window.
struct MotionCameraSection: View {
    @ObservedObject var cameras: MotionCameras
    let devices: [PlacedDevice]
    let open: (PlacedDevice) -> Void
    /// "Live View…" right in the row (design D11): the live picture window of the device.
    let openLive: (PlacedDevice) -> Void

    var body: some View {
        PanelSection("Motion Camera") {
            EmptyView()
        } content: {
            PanelCard {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { PanelDivider() }
                    if let peer = device.hostPeerID {
                        row(device, peer)
                    }
                }
            }
        }
        .onAppear { cameras.refreshAll() }
    }

    private func row(_ device: PlacedDevice, _ peer: UInt16) -> some View {
        let camera = cameras.camera(peer)
        let recording = camera.status?.state == .recording
        return HStack(spacing: 10) {
            Image(systemName: recording ? "record.circle.fill" : "video.fill")
                .font(.title3)
                .foregroundStyle(recording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName).fontWeight(.medium)
                Text(MotionCameraWindowView.summary(camera, connected: cameras.isConnected(peer)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            let liveReady = cameras.isConnected(peer) && (camera.installed ?? 0) >= MotionCamera.liveVersion
            Button("Live View…") { openLive(device) }
                .controlSize(.small)
                .disabled(!liveReady)
                .help(liveReady || !cameras.isConnected(peer)
                      ? String(localized: "Watch the camera of “\(device.displayName)” right now")
                      : String(localized: "Update the camera on the device first"))
            Button("Motion Camera…") { open(device) }
                .controlSize(.small)
                .help("Recording on motion for “\(device.displayName)”: on and off, camera, settings, clips")
        }
        .font(.callout)
        .padding(10)
    }
}

/// One camera window per device (design D8), keyed by the Android peer ID. The state is polled every 5 s
/// while at least one of them is open.
@MainActor
final class MotionCameraWindows: NSObject, NSWindowDelegate {
    private let cameras: MotionCameras
    private let openRecordings: (UInt16) -> Void
    private var open: [UInt16: NSWindow] = [:]
    /// Live picture windows (design D11), with their sessions.
    private var live: [UInt16: (window: NSWindow, session: MotionLiveSession)] = [:]

    init(cameras: MotionCameras, openRecordings: @escaping (UInt16) -> Void) {
        self.cameras = cameras
        self.openRecordings = openRecordings
    }

    func show(peer: UInt16, name: String) {
        NSApp.activate()
        if let window = open[peer] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = MotionCameraWindowView(cameras: cameras, peer: peer, name: name,
                                          openRecordings: { [weak self] in self?.openRecordings(peer) },
                                          openLive: { [weak self] in self?.showLive(peer: peer, name: name) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = String(localized: "Motion Camera — \(name)")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("MotionCamera")
        if open.isEmpty { window.center() } else { window.cascadeTopLeft(from: NSPoint(x: window.frame.minX + 24, y: window.frame.maxY - 24)) }
        window.delegate = self
        open[peer] = window
        cameras.startPolling()
        window.makeKeyAndOrderFront(nil)
    }

    /// "Live View…": the picture of the device's camera(s) right now.
    func showLive(peer: UInt16, name: String) {
        NSApp.activate()
        if let w = live[peer]?.window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let session = MotionLiveSession(cameras: cameras, peer: peer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "Live — \(name)")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MotionLiveWindowView(cameras: cameras, session: session))
        window.setFrameAutosaveName("MotionCameraLive")
        if live.isEmpty { window.center() }
        window.delegate = self
        live[peer] = (window, session)
        cameras.startPolling()
        session.start()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let peer = live.first(where: { $0.value.window === window })?.key {
            live[peer]?.session.stop()
            live[peer] = nil
        } else if let peer = open.first(where: { $0.value === window })?.key {
            open[peer] = nil
        } else {
            return
        }
        if open.isEmpty && live.isEmpty { cameras.stopPolling() }
    }
}

struct MotionCameraWindowView: View {
    @ObservedObject var cameras: MotionCameras
    let peer: UInt16
    let name: String
    let openRecordings: () -> Void
    let openLive: () -> Void

    private var camera: MotionCameras.Camera { cameras.camera(peer) }
    private var connected: Bool { cameras.isConnected(peer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if camera.slowInstall {
                Text("The device checks the app before installing it (Google Play Protect). This can take up to two minutes; keep the device unlocked and look for a question on its screen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = camera.error {
                Text(camera.needsConfirmation ? String(localized: "Confirm the install on the device screen, then press Install again.") : error)
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if connected, let status = camera.status {
                Divider()
                cameraChoice(status)
                settings(status.settings)
                Divider()
                HStack {
                    Text("\(status.clips) clips · \(ByteCountFormatter.string(fromByteCount: status.bytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Live View…", action: openLive)
                        .disabled((camera.installed ?? 0) < MotionCamera.liveVersion)
                        .help((camera.installed ?? 0) < MotionCamera.liveVersion
                              ? String(localized: "Update the camera on the device first")
                              : String(localized: "Watch the camera of “\(name)” right now"))
                    Button("Recordings…", action: openRecordings)
                        .help("Open the clips of “\(name)” in the file window")
                }
                Text("Turning it off here or on the device stops recording until it is turned on again, from the Mac or on the device. It stays off after the device restarts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header: state and the switch

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: camera.status?.state == .recording ? "record.circle.fill" : "video.fill")
                .font(.largeTitle)
                .foregroundStyle(camera.status?.state == .recording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Record when something moves").font(.headline)
                Text(Self.summary(camera, connected: connected))
                    .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let busy = camera.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
        } else if connected && camera.checked && camera.installed == nil {
            Button("Install Camera…") { cameras.install(peer) }
                .disabled(cameras.apk == nil)
                .help("Install UniversalKM Motion on “\(name)” over adb")
        } else if connected, let status = camera.status {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("", isOn: Binding(get: { status.on }, set: { cameras.setOn(peer, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Turn the motion camera on or off on “\(name)”")
                if cameras.hasUpdate(peer) {
                    Button("Update Camera") { cameras.install(peer) }.controlSize(.small)
                }
            }
        } else if connected {
            ProgressView().controlSize(.small)
        }
    }

    private var warning: Bool {
        guard connected, let state = camera.status?.state else { return false }
        switch state {
        case .noCamera, .noPermission, .lowSpace, .batteryLow, .stopped, .error: return true
        default: return false
        }
    }

    /// One line for the panel row and the window header.
    static func summary(_ camera: MotionCameras.Camera, connected: Bool) -> String {
        guard connected else {
            return String(localized: "Not connected: state unknown. The camera keeps working on the device.")
        }
        if camera.checked && camera.installed == nil {
            return String(localized: "Records video on the device while something moves")
        }
        guard let status = camera.status else { return String(localized: "Checking…") }
        if status.state == .recording, !status.active.isEmpty, status.settings.camera == .both {
            let which = status.active.map { $0 == "front" ? String(localized: "Front") : String(localized: "Rear") }
            return String(localized: "Recording: \(which.joined(separator: ", "))")
        }
        return text(status.state)
    }

    static func text(_ state: MotionStatus.State) -> String {
        switch state {
        case .off: String(localized: "Off")
        case .starting: String(localized: "Starting…")
        case .watching: String(localized: "Waiting for motion")
        case .recording: String(localized: "Recording")
        case .noCamera: String(localized: "The camera is busy or blocked")
        case .noPermission: String(localized: "No access to the camera")
        case .lowSpace: String(localized: "Not enough space: new clips are not recorded")
        case .batteryLow: String(localized: "Battery low: connect a charger")
        case .stopped: String(localized: "Stopped: open UniversalKM Motion on the device")
        case .error: String(localized: "Could not start: tap the notification on the device")
        case .unknown: String(localized: "State unknown")
        }
    }

    // MARK: Camera and settings

    private func cameraChoice(_ status: MotionStatus) -> some View {
        let s = status.settings
        return VStack(alignment: .leading, spacing: 6) {
            // Own radio buttons: a Picker cannot disable one of its items ("Both" where the device cannot).
            HStack(spacing: 16) {
                Text("Camera")
                ForEach(MotionSettings.Camera.allCases, id: \.self) { option in
                    let selected = s.camera == option
                    Button {
                        var n = s
                        n.camera = option
                        cameras.apply(peer, n)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text(Self.cameraName(option))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(option == .both && !status.bothSupported)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if !status.bothSupported {
                Text(s.camera == .both
                     ? String(localized: "This device cannot record with both cameras at once, so it records with the rear one.")
                     : String(localized: "“Both” is not available: this device cannot record with both cameras at once."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if s.camera == .both {
                Text("Each camera records its own clips (“rear” and “front” in the name), at 720p.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func cameraName(_ c: MotionSettings.Camera) -> String {
        switch c {
        case .back: String(localized: "Rear")
        case .front: String(localized: "Front")
        case .both: String(localized: "Both")
        }
    }

    private func settings(_ s: MotionSettings) -> some View {
        let set: (MotionSettings) -> Void = { cameras.apply(peer, $0) }
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Sensitivity").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.sensitivity }, set: { var n = s; n.sensitivity = $0; set(n) })) {
                    Text("Low").tag(MotionSettings.Sensitivity.low)
                    Text("Medium").tag(MotionSettings.Sensitivity.mid)
                    Text("High").tag(MotionSettings.Sensitivity.high)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Stop after").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.stopSeconds }, set: { var n = s; n.stopSeconds = $0; set(n) })) {
                    ForEach(Array(Set([5, 10, 20, 30, 60, s.stopSeconds])).sorted(), id: \.self) { sec in
                        Text("\(sec) s without motion").tag(sec)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                Text("Quality").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.quality }, set: { var n = s; n.quality = $0; set(n) })) {
                    Text(verbatim: "720p").tag(MotionSettings.Quality.hd)
                    Text(verbatim: "1080p").tag(MotionSettings.Quality.fullHD)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(s.camera == .both)
            }
            GridRow {
                Text("Keep up to").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.limitMB }, set: { var n = s; n.limitMB = $0; set(n) })) {
                    ForEach(Array(Set(MotionSettings.limitChoicesMB + [s.limitMB])).sorted(), id: \.self) { mb in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(mb) * 1024 * 1024, countStyle: .memory)).tag(mb)
                    }
                }
                .labelsHidden()
            }
        }
    }
}
