import Foundation
import os

/// The user's `adb` from Android platform-tools (design D5): finding it, running commands, following
/// the device list. The app never bundles adb and shares the user's adb server (like Android Studio).
final class ADBClient: @unchecked Sendable {
    let url: URL
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "adb")

    init(url: URL) {
        self.url = url
    }

    /// Standard places, because an app started from Finder has no shell PATH.
    static func find() -> URL? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin",
                 NSHomeDirectory() + "/Library/Android/sdk/platform-tools"]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = ProcessInfo.processInfo.environment[key] { dirs.append(sdk + "/platform-tools") }
        }
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent("adb")
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
        var ok: Bool { status == 0 }
    }

    /// Runs `adb <arguments>`; `completion` runs on `queue`. The process is killed after `timeout`.
    func run(_ arguments: [String], timeout: TimeInterval = 15, on queue: DispatchQueue,
             completion: @escaping @Sendable (Result) -> Void) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let log = self.log
        DispatchQueue.global(qos: .utility).async {
            do {
                try process.run()
            } catch {
                log.error("adb \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
                queue.async { completion(Result(status: -1, output: "", error: error.localizedDescription)) }
                return
            }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            let result = Result(status: process.terminationStatus,
                                output: String(decoding: output, as: UTF8.self),
                                error: String(decoding: error, as: UTF8.self))
            queue.async { completion(result) }
        }
    }

    /// Version of adb ("1.0.41", platform-tools "35.0.2"); nil if adb does not run.
    func platformToolsVersion(on queue: DispatchQueue, completion: @escaping @Sendable (Int?) -> Void) {
        run(["version"], timeout: 5, on: queue) { result in
            // "Version 35.0.2-12147458"
            let major = result.output.components(separatedBy: "\n")
                .first { $0.hasPrefix("Version ") }
                .flatMap { $0.dropFirst("Version ".count).split(separator: ".").first }
                .flatMap { Int($0) }
            completion(result.ok ? major ?? 0 : nil)
        }
    }

    // MARK: Device list

    struct Device: Equatable, Sendable {
        /// adb's transport name: USB serial, "ip:port" or an mDNS name.
        var serial: String
        /// "device", "unauthorized", "offline", …
        var state: String
        var isNetwork: Bool { serial.contains(":") || serial.contains("._adb-tls-connect.") }
    }

    private var tracker: Process?
    private var tracking = false

    /// Follows `adb track-devices`; `onChange` runs on `queue` with the full list after every change.
    /// The process is started again if it exits (adb server restarted by another program).
    func track(on queue: DispatchQueue, onChange: @escaping @Sendable ([Device]) -> Void) {
        tracking = true
        let process = Process()
        process.executableURL = url
        process.arguments = ["track-devices"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let buffer = TrackBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for devices in buffer.append(chunk) { queue.async { onChange(devices) } }
        }
        process.terminationHandler = { [weak self] _ in
            queue.async { [weak self] in
                guard let self, self.tracking else { return }
                self.log.info("adb track-devices exited; restarting")
                onChange([])
                queue.asyncAfter(deadline: .now() + 2) { [self] in
                    if self.tracking { self.track(on: queue, onChange: onChange) }
                }
            }
        }
        do {
            try process.run()
            tracker = process
        } catch {
            log.error("adb track-devices: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopTracking() {
        tracking = false
        tracker?.terminate()
        tracker = nil
    }

    // MARK: Parsing

    /// "inet 192.168.1.107/24 brd …" from `ip -4 addr show wlan0`.
    static func wlanAddress(_ output: String) -> String? {
        guard let range = output.range(of: #"inet (\d+\.\d+\.\d+\.\d+)/"#, options: .regularExpression) else { return nil }
        return String(output[range].dropFirst(5).dropLast())
    }

    /// `adb mdns services` lines: "adb-R28M303RHET-AbCdEf\t_adb-tls-connect._tcp\t192.168.1.107:37019".
    /// Returns serial → address for connect services.
    static func mdnsConnectServices(_ output: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3, parts[1].hasPrefix("_adb-tls-connect"), parts[0].hasPrefix("adb-") else { continue }
            var name = parts[0].dropFirst(4)
            if let dash = name.lastIndex(of: "-") { name = name[..<dash] }
            found[String(name)] = parts[2]
        }
        return found
    }
}

/// Splits `adb track-devices` output into messages: 4 hex digits of length, then
/// "serial\tstate\n" lines. Used only from the pipe's reading handler, one call at a time.
final class TrackBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ chunk: Data) -> [[ADBClient.Device]] {
        data.append(chunk)
        var messages: [[ADBClient.Device]] = []
        while data.count >= 4, let length = Int(String(decoding: data.prefix(4), as: UTF8.self), radix: 16),
              data.count >= 4 + length {
            let payload = String(decoding: data.dropFirst(4).prefix(length), as: UTF8.self)
            data = Data(data.dropFirst(4 + length))
            messages.append(payload.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t")
                return parts.count >= 2 ? ADBClient.Device(serial: String(parts[0]), state: String(parts[1])) : nil
            })
        }
        return messages
    }
}
