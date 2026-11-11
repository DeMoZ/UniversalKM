import CoreGraphics
import Foundation

/// The phone's screen on the Mac (openspec/changes/add-android-screen-mirror): the scrcpy-server protocol, read
/// and written without a device. The server is the unchanged scrcpy-server of `serverVersion` (design D1); its
/// protocol has no compatibility between versions, so everything here belongs to that version.
public enum ScreenMirror {
    /// Must match `scripts/fetch-scrcpy-server.sh`: the server refuses a client of another version.
    public static let serverVersion = "5.0.1"
    public static let mainClass = "com.genymobile.scrcpy.Server"
    /// Where the server lives on the device (readable and writable by `shell`, not by apps).
    public static let remotePath = "/data/local/tmp/ukm-scrcpy-server-\(serverVersion).jar"
    /// Codec id of H.264 on the video socket ("h264").
    public static let h264: UInt32 = 0x6832_3634

    /// The server's local socket for one session; `scid` is 31 bits.
    public static func socket(scid: UInt32) -> String {
        "localabstract:scrcpy_" + String(format: "%08x", scid & 0x7FFF_FFFF)
    }

    /// The `adb shell` command that runs the server (design D2). Video and control, no audio; the Mac connects
    /// (forward tunnel); the clipboard stays with the app's own helper.
    public static func serverCommand(scid: UInt32, maxSize: Int = 1920) -> String {
        let options = [
            "scid=" + String(format: "%08x", scid & 0x7FFF_FFFF),
            "log_level=info",
            "audio=false",
            "control=true",
            "tunnel_forward=true",
            "send_device_meta=false",
            "clipboard_autosync=false",
            "video_codec=h264",
            "max_size=\(maxSize)",
        ]
        return "CLASSPATH=\(remotePath) app_process / \(mainClass) \(serverVersion) " + options.joined(separator: " ")
    }

    public enum Packet: Equatable, Sendable {
        /// The video codec id, once, at the start. 0 and 1 mean the server turned video off (1: an error).
        case codec(UInt32)
        /// A new capture: the frame size (after a rotation, too).
        case session(width: Int, height: Int)
        /// The encoder's parameter sets (SPS and PPS) in Annex B.
        case config(Data)
        /// One access unit in Annex B.
        case frame(ptsUs: Int64, key: Bool, data: Data)
    }

    public struct ProtocolError: Error, Equatable {
        public let message: String
    }

    /// Cuts the video socket's bytes into packets: the dummy byte of the forward tunnel, the codec id, then
    /// 12-byte headers with their payloads. Keeps an incomplete tail for the next call.
    public struct Parser {
        private enum Stage { case dummy, codec, packets }
        private var stage: Stage
        private var buffer = Data()
        private static let maxPayload = 16 << 20

        public init(dummyByte: Bool = true) {
            stage = dummyByte ? .dummy : .codec
        }

        public mutating func append(_ data: Data) throws -> [Packet] {
            buffer.append(data)
            var out: [Packet] = []
            var at = buffer.startIndex
            loop: while true {
                switch stage {
                case .dummy:
                    guard at < buffer.endIndex else { break loop }
                    guard buffer[at] == 0 else { throw ProtocolError(message: "no dummy byte") }
                    at += 1
                    stage = .codec
                case .codec:
                    guard let id = u32(at) else { break loop }
                    out.append(.codec(id))
                    at += 4
                    stage = .packets
                case .packets:
                    guard buffer.endIndex - at >= 12, let high = u32(at), let low = u32(at + 4), let size = u32(at + 8)
                    else { break loop }
                    if high & 0x8000_0000 != 0 {
                        out.append(.session(width: Int(low), height: Int(size)))
                        at += 12
                        continue
                    }
                    guard size <= Self.maxPayload else { throw ProtocolError(message: "bad packet size \(size)") }
                    let length = Int(size)
                    guard buffer.endIndex - (at + 12) >= length else { break loop }
                    let payload = Data(buffer[at + 12..<at + 12 + length])
                    if high & 0x4000_0000 != 0 {
                        out.append(.config(payload))
                    } else {
                        let pts = Int64(high & 0x1FFF_FFFF) << 32 | Int64(low)
                        out.append(.frame(ptsUs: pts, key: high & 0x2000_0000 != 0, data: payload))
                    }
                    at += 12 + length
                }
            }
            buffer = Data(buffer[at...])
            return out
        }

        private func u32(_ i: Int) -> UInt32? {
            guard buffer.endIndex - i >= 4 else { return nil }
            return UInt32(buffer[i]) << 24 | UInt32(buffer[i + 1]) << 16 | UInt32(buffer[i + 2]) << 8 | UInt32(buffer[i + 3])
        }
    }

    /// SPS and PPS (without start codes) from a config packet; nil if one of them is missing.
    public static func parameterSets(_ annexB: Data) -> (sps: Data, pps: Data)? {
        var sps: Data?, pps: Data?
        for nal in MotionLive.nalUnits(annexB) {
            switch nal.first.map({ $0 & 0x1F }) {
            case 7: sps = sps ?? nal
            case 8: pps = pps ?? nal
            default: break
            }
        }
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }

    /// Where a point of the view falls on the video, in video pixels; nil on the black bars around it. The
    /// view shows the video fitted with its proportions kept (`resizeAspect`); `point` has its origin at the
    /// top left.
    public static func videoPoint(_ point: CGPoint, view: CGSize, video: CGSize) -> (x: Int, y: Int)? {
        guard view.width > 0, view.height > 0, video.width > 0, video.height > 0 else { return nil }
        let scale = min(view.width / video.width, view.height / video.height)
        let shown = CGSize(width: video.width * scale, height: video.height * scale)
        let origin = CGPoint(x: (view.width - shown.width) / 2, y: (view.height - shown.height) / 2)
        let x = (point.x - origin.x) / scale, y = (point.y - origin.y) / scale
        guard x >= 0, y >= 0, x < video.width, y < video.height else { return nil }
        return (Int(x), Int(y))
    }

    /// Like `videoPoint`, but a point on the bars goes to the nearest edge: a drag that leaves the picture
    /// keeps moving the finger along the edge, and its release is never lost.
    public static func clampedVideoPoint(_ point: CGPoint, view: CGSize, video: CGSize) -> (x: Int, y: Int) {
        guard view.width > 0, view.height > 0, video.width > 0, video.height > 0 else { return (0, 0) }
        let scale = min(view.width / video.width, view.height / video.height)
        let origin = CGPoint(x: (view.width - video.width * scale) / 2, y: (view.height - video.height * scale) / 2)
        let x = min(max((point.x - origin.x) / scale, 0), video.width - 1)
        let y = min(max((point.y - origin.y) / scale, 0), video.height - 1)
        return (Int(x), Int(y))
    }

    /// Control messages from the Mac to the server (scrcpy `app/src/control_msg.c`).
    public enum Control {
        public enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2 }
        public enum KeyAction: UInt8, Sendable { case down = 0, up = 1 }

        /// Android key codes the window sends.
        public enum Key: Int32, Sendable {
            case home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, tab = 61, enter = 66, delete = 67
            case forwardDelete = 112, appSwitch = 187
        }

        /// The server takes at most this many bytes of text in one message.
        public static let textLimit = 300

        /// A finger on the screen: pointer "mouse" with the primary button, which the server injects as a
        /// touch. `width`/`height` are the frame size: the server ignores events for an older size.
        public static func touch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int) -> Data {
            var d = Data([2, action.rawValue])
            d += be64(UInt64.max) // POINTER_ID_MOUSE (-1)
            d += position(x, y, width, height)
            d += be16(action == .up ? 0 : 0xFFFF) // pressure 1.0 while down
            let primary: UInt32 = 1 // AMOTION_EVENT_BUTTON_PRIMARY
            d += be32(action == .move ? 0 : primary) // action button
            d += be32(action == .up ? 0 : primary) // buttons held
            return d
        }

        /// Scroll at a point; `horizontal` and `vertical` are in wheel clicks, -16...16 (positive: up, right).
        public static func scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double) -> Data {
            var d = Data([3])
            d += position(x, y, width, height)
            d += be16(UInt16(bitPattern: i16fp(horizontal / 16)))
            d += be16(UInt16(bitPattern: i16fp(vertical / 16)))
            d += be32(0)
            return d
        }

        public static func key(_ action: KeyAction, _ key: Key, metaState: Int32 = 0) -> Data {
            var d = Data([0, action.rawValue])
            d += be32(UInt32(bitPattern: key.rawValue))
            d += be32(0) // repeat
            d += be32(UInt32(bitPattern: metaState))
            return d
        }

        /// Text typed into the focused field; cut at `textLimit` bytes without splitting a character.
        public static func text(_ s: String) -> Data {
            var bytes = 0
            var kept = ""
            for c in s {
                let n = String(c).utf8.count
                if bytes + n > textLimit { break }
                bytes += n
                kept.append(c)
            }
            return Data([1]) + be32(UInt32(bytes)) + Data(kept.utf8)
        }

        /// "Back", or "turn the screen on" while it is off.
        public static func backOrScreenOn(_ action: KeyAction) -> Data {
            Data([4, action.rawValue])
        }

        private static func position(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Data {
            be32(UInt32(bitPattern: Int32(clamping: x))) + be32(UInt32(bitPattern: Int32(clamping: y)))
                + be16(UInt16(clamping: w)) + be16(UInt16(clamping: h))
        }

        private static func i16fp(_ f: Double) -> Int16 {
            let i = Int32(min(max(f, -1), 1) * 32768)
            return Int16(min(i, 0x7FFF))
        }

        private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
        private static func be32(_ v: UInt32) -> Data {
            Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
        }
        private static func be64(_ v: UInt64) -> Data { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }
    }
}
