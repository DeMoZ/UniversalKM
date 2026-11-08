import Foundation
import os
import UniversalKMCore

/// The Android keyboard + mouse over ADB (design D5): `adb -s <transport> shell hid -` on the phone
/// reads JSON commands (HidCommand) and drives a UHID device. Closing stdin removes the device.
/// Over the network a second shell echoes a heartbeat, so a phone that left the Wi‑Fi is noticed
/// within seconds (adb's own TCP keepalive takes much longer).
final class ADBLink: @unchecked Sendable {
    let transport: String
    private let adb: URL
    private let queue: DispatchQueue
    private let writer = DispatchQueue(label: "ukm.adb.writer", qos: .userInteractive)
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "adb")

    // On `queue`.
    private var hid: Process?
    private var input: FileHandle?
    private var heartbeat: Process?
    private var heartbeatInput: FileHandle?
    private var lastEcho = Date()
    private var heartbeatTimer: DispatchSourceTimer?
    private var stopped = false
    private var errorText = ""

    /// Called once on `queue` when the link dies by itself (not after `stop`).
    var onLost: (() -> Void)?

    private static let startCheck: TimeInterval = 0.8
    private static let heartbeatInterval: TimeInterval = 1
    private static let heartbeatTimeout: TimeInterval = 2.5

    init(adb: URL, transport: String, queue: DispatchQueue) {
        self.adb = adb
        self.transport = transport
        self.queue = queue
        ADBLink.ignoreSIGPIPE
    }

    /// Writing to a pipe whose reader exited must not kill the app.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Starts `hid` and registers the device. `completion(true)` once `hid` is still alive a moment
    /// after the registration; an Android before 12 rejects the `bus` field, so it is tried without.
    /// Call on `queue`; `completion` runs on `queue`.
    func start(heartbeat useHeartbeat: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        launch(withBus: true) { [self] ok in
            if ok || stopped { finishStart(ok, useHeartbeat, completion); return }
            log.info("hid on \(self.transport, privacy: .public) refused the register command; again without bus")
            launch(withBus: false) { [self] ok in finishStart(ok, useHeartbeat, completion) }
        }
    }

    private func finishStart(_ ok: Bool, _ useHeartbeat: Bool, _ completion: @Sendable (Bool) -> Void) {
        if ok && useHeartbeat { startHeartbeat() }
        if !ok { log.error("hid on \(self.transport, privacy: .public) failed: \(self.errorText, privacy: .public)") }
        completion(ok && !stopped)
    }

    private func launch(withBus: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", transport, "shell", "hid", "-"]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        let queue = self.queue
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { handle.readabilityHandler = nil; return }
            queue.async { [weak self] in self?.errorText += text }
        }
        let startedOK = StartFlag()
        process.terminationHandler = { [weak self] process in
            queue.async { [weak self] in
                guard let self else { return }
                if startedOK.value == nil {
                    startedOK.value = false
                    completion(false)
                } else if self.hid === process {
                    self.lost("hid exited (\(process.terminationStatus))")
                }
            }
        }
        do {
            try process.run()
        } catch {
            errorText = error.localizedDescription
            startedOK.value = false
            completion(false)
            return
        }
        hid = process
        input = stdin.fileHandleForWriting
        write(HidCommand.register(withBus: withBus))
        queue.asyncAfter(deadline: .now() + Self.startCheck) {
            guard startedOK.value == nil else { return }
            startedOK.value = process.isRunning
            completion(process.isRunning)
        }
    }

    /// Sends one event; `completion(false)` if the pipe is broken. Call on `queue`.
    func send(_ event: [UInt8], completion: @escaping @Sendable (Bool) -> Void) {
        guard let input, !stopped else { completion(false); return }
        let line = Data(HidCommand.report(event).utf8)
        let queue = self.queue
        writer.async {
            let ok = (try? input.write(contentsOf: line)) != nil
            queue.async { completion(ok) }
        }
    }

    /// Releases everything and removes the device; blocks at most `timeout`. Call on `queue`.
    func stop(timeout: TimeInterval = 0.3) {
        guard !stopped else { return }
        stopped = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if let input {
            let lines = Data(AndroidHIDEvent.neutral.map(HidCommand.report).joined().utf8)
            let done = DispatchSemaphore(value: 0)
            writer.async {
                try? input.write(contentsOf: lines)
                try? input.close()
                done.signal()
            }
            _ = done.wait(timeout: .now() + timeout)
        }
        let process = hid
        queue.asyncAfter(deadline: .now() + 1) { if process?.isRunning == true { process?.terminate() } }
        heartbeat?.terminate()
        hid = nil
        input = nil
        heartbeat = nil
        heartbeatInput = nil
    }

    private func write(_ line: String) {
        guard let input else { return }
        let data = Data(line.utf8)
        writer.async { try? input.write(contentsOf: data) }
    }

    private func lost(_ reason: String) {
        guard !stopped else { return }
        log.info("ADB link \(self.transport, privacy: .public) lost: \(reason, privacy: .public)")
        stop(timeout: 0)
        onLost?()
        onLost = nil
    }

    // MARK: Heartbeat (network only)

    private func startHeartbeat() {
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", transport, "shell", "cat"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let queue = self.queue
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard !handle.availableData.isEmpty else { handle.readabilityHandler = nil; return }
            queue.async { [weak self] in self?.lastEcho = Date() }
        }
        do { try process.run() } catch { return }
        heartbeat = process
        heartbeatInput = stdin.fileHandleForWriting
        lastEcho = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let input = self.heartbeatInput else { return }
            if Date().timeIntervalSince(self.lastEcho) > Self.heartbeatTimeout {
                self.lost("no heartbeat for \(Self.heartbeatTimeout) s")
                return
            }
            self.writer.async { _ = try? input.write(contentsOf: Data("1\n".utf8)) }
        }
        timer.resume()
        heartbeatTimer = timer
    }
}

/// Whether `hid` survived its start; touched only on the link's queue.
private final class StartFlag: @unchecked Sendable {
    var value: Bool?
}
