import AppKit

// UniversalKM lives in the menu bar only (LSUIElement): no Dock icon, no main window.
// AppKit lifecycle: a SwiftUI `App` needs a scene, and even an empty Settings scene shows
// a window when the agent app activates. The menu bar icon and its panel are an
// NSStatusItem with an NSPopover hosting SwiftUI, owned by AppDelegate (design D13).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
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
let delegate = AppDelegate()
app.delegate = delegate
app.run()
