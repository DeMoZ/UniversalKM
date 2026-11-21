import AppKit
import CoreMedia
import Network
import os
import UniversalKMCore
import UniversalKMDisplay

/// One Android device used as a second monitor (openspec/changes/add-android-second-display, design D7): checks
/// the right to record the screen, puts the receiver app on the device and starts it, connects through
/// `adb forward`, makes the virtual display, then captures, encodes and sends it until stopped or lost.
@MainActor
final class SecondDisplaySession {
    enum Phase: Equatable {
        case starting(String)
        case running
    }

    struct Failure: Error {
        let message: String
        var needsScreenRecording = false
    }

    /// Called as the session moves on.
    var onPhase: ((Phase) -> Void)?
    /// Called once, when the session is over: the reason (nil when the user stopped it) and whether the Mac's
    /// "Screen Recording" permission is what is missing.
    var onEnd: ((String?, Bool) -> Void)?

    private let adb: ADBClient
    private let transport: String
    private let name: String
    private let serial: UInt32
    private var port: Int?
    private var connection: NWConnection?
    private var parser = SecondDisplay.Parser()
    private let link = DisplayLink()
    private var display: UKMVirtualDisplay?
    private var capture: DisplayCapture?
    private var encoder: DisplayEncoder?
    private var idleTimer: Timer?
    private var stopped = false
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "display")

    init(adb: ADBClient, transport: String, name: String, serial: UInt32) {
        self.adb = adb
        self.transport = transport
        self.name = name
        self.serial = serial
    }

    /// A Wi‑Fi transport is an address ("192.168.1.5:5555") or an mDNS name; USB is the serial number.
    private var overWiFi: Bool { transport.contains(":") || transport.contains("_adb-tls") }

    func start() {
        task = Task { [weak self] in
            do {
                try await self?.run()
            } catch {
                self?.finish(error)
            }
        }
    }

    /// The user turned the monitor off.
    func stop() {
        finish(nil)
    }

    // MARK: Starting

    private func phase(_ text: String) {
        guard !stopped else { return }
        onPhase?(.starting(text))
    }

    private func run() async throws {
        // 1. The right to record the screen.
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw Failure(message: String(localized: "Screen Recording is needed to send the display to the device."),
                          needsScreenRecording: true)
        }
        // 2. The receiver on the device.
        phase(String(localized: "Preparing the device…"))
        try await ensureReceiver()
        // 3. Start it and connect.
        _ = await adbRun(["-s", transport, "shell", "am", "force-stop", SecondDisplay.packageName])
        let started = await adbRun(["-s", transport, "shell", "am", "start", "-n", SecondDisplay.activity])
        guard started.ok, !started.output.contains("Error") else {
            throw Failure(message: String(localized: "The receiver did not start on the device. Unlock it and try again."))
        }
        phase(String(localized: "Connecting…"))
        let forward = await adbRun(["-s", transport, "forward", "tcp:0", SecondDisplay.socket])
        guard forward.ok, let port = Int(forward.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure(message: forward.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        self.port = port
        let hello = try await handshake(port: port)
        guard hello.version == SecondDisplay.protocolVersion else {
            throw Failure(message: String(localized: "The receiver on the device is not compatible. Try again to update it."))
        }
        guard hello.hardwareH264 else {
            throw Failure(message: String(localized: "This device has no hardware H.264 decoder, it cannot be a monitor."))
        }
        guard !stopped else { return }
        // 4. The virtual display, its capture and the encoder.
        phase(String(localized: "Creating the display…"))
        let size = SecondDisplay.displaySize(forDevice: hello.width, hello.height)
        guard let virtual = UKMVirtualDisplay(name: "UniversalKM · \(name)", width: UInt32(size.width),
                                              height: UInt32(size.height), serial: serial) else {
            throw Failure(message: String(localized: "macOS did not create the virtual display."))
        }
        display = virtual
        let encoder = try makeEncoder(width: size.width, height: size.height)
        self.encoder = encoder
        let capture = DisplayCapture(displayID: virtual.displayID, width: size.width, height: size.height,
                                     onFrame: { [weak encoder] buffer, pts in encoder?.encode(buffer, pts: pts) },
                                     onStop: { [weak self] error in
                                         Task { @MainActor in
                                             self?.finish(Failure(message: String(localized: "Screen capture stopped: \(error.localizedDescription)")))
                                         }
                                     })
        self.capture = capture
        do {
            try await capture.start()
        } catch {
            throw Failure(message: String(localized: "Screen capture did not start: \(error.localizedDescription)"),
                          needsScreenRecording: !CGPreflightScreenCaptureAccess())
        }
        guard !stopped else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak encoder] _ in
            encoder?.repeatIfIdle()
        }
        log.info("display: \(self.name, privacy: .public) \(size.width)x\(size.height) on \(self.transport, privacy: .public)")
        onPhase?(.running)
    }

    private func makeEncoder(width: Int, height: Int) throws -> DisplayEncoder {
        let link = self.link
        final class Box: @unchecked Sendable { weak var encoder: DisplayEncoder? }
        let box = Box()
        let log = self.log
        let meter = LatencyMeter { average, worst, fps in
            log.info("display: capture to socket \(average, format: .fixed(precision: 1)) ms (worst \(worst, format: .fixed(precision: 1))), \(fps) frames/s")
        }
        let encoder = try DisplayEncoder(
            width: width, height: height, bitrate: SecondDisplay.bitrate(overUSB: !overWiFi),
            onConfig: { w, h, sets in link.send(.config(width: w, height: h, parameterSets: sets)) },
            onFrame: { pts, key, data in
                meter.record(ptsUs: pts)
                if !link.sendFrame(ptsUs: pts, key: key, data: data) { box.encoder?.forceKeyFrame() }
            })
        box.encoder = encoder
        return encoder
    }

    // MARK: Receiver app

    /// The APK and its versionCode shipped in the app (scripts/build-display-apk.sh).
    private static var bundled: (apk: URL, version: Int)? {
        let inApp = Bundle.main.url(forResource: "ukm-display", withExtension: "apk") != nil
        let resources = inApp ? Bundle.main.resourceURL
            : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources")
        guard let resources else { return nil }
        let apk = resources.appendingPathComponent("ukm-display.apk")
        let text = try? String(contentsOf: resources.appendingPathComponent("ukm-display.version"), encoding: .utf8)
        guard FileManager.default.fileExists(atPath: apk.path),
              let version = Int(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else { return nil }
        return (apk, version)
    }

    /// versionCode of the installed receiver from `dumpsys package` output; nil when not installed.
    static func installedVersion(_ output: String) -> Int? {
        guard let r = output.range(of: "versionCode=") else { return nil }
        return Int(output[r.upperBound...].prefix { $0.isNumber })
    }

    private func ensureReceiver() async throws {
        guard let bundled = Self.bundled else {
            throw Failure(message: String(localized: "The receiver app is missing from UniversalKM."))
        }
        let check = await adbRun(["-s", transport, "shell", "dumpsys package \(SecondDisplay.packageName) | grep versionCode"])
        if let installed = Self.installedVersion(check.output), installed >= bundled.version { return }
        phase(String(localized: "Installing the receiver on the device…"))
        let result = await adbRun(["-s", transport, "install", "-r", bundled.apk.path], timeout: 180)
        let text = result.output + result.error
        guard result.ok, text.contains("Success") else {
            let line = text.split(whereSeparator: \.isNewline).last { $0.contains("Failure") || $0.contains("error") }
            throw Failure(message: String(localized: "The install on the device failed: \(line.map(String.init) ?? text)"))
        }
    }

    private func adbRun(_ arguments: [String], timeout: TimeInterval = 15) async -> ADBClient.Result {
        await withCheckedContinuation { continuation in
            adb.run(arguments, timeout: timeout, on: .main) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Connection

    private struct Hello {
        var version: UInt16
        var width: Int
        var height: Int
        var hardwareH264: Bool
    }

    /// Reads the first message of one connection attempt; `nil` when the connection closed first.
    private final class HelloWaiter: @unchecked Sendable {
        private var continuation: CheckedContinuation<Hello?, Never>?
        private var parser = SecondDisplay.Parser()

        init(_ c: CheckedContinuation<Hello?, Never>) { continuation = c }

        func finish(_ hello: Hello?) {
            continuation?.resume(returning: hello)
            continuation = nil
        }

        func receive(_ c: NWConnection) {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, done, error in
                if let data, !data.isEmpty {
                    do {
                        for case let .hello(version, width, height, hw) in try parser.append(data) {
                            return finish(Hello(version: version, width: width, height: height, hardwareH264: hw))
                        }
                    } catch {
                        return finish(nil)
                    }
                }
                if done || error != nil { finish(nil) } else { receive(c) }
            }
        }
    }

    /// Until the receiver listens, adb accepts the connection and closes it at once: try again every 0.3 s.
    private func handshake(port: Int) async throws -> Hello {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw Failure(message: String(localized: "The connection to the device was lost."))
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline, !stopped {
            let c = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
            let hello: Hello? = await withCheckedContinuation { continuation in
                let waiter = HelloWaiter(continuation)
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready: waiter.receive(c)
                    case .failed, .cancelled, .waiting: waiter.finish(nil)
                    default: break
                    }
                }
                c.start(queue: .main)
            }
            if let hello {
                connection = c
                parser = SecondDisplay.Parser()
                link.attach(c)
                c.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        MainActor.assumeIsolated {
                            self?.finish(Failure(message: String(localized: "The connection to the device was lost.")))
                        }
                    }
                }
                receiveLoop(c)
                return hello
            }
            c.cancel()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw Failure(message: String(localized: "The receiver on the device does not answer."))
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === c, !self.stopped else { return }
                if let data, !data.isEmpty {
                    do {
                        for message in try self.parser.append(data) { self.handle(message) }
                    } catch {
                        self.finish(Failure(message: String(localized: "The device sent data the Mac cannot read.")))
                        return
                    }
                }
                if done || error != nil {
                    self.finish(Failure(message: String(localized: "The device closed the monitor.")))
                } else {
                    self.receiveLoop(c)
                }
            }
        }
    }

    private func handle(_ message: SecondDisplay.Message) {
        switch message {
        case .keyFrameRequest:
            encoder?.forceKeyFrame()
        case let .stats(decodeUs, presentUs):
            log.info("display: device decode \(decodeUs) µs, present \(presentUs) µs")
        default:
            break // touches and rotation: add-android-second-display tasks 5.x
        }
    }

    // MARK: Ending

    private func finish(_ error: Error?) {
        guard !stopped else { return }
        stopped = true
        task?.cancel()
        idleTimer?.invalidate()
        idleTimer = nil
        link.attach(nil)
        connection?.cancel()
        connection = nil
        encoder?.invalidate()
        encoder = nil
        let capture = self.capture
        self.capture = nil
        let virtual = display
        display = nil
        let port = self.port
        let transport = self.transport
        let adb = self.adb
        Task { @MainActor [weak self] in
            // The display goes after its capture has stopped.
            await capture?.stop()
            virtual?.invalidate()
            if let port { adb.run(["-s", transport, "forward", "--remove", "tcp:\(port)"], on: .main) { _ in } }
            adb.run(["-s", transport, "shell", "am", "force-stop", SecondDisplay.packageName], on: .main) { _ in }
            let failure = error as? Failure
            let message = error.map { failure?.message ?? $0.localizedDescription }
            self?.onEnd?(message, failure?.needsScreenRecording ?? false)
        }
    }
}
