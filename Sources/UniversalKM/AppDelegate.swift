import AppKit
import os
import Sparkle
import SwiftUI
import UniversalKMCore

/// Owns the long-lived parts of the app. Step 3 moves state into AppStateManager.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "app")

    /// "0.1.0" from the bundle; empty for a `swift run` build.
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// `--ble-demo`: the BLE demo mode of task 1.12 (sends a test pattern to the phone).
    let isBLEDemo = CommandLine.arguments.contains("--ble-demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("launched \(self.version, privacy: .public), arguments: \(CommandLine.arguments, privacy: .public)")
        setUpStatusItem()
        transport.start()
        startCapture()
        cableDevices.start()
        // `--open-panel`: opens the panel on launch (manual UI checks and window snapshots).
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePanel() }
        }
    }

    // MARK: State (design D13)

    private(set) lazy var state: AppStateManager = AppStateManager(transport: transport, android: android, demoBindsAll: isBLEDemo)

    private func startCapture() {
        state.onModeChange = { [weak self] device in
            // Mac mode: the app's own menu bar icon; Device mode: the kind of device input goes to.
            self?.statusItem?.button?.image = device == nil ? StatusIcon.make() : NSImage(
                systemSymbolName: device?.kind == .tablet ? "ipad" : "iphone",
                accessibilityDescription: "UniversalKM")
        }
        state.start()
    }

    // MARK: Transports: Android (USB, Wi‑Fi) and ChameleonUltra (design D5; add-android-usb-transport D1)

    /// Latest Chameleon status, for the panel (task 3.3).
    @Published private(set) var transportStatus = TransportStatus.notConnected

    private lazy var chameleon: ChameleonHIDTransport = ChameleonHIDTransport { [weak self] status in
        Task { @MainActor in
            self?.transportStatus = status
            self?.state.transportChanged(status)
            self?.demo?.peersChanged(self?.state.subscribedPeers ?? [])
        }
    }

    private(set) lazy var android: AndroidHIDTransport = AndroidHIDTransport { [weak self] status in
        Task { @MainActor in
            self?.state.androidChanged(status)
            self?.fileBrowsers.update(status)
            self?.motionCameras.update(status)
            self?.demo?.peersChanged(self?.state.subscribedPeers ?? [])
        }
    }

    private(set) lazy var transport: HIDTransport = CompositeHIDTransport(chameleon: chameleon, android: android)

    // MARK: Android files (add-android-file-browser)

    private let fileBrowsers = FileBrowsers()

    // MARK: Motion camera (add-android-motion-camera)

    let motionCameras = MotionCameras()
    private lazy var motionWindows = MotionCameraWindows(cameras: motionCameras) { [weak self] peer in
        self?.openRecordings(peer: peer)
    }

    /// "Files…" in the panel: the window of the device bound to `device`.
    /// "Motion Camera…" in the panel (add-android-motion-camera design D8): the camera window of the device.
    func openMotionCamera(_ device: PlacedDevice) {
        guard let peer = device.hostPeerID else { return }
        closePanel()
        motionWindows.show(peer: peer, name: device.displayName)
    }

    /// "Recordings…" in the camera window: the file window on the clips folder.
    func openRecordings(peer: UInt16) {
        guard let android = state.androidStatus.device(peer) else { return }
        let name = state.arrangement.devices.first { $0.hostPeerID == peer }?.displayName ?? android.name
        fileBrowsers.show(key: android.serial, name: name, folder: RemotePath(MotionCamera.clipsFolder))
    }

    func openFiles(_ device: PlacedDevice) {
        guard let peer = device.hostPeerID, let android = state.androidStatus.device(peer) else { return }
        closePanel()
        fileBrowsers.show(key: android.serial, name: device.displayName)
    }

    private let photoBrowsers = PhotoBrowsers()
    /// The name of an iPhone or iPad on the cable, for "iPhone Photos…" in the panel (design D2).
    @Published private(set) var appleDeviceOnCable: String?
    private lazy var cableDevices = AppleDevicesOnCable { [weak self] name in self?.appleDeviceOnCable = name }

    /// "Photos…" in the panel (add-iphone-photo-browser design D2): the iPhone on the cable.
    func openPhotos() {
        closePanel()
        photoBrowsers.show()
    }

    /// `--ble-demo` only (task 1.12).
    private lazy var demo: BLEDemo? = isBLEDemo ? BLEDemo(transport: transport) : nil

    // MARK: Menu bar icon and panel (design D13)

    private var statusItem: NSStatusItem?
    private let panel = NSPopover()

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.make()
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        // Closes when the user clicks anywhere else, like a menu.
        panel.behavior = .transient
        panel.animates = false
        panel.delegate = self
        let content = NSHostingController(rootView: MenuBarView(app: self, state: state, donate: donateModel))
        // The popover follows the SwiftUI content's size (e.g. when the donate section opens).
        content.sizingOptions = [.preferredContentSize]
        panel.contentViewController = content
    }

    /// When the transient popover last closed. A click on the icon while the panel is open first closes
    /// the panel (mouse down outside the popover), then reaches the icon's action: without this check
    /// the action would open the panel again at once.
    private var panelClosedAt = Date.distantPast

    @objc private func togglePanel() {
        if panel.isShown {
            panel.performClose(nil)
        } else if Date().timeIntervalSince(panelClosedAt) < 0.3 {
            return
        } else if let button = statusItem?.button {
            // An agent app is not active by default; activate it so the panel takes clicks and keys.
            NSApp.activate()
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func closePanel() {
        panel.performClose(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("terminating")
        // Cursor back on the Mac first, then hosts get neutral reports and are disconnected (design D13).
        state.input.release(.quit)
        state.clipboard.shutdown()
        transport.shutdown(timeout: 0.3)
        // Files opened from the file window (add-android-file-browser design D8).
        try? FileManager.default.removeItem(at: FileBrowserModel.temporaryRoot)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Ways to donate shown in the panel (design D18).
    let donateModel = DonateModel()

    // MARK: Updates (design D17)

    /// Sparkle, only inside the app bundle: a `swift run` build has no Info.plist with the feed and key.
    /// Automatic checks (once a day) are on through SUEnableAutomaticChecks in Info.plist.
    private let updater: SPUStandardUpdaterController? = Bundle.main.bundleURL.pathExtension == "app"
        ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil

    func checkForUpdates() {
        closePanel()
        guard let updater else {
            log.error("updates work only in the app bundle (scripts/build-app.sh)")
            return
        }
        // A menu bar app: bring Sparkle's window to the front.
        NSApp.activate()
        updater.checkForUpdates(nil)
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        panelClosedAt = Date()
    }
}
