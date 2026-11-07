import AppKit

// UniversalKM lives in the menu bar only (LSUIElement): no Dock icon, no main window.
// AppKit lifecycle: a SwiftUI `App` needs a scene, and even an empty Settings scene shows
// a window when the agent app activates. The menu bar icon and its panel are an
// NSStatusItem with an NSPopover hosting SwiftUI, owned by AppDelegate (design D13).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
