import Foundation
import os
import UniversalKMCore

/// Stops a running file operation from another thread (design D1: closing the socket).
final class ADBCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: ADBSocket?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let socket = self.socket
        lock.unlock()
        socket?.cancel()
    }

    /// The socket a blocking call now waits on; cancels it at once if already cancelled.
    func attach(_ socket: ADBSocket?) {
        lock.lock()
        self.socket = socket
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { socket?.cancel() }
    }
}

/// Files on one adb transport over the server's socket (design D1, D7). Blocking: call it off the
/// main thread. Each call opens its own connection, so a listing does not wait for a transfer.
final class ADBFileClient: @unchecked Sendable {
    let transport: String
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "files")
    private let lock = NSLock()
    private var cachedFeatures: Set<String>?

    init(transport: String) {
        self.transport = transport
    }

    // MARK: Connections

    /// A connection to the device with `service` started ("sync:", "shell:…").
    private func open(_ service: String, cancel: ADBCancellation?, timeout: TimeInterval = 30) throws -> ADBSocket {
        let socket = try ADBSocket(timeout: timeout)
        do {
            try socket.host("host:transport:" + transport)
        } catch ADBFileError.failed(let message) {
            // "device 'x' not found", "device offline", "device unauthorized".
            log.info("files: \(self.transport, privacy: .public): \(message, privacy: .public)")
            throw ADBFileError.notConnected
        }
        try socket.host(service)
        cancel?.attach(socket)
        return socket
    }

    /// Runs `body`, turning errors after a cancel into `cancelled`.
    private func run<T>(_ cancel: ADBCancellation?, _ body: () throws -> T) throws -> T {
        do {
            let value = try body()
            cancel?.attach(nil)
            return value
        } catch {
            cancel?.attach(nil)
            if cancel?.isCancelled == true { throw ADBFileError.cancelled }
            throw error
        }
    }

    func features() throws -> Set<String> {
        lock.lock()
        if let cachedFeatures { lock.unlock(); return cachedFeatures }
        lock.unlock()
        let socket = try ADBSocket(timeout: 10)
        defer { socket.close() }
        do {
            try socket.host("host-serial:\(transport):features")
        } catch ADBFileError.failed {
            throw ADBFileError.notConnected
        }
        let features = ADBProtocol.features(try socket.readHexString())
        lock.lock(); cachedFeatures = features; lock.unlock()
        return features
    }

    // MARK: Sync

    /// Entries of a folder, "." and ".." included as adb sends them. An unreadable folder is empty (design D7).
    func list(_ path: String, cancel: ADBCancellation? = nil) throws -> [ADBSync.Entry] {
        let v2 = (try? features().contains("ls_v2")) ?? false
        return try run(cancel) {
            let socket = try open("sync:", cancel: cancel)
            defer { socket.close() }
            try socket.writeAll(ADBSync.list(path, v2: v2))
            var parser = ADBSync.Parser(v2 ? .list2 : .list)
            var entries: [ADBSync.Entry] = []
            while !parser.isFinished {
                let chunk = try socket.readSome()
                guard !chunk.isEmpty else { throw ADBFileError.connectionLost }
                for message in try parser.append(chunk) {
                    switch message {
                    case .entry(let entry): entries.append(entry)
                    case .fail(let text): throw ADBFileError.failed(text)
                    default: break
                    }
                }
            }
            try? socket.writeAll(ADBSync.quit)
            return entries
        }
    }

    /// Mode, size and time of one path; nil when it does not exist.
    func stat(_ path: String) throws -> ADBSync.Entry? {
        try run(nil) {
            let socket = try open("sync:", cancel: nil)
            defer { socket.close() }
            try socket.writeAll(ADBSync.stat(path))
            var parser = ADBSync.Parser(.stat)
            while !parser.isFinished {
                let chunk = try socket.readSome()
                guard !chunk.isEmpty else { throw ADBFileError.connectionLost }
                for case .stat(let entry) in try parser.append(chunk) {
                    try? socket.writeAll(ADBSync.quit)
                    return entry.mode == 0 ? nil : entry
                }
            }
            return nil
        }
    }

    /// Writes the device file into `destination` (created or truncated). `progress` gets the bytes so far.
    func download(_ path: String, to destination: URL, cancel: ADBCancellation? = nil,
                  progress: (UInt64) -> Void = { _ in }) throws {
        try run(cancel) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            let socket = try open("sync:", cancel: cancel)
            defer { socket.close() }
            try socket.writeAll(ADBSync.receive(path))
            var parser = ADBSync.Parser(.receive)
            var total: UInt64 = 0
            while !parser.isFinished {
                let chunk = try socket.readSome()
                guard !chunk.isEmpty else { throw ADBFileError.connectionLost }
                for message in try parser.append(chunk) {
                    switch message {
                    case .data(let data):
                        try file.write(contentsOf: data)
                        total += UInt64(data.count)
                        progress(total)
                    case .fail(let text): throw ADBFileError.failed(text)
                    default: break
                    }
                }
            }
            try? socket.writeAll(ADBSync.quit)
        }
    }

    /// Sends a Mac file to `path` on the device (the folder must exist). `progress` gets the bytes so far.
    func upload(_ source: URL, to path: String, cancel: ADBCancellation? = nil,
                progress: (UInt64) -> Void = { _ in }) throws {
        try run(cancel) {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let socket = try open("sync:", cancel: cancel)
            defer { socket.close() }
            try socket.writeAll(ADBSync.send(path))
            var total: UInt64 = 0
            while let chunk = try file.read(upToCount: ADBSync.maxChunk), !chunk.isEmpty {
                try socket.writeAll(ADBSync.data(chunk))
                total += UInt64(chunk.count)
                progress(total)
            }
            try socket.writeAll(ADBSync.done(modified: modified))
            // The device writes the rest of the file before it answers: a big file over Wi‑Fi takes a while.
            socket.setTimeout(120)
            var parser = ADBSync.Parser(.send)
            while !parser.isFinished {
                let chunk = try socket.readSome()
                guard !chunk.isEmpty else { throw ADBFileError.connectionLost }
                for message in try parser.append(chunk) {
                    if case .fail(let text) = message { throw ADBFileError.failed(text) }
                }
            }
            try? socket.writeAll(ADBSync.quit)
        }
    }

    // MARK: Shell

    /// Runs a command made by `ADBShell`; a non-zero exit code throws `shell`.
    @discardableResult
    func shell(_ service: String, cancel: ADBCancellation? = nil) throws -> String {
        try run(cancel) {
            let socket = try open(service, cancel: cancel, timeout: 120)
            defer { socket.close() }
            let output = String(decoding: try socket.readToEnd(), as: UTF8.self)
            guard let result = ADBShell.result(output) else { throw ADBFileError.connectionLost }
            guard result.code == 0 else { throw ADBFileError.shell(result.code, result.output) }
            return result.output
        }
    }
}
