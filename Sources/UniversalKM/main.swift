import AppKit
import os

// Temporary AppKit bootstrap for step 1 (BLE HID only). Step 3 replaces it with the
// SwiftUI MenuBarExtra app.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "app")
    let server = BluetoothHIDServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("launched, arguments: \(CommandLine.arguments, privacy: .public)")
        server.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
