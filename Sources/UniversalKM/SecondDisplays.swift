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

    init(cameras: MotionCameras) {
        self.cameras = cameras
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

    func toggle(peer: UInt16, name: String) {
        if let session = sessions[peer] {
            session.stop()
            return
        }
        guard sessions.isEmpty else {
            errors[peer] = String(localized: "Turn the other monitor off first.")
            return
        }
        guard let adb = cameras.adb, let transport = cameras.transport(peer) else {
            errors[peer] = String(localized: "The device is not connected through adb.")
            return
        }
        errors[peer] = nil
        let session = SecondDisplaySession(adb: adb, transport: transport, name: name, serial: UInt32(peer) + 1)
        sessions[peer] = session
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
