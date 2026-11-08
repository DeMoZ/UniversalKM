import AppKit
import SwiftUI
import UniversalKMCore

/// The menu bar panel (design D13, D14): status, the arrangement of displays and devices, device
/// controls, and the LocalAIBar-style footer.
struct MenuBarView: View {
    @ObservedObject var app: AppDelegate
    @Bindable var state: AppStateManager
    @ObservedObject var donate: DonateModel
    @State private var showDonate = false
    @State private var selection: UUID?
    @State private var adding = false
    @State private var newKind = DeviceKind.phone
    @State private var newName = ""
    @State private var newHostPeerID: UInt16?

    /// The firmware section of the README in the user's language (Russian or English).
    static var readmeFirmware: URL {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true
            ? URL(string: "https://github.com/DeMoZ/UniversalKM/blob/main/README.ru.md#chameleonultra-сборка-и-прошивка")!
            : URL(string: "https://github.com/DeMoZ/UniversalKM#chameleonultra-build-and-flash")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if showDonate {
                DonateView(model: donate, close: { showDonate = false })
            } else {
                status
                if !state.isCaptureRunning { permissionRow }
                ArrangementView(state: state, selection: $selection)
                deviceControls
                if adding { addForm }
                if let device = selectedDevice { speedControl(device) }
                if let device = state.currentDevice {
                    Button {
                        state.releaseToMac()
                    } label: {
                        Label("Back to the Mac (now: \(device.displayName))", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        // Solid background: the default translucent material lets windows behind show through.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }

    private var selectedDevice: PlacedDevice? {
        state.arrangement.devices.first { $0.id == selection }
    }

    // MARK: Header and status

    private var header: some View {
        HStack(spacing: 8) {
            if state.currentDevice == nil {
                // The app icon from the bundle; a `swift run` build has none and shows the generic one.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: modeIcon)
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            Text("UniversalKM").font(.headline)
            Spacer()
            Text(state.currentDevice.map { String(localized: "Input: \($0.displayName)") } ?? String(localized: "Input: Mac"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeIcon: String {
        guard let device = state.currentDevice else { return "desktopcomputer" }
        return device.kind == .tablet ? "ipad" : "iphone"
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state.transportStatus {
            case .notConnected:
                Label("Chameleon not connected", systemImage: "cable.connector.slash")
                    .foregroundStyle(.orange)
            case .unsupportedFirmware:
                HStack(spacing: 4) {
                    Label("Chameleon firmware has no keyboard and mouse mode", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Link("How to flash", destination: Self.readmeFirmware)
                }
            case .ready:
                ForEach(state.arrangement.devices) { device in
                    HStack(spacing: 6) {
                        Circle().fill(state.isConnected(device) ? Color.green : Color.gray).frame(width: 7, height: 7)
                        Text(device.displayName).fontWeight(.medium)
                        Text(state.isConnected(device) ? String(localized: "— connected") : String(localized: "— waiting for connection…"))
                            .foregroundStyle(.secondary)
                    }
                }
                if state.arrangement.devices.isEmpty {
                    Text("Add a device with the “+” button and pair it with ChameleonUltra in its Bluetooth settings.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.unboundHosts, id: \.self) { peer in
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(.tint)
                        Text("New device connected #\(Int(peer))")
                        Spacer()
                        Button("Add…") {
                            newHostPeerID = peer
                            newName = ""
                            adding = true
                        }
                        .disabled(!state.arrangement.canAddDevice)
                    }
                }
            }
        }
        .font(.callout)
    }

    private var permissionRow: some View {
        HStack(spacing: 6) {
            Label("No Accessibility access", systemImage: "lock")
                .foregroundStyle(.orange)
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .font(.callout)
    }

    // MARK: Device controls

    private var deviceControls: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button {
                    newHostPeerID = nil
                    newName = ""
                    adding = true
                } label: { Image(systemName: "plus") }
                    .disabled(!state.arrangement.canAddDevice || adding)
                    .help(state.arrangement.canAddDevice ? String(localized: "Add a device") : String(localized: "Chameleon holds at most three devices"))
                Button {
                    if let id = selection { state.removeDevice(id) }
                    selection = nil
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Remove the selected device")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            if let device = selectedDevice {
                Button("Rebind") { state.rebind(device.id) }
                    .help("The next device to connect becomes “\(device.displayName)”")
            }
            Spacer()
            Text("Drag a device next to a display edge")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    private var addForm: some View {
        HStack(spacing: 8) {
            Picker("", selection: $newKind) {
                Text("Phone").tag(DeviceKind.phone)
                Text("Tablet").tag(DeviceKind.tablet)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addDevice)
            Button("Add", action: addDevice).keyboardShortcut(.defaultAction)
            Button("Cancel") { adding = false }
        }
        .font(.callout)
    }

    private func addDevice() {
        state.addDevice(kind: newKind, name: newName, hostPeerID: newHostPeerID)
        selection = state.arrangement.devices.last?.id
        adding = false
    }

    private func speedControl(_ device: PlacedDevice) -> some View {
        // Logarithmic: the slider runs over log2(speed), 1× in the middle.
        let binding = Binding<Double>(
            get: { log2(device.pointerSpeed) },
            set: { state.setPointerSpeed(pow(2, $0), of: device.id) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Pointer speed for “\(device.displayName)”")
                Spacer()
                Text(String(format: "%.2g×", device.pointerSpeed)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: -2...2) {
                EmptyView()
            } minimumValueLabel: {
                Text("¼×").font(.caption2)
            } maximumValueLabel: {
                Text("4×").font(.caption2)
            }
            Text(state.isMacMouseAccelerationOn ? String(localized: "Mac mouse acceleration: on") : String(localized: "Mac mouse acceleration: off"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("Return to the Mac through the edge", isOn: Binding(
                get: { device.isReturnThroughEdgeOn },
                set: { state.setReturnThroughEdge($0, of: device.id) }
            ))
            .help("Move the mouse on the device back towards the Mac and past the edge. The hotkey always works.")
            screenFields(device)
        }
        .font(.callout)
    }

    /// Screen size of the device (portrait): points and, if known, pixels; the proportions follow it.
    private func screenFields(_ device: PlacedDevice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Screen, points").frame(width: 96, alignment: .leading)
                SizeField(size: device.screenPoints) { state.setScreen(points: $0, pixels: device.screenPixels, of: device.id) }
            }
            HStack(spacing: 6) {
                Text("Screen, pixels").frame(width: 96, alignment: .leading)
                SizeField(size: device.screenPixels) { state.setScreen(points: device.screenPoints, pixels: $0, of: device.id) }
            }
            Text(String(format: String(localized: "Long side %.0f mm, aspect ratio %.2f:1 — drag the corner in the layout to match the size"),
                        device.effectiveLongSideMillimeters, device.aspectRatio))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showDonate.toggle()
                if showDonate { donate.load() }
            } label: {
                Label("Support", systemImage: "heart.fill")
            }
            .foregroundStyle(.pink)
            Button("Updates") { app.checkForUpdates() }
                .help("Check for updates")
            Spacer()
            if !app.version.isEmpty {
                Text("v\(app.version)").foregroundStyle(.tertiary)
            }
            Button("Quit") { app.quit() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// "1280 × 800": two number fields; empty means unknown.
private struct SizeField: View {
    let size: CGSize?
    let commit: (CGSize?) -> Void
    @State private var width = ""
    @State private var height = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("width", text: $width).frame(width: 64).onSubmit(save)
            Text("×").foregroundStyle(.secondary)
            TextField("height", text: $height).frame(width: 64).onSubmit(save)
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform: load)
        .onChange(of: size) { load() }
    }

    private func load() {
        width = size.map { String(Int($0.width)) } ?? ""
        height = size.map { String(Int($0.height)) } ?? ""
    }

    private func save() {
        if let w = Double(width), let h = Double(height), w > 0, h > 0 {
            commit(CGSize(width: w, height: h))
        } else if width.isEmpty && height.isEmpty {
            commit(nil)
        }
    }
}
