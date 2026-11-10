import Darwin
import Foundation
import UniversalKMCore

/// A blocking TCP connection to the adb server on 127.0.0.1:5037 (add-android-file-browser design D1).
/// Used from one background thread at a time; `cancel` may come from any thread and wakes a blocked read.
final class ADBSocket: @unchecked Sendable {
    static let port: UInt16 = 5037

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    /// Fails with `notConnected` when no adb server listens.
    init(timeout: TimeInterval = 30) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBFileError.notConnected }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw ADBFileError.notConnected
        }
        setTimeout(timeout)
    }

    deinit { close() }

    /// Longest wait for one read or write; a quiet connection beyond it counts as lost.
    func setTimeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Stops the connection from another thread: the blocked read or write fails at once.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if !closed { shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw ADBFileError.connectionLost }
                offset += sent
            }
        }
    }

    /// Up to `max` bytes; empty at the end of the stream.
    func readSome(max: Int = 64 * 1024) throws -> Data {
        var data = Data(count: max)
        while true {
            let count = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, max, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ADBFileError.connectionLost }
            return data.prefix(count)
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try readSome(max: count - data.count)
            guard !chunk.isEmpty else { throw ADBFileError.connectionLost }
            data.append(chunk)
        }
        return data
    }

    func readToEnd() throws -> Data {
        var data = Data()
        while true {
            let chunk = try readSome()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }

    // MARK: Host protocol

    /// Sends a host request and waits for OKAY; FAIL throws with the server's message.
    func host(_ request: String) throws {
        try writeAll(ADBProtocol.request(request))
        try readStatus()
    }

    func readStatus() throws {
        switch ADBProtocol.status(try readExactly(4)) {
        case .okay: return
        case .fail: throw ADBFileError.failed(try readHexString())
        case nil: throw ADBFileError.protocolError("no OKAY or FAIL")
        }
    }

    /// 4 hex digits of length and the text (FAIL messages, `features`).
    func readHexString() throws -> String {
        guard let length = ADBProtocol.hexLength(try readExactly(4)) else { throw ADBFileError.protocolError("bad length") }
        return String(decoding: try readExactly(length), as: UTF8.self)
    }
}
