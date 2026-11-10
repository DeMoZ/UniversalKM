import AppKit
import Observation
import os
import UniversalKMCore

/// Shared text clipboard between the Mac and Android phones of the arrangement
/// (add-android-clipboard-sync design D4–D6). Watches the Mac pasteboard, runs one helper per phone
/// over adb and lets `ClipboardRelay` decide what goes where. Clipboard text is never logged.
@MainActor
@Observable
final class ClipboardSync {
    enum PeerState: Equatable {
        /// Switched off in the panel.
        case off
        /// No adb to the phone (AOA only, or not connected).
        case unavailable
        case starting
        case working
        case failed(String)
    }

    private(set) var states: [UInt16: PeerState] = [:]
    /// macOS does not let the app read the pasteboard: Mac → Android is off (design D6).
    private(set) var isMacReadDenied = false

    @ObservationIgnored private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "clipboard")
    @ObservationIgnored private let pasteboard = NSPasteboard.general
    @ObservationIgnored private let jar = HelperJar()
    @ObservationIgnored private var relay = ClipboardRelay()
    @ObservationIgnored private var adb: ADBClient?
    /// Phones of the arrangement → their adb transport now (nil = none).
    @ObservationIgnored private var targets: [UInt16: String?] = [:]
    @ObservationIgnored private var links: [UInt16: ClipboardHelperLink] = [:]
    /// Phones whose helper answered.
    @ObservationIgnored private var ready: Set<UInt16> = []
    /// After a lost link: no new start before this time.
    @ObservationIgnored private var retryAt: [UInt16: Date] = [:]
    /// Observed: the panel's "Clipboard: on / off" button reads it through `isEnabled`.
    private var disabled: Set<UInt16>
    @ObservationIgnored private var lastChangeCount: Int
    @ObservationIgnored private var timer: Timer?

    private static let disabledKey = "clipboardSyncOff"
    private static let pollInterval: TimeInterval = 0.3
    private static let retryDelay: TimeInterval = 5

    init() {
        disabled = Set((UserDefaults.standard.array(forKey: Self.disabledKey) as? [Int] ?? []).map { UInt16(truncatingIfNeeded: $0) })
        lastChangeCount = NSPasteboard.general.changeCount
        if jar == nil { log.error("ukm-clipboard.jar missing from the app bundle: clipboard sync off") }
        log.info("pasteboard access behavior: \(Self.accessBehavior(of: NSPasteboard.general))")
        isMacReadDenied = Self.readDenied(NSPasteboard.general)
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPasteboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func isEnabled(_ peer: UInt16) -> Bool { !disabled.contains(peer) }

    func setEnabled(_ enabled: Bool, for peer: UInt16) {
        if enabled { disabled.remove(peer) } else { disabled.insert(peer) }
        UserDefaults.standard.set(disabled.map(Int.init).sorted(), forKey: Self.disabledKey)
        if !enabled { relay.forget(peer) }
        reconcile()
    }

    /// The Android phones of the arrangement and their adb transport now; `adbPath` from AndroidStatus.
    func update(targets: [UInt16: String?], adbPath: String?) {
        if adb?.url.path != adbPath { adb = adbPath.map { ADBClient(url: URL(fileURLWithPath: $0)) } }
        for peer in Set(self.targets.keys).subtracting(targets.keys) { relay.forget(peer) }
        self.targets = targets
        reconcile()
    }

    /// Stops every helper (app quits).
    func shutdown() {
        timer?.invalidate()
        for link in links.values { link.stop() }
        links = [:]
        ready = []
    }

    // MARK: Helpers on the phones

    private func reconcile() {
        var next: [UInt16: PeerState] = [:]
        for (peer, transport) in targets {
            let wanted = isEnabled(peer) ? transport : nil
            if let link = links[peer], link.transport != wanted {
                link.stop()
                links[peer] = nil
                ready.remove(peer)
            }
            if !isEnabled(peer) {
                next[peer] = .off
            } else if wanted == nil {
                next[peer] = .unavailable
            } else if links[peer] != nil {
                next[peer] = ready.contains(peer) ? .working : .starting
            } else if let at = retryAt[peer], at > Date() {
                next[peer] = states[peer] ?? .starting
            } else if let adb, let jar, let transport = wanted {
                start(peer, transport, adb, jar)
                next[peer] = .starting
            } else {
                next[peer] = .failed(String(localized: "adb not found"))
            }
        }
        for (peer, link) in links where targets[peer] == nil {
            link.stop()
            links[peer] = nil
            ready.remove(peer)
        }
        if states != next { states = next }
    }

    private func start(_ peer: UInt16, _ transport: String, _ adb: ADBClient, _ jar: HelperJar) {
        let link = ClipboardHelperLink(adb: adb, transport: transport, jar: jar)
        link.onReady = { [weak self, weak link] _, _ in
            guard let self, let link, self.links[peer] === link else { return }
            self.ready.insert(peer)
            self.retryAt[peer] = nil
            self.states[peer] = .working
            // A copy made on the Mac while the phone was away (spec «С Mac на Android»).
            if let text = self.relay.connected(peer, macText: self.readMacText()) { link.set(text) }
        }
        link.onChanged = { [weak self, weak link] text in
            guard let self, let link, self.links[peer] === link else { return }
            self.phoneChanged(peer, text)
        }
        link.onLost = { [weak self, weak link] reason in
            guard let self, let link, self.links[peer] === link else { return }
            self.links[peer] = nil
            self.ready.remove(peer)
            self.states[peer] = .failed(reason)
            self.retryAt[peer] = Date().addingTimeInterval(Self.retryDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay + 0.1) { [weak self] in self?.reconcile() }
        }
        links[peer] = link
        link.start()
    }

    // MARK: Pasteboard

    private func pollPasteboard() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let peers = links.keys.filter(ready.contains)
        // Nobody to send to: the text is read when a phone connects (fewer reads of the pasteboard).
        guard !peers.isEmpty else { return }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        // Private content (passwords) is not even read.
        let text = types.isDisjoint(with: ClipboardRelay.privateTypes) ? readString(types) : nil
        for send in relay.macChanged(changeCount: count, types: types, text: text, connected: Array(peers)) {
            log.info("Mac clipboard → peer \(send.peer) (\(send.text.utf8.count) bytes)")
            links[send.peer]?.set(send.text)
        }
    }

    /// The current pasteboard text that may leave the Mac (design D5).
    private func readMacText() -> String? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ClipboardRelay.privateTypes) else { return nil }
        return ClipboardRelay.shareable(types: types, text: readString(types))
    }

    /// Reads plain text only when there is some: images and private content are never read (design D6).
    private func readString(_ types: Set<String>) -> String? {
        guard types.contains(NSPasteboard.PasteboardType.string.rawValue) else { return nil }
        if Self.readDenied(pasteboard) {
            if !isMacReadDenied { isMacReadDenied = true }
            return nil
        }
        if isMacReadDenied { isMacReadDenied = false }
        return pasteboard.string(forType: .string)
    }

    /// macOS 15.4+: 0 default, 1 ask, 2 always allow, 3 always deny; -1 before 15.4 (no such setting).
    private static func accessBehavior(of pasteboard: NSPasteboard) -> Int {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior.rawValue }
        return -1
    }

    private static func readDenied(_ pasteboard: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) { return pasteboard.accessBehavior == .alwaysDeny }
        return false
    }

    private func phoneChanged(_ peer: UInt16, _ text: String) {
        guard let text = relay.phoneChanged(peer, text: text, allPeers: Array(targets.keys)) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        relay.wroteToMac(changeCount: lastChangeCount)
        log.info("peer \(peer) clipboard → Mac (\(text.utf8.count) bytes)")
    }
}
