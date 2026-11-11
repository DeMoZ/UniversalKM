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
        /** The install runs for more than 15 s: the device checks the app (Play Protect). */
        var slowInstall = false
    }

    @Published private(set) var cameras: [UInt16: Camera] = [:]
    /// Devices that had the camera installed: their row stays when adb is gone ("state unknown").
    @Published private(set) var known: Set<UInt16>

    private var transports: [UInt16: String] = [:]
    private var inFlight: Set<UInt16> = []
    private var installs = 0
    private var timer: Timer?
    /// A camera window is open: every device is read, not only those with the camera.
    private var windowsOpen = false
    let adb = ADBClient.find().map { ADBClient(url: $0) }
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
    func transport(_ peer: UInt16) -> String? { transports[peer] }
    /// A connected device records now: the menu bar icon shows a blinking red dot (spec «Значок записи»).
    var anyRecording: Bool {
        cameras.contains { transports[$0.key] != nil && $0.value.status?.state == .recording }
    }
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
        if !next.isEmpty { ensureTimer() }
    }

    /// The state every 5 s (spec «Окно камеры», «Значок записи»): of devices with the camera always, for the
    /// recording dot on the menu bar icon; of every device while a camera window is open.
    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.windowsOpen {
                    self.refreshAll()
                } else {
                    for peer in self.transports.keys where self.camera(peer).installed != nil { self.refresh(peer) }
                }
            }
        }
    }

    func startPolling() {
        windowsOpen = true
        ensureTimer()
        refreshAll()
    }

    func stopPolling() {
        windowsOpen = false
    }

    /// Without the Android status (`--motion-window`): one device on a given adb transport.
    func attach(peer: UInt16, transport: String) {
        transports[peer] = transport
        ensureTimer()
        refresh(peer)
    }

    func refreshAll() {
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
        c.slowInstall = false
        cameras[peer] = c
        log.info("motion: install on \(t, privacy: .public)")
        installs += 1
        let attempt = installs
        // The first install on a phone may wait for Play Protect to check the app: say so instead of a silent
        // spinner.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.installs == attempt, self.camera(peer).busy != nil else { return }
            self.cameras[peer]?.slowInstall = true
        }
        let finished: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.runAll(t, MotionCamera.permissionCommands) {
                self.cameras[peer]?.busy = nil
                self.cameras[peer]?.slowInstall = false
                self.remember(peer)
                self.refresh(peer)
            }
        }
        adb.run(["-s", t, "install", "-r", "-g", apk.path], timeout: 180, on: .main) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let text = result.output + result.error
                if result.ok, text.contains("Success") {
                    finished()
                } else if !result.ok, !text.contains("Failure") {
                    // Killed after 3 minutes or adb lost the device: the app may be in place anyway.
                    self.shell(t, MotionCamera.versionCommand) { check in
                        if (MotionCamera.installedVersion(check.output) ?? 0) >= self.bundledVersion {
                            finished()
                        } else {
                            var c = self.camera(peer)
                            c.busy = nil
                            c.slowInstall = false
                            c.error = String(localized: "The device did not finish the install. Unlock it, look for a question on its screen, then press Install again.")
                            self.cameras[peer] = c
                        }
                    }
                } else {
                    var c = self.camera(peer)
                    c.busy = nil
                    c.slowInstall = false
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

    /// `adb shell` on a device (the live picture's commands).
    func send(_ peer: UInt16, _ words: [String], completion: @escaping @MainActor (ADBClient.Result) -> Void = { _ in }) {
        guard let t = transports[peer] else {
            completion(ADBClient.Result(status: -1, output: "", error: "not connected"))
            return
        }
        shell(t, words, completion: completion)
    }

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
