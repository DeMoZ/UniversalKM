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
    @State private var sectionsHeight: CGFloat = 600

    /// The screen with the menu bar minus the header, footer, paddings and the popover arrow.
    private static var maxSectionsHeight: CGFloat {
        let screen = NSScreen.screens.first?.visibleFrame.height ?? 800
        return max(300, screen - 150)
    }

    /// The firmware section of the README in the user's language (Russian or English).
    static var readmeFirmware: URL {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true
            ? URL(string: "https://github.com/DeMoZ/UniversalKM/blob/main/README.ru.md#chameleonultra-сборка-и-прошивка")!
            : URL(string: "https://github.com/DeMoZ/UniversalKM#chameleonultra-build-and-flash")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if showDonate {
                DonateView(model: donate, close: { showDonate = false })
            } else {
                // Never taller than the screen: a popover that does not fit is moved by AppKit, and its
                // arrow leaves the menu bar icon. Past that height the sections scroll.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        if !state.isCaptureRunning { permissionBanner }
                        layoutSection
                        devicesSection
                        if !transferSources.isEmpty { filesSection }
                        if !motionCameraDevices.isEmpty {
                            MotionCameraSection(cameras: app.motionCameras, devices: motionCameraDevices,
                                                open: app.openMotionCamera)
                        }
                        connectionsSection
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sectionsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(sectionsHeight, Self.maxSectionsHeight))
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

    /// An Android device reachable through adb now (add-android-file-browser design D2).
    private func hasFiles(_ device: PlacedDevice) -> Bool {
        device.hostPeerID.flatMap(state.androidStatus.device)?.fileTransport != nil
    }

    /// Android devices on adb now, and those that had the motion camera (their state shows as unknown).
    private var motionCameraDevices: [PlacedDevice] {
        state.arrangement.devices.filter { device in
            hasFiles(device) || device.hostPeerID.map(app.motionCameras.known.contains) == true
        }
    }

    private var selectedDevice: PlacedDevice? {
        state.arrangement.devices.first { $0.id == selection }
    }

    // MARK: Header

    /// The app and where the input goes now; while it is on a device, the way back is right here.
    private var header: some View {
        HStack(spacing: 10) {
            // The app icon from the bundle; a `swift run` build has none and shows the generic one.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("UniversalKM").font(.headline)
            Spacer()
            if let device = state.currentDevice {
                HStack(spacing: 6) {
                    Image(systemName: device.kind == .tablet ? "ipad" : "iphone")
                    Text(device.displayName).lineLimit(1)
                    Button("Back to the Mac") { state.releaseToMac() }
                        .controlSize(.small)
                        .help("The keyboard and mouse go back to the Mac")
                }
                .font(.caption.weight(.medium))
                .padding(.leading, 8).padding(.trailing, 3).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
            } else {
                Label("Input: Mac", systemImage: "desktopcomputer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("No Accessibility access").fontWeight(.medium)
                Text("Without it the keyboard and mouse stay on the Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Layout

    private var layoutSection: some View {
        PanelSection("Layout") {
            Button {
                newHostPeerID = nil
                newName = ""
                adding = true
            } label: { Label("Add Device", systemImage: "plus") }
                .disabled(!state.arrangement.canAddDevice || adding)
                .help(state.arrangement.canAddDevice ? String(localized: "Add a device") : String(localized: "Chameleon holds at most three devices"))
        } content: {
            VStack(spacing: 6) {
                ArrangementView(state: state, selection: $selection)
                Text("Drag a device next to a display edge")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        PanelSection("Devices") {
            EmptyView()
        } content: {
            PanelCard {
                if state.arrangement.devices.isEmpty && state.unboundHosts.isEmpty && !adding {
                    Text("Connect an Android phone or tablet with a cable or over Wi‑Fi, or pair a device with ChameleonUltra, then add it with the “+” button.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                }
                ForEach(Array(state.arrangement.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { PanelDivider() }
                    deviceRow(device)
                    if device.id == selection {
                        speedControl(device)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                }
                ForEach(state.unboundHosts, id: \.self) { peer in
                    if !state.arrangement.devices.isEmpty || peer != state.unboundHosts.first { PanelDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.hostName(peer)).fontWeight(.medium)
                            Text("Connected, not on the layout yet").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add…") {
                            newHostPeerID = peer
                            newName = state.androidStatus.device(peer)?.name ?? ""
                            adding = true
                        }
                        .controlSize(.small)
                        .disabled(!state.arrangement.canAddDevice)
                    }
                    .font(.callout)
                    .padding(10)
                }
                if adding {
                    if !state.arrangement.devices.isEmpty || !state.unboundHosts.isEmpty { PanelDivider() }
                    addForm.padding(10)
                }
            }
        }
    }

    private func deviceRow(_ device: PlacedDevice) -> some View {
        let selected = device.id == selection
        return VStack(alignment: .leading, spacing: 8) {
            deviceHeader(device, selected: selected)
            // Only for a bound device: one waiting for a host has nothing to switch yet.
            if let peer = device.hostPeerID { deviceSwitches(device, peer: peer).padding(.leading, 32) }
        }
        .font(.callout)
        .padding(10)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.08) : .clear)
        .onTapGesture { selection = selected ? nil : device.id }
    }

    /// The switches of a device, one under the other as in System Settings: the keyboard and mouse,
    /// and (Android) the shared clipboard.
    private func deviceSwitches(_ device: PlacedDevice, peer: UInt16) -> some View {
        VStack(spacing: 6) {
            switchRow("Keyboard and mouse", isOn: Binding(
                get: { device.isInputOn },
                set: { state.setInput($0, of: device.id) }
            ))
            .help(device.isInputOn
                  ? String(localized: "Click to stop sending the keyboard and mouse to this device. It stays connected: files and the clipboard keep working.")
                  : String(localized: "Click to send the keyboard and mouse to this device again."))
            if AndroidPeerRegistry.isAndroidPeer(peer) {
                let clipboard = state.clipboard
                switchRow("Shared clipboard", isOn: Binding(
                    get: { clipboard.isEnabled(peer) },
                    set: { clipboard.setEnabled($0, for: peer) }
                ))
                .help("Text copied on the Mac can be pasted on the device, and back. Needs adb: USB debugging or Wi‑Fi.")
            }
        }
    }

    private func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func deviceHeader(_ device: PlacedDevice, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind == .tablet ? "ipad" : "iphone")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName).fontWeight(.medium)
                HStack(spacing: 4) {
                    Circle().fill(state.isConnected(device) ? Color.green : Color.gray.opacity(0.6)).frame(width: 6, height: 6)
                    Text(connectionText(device))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(selected ? 0 : -90))
            Menu {
                Button("Rebind") { state.rebind(device.id) }
                    .help("The next device to connect becomes “\(device.displayName)”")
                Divider()
                Button("Remove from the Layout", role: .destructive) {
                    if selection == device.id { selection = nil }
                    state.removeDevice(device.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for “\(device.displayName)”")
        }
    }

    private func connectionText(_ device: PlacedDevice) -> String {
        switch state.connection(of: device) {
        case .usb: String(localized: "USB")
        case .wifi: String(localized: "Wi‑Fi")
        case .chameleon: String(localized: "Bluetooth via Chameleon")
        case nil: String(localized: "Waiting for connection…")
        }
    }

    // MARK: Files and photos

    private enum TransferSource: Identifiable {
        case android(PlacedDevice)
        case iPhone(String)

        var id: String {
            switch self {
            case .android(let device): device.id.uuidString
            case .iPhone(let name): "iphone:" + name
            }
        }
    }

    /// Everything the Mac can copy files from now, in one place: Android devices on adb, the iPhone on the cable.
    private var transferSources: [TransferSource] {
        state.arrangement.devices.filter(hasFiles).map(TransferSource.android)
            + (app.appleDeviceOnCable.map { [.iPhone($0)] } ?? [])
    }

    private var filesSection: some View {
        PanelSection("Files and Photos") {
            EmptyView()
        } content: {
            PanelCard {
                ForEach(Array(transferSources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { PanelDivider() }
                    switch source {
                    case .android(let device):
                        sourceRow(icon: "folder.fill", title: device.displayName,
                                  subtitle: String(localized: "Files on the device"), button: String(localized: "Files…")) {
                            app.openFiles(device)
                        }
                        .help("Files on “\(device.displayName)”: copy them to and from the Mac")
                    case .iPhone(let name):
                        sourceRow(icon: "photo.on.rectangle.angled", title: name,
                                  subtitle: String(localized: "Photos and videos, on the cable"), button: String(localized: "Photos…")) {
                            app.openPhotos()
                        }
                        .help("Photos and videos of “\(name)” on the cable: copy them to the Mac, delete them from the iPhone")
                    }
                }
            }
        }
    }

    private func sourceRow(icon: String, title: String, subtitle: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
        .font(.callout)
        .padding(10)
    }

    // MARK: Connections

    private var connectionsSection: some View {
        PanelSection("Connections") {
            EmptyView()
        } content: {
            PanelCard {
                AndroidWiFiView(state: state).padding(10)
                if showsChameleon {
                    PanelDivider()
                    chameleonStatus.padding(10)
                }
            }
        }
    }

    private var showsChameleon: Bool {
        state.transportStatus != .notConnected || state.usesChameleon
    }

    /// ChameleonUltra comes second (add-android-usb-transport): an error only when the layout needs it.
    @ViewBuilder
    private var chameleonStatus: some View {
        switch state.transportStatus {
        case .notConnected:
            Label("Chameleon not connected", systemImage: "cable.connector.slash")
                .font(.callout)
                .foregroundStyle(.orange)
        case .unsupportedFirmware:
            HStack(spacing: 4) {
                Label("Chameleon firmware has no keyboard and mouse mode", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Link("How to flash", destination: Self.readmeFirmware)
            }
            .font(.caption)
        case .ready:
            Label("ChameleonUltra connected", systemImage: "dot.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Device settings

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
                Text("Pointer speed")
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
            if let peer = device.hostPeerID, AndroidPeerRegistry.isAndroidPeer(peer) { clipboardControl(peer) }
            screenFields(device)
        }
        .font(.callout)
    }

    /// Shared clipboard status of an Android device; its on/off button is in the device row.
    @ViewBuilder
    private func clipboardControl(_ peer: UInt16) -> some View {
        let clipboard = state.clipboard
        if let text = clipboardText(clipboard.states[peer]) {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if clipboard.isEnabled(peer) && clipboard.isMacReadDenied {
            Text("macOS does not let UniversalKM read the clipboard, so text from the Mac is not sent. Allow it in System Settings → Privacy & Security.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clipboardText(_ state: ClipboardSync.PeerState?) -> String? {
        switch state {
        case .working: String(localized: "Clipboard: shared")
        case .starting: String(localized: "Clipboard: connecting…")
        case .unavailable: String(localized: "Clipboard: needs USB debugging or Wi‑Fi on the device")
        case .failed(let reason): String(localized: "Clipboard: error — \(reason)")
        case .off, nil: nil
        }
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

/// A titled group of the panel: a small header with an optional trailing control, then the content.
struct PanelSection<Trailing: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                trailing
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 2)
            content
        }
    }
}

/// Rows on one rounded card, as in System Settings.
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

/// A row separator inset past the row icon.
struct PanelDivider: View {
    var body: some View { Divider().padding(.leading, 42) }
}
