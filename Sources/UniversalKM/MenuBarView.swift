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

    static let readmeFirmware = URL(string: "https://github.com/DeMoZ/UniversalKM#chameleonultra-прошивка-с-режимом-клавиатуры-и-мыши")!

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
                        Label("Вернуть на Mac (сейчас: \(device.name))", systemImage: "arrow.uturn.backward")
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
            Text(state.currentDevice.map { "Ввод: \($0.name)" } ?? "Ввод: Mac")
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
                Label("Chameleon не подключён", systemImage: "cable.connector.slash")
                    .foregroundStyle(.orange)
            case .unsupportedFirmware:
                HStack(spacing: 4) {
                    Label("Прошивка Chameleon без режима клавиатуры и мыши", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Link("Как прошить", destination: Self.readmeFirmware)
                }
            case .ready:
                ForEach(state.arrangement.devices) { device in
                    HStack(spacing: 6) {
                        Circle().fill(state.isConnected(device) ? Color.green : Color.gray).frame(width: 7, height: 7)
                        Text(device.name).fontWeight(.medium)
                        Text(state.isConnected(device) ? "— подключено" : "— ожидание подключения…")
                            .foregroundStyle(.secondary)
                    }
                }
                if state.arrangement.devices.isEmpty {
                    Text("Добавьте устройство кнопкой «+» и сопрягите его с ChameleonUltra в настройках Bluetooth.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.unboundHosts, id: \.self) { peer in
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(.tint)
                        Text("Подключено новое устройство #\(peer)")
                        Spacer()
                        Button("Добавить…") {
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
            Label("Нет доступа «Универсальный доступ»", systemImage: "lock")
                .foregroundStyle(.orange)
            Spacer()
            Button("Открыть настройки") {
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
                    .help(state.arrangement.canAddDevice ? "Добавить устройство" : "Chameleon держит не больше трёх устройств")
                Button {
                    if let id = selection { state.removeDevice(id) }
                    selection = nil
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Удалить выбранное устройство")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            if let device = selectedDevice {
                Button("Перепривязать") { state.rebind(device.id) }
                    .help("Следующее подключившееся устройство станет «\(device.name)»")
            }
            Spacer()
            Text("Перетащите устройство к краю дисплея")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    private var addForm: some View {
        HStack(spacing: 8) {
            Picker("", selection: $newKind) {
                Text("Телефон").tag(DeviceKind.phone)
                Text("Планшет").tag(DeviceKind.tablet)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            TextField("Имя", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addDevice)
            Button("Добавить", action: addDevice).keyboardShortcut(.defaultAction)
            Button("Отмена") { adding = false }
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
                Text("Скорость указателя «\(device.name)»")
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
            Text("Ускорение мыши на Mac: \(state.isMacMouseAccelerationOn ? "вкл." : "выкл.")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showDonate.toggle()
                if showDonate { donate.load() }
            } label: {
                Label("Поддержать", systemImage: "heart.fill")
            }
            .foregroundStyle(.pink)
            Button("Обновления") { app.checkForUpdates() }
                .help("Проверить обновления")
            Spacer()
            if !app.version.isEmpty {
                Text("v\(app.version)").foregroundStyle(.tertiary)
            }
            Button("Выход") { app.quit() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}
