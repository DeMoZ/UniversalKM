import Foundation

/// The live picture of the motion camera (openspec/changes/add-android-motion-camera, design D11): the packets
/// the app's local socket `ukm-motion-live` sends, read without a device.
public enum MotionLive {
    /// The socket on the device; the Mac reaches it with `adb forward tcp:0 localabstract:ukm-motion-live`.
    public static let socket = "localabstract:ukm-motion-live"

    /// Which camera a connection asks for (the first line it sends).
    public enum Facing: String, CaseIterable, Sendable {
        case back, front
        public var request: Data { Data((rawValue + "\n").utf8) }
        /// The name in the status column `live` ("rear", "front").
        public var statusName: String { self == .back ? "rear" : "front" }
    }

    public enum Packet: Equatable, Sendable {
        /// The encoder's size and parameter sets (without start codes); sent before the first frame and after
        /// the encoder changes.
        case config(width: Int, height: Int, sps: Data, pps: Data)
        /// One H.264 access unit in Annex B; `rotation` is the clockwise turn (0, 90, 180, 270) that shows it
        /// upright.
        case frame(ptsUs: Int64, key: Bool, rotation: Int, annexB: Data)
    }

    public struct ProtocolError: Error, Equatable {
        public let message: String
    }

    /// Cuts a byte stream into packets; keeps an incomplete tail for the next call.
    public struct Parser {
        private var buffer = Data()
        /// Frames bigger than this are a broken stream, not video (a 1080p key frame is well under 2 MB).
        private static let maxPayload = 16 << 20

        public init() {}

        public mutating func append(_ data: Data) throws -> [Packet] {
            buffer.append(data)
            var out: [Packet] = []
            var at = buffer.startIndex
            while true {
                guard at < buffer.endIndex else { break }
                let start = at
                let type = buffer[at]
                if type == UInt8(ascii: "C") {
                    guard let w = int32(at + 1), let h = int32(at + 5), let sl = int32(at + 9) else { break }
                    guard (0...Self.maxPayload).contains(sl) else { throw ProtocolError(message: "bad SPS length") }
                    let spsAt = at + 13
                    guard let pl = int32(spsAt + sl) else { break }
                    guard (0...Self.maxPayload).contains(pl) else { throw ProtocolError(message: "bad PPS length") }
                    let ppsAt = spsAt + sl + 4
                    guard buffer.endIndex - ppsAt >= pl else { break }
                    out.append(.config(width: w, height: h, sps: Data(buffer[spsAt..<spsAt + sl]),
                                       pps: Data(buffer[ppsAt..<ppsAt + pl])))
                    at = ppsAt + pl
                } else if type == UInt8(ascii: "F") {
                    guard buffer.endIndex - at >= 16 else { break }
                    var pts: Int64 = 0
                    for i in 0..<8 { pts = pts << 8 | Int64(buffer[at + 1 + i]) }
                    let key = buffer[at + 9] != 0
                    let rotation = Int(buffer[at + 10]) << 8 | Int(buffer[at + 11])
                    guard let len = int32(at + 12) else { break }
                    guard (0...Self.maxPayload).contains(len) else { throw ProtocolError(message: "bad frame length") }
                    guard buffer.endIndex - (at + 16) >= len else { break }
                    out.append(.frame(ptsUs: pts, key: key, rotation: rotation,
                                      annexB: Data(buffer[at + 16..<at + 16 + len])))
                    at += 16 + len
                } else {
                    throw ProtocolError(message: "unknown packet \(type)")
                }
                precondition(at > start)
            }
            buffer = Data(buffer[at...])
            return out
        }

        private func int32(_ i: Int) -> Int? {
            guard buffer.endIndex - i >= 4 else { return nil }
            let v = UInt32(buffer[i]) << 24 | UInt32(buffer[i + 1]) << 16 | UInt32(buffer[i + 2]) << 8 | UInt32(buffer[i + 3])
            return Int(Int32(bitPattern: v))
        }
    }

    /// NAL units of an Annex B stream, without their start codes.
    public static func nalUnits(_ annexB: Data) -> [Data] {
        let b = [UInt8](annexB)
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                let code = i > 0 && b[i - 1] == 0 ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var out: [Data] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].code : b.count
            if end > s.nal { out.append(Data(b[s.nal..<end])) }
        }
        return out
    }

    /// The AVCC form a decoder takes: each NAL unit with a 4-byte length instead of a start code. Parameter
    /// sets inside a frame are left out (the format description carries them).
    public static func avcc(_ annexB: Data) -> Data {
        var out = Data(capacity: annexB.count + 16)
        for nal in nalUnits(annexB) {
            let type = nal.first.map { $0 & 0x1F } ?? 0
            if type == 7 || type == 8 { continue }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }
}

extension MotionCamera {
    /// The exact `adb shell` words that ask for the live picture of some cameras, or end it (`[]`).
    public static func liveCommand(_ cameras: Set<MotionLive.Facing>) -> [String] {
        let value: String
        switch (cameras.contains(.back), cameras.contains(.front)) {
        case (true, true): value = "both"
        case (true, false): value = "back"
        case (false, true): value = "front"
        case (false, false): value = "none"
        }
        return ["am", "start", "-n", "\(package)/.ControlActivity", "--es", "live", value]
    }

    /// The first app version with the live picture.
    public static let liveVersion = 3
}
