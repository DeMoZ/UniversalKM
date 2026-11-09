import Foundation

/// The adb host protocol (add-android-file-browser design D1), as in adb's OVERVIEW.TXT and
/// SERVICES.TXT: a request is 4 hex digits of length and the text; the server answers "OKAY", or
/// "FAIL" with 4 hex digits of length and a message. Encoding and parsing only; no I/O.
public enum ADBProtocol {
    /// "host:version" → "000chost:version".
    public static func request(_ text: String) -> Data {
        let body = Data(text.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    /// The 4 hex digits of a length; nil when they are not hex.
    public static func hexLength(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        return Int(String(decoding: data, as: UTF8.self), radix: 16)
    }

    public enum Status: Equatable, Sendable {
        case okay
        /// "FAIL": the 4 hex digits of the message length follow.
        case fail
    }

    /// The 4-byte status word; nil for anything else (the connection is out of step).
    public static func status(_ data: Data) -> Status? {
        switch String(decoding: data, as: UTF8.self) {
        case "OKAY": .okay
        case "FAIL": .fail
        default: nil
        }
    }

    /// `host-serial:<s>:features` → "shell_v2,cmd,stat_v2,ls_v2,…".
    public static func features(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}

/// adb errors as the file client reports them (design D7).
public enum ADBFileError: Error, Equatable, Sendable {
    /// No adb server, or the device is not one of its transports.
    case notConnected
    /// The socket closed or broke in the middle of an operation.
    case connectionLost
    /// "FAIL" from the server or the device, with its message.
    case failed(String)
    /// A shell command exited with a non-zero code; its output.
    case shell(Int, String)
    /// Stopped by the user.
    case cancelled
    /// The answer did not follow the protocol.
    case protocolError(String)
}
