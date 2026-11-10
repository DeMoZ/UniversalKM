import CryptoKit
import Foundation
import os
import UniversalKMCore

/// The clipboard helper on one Android phone (add-android-clipboard-sync design D1, D2, D4):
/// `adb -s <transport> shell CLASSPATH=… app_process / com.universalkm.clipboard.Main`, JSON lines
/// over stdin and stdout. Closing stdin ends the helper on the phone.
final class ClipboardHelperLink: @unchecked Sendable {
    let transport: String
    private let adb: ADBClient
    private let jar: HelperJar
    private let queue = DispatchQueue(label: "ukm.clipboard.link", qos: .utility)
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "clipboard")

    // On `queue`.
    private var process: Process?
    private var input: FileHandle?
    private var lineBuffer = Data()
    private var lastHeard = Date()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var nextID = 1

    /// Called on the main queue.
    var onReady: (@MainActor (_ sdk: Int, _ listening: Bool) -> Void)?
    var onChanged: (@MainActor (String) -> Void)?
    /// Called once when the link dies by itself (not after `stop`), with a short reason.
    var onLost: (@MainActor (String) -> Void)?

    private static let pingInterval: TimeInterval = 2
    private static let silenceTimeout: TimeInterval = 5
    private static let mainClass = "com.universalkm.clipboard.Main"

    init(adb: ADBClient, transport: String, jar: HelperJar) {
        self.adb = adb
        self.transport = transport
        self.jar = jar
        ClipboardHelperLink.ignoreSIGPIPE
    }

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Pushes the helper if the phone lacks this version, then starts it.
    func start() {
        queue.async { [self] in
            adb.run(["-s", transport, "shell", "ls \(jar.remotePath)"], timeout: 10, on: queue) { [self] result in
                guard !stopped else { return }
                if result.ok && result.output.contains(jar.remotePath) {
                    launch()
                    return
                }
                log.info("pushing clipboard helper to \(self.transport, privacy: .public)")
                adb.run(["-s", transport, "push", jar.localURL.path, jar.remotePath], timeout: 30, on: queue) { [self] result in
                    guard !stopped else { return }
                    if result.ok { launch() } else { lost("push failed: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
                }
            }
        }
    }

    private func launch() {
        let process = Process()
        process.executableURL = adb.url
        process.arguments = ["-s", transport, "shell", "CLASSPATH=\(jar.remotePath) app_process / \(Self.mainClass)"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let queue = self.queue
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            queue.async { [weak self] in self?.received(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            queue.async { [weak self] in
                guard let self, self.process === process else { return }
                self.lost("helper exited (\(process.terminationStatus))")
            }
        }
        do {
            try process.run()
        } catch {
            lost(error.localizedDescription)
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        lastHeard = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastHeard) > Self.silenceTimeout {
                self.lost("no answer for \(Self.silenceTimeout) s")
                return
            }
            self.write(ClipboardProtocol.ping)
        }
        timer.resume()
        self.timer = timer
    }

    /// Sends text to the phone's clipboard. Text over the limit is dropped (the relay never passes it).
    func set(_ text: String) {
        queue.async { [self] in
            guard let line = ClipboardProtocol.set(text, id: nextID) else { return }
            nextID += 1
            write(line)
        }
    }

    /// Ends the helper: closing stdin makes it exit; the local adb process is killed if it lingers.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            shutDown()
        }
    }

    private func shutDown() {
        timer?.cancel()
        timer = nil
        try? input?.close()
        input = nil
        let process = self.process
        self.process = nil
        queue.asyncAfter(deadline: .now() + 1) { if process?.isRunning == true { process?.terminate() } }
    }

    private func write(_ line: String) {
        guard let input else { return }
        if (try? input.write(contentsOf: Data(line.utf8))) == nil { lost("pipe closed") }
    }

    private func received(_ chunk: Data) {
        lastHeard = Date()
        lineBuffer.append(chunk)
        while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handle(line)
        }
        // A runaway line (no newline) cannot be a valid message; the limit leaves room for base64.
        if lineBuffer.count > ClipboardProtocol.maxTextBytes * 2 { lineBuffer.removeAll() }
    }

    private func handle(_ line: String) {
        guard !stopped, let message = ClipboardProtocol.parse(line) else { return }
        switch message {
        case .hello(let version, let sdk, let listening):
            guard version == ClipboardProtocol.version else {
                lost("helper protocol \(version), expected \(ClipboardProtocol.version)")
                return
            }
            log.info("clipboard helper on \(self.transport, privacy: .public): v\(version) sdk \(sdk) \(listening ? "listener" : "poll", privacy: .public)")
            removeOldJars()
            let onReady = self.onReady
            DispatchQueue.main.async { MainActor.assumeIsolated { onReady?(sdk, listening) } }
        case .changed(let text):
            log.info("phone \(self.transport, privacy: .public) clipboard changed (\(text.utf8.count) bytes)")
            let onChanged = self.onChanged
            DispatchQueue.main.async { MainActor.assumeIsolated { onChanged?(text) } }
        case .error(let message):
            log.error("clipboard helper on \(self.transport, privacy: .public): \(message, privacy: .public)")
        case .ack, .pong:
            break
        }
    }

    private func removeOldJars() {
        let keep = jar.remotePath
        let script = "for f in \(HelperJar.remoteDir)/\(HelperJar.prefix)*.jar; do [ \"$f\" = \(keep) ] || rm -f \"$f\"; done"
        adb.run(["-s", transport, "shell", script], timeout: 10, on: queue) { _ in }
    }

    private func lost(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        log.info("clipboard link \(self.transport, privacy: .public) lost: \(reason, privacy: .public)")
        shutDown()
        let onLost = self.onLost
        DispatchQueue.main.async { MainActor.assumeIsolated { onLost?(reason) } }
    }
}

/// The helper jar in the app bundle and its name on the phone: the content hash in the name means a
/// new version never runs an old file, and an existing file needs no new push (design D1).
struct HelperJar: Sendable {
    static let remoteDir = "/data/local/tmp"
    static let prefix = "ukm-clipboard-"

    let localURL: URL
    let remotePath: String

    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "ukm-clipboard", withExtension: "jar"),
              let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(8)
        localURL = url
        remotePath = "\(Self.remoteDir)/\(Self.prefix)\(hash).jar"
    }
}
