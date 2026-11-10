import Foundation

/// The motion camera app on an Android device (openspec/changes/add-android-motion-camera, design D5, D6):
/// what the Mac sends to it and how it reads its state, without a device.
public enum MotionCamera {
    public static let package = "com.universalkm.motion"
    public static let statusURI = "content://\(package)/status"
    /// Where the clips are, relative to the shared storage (`/sdcard`).
    public static let clipsFolder = ["Movies", "UniversalKM Motion"]

    /// `adb shell` words that read the state.
    public static var statusCommand: [String] { ["content", "query", "--uri", statusURI] }

    /// `adb shell` words that report the installed version.
    public static var versionCommand: [String] { ["pm", "list", "packages", "--show-versioncode", package] }

    /// `adb shell` words run after an install and before every switch-on (design D6): opening the camera from
    /// the background after a restart, no battery restrictions. Each is a separate command.
    public static var permissionCommands: [[String]] {
        [["appops", "set", package, "SYSTEM_ALERT_WINDOW", "allow"],
         ["cmd", "appops", "set", package, "RUN_ANY_IN_BACKGROUND", "allow"],
         ["dumpsys", "deviceidle", "whitelist", "+\(package)"]]
    }

    /// The installed versionCode from `pm list packages --show-versioncode`; nil = not installed.
    public static func installedVersion(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.first == "package:\(package)" else { continue }
            for w in words where w.hasPrefix("versionCode:") { return Int(w.dropFirst("versionCode:".count)) }
        }
        return nil
    }

    /// `adb install` refused because the phone wants the install confirmed on its screen
    /// (Xiaomi, some Samsung: "Install via USB").
    public static func needsConfirmationOnDevice(_ installOutput: String) -> Bool {
        installOutput.contains("INSTALL_FAILED_USER_RESTRICTED") || installOutput.contains("INSTALL_FAILED_ABORTED")
            || installOutput.contains("INSTALL_FAILED_VERIFICATION_FAILURE")
    }

    /// The exact `adb shell` words that start ControlActivity with `on` and the settings (design D5).
    public static func command(on: Bool?, settings: MotionSettings?) -> [String] {
        var words = ["am", "start", "-n", "\(package)/.ControlActivity"]
        if let on { words += ["--ez", "on", on ? "true" : "false"] }
        if let s = settings {
            words += ["--es", "sens", s.sensitivity.rawValue,
                      "--ei", "stop", String(s.stopSeconds),
                      "--es", "cam", s.camera.rawValue,
                      "--ei", "q", String(s.quality.rawValue),
                      "--el", "limitMB", String(s.limitMB)]
        }
        return words
    }
}

public struct MotionSettings: Equatable, Sendable {
    public enum Sensitivity: String, CaseIterable, Sendable { case low, mid, high }
    public enum Camera: String, CaseIterable, Sendable { case back, front }
    public enum Quality: Int, CaseIterable, Sendable { case hd = 720, fullHD = 1080 }

    public var sensitivity: Sensitivity = .mid
    /// 5–60 s without motion before a clip ends.
    public var stopSeconds = 10
    public var camera: Camera = .back
    public var quality: Quality = .hd
    public var limitMB = 4096

    public static let stopRange = 5...60
    public static let limitChoicesMB = [1024, 2048, 4096, 8192, 16384, 32768]

    public init() {}
}

/// One row of `content query --uri content://com.universalkm.motion/status`.
public struct MotionStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case off, starting, watching, recording
        case noCamera = "no_camera", noPermission = "no_permission", lowSpace = "low_space"
        case batteryLow = "battery_low", stopped, error
        case unknown
    }

    public var state: State = .unknown
    public var on = false
    public var clips = 0
    public var bytes: Int64 = 0
    public var free: Int64 = 0
    public var battery = -1
    public var charging = false
    public var version = 0
    public var settings = MotionSettings()

    public init() {}

    /// Parses `Row: 0 state=watching, on=1, clips=12, …`; nil when there is no row (app missing, old adb).
    /// Unknown keys are ignored, missing ones keep their defaults, so newer and older apps both parse.
    public static func parse(_ output: String) -> MotionStatus? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Row: ") }) else { return nil }
        var fields: [String: String] = [:]
        var rest = line.drop(while: { $0 != " " }).dropFirst() // "0 state=…"
        rest = rest.drop(while: { $0 != " " }).dropFirst()
        for part in rest.components(separatedBy: ", ") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard fields["state"] != nil else { return nil }
        var s = MotionStatus()
        s.state = fields["state"].flatMap(State.init(rawValue:)) ?? .unknown
        s.on = fields["on"] == "1"
        s.clips = fields["clips"].flatMap { Int($0) } ?? 0
        s.bytes = fields["bytes"].flatMap { Int64($0) } ?? 0
        s.free = fields["free"].flatMap { Int64($0) } ?? 0
        s.battery = fields["battery"].flatMap { Int($0) } ?? -1
        s.charging = fields["charging"] == "1"
        s.version = fields["version"].flatMap { Int($0) } ?? 0
        if let v = fields["sens"].flatMap(MotionSettings.Sensitivity.init(rawValue:)) { s.settings.sensitivity = v }
        if let v = fields["stop"].flatMap({ Int($0) }) { s.settings.stopSeconds = v }
        if let v = fields["cam"].flatMap(MotionSettings.Camera.init(rawValue:)) { s.settings.camera = v }
        if let v = fields["q"].flatMap({ Int($0) }).flatMap(MotionSettings.Quality.init(rawValue:)) { s.settings.quality = v }
        if let v = fields["limitMB"].flatMap({ Int($0) }) { s.settings.limitMB = v }
        return s
    }
}
