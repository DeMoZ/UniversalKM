import Foundation

/// Battery of an Android device, from `dumpsys battery` over adb.
public struct AndroidBattery: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case charging
        /// Charged to the top and still on the charger.
        case full
        /// On the charger, but not taking charge (battery protection, too hot, weak charger).
        case notCharging
        case discharging
    }

    /// 0…100.
    public var percent: Int
    public var state: State

    public init(percent: Int, state: State) {
        self.percent = percent
        self.state = state
    }

    public var isPlugged: Bool { state != .discharging }

    /// `dumpsys battery` output:
    /// ```
    /// Current Battery Service state:
    ///   AC powered: false
    ///   USB powered: true
    ///   Wireless powered: false
    ///   status: 2
    ///   level: 85
    ///   scale: 100
    /// ```
    /// Status codes are BatteryManager's: 2 charging, 3 discharging, 4 not charging, 5 full.
    /// nil when there is no level.
    public static func parse(_ output: String) -> AndroidBattery? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // The first one wins: some phones list a second battery (a pen, a dock) further down.
            if fields[name] == nil { fields[name] = value }
        }
        guard let level = fields["level"].flatMap(Int.init), level >= 0 else { return nil }
        let scale = fields["scale"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 100
        let percent = min(100, max(0, Int((Double(level) * 100 / Double(scale)).rounded())))
        let plugged = ["ac powered", "usb powered", "wireless powered", "dock powered"].contains { fields[$0] == "true" }
        let state: State = switch fields["status"].flatMap(Int.init) {
        case 2: .charging
        case 5: plugged ? .full : .discharging
        case 4: plugged ? .notCharging : .discharging
        case 3: .discharging
        default: plugged ? .charging : .discharging
        }
        return AndroidBattery(percent: percent, state: state)
    }
}
