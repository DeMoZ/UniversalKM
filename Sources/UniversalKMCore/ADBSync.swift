import Foundation

/// The adb sync protocol (design D1, adb's SYNC.TXT and file_sync_protocol.h) after `sync:`.
/// Every packet is a 4-byte id and little-endian 32-bit fields. Encoding and parsing only; no I/O.
public enum ADBSync {
    /// Largest DATA chunk adb accepts.
    public static let maxChunk = 64 * 1024

    // MARK: Requests

    /// "LIST"/"LIS2"/"STAT"/"RECV"/"SEND" + length + path (SEND: "path,mode").
    public static func request(_ id: String, _ payload: String) -> Data {
        request(id, Data(payload.utf8))
    }

    public static func request(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8)
        data.appendLE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    public static func list(_ path: String, v2: Bool) -> Data { request(v2 ? "LIS2" : "LIST", path) }
    public static func stat(_ path: String) -> Data { request("STAT", path) }
    public static func receive(_ path: String) -> Data { request("RECV", path) }
    /// Mode 0644 regular file, as `adb push` sends for a plain file.
    public static func send(_ path: String, mode: UInt32 = 0o100644) -> Data { request("SEND", "\(path),\(mode)") }
    public static func data(_ chunk: Data) -> Data { request("DATA", chunk) }

    /// "DONE" + modification time: ends a SEND.
    public static func done(modified: Date) -> Data {
        var data = Data("DONE".utf8)
        data.appendLE(UInt32(clamping: Int(max(0, modified.timeIntervalSince1970))))
        return data
    }

    public static var quit: Data {
        var data = Data("QUIT".utf8)
        data.appendLE(UInt32(0))
        return data
    }

    // MARK: Replies

    /// A directory entry from LIST (DENT) or LIS2 (DNT2).
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var mode: UInt32
        public var size: UInt64
        public var modified: Date

        public init(name: String, mode: UInt32, size: UInt64, modified: Date) {
            self.name = name
            self.mode = mode
            self.size = size
            self.modified = modified
        }

        public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
        public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
    }

    public enum Message: Equatable, Sendable {
        case entry(Entry)
        case data(Data)
        /// End of a list or of a file.
        case done
        /// SEND accepted.
        case okay
        case fail(String)
        /// STAT reply: mode, size, mtime (mode 0 = no such file).
        case stat(Entry)
    }

    /// What a reply stream is: it decides the size of "DONE".
    public enum Reply: Sendable {
        /// DENT… DONE (DONE has the 20 bytes of a DENT header).
        case list
        /// DNT2… DONE (DONE has the 76 bytes of a DNT2 header).
        case list2
        /// DATA… DONE (DONE has 4 bytes).
        case receive
        /// OKAY or FAIL after SEND.
        case send
        /// STAT: one packet.
        case stat
    }

    /// Splits a reply stream into messages; data may come in pieces of any length.
    public struct Parser: Sendable {
        public let reply: Reply
        private var buffer = Data()
        private var finished = false

        public init(_ reply: Reply) {
            self.reply = reply
        }

        /// True after DONE, OKAY, FAIL or STAT: the reply is complete.
        public var isFinished: Bool { finished }

        public mutating func append(_ chunk: Data) throws -> [Message] {
            buffer.append(chunk)
            var messages: [Message] = []
            while !finished, let message = try next() { messages.append(message) }
            return messages
        }

        private mutating func next() throws -> Message? {
            guard buffer.count >= 8 else { return nil }
            let id = String(decoding: buffer.prefix(4), as: UTF8.self)
            switch (id, reply) {
            case ("DENT", .list):
                guard buffer.count >= 20 else { return nil }
                let length = Int(buffer.le32(16))
                guard buffer.count >= 20 + length else { return nil }
                let entry = Entry(name: buffer.string(20, length), mode: buffer.le32(4), size: UInt64(buffer.le32(8)),
                                  modified: Date(timeIntervalSince1970: TimeInterval(buffer.le32(12))))
                consume(20 + length)
                return .entry(entry)
            case ("DNT2", .list2):
                // id, error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime, namelen.
                guard buffer.count >= 76 else { return nil }
                let length = Int(buffer.le32(72))
                guard buffer.count >= 76 + length else { return nil }
                let entry = Entry(name: buffer.string(76, length), mode: buffer.le32(24), size: buffer.le64(40),
                                  modified: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: buffer.le64(56)))))
                consume(76 + length)
                return .entry(entry)
            case ("DATA", .receive):
                let length = Int(buffer.le32(4))
                guard length <= maxChunk else { throw ADBFileError.protocolError("DATA of \(length) bytes") }
                guard buffer.count >= 8 + length else { return nil }
                let data = Data(buffer.subdata(in: buffer.startIndex + 8 ..< buffer.startIndex + 8 + length))
                consume(8 + length)
                return .data(data)
            case ("DONE", _):
                let size = switch reply {
                case .list: 20
                case .list2: 76
                default: 8
                }
                guard buffer.count >= size else { return nil }
                consume(size)
                finished = true
                return .done
            case ("STAT", .stat):
                guard buffer.count >= 16 else { return nil }
                let entry = Entry(name: "", mode: buffer.le32(4), size: UInt64(buffer.le32(8)),
                                  modified: Date(timeIntervalSince1970: TimeInterval(buffer.le32(12))))
                consume(16)
                finished = true
                return .stat(entry)
            case ("OKAY", .send):
                consume(8)
                finished = true
                return .okay
            case ("FAIL", _):
                let length = Int(buffer.le32(4))
                guard buffer.count >= 8 + length else { return nil }
                let text = buffer.string(8, length)
                consume(8 + length)
                finished = true
                return .fail(text)
            default:
                throw ADBFileError.protocolError("unexpected \(id.debugDescription) in a \(reply) reply")
            }
        }

        private mutating func consume(_ count: Int) {
            buffer = Data(buffer.dropFirst(count))
        }
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func le32(_ offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start ..< start + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }

    func string(_ offset: Int, _ length: Int) -> String {
        let start = startIndex + offset
        return String(decoding: self[start ..< start + length], as: UTF8.self)
    }
}
