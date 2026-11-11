import AppKit
import UniversalKMCore

// UniversalKM lives in the menu bar (LSUIElement): no Dock icon, no main window. While one of its
// windows is open it shows in the Dock and ⌘Tab (DockPresence).
// AppKit lifecycle: a SwiftUI `App` needs a scene, and even an empty Settings scene shows
// a window when the agent app activates. The menu bar icon and its panel are an
// NSStatusItem with an NSPopover hosting SwiftUI, owned by AppDelegate (design D13).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// A Dock icon while a window is open, so the user can switch back to it.
MainActor.assumeIsolated { DockPresence.shared.install() }
// `--photos-window`: only the photo window (add-iphone-photo-browser), for manual checks.
if CommandLine.arguments.contains("--photos-window") {
    MainActor.assumeIsolated {
        let browsers = PhotoBrowsers()
        browsers.show()
        objc_setAssociatedObject(app, "photoBrowsers", browsers, .OBJC_ASSOCIATION_RETAIN)
    }
    app.run()
    exit(0)
}
// `--files-window <adb transport> [name]`: only the file window of one device, for manual checks of
// add-android-file-browser next to a running UniversalKM (no event tap, no HID, no panel).

if let i = CommandLine.arguments.firstIndex(of: "--files-window"), i + 1 < CommandLine.arguments.count {
    let transport = CommandLine.arguments[i + 1]
    let name = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : transport
    MainActor.assumeIsolated {
        let browsers = FileBrowsers()
        browsers.show(key: transport, name: name, transport: transport)
        objc_setAssociatedObject(app, "fileBrowsers", browsers, .OBJC_ASSOCIATION_RETAIN)
    }
    app.run()
    exit(0)
}
// `--motion-window <adb transport> [name] [--live] [--screen]`: only the motion camera window of one device
// (add-android-motion-camera), for manual checks next to a running UniversalKM (no event tap, no HID, no panel).
if let i = CommandLine.arguments.firstIndex(of: "--motion-window"), i + 1 < CommandLine.arguments.count {
    let transport = CommandLine.arguments[i + 1]
    let name = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : transport
    MainActor.assumeIsolated {
        let cameras = MotionCameras()
        let files = FileBrowsers()
        let windows = MotionCameraWindows(cameras: cameras) { _ in
            files.show(key: transport, name: name, transport: transport, folder: RemotePath(MotionCamera.clipsFolder))
        }
        cameras.attach(peer: 0, transport: transport)
        windows.show(peer: 0, name: name)
        // `--live`: the live picture window too (design D11).
        if CommandLine.arguments.contains("--live") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { windows.showLive(peer: 0, name: name) }
        }
        // `--screen`: the device's screen window (add-android-screen-mirror).
        if CommandLine.arguments.contains("--screen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { windows.showScreen(peer: 0, name: name) }
        }
        objc_setAssociatedObject(app, "motionWindows", [cameras, files, windows] as NSArray, .OBJC_ASSOCIATION_RETAIN)
    }
    app.run()
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
