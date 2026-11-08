import Foundation
import UniversalKMCore

/// Where HID reports go (design D5). Modules 2–3 talk only to this protocol; ChameleonHIDTransport
/// implements it over USB. All methods are thread-safe and return at once; work happens on the
/// transport's own queue. Reports are addressed to a bonded host by its peer ID.
protocol HIDTransport: AnyObject, Sendable {
    /// Starts watching for the device. Status changes arrive through the handler given at creation.
    func start()

    /// Turns the HID mode of the device on or off (on also after every reconnect of the device).
    func setEnabled(_ enabled: Bool)

    /// Relative motion in points; fractions are carried over (MouseAccumulator).
    func moveMouse(dx: Double, dy: Double, to peerID: UInt16)
    /// Scroll in wheel clicks; fractions are carried over.
    func scroll(wheel: Double, pan: Double, to peerID: UInt16)
    func setButtons(_ buttons: MouseButtons, to peerID: UInt16)
    /// Key press or release by HID usage (modifiers 0xE0…0xE7 included).
    func key(usage: UInt8, isDown: Bool, to peerID: UInt16)
    /// Releases every key and button on the host and drops pending motion.
    func sendNeutral(to peerID: UInt16)

    /// Synchronous shutdown for quitting (design D13): turns the HID mode off, waiting up to `timeout`.
    func shutdown(timeout: TimeInterval)
}

enum TransportStatus: Equatable, Sendable {
    /// No ChameleonUltra on USB (or its port is held by another program).
    case notConnected
    /// The firmware has no HID mode or an older protocol; the detail is for the log.
    case unsupportedFirmware(String)
    /// HID mode protocol is supported; the state lists the connected hosts.
    case ready(ChameleonHIDState)
}
