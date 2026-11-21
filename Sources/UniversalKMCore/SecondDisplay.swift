import CoreGraphics
import Foundation

/// An Android device as a second display of the Mac (openspec/changes/add-android-second-display): the wire
/// protocol between the Mac and the receiver app, the mode of the virtual display, and the touch gestures that
/// become mouse events. No I/O, so it is unit-testable.
public enum SecondDisplay {
    /// Raised with every incompatible change of the messages; the receiver sends its own in HELLO (design D4).
    public static let protocolVersion: UInt16 = 1
    /// The receiver's local socket the Mac connects to through `adb forward` (design D4).
    public static let socketName = "ukm_display"
    public static let socket = "localabstract:" + socketName
    public static let packageName = "com.universalkm.display"
    public static let activity = packageName + "/.DisplayActivity"
    /// The virtual display is at most this many pixels on its long side (design D1).
    public static let maxLongSide = 2560

    // MARK: Messages

    public enum Message: Equatable, Sendable {
        /// Receiver → Mac, first: protocol version, screen size in pixels (current orientation), and whether the
        /// device has a hardware H.264 decoder.
        case hello(version: UInt16, width: Int, height: Int, hardwareH264: Bool)
        /// Mac → receiver: size of the video and its parameter sets (SPS and PPS, Annex B). Sent first, and again
        /// after a change of the size.
        case config(width: Int, height: Int, parameterSets: Data)
        /// Mac → receiver: one access unit in Annex B.
        case frame(ptsUs: UInt64, key: Bool, data: Data)
        /// Receiver → Mac: the decoder needs a key frame.
        case keyFrameRequest
        /// Receiver → Mac: the device was rotated; the new screen size in pixels.
        case rotated(width: Int, height: Int)
        /// Receiver → Mac, once a second: the last frame's decode and present time, in microseconds.
        case stats(decodeUs: UInt32, presentUs: UInt32)
        /// Receiver → Mac: a finger event; `x` and `y` are 0...65535 over the picture, `fingers` is how many are down.
        case touch(Touch)
    }

    public struct Touch: Equatable, Sendable {
        public enum Action: UInt8, Sendable { case down = 0, move = 1, up = 2 }
        public var action: Action
        public var fingers: Int
        public var x: Int
        public var y: Int
        /// Milliseconds on the device's clock; only differences are used.
        public var timeMs: UInt32
        public init(action: Action, fingers: Int, x: Int, y: Int, timeMs: UInt32) {
            self.action = action
            self.fingers = fingers
            self.x = x
            self.y = y
            self.timeMs = timeMs
        }
    }

    private enum Kind: UInt8 {
        case hello = 1, config, frame, keyFrameRequest, rotated, stats, touch
    }

    public struct ProtocolError: Error, Equatable {
        public let message: String
    }

    /// `u8 type, u32 length, body`, big endian.
    public static func encode(_ message: Message) -> Data {
        var body = Data()
        let kind: Kind
        switch message {
        case let .hello(version, width, height, hardwareH264):
            kind = .hello
            body += be16(version) + be32(UInt32(width)) + be32(UInt32(height)) + Data([hardwareH264 ? 1 : 0])
        case let .config(width, height, parameterSets):
            kind = .config
            body += be32(UInt32(width)) + be32(UInt32(height)) + parameterSets
        case let .frame(ptsUs, key, data):
            kind = .frame
            body += Data([key ? 1 : 0]) + be32(UInt32(ptsUs >> 32)) + be32(UInt32(ptsUs & 0xFFFF_FFFF)) + data
        case .keyFrameRequest:
            kind = .keyFrameRequest
        case let .rotated(width, height):
            kind = .rotated
            body += be32(UInt32(width)) + be32(UInt32(height))
        case let .stats(decodeUs, presentUs):
            kind = .stats
            body += be32(decodeUs) + be32(presentUs)
        case let .touch(t):
            kind = .touch
            body += Data([t.action.rawValue, UInt8(clamping: t.fingers)]) + be16(UInt16(clamping: t.x))
                + be16(UInt16(clamping: t.y)) + be32(t.timeMs)
        }
        return Data([kind.rawValue]) + be32(UInt32(body.count)) + body
    }

    /// Cuts a byte stream into messages; keeps an incomplete tail for the next call. A message of an unknown
    /// type is skipped (a newer peer), a bad body is an error.
    public struct Parser {
        private var buffer = Data()
        private static let maxBody = 16 << 20

        public init() {}

        public mutating func append(_ data: Data) throws -> [Message] {
            buffer.append(data)
            var out: [Message] = []
            var at = buffer.startIndex
            while buffer.endIndex - at >= 5 {
                let type = buffer[at]
                let length = Int(rd32(buffer, at + 1))
                guard length <= Self.maxBody else { throw ProtocolError(message: "bad message size \(length)") }
                guard buffer.endIndex - (at + 5) >= length else { break }
                let body = Data(buffer[at + 5..<at + 5 + length])
                at += 5 + length
                if let kind = Kind(rawValue: type) { out.append(try Self.message(kind, body)) }
            }
            buffer = Data(buffer[at...])
            return out
        }

        private static func message(_ kind: Kind, _ b: Data) throws -> Message {
            func need(_ n: Int) throws {
                if b.count < n { throw ProtocolError(message: "short message \(kind)") }
            }
            switch kind {
            case .hello:
                try need(11)
                return .hello(version: rd16(b, 0), width: Int(rd32(b, 2)), height: Int(rd32(b, 6)),
                              hardwareH264: b[b.startIndex + 10] & 1 != 0)
            case .config:
                try need(8)
                return .config(width: Int(rd32(b, 0)), height: Int(rd32(b, 4)), parameterSets: Data(b.dropFirst(8)))
            case .frame:
                try need(9)
                let pts = UInt64(rd32(b, 1)) << 32 | UInt64(rd32(b, 5))
                return .frame(ptsUs: pts, key: b[b.startIndex] & 1 != 0, data: Data(b.dropFirst(9)))
            case .keyFrameRequest:
                return .keyFrameRequest
            case .rotated:
                try need(8)
                return .rotated(width: Int(rd32(b, 0)), height: Int(rd32(b, 4)))
            case .stats:
                try need(8)
                return .stats(decodeUs: rd32(b, 0), presentUs: rd32(b, 4))
            case .touch:
                try need(10)
                guard let action = Touch.Action(rawValue: b[b.startIndex]) else {
                    throw ProtocolError(message: "bad touch action")
                }
                return .touch(Touch(action: action, fingers: Int(b[b.startIndex + 1]), x: Int(rd16(b, 2)),
                                    y: Int(rd16(b, 4)), timeMs: rd32(b, 6)))
            }
        }
    }

    // MARK: Display mode

    /// The pixel size of the virtual display for a device screen: the same proportions, at most `maxLongSide`
    /// on the long side, both sides even (the encoder wants it).
    public static func displaySize(forDevice width: Int, _ height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let long = max(width, height)
        let scale = long > maxLongSide ? Double(maxLongSide) / Double(long) : 1
        func even(_ v: Double) -> Int { max(2, Int(v.rounded()) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// Video bitrate in bits per second for the link (design D3).
    public static func bitrate(overUSB: Bool) -> Int { overUSB ? 12_000_000 : 6_000_000 }

    // MARK: Touch → mouse

    /// A mouse event on the virtual display, in display pixels (origin top left).
    public enum MouseEvent: Equatable, Sendable {
        case leftDown(x: Int, y: Int)
        case leftDragged(x: Int, y: Int)
        case leftUp(x: Int, y: Int)
        /// Press and release of the right button (a long touch).
        case rightClick(x: Int, y: Int)
        /// Wheel in pixels at a point: positive `dy` moves the content down (the finger moved down).
        case scroll(x: Int, y: Int, dx: Int, dy: Int)
    }

    /// Turns finger events into mouse events (design D6): one finger touches, drags; two fingers scroll; a touch
    /// held `longPress` without moving is the right button, decided when the finger lifts.
    public struct Gesture {
        public static let longPressMs: UInt32 = 500
        /// A finger that moved this far (display pixels) is a drag, not a touch.
        public static let slop = 12.0

        private enum State {
            case idle
            case pending(x: Int, y: Int, timeMs: UInt32)
            case dragging(x: Int, y: Int)
            case scrolling(x: Int, y: Int)
            /// A scroll went down to one finger: nothing until it lifts.
            case ignoring
        }

        private var state = State.idle
        private let width: Int
        private let height: Int

        public init(displayWidth: Int, displayHeight: Int) {
            width = max(displayWidth, 1)
            height = max(displayHeight, 1)
        }

        private func point(_ t: Touch) -> (x: Int, y: Int) {
            (min(max(t.x * width / 65535, 0), width - 1), min(max(t.y * height / 65535, 0), height - 1))
        }

        public mutating func feed(_ t: Touch) -> [MouseEvent] {
            let p = point(t)
            if t.action == .up {
                defer { state = .idle }
                switch state {
                case let .pending(x, y, start):
                    return t.timeMs &- start >= Self.longPressMs
                        ? [.rightClick(x: x, y: y)] : [.leftDown(x: x, y: y), .leftUp(x: x, y: y)]
                case .dragging: return [.leftUp(x: p.x, y: p.y)]
                default: return []
                }
            }
            switch state {
            case .idle:
                state = t.fingers >= 2 ? .scrolling(x: p.x, y: p.y) : .pending(x: p.x, y: p.y, timeMs: t.timeMs)
                return []
            case let .pending(x, y, _):
                if t.fingers >= 2 {
                    state = .scrolling(x: p.x, y: p.y)
                    return []
                }
                guard hypot(Double(p.x - x), Double(p.y - y)) > Self.slop else { return [] }
                state = .dragging(x: p.x, y: p.y)
                return [.leftDown(x: x, y: y), .leftDragged(x: p.x, y: p.y)]
            case let .dragging(lx, ly):
                if t.fingers >= 2 {
                    state = .scrolling(x: p.x, y: p.y)
                    return [.leftUp(x: lx, y: ly)]
                }
                state = .dragging(x: p.x, y: p.y)
                return [.leftDragged(x: p.x, y: p.y)]
            case let .scrolling(lx, ly):
                if t.fingers < 2 {
                    state = .ignoring
                    return []
                }
                state = .scrolling(x: p.x, y: p.y)
                let dx = p.x - lx, dy = p.y - ly
                return dx == 0 && dy == 0 ? [] : [.scroll(x: p.x, y: p.y, dx: dx, dy: dy)]
            case .ignoring:
                return []
            }
        }
    }

    // MARK: Byte helpers

    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}

private func rd16(_ d: Data, _ i: Int) -> UInt16 {
    let s = d.startIndex + i
    return UInt16(d[s]) << 8 | UInt16(d[s + 1])
}

private func rd32(_ d: Data, _ i: Int) -> UInt32 {
    let s = d.startIndex + i
    return UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3])
}
