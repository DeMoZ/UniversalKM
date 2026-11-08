import Foundation

/// ChameleonUltra USB frame (`netdata` of the upstream firmware, design D5):
///
///     SOF 0x11 | LRC1 | cmd u16 BE | status u16 BE | length u16 BE | LRC2 | data… | LRC3
///
/// LRC1 covers SOF, LRC2 the first 8 bytes, LRC3 the data. LRC = two's complement of the byte sum.
public struct ChameleonFrame: Equatable, Sendable {
    public static let sof: UInt8 = 0x11
    public static let headerLength = 9
    public static let maxDataLength = 4096

    public var command: UInt16
    public var status: UInt16
    public var data: [UInt8]

    public init(command: UInt16, status: UInt16 = 0, data: [UInt8] = []) {
        self.command = command
        self.status = status
        self.data = data
    }

    public init(_ command: ChameleonCommand, data: [UInt8] = []) {
        self.init(command: command.rawValue, data: data)
    }

    public static func lrc<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var sum: UInt8 = 0
        for byte in bytes { sum &+= byte }
        return 0 &- sum
    }

    public var encoded: [UInt8] {
        var out: [UInt8] = [Self.sof, Self.lrc([Self.sof])]
        out += [UInt8(command >> 8), UInt8(command & 0xFF)]
        out += [UInt8(status >> 8), UInt8(status & 0xFF)]
        out += [UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
        out.append(Self.lrc(out))
        out += data
        out.append(Self.lrc(data))
        return out
    }

    public var knownStatus: ChameleonStatus? { ChameleonStatus(rawValue: status) }
}

/// Commands the app uses: upstream ones and the UniversalKM HID mode (firmware/src/ukm_hid.h).
public enum ChameleonCommand: UInt16, Sendable {
    case getAppVersion = 1000
    case getGitVersion = 1017
    case hidGetInfo = 9000
    case hidSetEnabled = 9001
    case hidKeyboard = 9002
    case hidMouse = 9003
    case hidState = 9004
    case hidDiagnostics = 9005
    case hidCounters = 9006
}

/// Response statuses (upstream app_status.h plus the HID mode ones).
public enum ChameleonStatus: UInt16, Sendable {
    case parameterError = 0x60
    case invalidCommand = 0x67     // the firmware has no such command (official firmware for 9000+)
    case success = 0x68
    case busy = 0xA0               // BLE notification queue full: retry shortly
    case notConnected = 0xA1       // HID mode off, or the target host is not connected / subscribed
}

/// Assembles frames from a byte stream that may arrive in pieces and may contain garbage:
/// bytes before a SOF are skipped, and a frame with a bad LRC is dropped (scanning resumes
/// right after its SOF byte).
public struct ChameleonFrameParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append<C: Collection>(_ bytes: C) -> [ChameleonFrame] where C.Element == UInt8 {
        buffer += bytes
        var frames: [ChameleonFrame] = []
        while let result = nextFrame() {
            if let frame = result { frames.append(frame) }
        }
        return frames
    }

    public mutating func reset() { buffer.removeAll() }

    /// nil: need more bytes. .some(nil): dropped bytes, try again. .some(frame): a frame.
    private mutating func nextFrame() -> ChameleonFrame?? {
        guard let start = buffer.firstIndex(of: ChameleonFrame.sof) else {
            buffer.removeAll()
            return nil
        }
        if start > 0 { buffer.removeFirst(start) }
        guard buffer.count >= 2 else { return nil }
        guard buffer[1] == ChameleonFrame.lrc([ChameleonFrame.sof]) else { return dropSOF() }
        guard buffer.count >= ChameleonFrame.headerLength else { return nil }
        guard buffer[8] == ChameleonFrame.lrc(buffer[0..<8]) else { return dropSOF() }
        let length = Int(buffer[6]) << 8 | Int(buffer[7])
        guard length <= ChameleonFrame.maxDataLength else { return dropSOF() }
        let total = ChameleonFrame.headerLength + length + 1
        guard buffer.count >= total else { return nil }
        let data = Array(buffer[ChameleonFrame.headerLength..<(ChameleonFrame.headerLength + length)])
        guard buffer[total - 1] == ChameleonFrame.lrc(data) else { return dropSOF() }
        let frame = ChameleonFrame(
            command: UInt16(buffer[2]) << 8 | UInt16(buffer[3]),
            status: UInt16(buffer[4]) << 8 | UInt16(buffer[5]),
            data: data
        )
        buffer.removeFirst(total)
        return .some(frame)
    }

    private mutating func dropSOF() -> ChameleonFrame?? {
        buffer.removeFirst()
        return .some(nil)
    }
}

// MARK: - HID mode (protocol version 2)

public enum ChameleonHID {
    /// Lowest firmware HID protocol the app works with (several hosts, addressed reports).
    public static let protocolVersion: UInt8 = 2
    /// Peer ID of a host that is connected but not bonded yet.
    public static let unbondedPeerID: UInt16 = 0xFFFF

    public static func setEnabled(_ enabled: Bool) -> ChameleonFrame {
        ChameleonFrame(.hidSetEnabled, data: [enabled ? 1 : 0])
    }

    public static func keyboard(_ report: KeyboardReport, to peerID: UInt16) -> ChameleonFrame {
        ChameleonFrame(.hidKeyboard, data: peerBytes(peerID) + report.bytes)
    }

    public static func mouse(_ report: MouseReport, to peerID: UInt16) -> ChameleonFrame {
        ChameleonFrame(.hidMouse, data: peerBytes(peerID) + report.bytes)
    }

    static func peerBytes(_ peerID: UInt16) -> [UInt8] { [UInt8(peerID >> 8), UInt8(peerID & 0xFF)] }
}

/// Reply to UKM_HID_GET_INFO: `[version, enabled, hostCount, maxHosts]`.
public struct ChameleonHIDInfo: Equatable, Sendable {
    public var protocolVersion: UInt8
    public var isEnabled: Bool
    public var hostCount: Int
    public var maxHosts: Int

    public init?(_ data: [UInt8]) {
        guard data.count >= 4 else { return nil }
        protocolVersion = data[0]
        isEnabled = data[1] != 0
        hostCount = Int(data[2])
        maxHosts = Int(data[3])
    }

    public var isSupported: Bool { protocolVersion >= ChameleonHID.protocolVersion }
}

/// One connected host in UKM_HID_STATE.
public struct ChameleonHost: Equatable, Sendable, Identifiable {
    public enum State: UInt8, Sendable {
        case connected = 2      // connected, not subscribed to reports (yet)
        case subscribed = 3     // reports are delivered
    }

    /// Peer Manager peer ID: stable for a bonded host. nil until the host has bonded.
    public var peerID: UInt16?
    /// BLE address as sent (little-endian); random and changing for phones, for display only.
    public var address: [UInt8]
    public var state: State

    public var id: String { peerID.map { "peer-\($0)" } ?? "addr-" + addressString }

    /// "7d:34:68:d8:66:88" (most significant byte first).
    public var addressString: String { address.reversed().map { String(format: "%02x", $0) }.joined(separator: ":") }
}

/// Reply to UKM_HID_STATE: `[enabled, advertising, n] + n × [peerID u16 BE, address 6, state]`.
public struct ChameleonHIDState: Equatable, Sendable {
    public var isEnabled: Bool
    public var isAdvertising: Bool
    public var hosts: [ChameleonHost]

    public init(isEnabled: Bool, isAdvertising: Bool, hosts: [ChameleonHost]) {
        self.isEnabled = isEnabled
        self.isAdvertising = isAdvertising
        self.hosts = hosts
    }

    public init?(_ data: [UInt8]) {
        guard data.count >= 3 else { return nil }
        let count = Int(data[2])
        guard data.count >= 3 + count * 9 else { return nil }
        var hosts: [ChameleonHost] = []
        for index in 0..<count {
            let entry = Array(data[(3 + index * 9)..<(3 + index * 9 + 9)])
            let peer = UInt16(entry[0]) << 8 | UInt16(entry[1])
            guard let state = ChameleonHost.State(rawValue: entry[8]) else { return nil }
            hosts.append(ChameleonHost(
                peerID: peer == ChameleonHID.unbondedPeerID ? nil : peer,
                address: Array(entry[2..<8]),
                state: state
            ))
        }
        self.init(isEnabled: data[0] != 0, isAdvertising: data[1] != 0, hosts: hosts)
    }

    /// Bonded hosts that receive reports.
    public var subscribedPeerIDs: Set<UInt16> {
        Set(hosts.compactMap { $0.state == .subscribed ? $0.peerID : nil })
    }
}

/// Data of a reply to UKM_HID_KEYBOARD / UKM_HID_MOUSE: `[state of the target host, host count]`.
public struct ChameleonReportReply: Equatable, Sendable {
    /// 0 mode off, 1 target not connected, 2 connected, 3 subscribed.
    public var targetState: UInt8
    public var hostCount: Int

    public init?(_ data: [UInt8]) {
        guard data.count >= 2 else { return nil }
        targetState = data[0]
        hostCount = Int(data[1])
    }
}
