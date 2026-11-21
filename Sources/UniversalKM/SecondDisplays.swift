import AppKit
import SwiftUI
import UniversalKMCore

/// The devices that are second monitors right now (openspec/changes/add-android-second-display, design D8): the
/// button in the device row turns one on and off. One monitor at a time. Keyed by the Android peer ID.
@MainActor
final class SecondDisplays: ObservableObject {
    enum State: Equatable {
        case starting(String)
        case running
    }

    @Published private(set) var states: [UInt16: State] = [:]
    /// Why the last monitor stopped (shown in the row until the next start).
    @Published private(set) var errors: [UInt16: String] = [:]
    private var sessions: [UInt16: SecondDisplaySession] = [:]
    private let cameras: MotionCameras
    private let layout: AppStateManager

    init(cameras: MotionCameras, state: AppStateManager) {
        self.cameras = cameras
        self.layout = state
        // A monitor follows its rectangle in the layout (design D9).
        state.onLayoutChange = { [weak self] in
            for session in self?.sessions.values.map({ $0 }) ?? [] { session.layoutChanged() }
        }
    }

    func isOn(_ peer: UInt16) -> Bool { sessions[peer] != nil }

    /// The row's second line while the monitor is starting, running or has just failed.
    func status(_ peer: UInt16) -> String? {
        switch states[peer] {
        case let .starting(text): return text
        case .running: return String(localized: "Monitor on")
        case nil: return errors[peer]
        }
    }

    /// The device's mode (design D8): `true` is "Monitor", `false` is "Keyboard and mouse".
    func set(_ on: Bool, peer: UInt16, name: String) {
        if !on {
            sessions[peer]?.stop()
            return
        }
        guard sessions[peer] == nil else { return }
        guard sessions.isEmpty else {
            errors[peer] = String(localized: "Turn the other monitor off first.")
            return
        }
        guard let adb = cameras.adb, let transport = cameras.transport(peer) else {
            errors[peer] = String(localized: "The device is not connected through adb.")
            return
        }
        errors[peer] = nil
        let layout = self.layout
        let host = SecondDisplaySession.Host(
            rect: { layout.layout(forPeer: peer)?.rect },
            deviceScreen: { width, height in layout.deviceReportedScreen(peer: peer, width: width, height: height) })
        let session = SecondDisplaySession(adb: adb, transport: transport, name: name, serial: UInt32(peer) + 1, host: host)
        sessions[peer] = session
        layout.setMonitor(true, peer: peer)
        states[peer] = .starting(String(localized: "Starting…"))
        session.onPhase = { [weak self] phase in
            switch phase {
            case let .starting(text): self?.states[peer] = .starting(text)
            case .running: self?.states[peer] = .running
            }
        }
        session.onEnd = { [weak self] message, needsScreenRecording in
            guard let self else { return }
            self.sessions[peer] = nil
            self.layout.setMonitor(false, peer: peer)
            self.states[peer] = nil
            self.errors[peer] = message
            if needsScreenRecording { Self.askForScreenRecording() }
        }
        session.start()
    }

    /// Switches every monitor off (the app quits).
    func stopAll() {
        for session in sessions.values { session.stop() }
    }

    private static func askForScreenRecording() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Screen Recording is needed")
        alert.informativeText = String(localized: "UniversalKM takes the picture of the virtual display and sends it to the device. Allow it in System Settings → Privacy & Security → Screen Recording, then turn the monitor on again.")
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
