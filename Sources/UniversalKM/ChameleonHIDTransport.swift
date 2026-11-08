import Foundation
import os
import UniversalKMCore

/// HIDTransport over the ChameleonUltra USB serial port (design D5, D6).
///
/// - The firmware takes one frame at a time, so exactly one request is in flight; the next one goes
///   out when the reply arrives (or after a timeout).
/// - Priority: control requests, then keyboard reports (FIFO, never merged), then mouse reports
///   (merged per host in a MouseAccumulator while the channel is busy).
/// - BUSY (BLE queue full) → the same frame is sent again after 2 ms; new motion keeps accumulating.
/// - The host list comes from the state byte of report replies and from polling UKM_HID_STATE
///   every 250 ms when idle; the device sends nothing unsolicited.
final class ChameleonHIDTransport: HIDTransport, @unchecked Sendable {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "transport")
    private let queue = DispatchQueue(label: "ukm.serial", qos: .userInteractive)
    private let onStatus: @Sendable (TransportStatus) -> Void

    // Everything below is touched only on `queue`.
    private lazy var watcher = ChameleonDeviceWatcher(queue: queue)
    private var devicePath: String?
    private var port: SerialPort?
    private var parser = ChameleonFrameParser()
    private var phase = Phase.disconnected
    private var desiredEnabled = true
    private var status: TransportStatus?

    private enum Phase { case disconnected, probing, ready, unsupported }

    private enum Request {
        case info, enable(Bool), state
        case keyboard(UInt16, KeyboardReport)
        case mouse(UInt16, MouseReport)

        var frame: ChameleonFrame {
            switch self {
            case .info: ChameleonFrame(.hidGetInfo)
            case .enable(let on): ChameleonHID.setEnabled(on)
            case .state: ChameleonFrame(.hidState)
            case .keyboard(let peer, let report): ChameleonHID.keyboard(report, to: peer)
            case .mouse(let peer, let report): ChameleonHID.mouse(report, to: peer)
            }
        }
    }

    private var control: [Request] = []
    private var reports: [Request] = []                 // keyboard reports and neutral mouse reports, FIFO
    private var keyboards: [UInt16: KeyboardState] = [:]
    private var mice: [UInt16: MouseAccumulator] = [:]
    private var mouseTurn: [UInt16] = []                // round robin between hosts with pending motion
    private var inFlight: Request?
    private var inFlightToken = 0
    private var retryPending = false
    private var probeAttempts = 0
    private var timer: DispatchSourceTimer?

    private static let replyTimeout: TimeInterval = 0.5
    private static let busyRetry: TimeInterval = 0.002
    private static let pollInterval: TimeInterval = 0.25

    init(onStatus: @escaping @Sendable (TransportStatus) -> Void) {
        self.onStatus = onStatus
    }

    // MARK: HIDTransport

    func start() {
        queue.async { [self] in
            publish(.notConnected)
            watcher.onAppear = { [weak self] path in self?.deviceAppeared(path) }
            watcher.onDisappear = { [weak self] path in self?.deviceDisappeared(path) }
            watcher.start()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [self] in
            desiredEnabled = enabled
            guard phase == .ready else { return }
            control.append(.enable(enabled))
            pump()
        }
    }

    func moveMouse(dx: Double, dy: Double, to peerID: UInt16) {
        queue.async { [self] in
            mice[peerID, default: MouseAccumulator()].addMotion(dx: dx, dy: dy)
            mouseChanged(peerID)
        }
    }

    func scroll(wheel: Double, pan: Double, to peerID: UInt16) {
        queue.async { [self] in
            mice[peerID, default: MouseAccumulator()].addScroll(wheel: wheel, pan: pan)
            mouseChanged(peerID)
        }
    }

    func setButtons(_ buttons: MouseButtons, to peerID: UInt16) {
        queue.async { [self] in
            mice[peerID, default: MouseAccumulator()].setButtons(buttons)
            mouseChanged(peerID)
        }
    }

    func key(usage: UInt8, isDown: Bool, to peerID: UInt16) {
        queue.async { [self] in
            guard phase == .ready else { return }
            if keyboards[peerID, default: KeyboardState()].apply(usage: usage, isDown: isDown),
               let report = keyboards[peerID]?.report {
                reports.append(.keyboard(peerID, report))
                pump()
            }
        }
    }

    func sendNeutral(to peerID: UInt16) {
        queue.async { [self] in
            keyboards[peerID] = KeyboardState()
            mice[peerID] = MouseAccumulator()
            mouseTurn.removeAll { $0 == peerID }
            guard phase == .ready else { return }
            reports.append(.keyboard(peerID, .neutral))
            reports.append(.mouse(peerID, .neutral))
            pump()
        }
    }

    func shutdown(timeout: TimeInterval) {
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            guard phase == .ready, let port else { return }
            // The firmware sends neutral reports to every host, then disconnects them and stops advertising.
            port.write(ChameleonHID.setEnabled(false).encoded)
            var shutdownParser = ChameleonFrameParser()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let frames = shutdownParser.append(port.readBlocking(timeout: deadline.timeIntervalSinceNow))
                if frames.contains(where: { $0.command == ChameleonCommand.hidSetEnabled.rawValue }) {
                    log.info("HID mode off")
                    break
                }
            }
            closePort()
        }
    }

    // MARK: Device

    private func deviceAppeared(_ path: String) {
        log.info("ChameleonUltra on \(path, privacy: .public)")
        devicePath = path
        openPort()
    }

    private func deviceDisappeared(_ path: String) {
        guard path == devicePath else { return }
        log.info("ChameleonUltra removed")
        devicePath = nil
        closePort()
    }

    private func openPort() {
        guard port == nil, let path = devicePath else { return }
        let port = SerialPort(path: path, queue: queue)
        do {
            try port.open()
        } catch {
            // Busy (another program holds it) or not ready yet: tick() tries again.
            log.error("cannot open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        port.onData = { [weak self] bytes in self?.received(bytes) }
        port.onClose = { [weak self] in self?.portClosed() }
        self.port = port
        parser.reset()
        phase = .probing
        probeAttempts = 0
        control = [.info]
        pump()
    }

    private func portClosed() {
        port = nil
        resetLink()
    }

    private func closePort() {
        port?.close()
        port = nil
        resetLink()
    }

    private func resetLink() {
        phase = .disconnected
        control = []
        reports = []
        keyboards = [:]
        mice = [:]
        mouseTurn = []
        inFlight = nil
        retryPending = false
        publish(.notConnected)
    }

    private func tick() {
        if port == nil {
            openPort()
            return
        }
        if phase == .ready && inFlight == nil && control.isEmpty && reports.isEmpty && mouseTurn.isEmpty {
            control.append(.state)
            pump()
        }
    }

    // MARK: Sending

    private func mouseChanged(_ peerID: UInt16) {
        guard phase == .ready else {
            mice[peerID] = nil
            return
        }
        if !mouseTurn.contains(peerID) { mouseTurn.append(peerID) }
        pump()
    }

    private func nextRequest() -> Request? {
        if !control.isEmpty { return control.removeFirst() }
        guard phase == .ready else { return nil }
        if !reports.isEmpty { return reports.removeFirst() }
        while !mouseTurn.isEmpty {
            let peer = mouseTurn.removeFirst()
            if let report = mice[peer]?.nextReport() {
                if mice[peer]?.hasPendingReport == true { mouseTurn.append(peer) }
                return .mouse(peer, report)
            }
        }
        return nil
    }

    private func pump() {
        guard inFlight == nil, !retryPending, let port, let request = nextRequest() else { return }
        send(request, on: port)
    }

    private func send(_ request: Request, on port: SerialPort) {
        inFlight = request
        inFlightToken &+= 1
        let token = inFlightToken
        guard port.write(request.frame.encoded) else { return }   // onClose resets the link
        queue.asyncAfter(deadline: .now() + Self.replyTimeout) { [weak self] in self?.timedOut(token) }
    }

    private func timedOut(_ token: Int) {
        guard token == inFlightToken, let request = inFlight else { return }
        log.error("no reply to \(request.frame.command)")
        inFlight = nil
        parser.reset()
        if case .info = request {
            probeAttempts += 1
            if probeAttempts < 3 {
                control.insert(.info, at: 0)
            } else {
                phase = .unsupported
                publish(.unsupportedFirmware("no reply to UKM_HID_GET_INFO"))
            }
        }
        pump()
    }

    // MARK: Receiving

    private func received(_ bytes: [UInt8]) {
        for frame in parser.append(bytes) {
            handle(frame)
        }
    }

    private func handle(_ frame: ChameleonFrame) {
        guard let request = inFlight, request.frame.command == frame.command else {
            log.debug("unexpected frame \(frame.command)")
            return
        }
        inFlight = nil
        let status = frame.knownStatus

        switch request {
        case .info:
            if status == .invalidCommand {
                phase = .unsupported
                publish(.unsupportedFirmware("firmware without the HID mode"))
            } else if status == .success, let info = ChameleonHIDInfo(frame.data), info.isSupported {
                log.info("HID protocol \(info.protocolVersion), up to \(info.maxHosts) hosts")
                phase = .ready
                control += [.enable(desiredEnabled), .state]
            } else {
                phase = .unsupported
                let version = ChameleonHIDInfo(frame.data).map { "HID protocol \($0.protocolVersion)" } ?? "status \(frame.status)"
                publish(.unsupportedFirmware(version))
            }

        case .enable, .state:
            if case .state = request, status == .success, let state = ChameleonHIDState(frame.data) {
                publish(.ready(state))
                dropHostsNotSubscribed(state)
            }

        case .keyboard(let peer, _), .mouse(let peer, _):
            if status == .busy {
                // Same frame again shortly; it stays in flight so nothing overtakes it.
                retryPending = true
                inFlight = request
                queue.asyncAfter(deadline: .now() + Self.busyRetry) { [weak self] in
                    guard let self, self.retryPending, let port = self.port, let request = self.inFlight else { return }
                    self.retryPending = false
                    self.inFlight = nil
                    self.send(request, on: port)
                }
                return
            }
            if status == .notConnected {
                // The host left or has not subscribed: forget what was pending for it.
                keyboards[peer] = nil
                mice[peer] = nil
                mouseTurn.removeAll { $0 == peer }
                reports.removeAll {
                    if case .keyboard(peer, _) = $0 { return true }
                    if case .mouse(peer, _) = $0 { return true }
                    return false
                }
                control.append(.state)
            }
        }
        pump()
    }

    private func dropHostsNotSubscribed(_ state: ChameleonHIDState) {
        let subscribed = state.subscribedPeerIDs
        for peer in Set(mice.keys).union(keyboards.keys) where !subscribed.contains(peer) {
            mice[peer] = nil
            keyboards[peer] = nil
            mouseTurn.removeAll { $0 == peer }
        }
    }

    private func publish(_ new: TransportStatus) {
        guard new != status else { return }
        status = new
        switch new {
        case .notConnected:
            log.info("status: Chameleon not connected")
        case .unsupportedFirmware(let detail):
            log.info("status: unsupported firmware (\(detail, privacy: .public))")
        case .ready(let state):
            let hosts = state.hosts.map { "\($0.peerID.map(String.init) ?? "-"):\($0.state == .subscribed ? "subscribed" : "connected")" }
            log.info("status: ready, enabled \(state.isEnabled), hosts [\(hosts.joined(separator: ", "), privacy: .public)]")
        }
        onStatus(new)
    }
}
