import Foundation
import IOKit
import os
import UniversalKMCore

/// How an Android device is reached.
enum AndroidChannel: String, Sendable {
    /// AOA2 HID over the cable.
    case usb
    /// ADB over the network.
    case wifi
    /// ADB over the cable (USB debugging on, AOA unusable).
    case adbUSB
}

/// One Android device as the panel sees it.
struct AndroidDeviceStatus: Equatable, Sendable, Identifiable {
    var id: UInt16 { peerID }
    var peerID: UInt16
    var name: String
    var serial: String
    /// AOA 2 over USB right now.
    var hasUSB = false
    /// ADB over the network right now.
    var hasWiFi = false
    /// ADB over the cable right now: "Enable Wi‑Fi" is possible.
    var hasADBOverUSB = false
    /// The channel the keyboard and mouse are registered on; nil = not registered.
    var active: AndroidChannel?
    /// Saved Wi‑Fi address from `adb tcpip` (port 5555): after a phone restart a cable is needed again.
    var tcpipAddress: String?

    var isAvailable: Bool { hasUSB || hasWiFi || hasADBOverUSB }
}

struct AndroidStatus: Equatable, Sendable {
    /// nil: no usable adb (Wi‑Fi off); the panel shows how to install it.
    var adbPath: String?
    var devices: [AndroidDeviceStatus] = []
    /// ADB transports that need the user: "unauthorized" (confirm on the phone), "offline".
    var adbProblems: [String] = []

    var registeredPeers: [UInt16] { devices.filter { $0.active != nil }.map(\.peerID) }
    var availablePeers: [UInt16] { devices.filter(\.isAvailable).map(\.peerID) }
    func device(_ peerID: UInt16) -> AndroidDeviceStatus? { devices.first { $0.peerID == peerID } }
}

/// HIDTransport for Android devices (add-android-usb-transport design D1–D7): AOA2 HID over USB and
/// ADB + `/system/bin/hid` over Wi‑Fi. A device is known by its serial number on both channels and
/// gets a peer ID from `AndroidPeerRegistry`. The keyboard and mouse are registered only on devices
/// bound in the arrangement (`setBoundPeers`) while sending is enabled, on the best channel:
/// USB, then Wi‑Fi, then ADB over the cable. Losing the active channel moves to another one.
final class AndroidHIDTransport: HIDTransport, @unchecked Sendable {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "android")
    private let queue = DispatchQueue(label: "ukm.android", qos: .userInteractive)
    private let onStatus: @Sendable (AndroidStatus) -> Void

    // Everything below is touched only on `queue`.
    private lazy var watcher = AndroidUSBDeviceWatcher(queue: queue)
    private var adb: ADBClient?
    private var registry: AndroidPeerRegistry
    private var names: [String: String]
    private var wifiAddresses: [String: String]
    private var bound: Set<UInt16> = []
    private var enabled = true
    private var started = false
    private var status = AndroidStatus()

    private struct USBDevice {
        var key: String
        var info: USBDeviceInfo
        var link: AOALink?
        var aoaVersion: Int?
    }
    private var usb: [UInt64: USBDevice] = [:]

    private struct ADBDevice {
        var device: ADBClient.Device
        var key: String?
        var asked = false
    }
    private var adbDevices: [String: ADBDevice] = [:]
    /// Network transports whose heartbeat stopped: adb may still list them as "device" for a long
    /// time, so they are disconnected and not used until adb lists them anew.
    private var deadTransports: Set<String> = []

    private enum Active {
        case usb(UInt64, AOALink)
        case adb(String, ADBLink, AndroidChannel)

        var channel: AndroidChannel {
            switch self {
            case .usb: .usb
            case .adb(_, _, let channel): channel
            }
        }
    }
    private var active: [UInt16: Active] = [:]
    /// ADB links being started, by peer.
    private var starting: [UInt16: ADBLink] = [:]
    /// Peers whose channel was lost while another one is there: they count as connected (input stays
    /// on the device, events wait in the queue) until the other channel is registered (design D7).
    private var switching: [UInt16: (channel: AndroidChannel, since: TimeInterval)] = [:]
    private static let switchTimeout: TimeInterval = 3

    private struct Sender {
        var events: [[UInt8]] = []
        var keyboard = KeyboardState()
        var mouse = MouseAccumulator()
        var busy = false
        var lastMouse: TimeInterval = 0
        var timerArmed = false
        /// Android needs a moment to create the device after an AOA registration: events before this
        /// uptime would stall.
        var notBefore: TimeInterval = 0
    }
    private var senders: [UInt16: Sender] = [:]

    private var timer: DispatchSourceTimer?
    private var connecting: Set<String> = []
    private var mdnsRunning = false

    private static let registryKey = "androidPeers"
    private static let namesKey = "androidNames"
    private static let wifiKey = "androidWifiAddresses"
    private static let usbMouseInterval: TimeInterval = 1.0 / 250
    private static let adbMouseInterval: TimeInterval = 1.0 / 125
    private static let reconnectInterval: TimeInterval = 5
    private static let aoaSettle: TimeInterval = 0.3
    static let tcpipPort = 5555

    init(onStatus: @escaping @Sendable (AndroidStatus) -> Void) {
        self.onStatus = onStatus
        let defaults = UserDefaults.standard
        registry = defaults.data(forKey: Self.registryKey).flatMap { try? JSONDecoder().decode(AndroidPeerRegistry.self, from: $0) }
            ?? AndroidPeerRegistry()
        names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        wifiAddresses = defaults.dictionary(forKey: Self.wifiKey) as? [String: String] ?? [:]
    }

    // MARK: HIDTransport

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            watcher.onAppear = { [weak self] id, service, info in self?.usbAppeared(id, service, info) }
            watcher.onDisappear = { [weak self] id in self?.usbDisappeared(id) }
            watcher.start()
            startADB()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.reconnectInterval, repeating: Self.reconnectInterval)
            timer.setEventHandler { [weak self] in
                self?.reconnectWiFi()
                if self?.switching.isEmpty == false { self?.reconcile() }
            }
            timer.resume()
            self.timer = timer
            publish()
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            self.enabled = enabled
            reconcile()
        }
    }

    func setBoundPeers(_ peers: Set<UInt16>) {
        queue.async { [self] in
            let android = peers.filter(AndroidPeerRegistry.isAndroidPeer)
            guard android != bound else { return }
            bound = android
            reconcile()
        }
    }

    func moveMouse(dx: Double, dy: Double, to peerID: UInt16) {
        queue.async { [self] in
            guard takesInput(peerID) else { return }
            senders[peerID, default: Sender()].mouse.addMotion(dx: dx, dy: dy)
            pump(peerID)
        }
    }

    func scroll(wheel: Double, pan: Double, to peerID: UInt16) {
        queue.async { [self] in
            guard takesInput(peerID) else { return }
            senders[peerID, default: Sender()].mouse.addScroll(wheel: wheel, pan: pan)
            pump(peerID)
        }
    }

    func setButtons(_ buttons: MouseButtons, to peerID: UInt16) {
        queue.async { [self] in
            guard takesInput(peerID) else { return }
            senders[peerID, default: Sender()].mouse.setButtons(buttons)
            pump(peerID)
        }
    }

    func key(usage: UInt8, isDown: Bool, to peerID: UInt16) {
        queue.async { [self] in
            guard takesInput(peerID) else { return }
            var sender = senders[peerID, default: Sender()]
            if sender.keyboard.apply(usage: usage, isDown: isDown) {
                sender.events.append(AndroidHIDEvent.keyboard(sender.keyboard.report))
            }
            senders[peerID] = sender
            pump(peerID)
        }
    }

    func sendNeutral(to peerID: UInt16) {
        queue.async { [self] in
            guard takesInput(peerID) else { return }
            queueNeutral(peerID)
            pump(peerID)
        }
    }

    /// Registered, or between two channels.
    private func takesInput(_ peer: UInt16) -> Bool {
        active[peer] != nil || switching[peer] != nil
    }

    func shutdown(timeout: TimeInterval) {
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            adb?.stopTracking()
            for peer in Array(active.keys) { deactivate(peer) }
            starting.values.forEach { $0.stop(timeout: 0) }
            starting = [:]
            watcher.stop()
        }
    }

    // MARK: Wi‑Fi actions from the panel

    /// `adb pair <address> <code>` ("Wireless debugging" → "Pair device with pairing code").
    func pair(address: String, code: String, completion: @escaping @Sendable (Result<Void, ADBError>) -> Void) {
        queue.async { [self] in
            guard let adb else { completion(.failure(.noADB)); return }
            adb.run(["pair", address, code], timeout: 20, on: queue) { [weak self] result in
                let text = result.output + result.error
                if result.ok && text.contains("Successfully paired") {
                    self?.log.info("paired with \(address, privacy: .public)")
                    completion(.success(()))
                    self?.reconnectWiFi()
                } else {
                    completion(.failure(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }
        }
    }

    /// `adb tcpip` for a phone on the cable with USB debugging: learns its Wi‑Fi address, switches adbd
    /// to TCP and connects over the network.
    func enableWiFi(peerID: UInt16, completion: @escaping @Sendable (Result<String, ADBError>) -> Void) {
        queue.async { [self] in
            guard let adb else { completion(.failure(.noADB)); return }
            guard let key = registry.key(for: peerID),
                  let transport = adbDevices.values.first(where: { $0.key == key && !$0.device.isNetwork && $0.device.state == "device" })?.device.serial
            else { completion(.failure(.failed("no USB debugging connection"))); return }
            adb.run(["-s", transport, "shell", "ip", "-4", "addr", "show", "wlan0"], timeout: 5, on: queue) { [weak self] result in
                guard let self else { return }
                guard let ip = ADBClient.wlanAddress(result.output) else {
                    completion(.failure(.failed("the phone is not on Wi‑Fi")))
                    return
                }
                let address = "\(ip):\(Self.tcpipPort)"
                adb.run(["-s", transport, "tcpip", String(Self.tcpipPort)], timeout: 10, on: self.queue) { [weak self] result in
                    guard let self else { return }
                    guard result.ok else { completion(.failure(.failed(result.error))); return }
                    self.wifiAddresses[key] = address
                    UserDefaults.standard.set(self.wifiAddresses, forKey: Self.wifiKey)
                    self.log.info("tcpip on \(address, privacy: .public)")
                    // adbd restarts in TCP mode: give it a moment.
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.connect(address)
                        completion(.success(address))
                    }
                }
            }
        }
    }

    enum ADBError: Error, Equatable, Sendable {
        case noADB
        case failed(String)
    }

    // MARK: USB

    private func usbAppeared(_ id: UInt64, _ service: io_service_t, _ info: USBDeviceInfo) {
        let key = info.serialNumber ?? AndroidPeerRegistry.usbLocationKey(info.locationID)
        if info.serialNumber == nil {
            log.info("USB device \(String(format: "%04x:%04x", info.vendorID, info.productID), privacy: .public) has no serial number: known by its port")
        }
        var device = USBDevice(key: key, info: info)
        do {
            let link = try AOALink(service: service)
            device.link = link
            device.aoaVersion = link.protocolVersion()
        } catch {
            log.error("USB \(key, privacy: .public): cannot open: \(String(describing: error), privacy: .public)")
        }
        let version = device.aoaVersion.map(String.init) ?? "none"
        let verdict = (device.aoaVersion ?? 0) >= AOAHID.minimumProtocol ? "available" : "unsupported"
        log.info("USB \(info.productName ?? "?", privacy: .public) \(key, privacy: .public) \(String(format: "%04x:%04x", info.vendorID, info.productID), privacy: .public): AOA \(version, privacy: .public), \(verdict, privacy: .public)")
        usb[id] = device
        if (device.aoaVersion ?? 0) >= AOAHID.minimumProtocol {
            _ = peerID(for: key, name: info.productName)
        }
        reconcile()
    }

    private func usbDisappeared(_ id: UInt64) {
        guard let device = usb.removeValue(forKey: id) else { return }
        log.info("USB \(device.key, privacy: .public) gone")
        for (peer, link) in active {
            if case .usb(id, _) = link { channelLost(peer) }
        }
        reconcile()
    }

    // MARK: ADB

    private func startADB() {
        guard let url = ADBClient.find() else {
            log.info("adb not found: Wi‑Fi off")
            return
        }
        let client = ADBClient(url: url)
        client.platformToolsVersion(on: queue) { [weak self] major in
            guard let self else { return }
            guard let major, major >= 30 else {
                self.log.info("adb at \(url.path, privacy: .public) is missing or too old (platform-tools \(major ?? -1)): Wi‑Fi off")
                return
            }
            self.adb = client
            self.status.adbPath = url.path
            self.log.info("adb \(url.path, privacy: .public), platform-tools \(major)")
            client.ensureServer(on: self.queue) { [weak self] in
                guard let self else { return }
                client.track(on: self.queue) { [weak self] devices in self?.adbDevicesChanged(devices) }
                self.reconnectWiFi()
            }
            self.publish()
        }
    }

    private func adbDevicesChanged(_ list: [ADBClient.Device]) {
        var next: [String: ADBDevice] = [:]
        for device in list {
            var entry = adbDevices[device.serial] ?? ADBDevice(device: device)
            if entry.device.state != device.state { entry.asked = false }
            entry.device = device
            next[device.serial] = entry
        }
        let gone = Set(adbDevices.keys).subtracting(next.keys)
        adbDevices = next
        deadTransports.subtract(gone)
        for serial in gone { log.info("ADB \(serial, privacy: .public) gone") }
        for (peer, link) in active {
            if case .adb(let serial, _, _) = link, adbDevices[serial]?.device.state != "device" { channelLost(peer) }
        }
        for (serial, entry) in adbDevices where entry.device.state == "device" && entry.key == nil && !entry.asked {
            identify(serial)
        }
        status.adbProblems = adbDevices.values.filter { $0.device.state != "device" }.map { "\($0.device.serial): \($0.device.state)" }.sorted()
        reconcile()
    }

    /// Serial number and model of a new ADB transport.
    private func identify(_ serial: String) {
        guard let adb else { return }
        adbDevices[serial]?.asked = true
        adb.run(["-s", serial, "shell", "getprop ro.serialno; getprop ro.product.model"], timeout: 10, on: queue) { [weak self] result in
            guard let self, self.adbDevices[serial] != nil else { return }
            let lines = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard result.ok, let key = lines.first, !key.isEmpty else {
                self.log.error("ADB \(serial, privacy: .public): no serial number (\(result.error, privacy: .public))")
                return
            }
            let model = lines.count > 1 ? lines[1] : nil
            self.adbDevices[serial]?.key = key
            let network = self.adbDevices[serial]?.device.isNetwork == true
            self.log.info("ADB \(serial, privacy: .public) = \(key, privacy: .public) \(model ?? "", privacy: .public) over \(network ? "Wi‑Fi" : "USB", privacy: .public)")
            if network, serial.contains(":"), !serial.contains("._adb-tls-connect.") {
                self.wifiAddresses[key] = serial
                UserDefaults.standard.set(self.wifiAddresses, forKey: Self.wifiKey)
            }
            _ = self.peerID(for: key, name: model)
            self.reconcile()
        }
    }

    private func connect(_ address: String) {
        guard let adb, !connecting.contains(address) else { return }
        connecting.insert(address)
        adb.run(["connect", address], timeout: 8, on: queue) { [weak self] result in
            self?.connecting.remove(address)
            if !result.output.contains("connected to") {
                self?.log.debug("adb connect \(address, privacy: .public): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
            }
        }
    }

    /// Every few seconds: bound devices without a network transport are looked up by their saved
    /// `tcpip` address and among the mDNS "Wireless debugging" services of paired phones.
    private func reconnectWiFi() {
        guard let adb else { return }
        let onNetwork = Set(adbDevices.values.compactMap { $0.device.isNetwork && $0.device.state == "device" ? $0.key : nil })
        let missing = bound.compactMap(registry.key(for:)).filter { !onNetwork.contains($0) }
        guard !missing.isEmpty else { return }
        for key in missing {
            if let address = wifiAddresses[key] { connect(address) }
        }
        guard !mdnsRunning else { return }
        mdnsRunning = true
        adb.run(["mdns", "services"], timeout: 5, on: queue) { [weak self] result in
            guard let self else { return }
            self.mdnsRunning = false
            let services = ADBClient.mdnsConnectServices(result.output)
            for key in missing {
                if let address = services[key] { self.connect(address) }
            }
        }
    }

    // MARK: Peers and status

    private func peerID(for key: String, name: String?) -> UInt16? {
        let before = registry
        guard let peer = registry.peerID(for: key) else {
            log.error("no free Android peer ID for \(key, privacy: .public)")
            return nil
        }
        if registry != before, let data = try? JSONEncoder().encode(registry) {
            UserDefaults.standard.set(data, forKey: Self.registryKey)
        }
        if let name, !name.isEmpty, names[key] == nil || (names[key] == "SAMSUNG_Android" && name != names[key]) {
            names[key] = name
            UserDefaults.standard.set(names, forKey: Self.namesKey)
        }
        return peer
    }

    /// Channels of a device right now, best first (design D1): USB, Wi‑Fi, ADB over the cable.
    private func candidates(_ key: String) -> [(AndroidChannel, String)] {
        var list: [(AndroidChannel, String)] = []
        for (id, device) in usb where device.key == key && (device.aoaVersion ?? 0) >= AOAHID.minimumProtocol {
            list.append((.usb, String(id)))
        }
        let adb = adbDevices.values.filter { $0.key == key && $0.device.state == "device" && !deadTransports.contains($0.device.serial) }
        list += adb.filter(\.device.isNetwork).map { (.wifi, $0.device.serial) }
        list += adb.filter { !$0.device.isNetwork }.map { (.adbUSB, $0.device.serial) }
        return list
    }

    private func publish() {
        var devices: [AndroidDeviceStatus] = []
        for (key, peer) in registry.peers {
            let channels = candidates(key)
            let isBound = bound.contains(peer)
            guard !channels.isEmpty || isBound else { continue }
            var device = AndroidDeviceStatus(peerID: peer, name: names[key] ?? key, serial: key)
            device.hasUSB = channels.contains { $0.0 == .usb }
            device.hasWiFi = channels.contains { $0.0 == .wifi }
            device.hasADBOverUSB = channels.contains { $0.0 == .adbUSB }
            device.active = active[peer]?.channel ?? switching[peer]?.channel
            device.tcpipAddress = wifiAddresses[key].flatMap { $0.hasSuffix(":\(Self.tcpipPort)") ? $0 : nil }
            devices.append(device)
        }
        status.devices = devices.sorted { $0.peerID < $1.peerID }
        onStatus(status)
    }

    // MARK: Choosing the channel

    private func reconcile() {
        let now = ProcessInfo.processInfo.systemUptime
        for (key, peer) in registry.peers {
            let wanted = enabled && bound.contains(peer)
            let channels = wanted ? candidates(key) : []
            var best = channels.first
            // Stay on the current link while it is as good as the best one (two Wi‑Fi transports of
            // one phone, e.g. `tcpip` and Wireless debugging, must not take turns).
            if let current = active[peer], let first = best, current.channel == first.0,
               let same = channels.first(where: { $0.0 == current.channel && isSame(current, $0.1) }) {
                best = same
            }
            if let pending = switching[peer], best == nil || now - pending.since > Self.switchTimeout {
                log.info("peer \(peer): no other channel; disconnected")
                switching[peer] = nil
                senders[peer] = nil
            }
            let current = active[peer]
            switch (current, best) {
            case (nil, nil):
                break
            case (.some, nil):
                deactivate(peer)
            case (let current, .some(let best)):
                if let current, current.channel == best.0, isSame(current, best.1) { continue }
                // A better channel (or the first one): register there, then drop the old one (design D7).
                // USB does not wait for an ADB link that is still starting.
                if let pending = starting[peer] {
                    guard best.0 == .usb else { continue }
                    pending.stop(timeout: 0)
                    starting[peer] = nil
                }
                activate(peer, best.0, best.1)
            }
        }
        publish()
    }

    private func isSame(_ active: Active, _ id: String) -> Bool {
        switch active {
        case .usb(let entry, _): String(entry) == id
        case .adb(let serial, _, _): serial == id
        }
    }

    private func activate(_ peer: UInt16, _ channel: AndroidChannel, _ id: String) {
        switch channel {
        case .usb:
            guard let entry = UInt64(id), let link = usb[entry]?.link else { return }
            do {
                try link.register()
            } catch {
                log.error("AOA register on \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                usb[entry]?.aoaVersion = nil
                reconcile()
                return
            }
            switchTo(peer, .usb(entry, link))
        case .wifi, .adbUSB:
            guard let adb else { return }
            let link = ADBLink(adb: adb.url, transport: id, queue: queue)
            starting[peer] = link
            link.start(heartbeat: channel == .wifi) { [weak self, weak link] ok in
                guard let self, let link, self.starting[peer] === link else { return }
                self.starting[peer] = nil
                guard ok else {
                    self.log.error("hid over ADB \(id, privacy: .public) did not start")
                    if self.switching[peer] != nil {
                        self.switching[peer] = nil
                        self.senders[peer] = nil
                    }
                    self.publish()
                    return
                }
                link.onLost = { [weak self] in self?.adbLinkLost(peer, link) }
                // The wanted channel may have changed while hid was starting.
                guard self.enabled, self.bound.contains(peer) else { link.stop(); self.publish(); return }
                self.switchTo(peer, .adb(id, link, channel))
                self.reconcile()
            }
        }
    }

    private func switchTo(_ peer: UInt16, _ new: Active) {
        let old = active[peer]
        active[peer] = new
        log.info("peer \(peer) → \(new.channel.rawValue, privacy: .public)")
        if let old { remove(old) }
        switching[peer] = nil
        // Neutral reports first, then what was queued during the switch. The pressed-key state is kept:
        // its reports are full states, so keys held across the switch stay held and are released later.
        var sender = senders[peer, default: Sender()]
        sender.events.insert(contentsOf: AndroidHIDEvent.neutral, at: 0)
        sender.busy = false
        if case .usb = new { sender.notBefore = ProcessInfo.processInfo.systemUptime + Self.aoaSettle }
        senders[peer] = sender
        pump(peer)
        publish()
    }

    private func deactivate(_ peer: UInt16) {
        switching[peer] = nil
        guard let old = active.removeValue(forKey: peer) else { senders[peer] = nil; return }
        log.info("peer \(peer) unregistered")
        senders[peer] = nil
        remove(old)
        publish()
    }

    /// Releases everything and removes the keyboard and mouse from the device.
    private func remove(_ active: Active) {
        switch active {
        case .usb(_, let link):
            AndroidHIDEvent.neutral.forEach(link.sendBlocking)
            link.unregister()
        case .adb(_, let link, _):
            link.stop()
        }
    }

    private func channelLost(_ peer: UInt16) {
        guard let lost = active.removeValue(forKey: peer) else { return }
        log.info("peer \(peer): \(lost.channel.rawValue, privacy: .public) lost")
        if case .adb(_, let link, _) = lost { link.stop(timeout: 0) }
        senders[peer]?.busy = false
        // reconcile() picks another channel or leaves the device unregistered (input returns to the Mac).
        if let key = registry.key(for: peer), enabled, bound.contains(peer), !candidates(key).isEmpty {
            switching[peer] = (lost.channel, ProcessInfo.processInfo.systemUptime)
        } else {
            senders[peer] = nil
        }
    }

    private func adbLinkLost(_ peer: UInt16, _ link: ADBLink) {
        guard case .adb(let serial, let current, let channel) = active[peer], current === link else { return }
        if channel == .wifi, let adb {
            // The phone left the network (or adb lost it): drop the transport; reconnectWiFi() brings it back.
            deadTransports.insert(serial)
            adb.run(["disconnect", serial], timeout: 5, on: queue) { _ in }
        }
        channelLost(peer)
        reconcile()
    }

    // MARK: Sending

    private func queueNeutral(_ peer: UInt16) {
        var sender = senders[peer, default: Sender()]
        sender.keyboard.reset()
        sender.mouse.reset()
        sender.events.append(contentsOf: AndroidHIDEvent.neutral)
        senders[peer] = sender
    }

    private func pump(_ peer: UInt16) {
        guard let link = active[peer], var sender = senders[peer], !sender.busy else { return }
        let settle = sender.notBefore - ProcessInfo.processInfo.systemUptime
        if settle > 0 {
            if !sender.timerArmed {
                sender.timerArmed = true
                senders[peer] = sender
                queue.asyncAfter(deadline: .now() + settle) { [weak self] in
                    self?.senders[peer]?.timerArmed = false
                    self?.pump(peer)
                }
            }
            return
        }
        var event: [UInt8]?
        if !sender.events.isEmpty {
            event = sender.events.removeFirst()
        } else if sender.mouse.hasPendingReport {
            let interval = link.channel == .usb ? Self.usbMouseInterval : Self.adbMouseInterval
            let now = ProcessInfo.processInfo.systemUptime
            let wait = sender.lastMouse + interval - now
            if wait > 0 {
                if !sender.timerArmed {
                    sender.timerArmed = true
                    queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                        self?.senders[peer]?.timerArmed = false
                        self?.pump(peer)
                    }
                }
                senders[peer] = sender
                return
            }
            if let report = sender.mouse.nextReport() {
                sender.lastMouse = now
                event = AndroidHIDEvent.mouse(report)
            }
        }
        guard let event else { senders[peer] = sender; return }
        sender.busy = true
        senders[peer] = sender
        switch link {
        case .usb(let entry, let aoa):
            aoa.send(event, on: queue) { [weak self] error in
                guard let self else { return }
                self.senders[peer]?.busy = false
                if let error {
                    self.log.error("AOA event to peer \(peer) failed: \(String(describing: error), privacy: .public)")
                    if error.isGone, case .usb(entry, _)? = self.active[peer] {
                        self.usb[entry]?.aoaVersion = nil
                        self.channelLost(peer)
                        self.reconcile()
                        return
                    }
                }
                self.pump(peer)
            }
        case .adb(_, let adbLink, _):
            adbLink.send(event) { [weak self] ok in
                guard let self else { return }
                self.senders[peer]?.busy = false
                if !ok {
                    self.adbLinkLost(peer, adbLink)
                    return
                }
                self.pump(peer)
            }
        }
    }
}
