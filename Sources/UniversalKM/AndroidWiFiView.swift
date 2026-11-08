import SwiftUI
import UniversalKMCore

/// "Android over Wi‑Fi" in the panel (add-android-usb-transport, spec android-wifi-link): how to get
/// adb, pairing with a code (Wireless debugging, Android 11+), "Enable Wi‑Fi" for a phone on the
/// cable with USB debugging (`adb tcpip`), and what to do after a phone restart.
struct AndroidWiFiView: View {
    @Bindable var state: AppStateManager
    @State private var pairing = false
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false
    @State private var message: Message?

    private struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Android over Wi‑Fi", systemImage: "wifi")
                    .fontWeight(.medium)
                Spacer()
                if state.androidStatus.adbPath != nil && !pairing {
                    Button("Pair with code…") {
                        pairing = true
                        message = nil
                    }
                }
            }
            if state.androidStatus.adbPath == nil {
                Text("Wi‑Fi needs adb from Android platform-tools:")
                    .foregroundStyle(.secondary)
                Text(verbatim: "brew install android-platform-tools")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                if pairing { pairForm }
                ForEach(cableDevices) { device in
                    HStack(spacing: 6) {
                        Text(device.name)
                        Spacer()
                        Button("Enable Wi‑Fi") { enableWiFi(device) }
                            .disabled(busy)
                            .help("Switches adb on the phone to Wi‑Fi, so it keeps working without the cable until the phone restarts")
                    }
                }
                ForEach(restartedDevices) { device in
                    Text("“\(device.name)” was on Wi‑Fi through the cable: after a phone restart, connect the cable and press “Enable Wi‑Fi” again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.androidStatus.adbProblems, id: \.self) { problem in
                    Label(problem.hasSuffix("unauthorized")
                          ? String(localized: "\(problem.components(separatedBy: ":").first ?? problem): allow USB debugging on the phone")
                          : problem,
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let message {
                Text(message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private var pairForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On the phone: Developer options → Wireless debugging → Pair device with pairing code (not the QR code). Enter the IP address with port and the six-digit code it shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("IP address:port", text: $address)
                    .frame(width: 150)
                TextField("Code", text: $code)
                    .frame(width: 80)
                    .onSubmit(pair)
                Button("Pair", action: pair)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || address.isEmpty || code.isEmpty)
                Button("Cancel") { pairing = false }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    /// Phones on the cable with USB debugging and no Wi‑Fi yet.
    private var cableDevices: [AndroidDeviceStatus] {
        state.androidStatus.devices.filter { $0.hasADBOverUSB && !$0.hasWiFi }
    }

    /// Bound phones known from `adb tcpip` that are gone: most likely restarted.
    private var restartedDevices: [AndroidDeviceStatus] {
        let bound = Set(state.arrangement.devices.compactMap(\.hostPeerID))
        return state.androidStatus.devices.filter { $0.tcpipAddress != nil && !$0.isAvailable && bound.contains($0.peerID) }
    }

    private func pair() {
        let address = address.trimmingCharacters(in: .whitespaces)
        let code = code.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty, !code.isEmpty else { return }
        busy = true
        message = nil
        state.android.pair(address: address, code: code) { result in
            Task { @MainActor in
                busy = false
                switch result {
                case .success:
                    pairing = false
                    self.code = ""
                    message = Message(text: String(localized: "Paired. The phone connects by itself while Wireless debugging is on."), isError: false)
                case .failure(let error):
                    message = Message(text: String(localized: "Pairing failed: \(Self.text(error))"), isError: true)
                }
            }
        }
    }

    private func enableWiFi(_ device: AndroidDeviceStatus) {
        busy = true
        message = nil
        state.android.enableWiFi(peerID: device.peerID) { result in
            Task { @MainActor in
                busy = false
                switch result {
                case .success(let address):
                    message = Message(text: String(localized: "Wi‑Fi on: \(address). The cable can be unplugged."), isError: false)
                case .failure(let error):
                    message = Message(text: String(localized: "Could not enable Wi‑Fi: \(Self.text(error))"), isError: true)
                }
            }
        }
    }

    private static func text(_ error: AndroidHIDTransport.ADBError) -> String {
        switch error {
        case .noADB: String(localized: "adb not found")
        case .failed(let detail): detail.isEmpty ? String(localized: "unknown error") : detail
        }
    }
}
