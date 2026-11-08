import CoreBluetooth
import Foundation
import os

/// Bluetooth control channel to the ChameleonUltra (design D5, "Управление по Bluetooth"): the upstream
/// Nordic UART Service carries the same netdata frames as USB. The Mac is a plain GATT client here (no
/// pairing, not a HID connection). Only the Chameleon whose advertised device address (manufacturer
/// data 0xFFFF in the HID mode scan response) matches the address read over USB is used.
/// All callbacks run on the given queue.
final class ChameleonBLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static var nusService: CBUUID { CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") }
    static var nusRX: CBUUID { CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") }
    static var nusTX: CBUUID { CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") }
    static let companyID: [UInt8] = [0xFF, 0xFF]

    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "ble-link")
    private let queue: DispatchQueue
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private(set) var isReady = false

    /// Device address (most significant byte first) of our Chameleon; nil until known.
    var targetAddress: [UInt8]? {
        didSet { if targetAddress != oldValue { restart() } }
    }

    var onReady: (() -> Void)?
    var onData: (([UInt8]) -> Void)?
    var onLost: (() -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func write(_ bytes: [UInt8]) -> Bool {
        guard isReady, let peripheral, let rx else { return false }
        let type: CBCharacteristicWriteType = peripheral.canSendWriteWithoutResponse ? .withoutResponse : .withResponse
        // Frames are small; split only if the ATT payload is smaller than the frame.
        let chunk = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + chunk)
            peripheral.writeValue(Data(bytes[offset..<end]), for: rx, type: type)
            offset = end
        }
        return true
    }

    // MARK: Connection

    private func restart() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        rx = nil
        setReady(false)
        scanIfPossible()
    }

    private func scanIfPossible() {
        guard let central, central.state == .poweredOn, targetAddress != nil, peripheral == nil else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("Bluetooth state \(central.state.rawValue)")
        if central.state == .poweredOn {
            scanIfPossible()
        } else {
            peripheral = nil
            rx = nil
            setReady(false)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, let target = targetAddress,
              let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              Array(manufacturer) == Self.companyID + target
        else { return }
        log.info("found our Chameleon (\(peripheral.identifier, privacy: .public)), connecting")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.nusService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("connect failed: \(error?.localizedDescription ?? "", privacy: .public)")
        self.peripheral = nil
        scanIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log.info("disconnected")
        self.peripheral = nil
        rx = nil
        setReady(false)
        // The Chameleon advertises again while the HID mode is on and a link is free.
        scanIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.nusService }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.nusRX, Self.nusTX], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        rx = service.characteristics?.first { $0.uuid == Self.nusRX }
        guard rx != nil, let tx = service.characteristics?.first(where: { $0.uuid == Self.nusTX }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        // Subscribing makes this link the firmware's control channel (it is then not a HID host).
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.nusTX else { return }
        if characteristic.isNotifying {
            log.info("control channel ready")
            setReady(true)
        } else {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.nusTX, let value = characteristic.value else { return }
        onData?(Array(value))
    }

    private func setReady(_ ready: Bool) {
        guard ready != isReady else { return }
        isReady = ready
        if ready { onReady?() } else { onLost?() }
    }
}
