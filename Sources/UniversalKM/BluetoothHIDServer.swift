import CoreBluetooth
import Foundation
import ObjCSupport
import os
import UniversalKMCore

/// Bluetooth state as shown to the user (spec ble-hid-peripheral, "Статус подключения").
enum BluetoothStatus: Equatable, Sendable {
    case starting
    case poweredOff
    case unauthorized
    case unsupported
    /// GATT setup failed (for example macOS rejected the HID service).
    case failed(String)
    case advertising
    case connected(hostID: UUID)
}

/// BLE HID peripheral (HID over GATT): the Mac as a composite keyboard + mouse.
///
/// All state lives on `queue` (design D5). Public methods may be called from any
/// thread; they hop onto the queue.
final class BluetoothHIDServer: NSObject, @unchecked Sendable {
    static let localName = "UniversalKM"

    private enum UUIDs {
        static var hidService: CBUUID { CBUUID(string: "1812") }
        static var deviceInfoService: CBUUID { CBUUID(string: "180A") }
        static var batteryService: CBUUID { CBUUID(string: "180F") }

        static var hidInformation: CBUUID { CBUUID(string: "2A4A") }
        static var reportMap: CBUUID { CBUUID(string: "2A4B") }
        static var hidControlPoint: CBUUID { CBUUID(string: "2A4C") }
        static var report: CBUUID { CBUUID(string: "2A4D") }
        static var protocolMode: CBUUID { CBUUID(string: "2A4E") }
        static var reportReference: CBUUID { CBUUID(string: "2908") }

        static var manufacturerName: CBUUID { CBUUID(string: "2A29") }
        static var pnpID: CBUUID { CBUUID(string: "2A50") }
        static var batteryLevel: CBUUID { CBUUID(string: "2A19") }
    }

    private let queue = DispatchQueue(label: "ble.hid", qos: .userInteractive)
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "ble")
    private var manager: CBPeripheralManager?

    // GATT
    private var hidInformation: CBMutableCharacteristic?
    private var reportMap: CBMutableCharacteristic?
    private var controlPoint: CBMutableCharacteristic?
    private var protocolMode: CBMutableCharacteristic?
    private var keyboardInput: CBMutableCharacteristic?
    private var keyboardOutput: CBMutableCharacteristic?
    private var mouseInput: CBMutableCharacteristic?
    private var manufacturerName: CBMutableCharacteristic?
    private var pnpID: CBMutableCharacteristic?
    private var batteryLevel: CBMutableCharacteristic?
    private var pendingServices = 0
    private var servicesReady = false

    // Connection: central id → characteristics it subscribed to.
    private var subscriptions: [UUID: Set<ObjectIdentifier>] = [:]

    // Report state
    private var protocolModeValue: UInt8 = 0x01 // Report Protocol
    private var keyboardLEDs: UInt8 = 0
    private var keyboardState = KeyboardState()
    private var keyboardQueue: [KeyboardReport] = []
    private var mouse = MouseAccumulator()
    private var waitingForReady = false

    private(set) var status: BluetoothStatus = .starting {
        didSet {
            guard status != oldValue else { return }
            log.info("status: \(String(describing: self.status), privacy: .public)")
            let handler = onStatusChange
            let status = self.status
            handler?(status)
        }
    }

    /// Called on the BLE queue whenever `status` changes.
    var onStatusChange: (@Sendable (BluetoothStatus) -> Void)?

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            log.info("starting CBPeripheralManager")
            manager = CBPeripheralManager(
                delegate: self,
                queue: queue,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
            )
        }
    }

    /// Sends neutral reports, stops advertising and removes the services.
    /// Blocks until done, so it is safe to call from `applicationWillTerminate`.
    func stop() {
        queue.sync { [self] in
            sendNeutralOnQueue()
            manager?.stopAdvertising()
            manager?.removeAllServices()
        }
    }

    // MARK: Sending (any thread)

    /// Adds relative motion and scroll; `buttons` replaces the pressed buttons when given.
    func sendMouse(
        dx: Double = 0, dy: Double = 0, buttons: MouseButtons? = nil,
        wheel: Double = 0, pan: Double = 0
    ) {
        queue.async { [self] in
            guard isConnected else { return }
            mouse.addMotion(dx: dx, dy: dy)
            mouse.addScroll(wheel: wheel, pan: pan)
            if let buttons { mouse.setButtons(buttons) }
            flush()
        }
    }

    /// Presses or releases a key by HID usage (modifiers are usages 0xE0…0xE7).
    func sendKey(usage: UInt8, isDown: Bool) {
        queue.async { [self] in
            guard isConnected else { return }
            if keyboardState.apply(usage: usage, isDown: isDown) {
                keyboardQueue.append(keyboardState.report)
                flush()
            }
        }
    }

    /// Releases every key and button on the host.
    func sendNeutral() {
        queue.async { [self] in sendNeutralOnQueue() }
    }

    // MARK: Queue-confined helpers

    private var isConnected: Bool { !subscriptions.isEmpty }

    private func sendNeutralOnQueue() {
        keyboardState.reset()
        keyboardQueue.removeAll()
        mouse.reset()
        guard isConnected else { return }
        keyboardQueue.append(.neutral)
        // Force a buttons-up report even if nothing is pending.
        mouseNeutralPending = true
        flush()
    }

    private var mouseNeutralPending = false

    /// Sends queued reports until CoreBluetooth's transmit queue is full.
    /// Keyboard reports go first and are never merged; mouse motion is merged.
    private func flush() {
        guard let manager, isConnected, !waitingForReady else { return }
        while true {
            if let report = keyboardQueue.first, let keyboardInput {
                guard manager.updateValue(Data(report.bytes), for: keyboardInput, onSubscribedCentrals: nil) else {
                    waitingForReady = true
                    return
                }
                keyboardQueue.removeFirst()
                continue
            }
            guard let mouseInput else { return }
            if mouseNeutralPending {
                guard manager.updateValue(Data(MouseReport.neutral.bytes), for: mouseInput, onSubscribedCentrals: nil) else {
                    waitingForReady = true
                    return
                }
                mouseNeutralPending = false
                continue
            }
            var next = mouse
            guard let report = next.nextReport() else { return }
            guard manager.updateValue(Data(report.bytes), for: mouseInput, onSubscribedCentrals: nil) else {
                waitingForReady = true
                return
            }
            mouse = next
        }
    }

    // MARK: GATT setup

    private func setUpServices() {
        guard let manager else { return }
        manager.removeAllServices()
        servicesReady = false

        var services: [CBMutableService] = []
        let error = UKMCatchObjCException { [self] in
            services = makeServices()
        }
        if let error {
            log.error("GATT definition rejected: \(error.localizedDescription, privacy: .public)")
            status = .failed("macOS отклонил GATT‑структуру: \(error.localizedDescription)")
            return
        }

        pendingServices = services.count
        for service in services {
            if let addError = UKMCatchObjCException({ manager.add(service) }) {
                log.error("add(\(service.uuid.uuidString, privacy: .public)) raised: \(addError.localizedDescription, privacy: .public)")
                status = .failed("macOS отклонил сервис \(service.uuid.uuidString): \(addError.localizedDescription)")
                return
            }
        }
    }

    private func makeServices() -> [CBMutableService] {
        let encryptedRead: CBAttributePermissions = [.readEncryptionRequired]
        let encryptedReadWrite: CBAttributePermissions = [.readEncryptionRequired, .writeEncryptionRequired]

        let hidInformation = CBMutableCharacteristic(
            type: UUIDs.hidInformation, properties: [.read], value: nil, permissions: encryptedRead)
        let reportMap = CBMutableCharacteristic(
            type: UUIDs.reportMap, properties: [.read], value: nil, permissions: encryptedRead)
        let controlPoint = CBMutableCharacteristic(
            type: UUIDs.hidControlPoint, properties: [.writeWithoutResponse], value: nil,
            permissions: [.writeEncryptionRequired])
        let protocolMode = CBMutableCharacteristic(
            type: UUIDs.protocolMode, properties: [.read, .writeWithoutResponse], value: nil,
            permissions: encryptedReadWrite)

        let keyboardInput = CBMutableCharacteristic(
            type: UUIDs.report, properties: [.read, .notify], value: nil, permissions: encryptedRead)
        keyboardInput.descriptors = [reportReference(id: HIDReportID.keyboard, type: .input)]

        let keyboardOutput = CBMutableCharacteristic(
            type: UUIDs.report, properties: [.read, .write, .writeWithoutResponse], value: nil,
            permissions: encryptedReadWrite)
        keyboardOutput.descriptors = [reportReference(id: HIDReportID.keyboard, type: .output)]

        let mouseInput = CBMutableCharacteristic(
            type: UUIDs.report, properties: [.read, .notify], value: nil, permissions: encryptedRead)
        mouseInput.descriptors = [reportReference(id: HIDReportID.mouse, type: .input)]

        let hid = CBMutableService(type: UUIDs.hidService, primary: true)
        hid.characteristics = [
            hidInformation, reportMap, controlPoint, protocolMode,
            keyboardInput, keyboardOutput, mouseInput,
        ]

        let manufacturerName = CBMutableCharacteristic(
            type: UUIDs.manufacturerName, properties: [.read], value: nil, permissions: [.readable])
        let pnpID = CBMutableCharacteristic(
            type: UUIDs.pnpID, properties: [.read], value: nil, permissions: [.readable])
        let deviceInfo = CBMutableService(type: UUIDs.deviceInfoService, primary: true)
        deviceInfo.characteristics = [manufacturerName, pnpID]

        let batteryLevel = CBMutableCharacteristic(
            type: UUIDs.batteryLevel, properties: [.read, .notify], value: nil, permissions: [.readable])
        let battery = CBMutableService(type: UUIDs.batteryService, primary: true)
        battery.characteristics = [batteryLevel]

        self.hidInformation = hidInformation
        self.reportMap = reportMap
        self.controlPoint = controlPoint
        self.protocolMode = protocolMode
        self.keyboardInput = keyboardInput
        self.keyboardOutput = keyboardOutput
        self.mouseInput = mouseInput
        self.manufacturerName = manufacturerName
        self.pnpID = pnpID
        self.batteryLevel = batteryLevel

        return [deviceInfo, battery, hid]
    }

    private func reportReference(id: UInt8, type: HIDReportType) -> CBMutableDescriptor {
        CBMutableDescriptor(type: UUIDs.reportReference, value: Data([id, type.rawValue]))
    }

    private func startAdvertising() {
        guard let manager, servicesReady, manager.state == .poweredOn, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: Self.localName,
            CBAdvertisementDataServiceUUIDsKey: [UUIDs.hidService],
        ])
    }

    /// Current value of a readable characteristic.
    private func value(for characteristic: CBCharacteristic) -> [UInt8]? {
        switch characteristic {
        case let c where c === hidInformation: HIDReportDescriptor.hidInformation
        case let c where c === reportMap: HIDReportDescriptor.reportMap
        case let c where c === protocolMode: [protocolModeValue]
        case let c where c === keyboardInput: keyboardState.report.bytes
        case let c where c === keyboardOutput: [keyboardLEDs]
        case let c where c === mouseInput: MouseReport.neutral.bytes
        case let c where c === manufacturerName: Array("UniversalKM".utf8)
        case let c where c === pnpID: HIDReportDescriptor.pnpID
        case let c where c === batteryLevel: [100]
        default: nil
        }
    }

    private func name(of characteristic: CBCharacteristic) -> String {
        switch characteristic {
        case let c where c === hidInformation: "HID Information"
        case let c where c === reportMap: "Report Map"
        case let c where c === controlPoint: "HID Control Point"
        case let c where c === protocolMode: "Protocol Mode"
        case let c where c === keyboardInput: "Report (keyboard in)"
        case let c where c === keyboardOutput: "Report (keyboard out)"
        case let c where c === mouseInput: "Report (mouse in)"
        case let c where c === manufacturerName: "Manufacturer Name"
        case let c where c === pnpID: "PnP ID"
        case let c where c === batteryLevel: "Battery Level"
        default: characteristic.uuid.uuidString
        }
    }

    private func updateConnectionStatus() {
        if let host = subscriptions.keys.first {
            status = .connected(hostID: host)
        } else if servicesReady, manager?.state == .poweredOn {
            status = .advertising
        }
    }
}

// MARK: - CBPeripheralManagerDelegate (called on `queue`)

extension BluetoothHIDServer: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log.info("state: \(peripheral.state.rawValue, privacy: .public)")
        switch peripheral.state {
        case .poweredOn:
            setUpServices()
        case .poweredOff:
            subscriptions.removeAll()
            status = .poweredOff
        case .unauthorized:
            status = .unauthorized
        case .unsupported:
            status = .unsupported
        case .resetting, .unknown:
            subscriptions.removeAll()
            status = .starting
        @unknown default:
            status = .starting
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.error("didAdd \(service.uuid.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("macOS не дал добавить сервис \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        log.info("didAdd \(service.uuid.uuidString, privacy: .public) OK")
        pendingServices -= 1
        if pendingServices == 0 {
            servicesReady = true
            startAdvertising()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            log.error("advertising failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("Не удалось начать рекламу: \(error.localizedDescription)")
            return
        }
        log.info("advertising as \(Self.localName, privacy: .public)")
        updateConnectionStatus()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        log.info("central \(central.identifier, privacy: .public) subscribed to \(self.name(of: characteristic), privacy: .public), max update \(central.maximumUpdateValueLength, privacy: .public)")
        let wasConnected = isConnected
        subscriptions[central.identifier, default: []].insert(ObjectIdentifier(characteristic))
        if !wasConnected {
            peripheral.stopAdvertising()
            waitingForReady = false
        }
        updateConnectionStatus()
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        log.info("central \(central.identifier, privacy: .public) unsubscribed from \(self.name(of: characteristic), privacy: .public)")
        subscriptions[central.identifier]?.remove(ObjectIdentifier(characteristic))
        if subscriptions[central.identifier]?.isEmpty == true {
            subscriptions[central.identifier] = nil
        }
        if !isConnected {
            // Host went away (unsubscribe also fires on link loss): forget pressed state
            // and advertise again.
            keyboardState.reset()
            keyboardQueue.removeAll()
            mouse.reset()
            mouseNeutralPending = false
            waitingForReady = false
            startAdvertising()
        }
        updateConnectionStatus()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        waitingForReady = false
        flush()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let value = value(for: request.characteristic) else {
            log.error("read of unknown characteristic \(request.characteristic.uuid.uuidString, privacy: .public)")
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        log.debug("read \(self.name(of: request.characteristic), privacy: .public) offset \(request.offset, privacy: .public)")
        request.value = Data(value[request.offset...])
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let bytes = [UInt8](request.value ?? Data())
            switch request.characteristic {
            case let c where c === protocolMode:
                if let mode = bytes.first { protocolModeValue = mode }
                log.info("Protocol Mode ← \(bytes, privacy: .public)")
            case let c where c === controlPoint:
                log.info("HID Control Point ← \(bytes, privacy: .public)")
            case let c where c === keyboardOutput:
                if let leds = bytes.first { keyboardLEDs = leds }
                log.debug("keyboard LEDs ← \(bytes, privacy: .public)")
            default:
                log.error("write to unexpected \(request.characteristic.uuid.uuidString, privacy: .public)")
                peripheral.respond(to: request, withResult: .writeNotPermitted)
                return
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}
