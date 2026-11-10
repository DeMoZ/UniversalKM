import Foundation
import os
import UniversalKMCore

/// The motion camera app on each Android device with adb (openspec/changes/add-android-motion-camera, design
/// D5, D6, D8): installing it, switching it on and off, its settings and its state, polled while the panel is
/// open. Keyed by the Android peer ID, like the layout.
@MainActor
final class MotionCameras: ObservableObject {
    struct Camera: Equatable {
        /// versionCode on the device; nil = not installed (when `checked`).
        var installed: Int?
        var checked = false
        /// nil = unknown (no adb now, or not read yet).
        var status: MotionStatus?
        /// "Installing…" while a long action runs.
        var busy: String?
        var error: String?
        var needsConfirmation = false
    }

    @Published private(set) var cameras: [UInt16: Camera] = [:]
    /// Devices that had the camera installed: their row stays when adb is gone ("state unknown").
    @Published private(set) var known: Set<UInt16>

    private var transports: [UInt16: String] = [:]
    private var inFlight: Set<UInt16> = []
    private var timer: Timer?
    private let adb = ADBClient.find().map { ADBClient(url: $0) }
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "motion")
    private static let knownKey = "motionCameraPeers"

    /// The APK and its versionCode shipped in the app (scripts/build-motion-apk.sh).
    let apk: URL?
    let bundledVersion: Int

    init() {
        known = Set((UserDefaults.standard.array(forKey: Self.knownKey) as? [Int] ?? []).map { UInt16($0) })
        let resources = Bundle.main.url(forResource: "ukm-motion", withExtension: "apk") != nil
            ? Bundle.main.resourceURL
            // `swift run`: the repository's Resources folder.
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources")
        let apk = resources?.appendingPathComponent("ukm-motion.apk")
        self.apk = apk.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let version = resources.flatMap { try? String(contentsOf: $0.appendingPathComponent("ukm-motion.version"), encoding: .utf8) }
        bundledVersion = Int(version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    func camera(_ peer: UInt16) -> Camera { cameras[peer] ?? Camera() }
    func isConnected(_ peer: UInt16) -> Bool { transports[peer] != nil }
    func hasUpdate(_ peer: UInt16) -> Bool { (camera(peer).installed ?? Int.max) < bundledVersion }

    // MARK: Following the Android status

    /// New adb transports are read at once; a device without adb keeps its row with an unknown state.
    func update(_ status: AndroidStatus) {
        var next: [UInt16: String] = [:]
        for device in status.devices { if let t = device.fileTransport { next[device.peerID] = t } }
        let previous = transports
        transports = next
        for peer in previous.keys where next[peer] == nil { cameras[peer]?.status = nil }
        for (peer, t) in next where previous[peer] != t { refresh(peer) }
    }

    /// While the panel shows the camera section: the state every 5 s (spec «Состояние и настройки в панели»).
    func startPolling() {
        guard timer == nil else { return }
        refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshAll() {
        for peer in transports.keys { refresh(peer) }
    }

    func refresh(_ peer: UInt16) {
        guard let t = transports[peer], !inFlight.contains(peer) else { return }
        inFlight.insert(peer)
        shell(t, MotionCamera.versionCommand) { [weak self] result in
            guard let self else { return }
            guard self.transports[peer] == t else { self.inFlight.remove(peer); return }
            let installed = result.ok ? MotionCamera.installedVersion(result.output) : self.camera(peer).installed
            var c = self.camera(peer)
            c.installed = installed
            c.checked = result.ok || c.checked
            if installed == nil {
                c.status = nil
                self.cameras[peer] = c
                self.inFlight.remove(peer)
                return
            }
            self.remember(peer)
            self.cameras[peer] = c
            self.shell(t, MotionCamera.statusCommand) { [weak self] result in
                guard let self else { return }
                self.inFlight.remove(peer)
                guard self.transports[peer] == t else { return }
                self.cameras[peer, default: Camera()].status = MotionStatus.parse(result.output)
            }
        }
    }

    private func remember(_ peer: UInt16) {
        guard !known.contains(peer) else { return }
        known.insert(peer)
        UserDefaults.standard.set(known.map { Int($0) }, forKey: Self.knownKey)
    }

    // MARK: Actions

    /// `adb install -r -g`, then the permissions adb can give (design D6).
    func install(_ peer: UInt16) {
        guard let t = transports[peer], let adb, let apk else { return }
        var c = camera(peer)
        c.busy = String(localized: "Installing…")
        c.error = nil
        c.needsConfirmation = false
        cameras[peer] = c
        log.info("motion: install on \(t, privacy: .public)")
        adb.run(["-s", t, "install", "-r", "-g", apk.path], timeout: 180, on: .main) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let text = result.output + result.error
                if result.ok, text.contains("Success") {
                    self.runAll(t, MotionCamera.permissionCommands) {
                        self.cameras[peer]?.busy = nil
                        self.remember(peer)
                        self.refresh(peer)
                    }
                } else {
                    var c = self.camera(peer)
                    c.busy = nil
                    c.needsConfirmation = MotionCamera.needsConfirmationOnDevice(text)
                    let line = text.split(whereSeparator: \.isNewline).last { $0.contains("Failure") || $0.contains("error") }
                    c.error = line.map(String.init) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.cameras[peer] = c
                    self.log.error("motion: install failed: \(c.error ?? "", privacy: .public)")
                }
            }
        }
    }

    func setOn(_ peer: UInt16, _ on: Bool) {
        guard let t = transports[peer] else { return }
        cameras[peer]?.status?.on = on
        cameras[peer]?.status?.state = on ? .starting : .off
        let send: @MainActor () -> Void = { [weak self] in
            self?.shell(t, MotionCamera.command(on: on, settings: nil)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh(peer) }
            }
        }
        // The permissions again: the user may have taken them away on the device (design D6).
        if on { runAll(t, MotionCamera.permissionCommands, then: send) } else { send() }
    }

    func apply(_ peer: UInt16, _ settings: MotionSettings) {
        guard let t = transports[peer] else { return }
        cameras[peer]?.status?.settings = settings
        shell(t, MotionCamera.command(on: nil, settings: settings)) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh(peer) }
        }
    }

    // MARK: adb

    private func shell(_ transport: String, _ words: [String], completion: @escaping @MainActor (ADBClient.Result) -> Void) {
        guard let adb else {
            completion(ADBClient.Result(status: -1, output: "", error: "no adb"))
            return
        }
        adb.run(["-s", transport, "shell"] + words.map(ADBShell.quote), timeout: 15, on: .main) { result in
            Task { @MainActor in completion(result) }
        }
    }

    private func runAll(_ transport: String, _ commands: [[String]], then done: @escaping @MainActor () -> Void) {
        guard let first = commands.first else { done(); return }
        shell(transport, first) { [weak self] result in
            if !result.ok { self?.log.info("motion: \(first.joined(separator: " "), privacy: .public): \(result.error, privacy: .public)") }
            self?.runAll(transport, Array(commands.dropFirst()), then: done)
        }
    }
}
