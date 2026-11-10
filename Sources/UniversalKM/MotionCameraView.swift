import SwiftUI
import UniversalKMCore

/// The "Motion Camera" section of the panel (add-android-motion-camera design D8): one card per Android
/// device with adb or with the camera installed earlier.
struct MotionCameraSection: View {
    @ObservedObject var cameras: MotionCameras
    let devices: [PlacedDevice]
    let openRecordings: (PlacedDevice) -> Void

    var body: some View {
        PanelSection("Motion Camera") {
            EmptyView()
        } content: {
            PanelCard {
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { PanelDivider() }
                    if let peer = device.hostPeerID {
                        MotionCameraRow(cameras: cameras, camera: cameras.camera(peer), peer: peer, device: device,
                                        openRecordings: { openRecordings(device) })
                    }
                }
            }
        }
        .onAppear { cameras.startPolling() }
        .onDisappear { cameras.stopPolling() }
    }
}

private struct MotionCameraRow: View {
    @ObservedObject var cameras: MotionCameras
    let camera: MotionCameras.Camera
    let peer: UInt16
    let device: PlacedDevice
    let openRecordings: () -> Void
    @State private var showSettings = false

    private var connected: Bool { cameras.isConnected(peer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: camera.status?.state == .recording ? "record.circle.fill" : "video.fill")
                    .font(.title3)
                    .foregroundStyle(camera.status?.state == .recording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(subtitleIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                trailing
            }
            if let error = camera.error {
                Text(camera.needsConfirmation ? String(localized: "Confirm the install on the device screen, then press Install again.") : error)
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 32)
            }
            if connected, let status = camera.status {
                HStack {
                    Text("\(status.clips) clips · \(ByteCountFormatter.string(fromByteCount: status.bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(showSettings ? String(localized: "Hide Settings") : String(localized: "Settings…")) {
                        showSettings.toggle()
                    }
                    .controlSize(.small)
                    Button("Recordings…", action: openRecordings)
                        .controlSize(.small)
                        .help("Open the clips of “\(device.displayName)” in the file window")
                }
                .padding(.leading, 32)
                if showSettings { settings(status.settings).padding(.leading, 32) }
            }
        }
        .font(.callout)
        .padding(10)
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
                .controlSize(.small)
                .disabled(cameras.apk == nil)
                .help("Install UniversalKM Motion on “\(device.displayName)” over adb")
        } else if connected, let status = camera.status {
            HStack(spacing: 8) {
                if cameras.hasUpdate(peer) {
                    Button("Update Camera") { cameras.install(peer) }.controlSize(.small)
                }
                Toggle("", isOn: Binding(get: { status.on }, set: { cameras.setOn(peer, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("Turn the motion camera on or off on “\(device.displayName)”")
            }
        } else if connected {
            ProgressView().controlSize(.small)
        }
    }

    private var subtitle: String {
        guard connected else {
            return String(localized: "Not connected: state unknown. The camera keeps working on the device.")
        }
        if camera.checked && camera.installed == nil {
            return String(localized: "Records video on the device while something moves")
        }
        guard let status = camera.status else { return String(localized: "Checking…") }
        return Self.text(status.state)
    }

    private var subtitleIsWarning: Bool {
        guard connected, let state = camera.status?.state else { return false }
        switch state {
        case .noCamera, .noPermission, .lowSpace, .batteryLow, .stopped, .error: return true
        default: return false
        }
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

    private func settings(_ s: MotionSettings) -> some View {
        let set: (MotionSettings) -> Void = { cameras.apply(peer, $0) }
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
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
                Text("Camera").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.camera }, set: { var n = s; n.camera = $0; set(n) })) {
                    Text("Rear").tag(MotionSettings.Camera.back)
                    Text("Front").tag(MotionSettings.Camera.front)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Quality").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { s.quality }, set: { var n = s; n.quality = $0; set(n) })) {
                    Text(verbatim: "720p").tag(MotionSettings.Quality.hd)
                    Text(verbatim: "1080p").tag(MotionSettings.Quality.fullHD)
                }
                .pickerStyle(.segmented).labelsHidden()
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
        .font(.caption)
        .controlSize(.small)
    }
}
