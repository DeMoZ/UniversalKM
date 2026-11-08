import Foundation

/// Commands for Android's built-in `/system/bin/hid` tool (design D5). Run as `adb shell hid -`, it
/// reads one JSON object after another from stdin and drives a UHID device: `register` creates it,
/// `report` sends an input report, closing stdin removes it.
public enum HidCommand {
    /// Generic "pid.codes" test vendor; Android only uses the IDs to name the device.
    public static let vendorID = 0x1209
    public static let productID = 0x0001
    public static let deviceName = "UniversalKM"
    public static let deviceID = 1

    /// `bus` is understood from Android 12; older `hid` versions reject unknown fields, so the
    /// caller retries without it (design D5).
    public static func register(descriptor: [UInt8] = HIDReportDescriptor.reportMap, withBus: Bool = true) -> String {
        var line = #"{"id":\#(deviceID),"command":"register","name":"\#(deviceName)","vid":\#(vendorID),"pid":\#(productID),"#
        if withBus { line += #""bus":"bluetooth","# }
        line += #""descriptor":[\#(numbers(descriptor))]}"#
        return line + "\n"
    }

    /// One input report, report ID first (`AndroidHIDEvent`).
    public static func report(_ event: [UInt8]) -> String {
        #"{"id":\#(deviceID),"command":"report","report":[\#(numbers(event))]}"# + "\n"
    }

    private static func numbers(_ bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ",")
    }
}
