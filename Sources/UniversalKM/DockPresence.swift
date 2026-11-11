import AppKit

/// UniversalKM is a menu bar app (LSUIElement, `.accessory`): no Dock icon. While one of its windows is open
/// (camera, live view, files, photos, support), it becomes a regular app: icon in the Dock and in ⌘Tab, so
/// the user can get back to the window after switching to another app. When the last window closes, the app
/// goes back to the menu bar only. Minimized windows keep the Dock icon (they live in the Dock).
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let closing = name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { DockPresence.shared.update(closing: closing) }
            })
        }
        // A window shown while the app is not active never becomes key: check after each event loop pass too.
        observers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockPresence.shared.update(closing: nil) }
        })
        installMenu()
    }

    /// Ordinary titled windows count; the status item, the panel popover, sheets and menus do not
    /// (none of them can become the main window).
    private func update(closing: NSWindow?) {
        let hasWindows = NSApp.windows.contains { w in
            w !== closing && w.canBecomeMain && w.styleMask.contains(.titled)
                && w.level == .normal && (w.isVisible || w.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = hasWindows ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if hasWindows { NSApp.activate() }
    }

    /// While the app is regular, macOS shows its menu bar menu: ⌘W closes the front window, ⌘Q quits.
    private func installMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
}
