import CoreBluetooth
import os.log

/// BLE connection states matching the web app.
enum ConnectionState: String, Sendable {
    case disconnected
    case scanning
    case connecting
    case connected
    case reconnecting
}

/// CoreBluetooth central manager for the uCrit device.
/// Ported from src/ble/connection.ts → BleConnection class.
@Observable
final class BLEManager: NSObject {

    // MARK: - Published State

    var connectionState: ConnectionState = .disconnected
    private(set) var discoveredPeripherals: [CBPeripheral] = []

    // MARK: - Internal State

    private(set) var connectedPeripheral: CBPeripheral?
    /// CoreBluetooth central manager. Implicitly unwrapped because `CBCentralManager(delegate:)`
    /// requires `self`, so initialization must occur after `super.init()`. Always non-nil after init.
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var centralManager: CBCentralManager!
    private var customService: CBService?
    private var essService: CBService?
    private var characteristicCache: [CBUUID: CBCharacteristic] = [:]

    // Reconnection (matches web app: 2 attempts, 3s delay, 5s timeout)
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 2
    private let reconnectDelay: TimeInterval = 3.0
    private let connectTimeout: TimeInterval = 5.0
    private var connectTimeoutWork: DispatchWorkItem?

    // Current cell polling (5s interval, matches web app)
    private var pollTimer: Timer?

    // Async/await bridging for characteristic reads/writes
    private var pendingReads: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var pendingWrites: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    // Services discovered continuation
    private var serviceDiscoveryContinuation: CheckedContinuation<Void, Error>?
    private var charDiscoveryCount = 0
    private var charDiscoveryTarget = 0

    // Callbacks to ViewModels
    var onSensorUpdate: ((PartialSensorUpdate) -> Void)?
    var onConnectionStateChanged: ((ConnectionState) -> Void)?

    /// Callback for log stream notification payloads (raw Data).
    /// Set by BLELogStream before starting a stream, cleared on completion.
    var onLogStreamNotification: ((Data) -> Void)?

    /// One-shot callback for when Bluetooth becomes ready (poweredOn).
    private var onBluetoothReady: (() -> Void)?

    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "BLE")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    /// The stable BLE identifier of the currently connected device.
    var connectedDeviceId: String? {
        connectedPeripheral?.identifier.uuidString
    }

    /// Register a one-shot callback for when Bluetooth becomes ready.
    /// If already poweredOn, fires immediately.
    func whenBluetoothReady(_ callback: @escaping () -> Void) {
        if centralManager.state == .poweredOn {
            callback()
        } else {
            onBluetoothReady = callback
        }
    }

    // MARK: - Public API

    /// Reconnect to a previously known device by its stored UUID.
    /// Uses CoreBluetooth's `retrievePeripherals` to get the CBPeripheral
    /// without requiring a full scan.
    func reconnectToKnownDevice(identifier: UUID) {
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = peripherals.first {
            connect(to: peripheral)
        } else {
            // Device not nearby — fall back to scan
            logger.info("Known device not found nearby, starting scan")
            scan()
        }
    }

    /// Start scanning for uCrit devices.
    func scan() {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot scan: Bluetooth not powered on")
            return
        }

        discoveredPeripherals = []
        setState(.scanning)
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.customServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Connect to a discovered peripheral.
    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        setState(.connecting)
        reconnectAttempts = 0

        // Connect with timeout
        startConnectTimeout()
        centralManager.connect(peripheral, options: nil)
    }

    /// Disconnect from the current device.
    func disconnect() {
        stopCurrentCellPolling()
        cancelConnectTimeout()
        reconnectAttempts = maxReconnectAttempts // prevent auto-reconnect

        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        cleanupConnection()
        setState(.disconnected)
    }

    /// Read a custom service characteristic.
    /// Dictionary access and CB calls are dispatched to the main queue to prevent
    /// data races when multiple reads are issued concurrently (e.g. async let).
    func readCharacteristic(_ uuid: CBUUID) async throws -> Data {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.pendingReads[uuid] = continuation
                peripheral.readValue(for: char)
            }
        }
    }

    /// Write data to a custom service characteristic.
    func writeCharacteristic(_ uuid: CBUUID, data: Data) async throws {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.pendingWrites[uuid] = continuation
                peripheral.writeValue(data, for: char, type: .withResponse)
            }
        }
    }

    /// Read an ESS service characteristic.
    func readESSCharacteristic(_ uuid: CBUUID) async throws -> Data {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.pendingReads[uuid] = continuation
                peripheral.readValue(for: char)
            }
        }
    }

    // MARK: - Private Helpers

    /// Update the connection state and notify observers.
    /// - Parameter state: The new connection state to transition to.
    private func setState(_ state: ConnectionState) {
        connectionState = state
        onConnectionStateChanged?(state)
    }

    /// Reset all connection-related state to a clean baseline.
    ///
    /// Clears the peripheral reference, cached services and characteristics,
    /// pending read/write continuations, and the log stream callback.
    private func cleanupConnection() {
        connectedPeripheral = nil
        customService = nil
        essService = nil
        characteristicCache = [:]
        pendingReads = [:]
        pendingWrites = [:]
        serviceDiscoveryContinuation = nil
        onLogStreamNotification = nil
    }

    /// Schedule a timeout that fires after ``connectTimeout`` seconds.
    ///
    /// If the connection has not completed by then, the peripheral connection
    /// is cancelled and ``handleDisconnect()`` is invoked to attempt reconnection.
    private func startConnectTimeout() {
        cancelConnectTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .connecting || self.connectionState == .reconnecting else { return }
            self.logger.warning("Connect timeout")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            self.handleDisconnect()
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: work)
    }

    /// Cancel any pending connection timeout work item.
    private func cancelConnectTimeout() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
    }

    // MARK: - ESS Subscriptions

    /// Subscribe to ESS notifications and read non-notify characteristics.
    /// Matches web app's subscribeToESS().
    private func subscribeToESS() {
        guard let peripheral = connectedPeripheral else { return }

        // Subscribe to notify characteristics
        for uuid in BLEConstants.essNotifyCharacteristicUUIDs {
            if let char = characteristicCache[uuid] {
                peripheral.setNotifyValue(true, for: char)
            } else {
                logger.warning("ESS characteristic not found for notification: \(uuid)")
            }
        }

        // Read non-notify characteristics once
        for uuid in BLEConstants.essReadCharacteristicUUIDs {
            if let char = characteristicCache[uuid] {
                peripheral.readValue(for: char)
            }
        }
    }

    // MARK: - Log Stream Notifications

    /// Enable or disable notifications for the log stream characteristic.
    func setLogStreamNotifications(enabled: Bool) {
        guard let peripheral = connectedPeripheral,
              let char = characteristicCache[BLEConstants.charLogStream] else { return }
        peripheral.setNotifyValue(enabled, for: char)
    }

    /// Pause current cell polling (e.g. during log streaming to avoid BLE interleaving).
    func pausePolling() {
        stopCurrentCellPolling()
    }

    /// Resume current cell polling after a pause.
    func resumePolling() {
        guard connectionState == .connected else { return }
        startCurrentCellPolling()
    }

    // MARK: - Current Cell Polling

    /// Poll the "current cell" via custom service to get live VOC/NOx/PM4.0 values.
    /// These sensors are NOT exposed via ESS — only via log cell data.
    /// Writing 0xFFFFFFFF to the cell selector selects the live/current cell.
    /// Matches web app's startCurrentCellPolling().
    private func startCurrentCellPolling() {
        stopCurrentCellPolling()

        // Poll immediately, then every 5 seconds
        pollCurrentCell()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollCurrentCell()
        }
    }

    /// Stop the repeating current-cell poll timer and release it.
    private func stopCurrentCellPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Write the live-cell selector (`0xFFFFFFFF`) and read back the cell data.
    ///
    /// The write selects the device's current (live) log cell, then after a
    /// short delay the cell data characteristic is read. The parsed result
    /// provides VOC, NOx, and PM4.0 values not available via ESS.
    private func pollCurrentCell() {
        guard let peripheral = connectedPeripheral,
              let selectorChar = characteristicCache[BLEConstants.charCellSelector],
              let dataChar = characteristicCache[BLEConstants.charCellData] else { return }

        // Write 0xFFFFFFFF to cell selector
        var selectorData = Data(count: 4)
        selectorData.writeUInt32LE(BLEConstants.logStreamEndMarker, at: 0)
        peripheral.writeValue(selectorData, for: selectorChar, type: .withResponse)

        // Read will happen in didWriteValueFor callback → then we read cell data
        // For simplicity, we read after a small delay to allow the write to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self?.connectionState == .connected else { return }
            peripheral.readValue(for: dataChar)
        }
    }

    // MARK: - Reconnection

    /// Handle unexpected disconnect — attempt reconnection.
    /// Matches web app's handleDisconnect().
    private func handleDisconnect() {
        stopCurrentCellPolling()
        cancelConnectTimeout()
        customService = nil
        essService = nil

        if reconnectAttempts < maxReconnectAttempts, let peripheral = connectedPeripheral {
            setState(.reconnecting)
            reconnectAttempts += 1
            logger.info("Reconnect attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts)...")

            DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
                guard let self, self.connectionState == .reconnecting else { return }
                self.startConnectTimeout()
                self.centralManager.connect(peripheral, options: nil)
            }
        } else {
            logger.info("Reconnection gave up — use Connect button to re-pair")
            cleanupConnection()
            setState(.disconnected)
        }
    }

    // MARK: - Service/Characteristic Discovery Flow

    /// Kick off GATT service discovery for the custom vendor service and ESS.
    ///
    /// Called immediately after a successful connection. Discovered characteristics
    /// are cached in ``characteristicCache`` via the peripheral delegate callback.
    private func discoverServices() {
        guard let peripheral = connectedPeripheral else { return }
        peripheral.discoverServices([BLEConstants.customServiceUUID, BLEConstants.essServiceUUID])
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    /// Called when the Bluetooth radio state changes (e.g. poweredOn, poweredOff).
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central manager state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            onBluetoothReady?()
            onBluetoothReady = nil  // Fire only once
        }
        if central.state != .poweredOn && connectionState == .scanning {
            setState(.disconnected)
        }
    }

    /// Called when a peripheral advertising the custom service UUID is discovered during scanning.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            logger.info("Discovered: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        }
    }

    /// Called when the peripheral connection succeeds. Begins service discovery.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.name ?? "Unknown")")
        cancelConnectTimeout()
        characteristicCache = [:]
        discoverServices()
    }

    /// Called when the peripheral connection attempt fails. Triggers reconnection logic.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "Unknown")")
        cancelConnectTimeout()
        handleDisconnect()
    }

    /// Called when the peripheral disconnects (clean or unexpected). Triggers reconnection logic.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Disconnected: \(error?.localizedDescription ?? "clean")")
        handleDisconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    /// Called after GATT service discovery completes. Initiates characteristic discovery for each service.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.error("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        for service in services {
            if service.uuid == BLEConstants.customServiceUUID {
                customService = service
                peripheral.discoverCharacteristics(BLEConstants.allCustomCharacteristicUUIDs, for: service)
            } else if service.uuid == BLEConstants.essServiceUUID {
                essService = service
                peripheral.discoverCharacteristics(BLEConstants.allESSCharacteristicUUIDs, for: service)
            }
        }
    }

    /// Called after characteristic discovery for a service. Caches characteristics and finalizes the connection once all services are ready.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            logger.error("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            characteristicCache[char.uuid] = char
        }

        // Check if we've discovered characteristics for all services
        let hasCustomChars = customService?.characteristics != nil
        let hasESSChars = essService?.characteristics != nil || essService == nil

        if hasCustomChars && hasESSChars {
            // All services discovered — finalize connection
            reconnectAttempts = 0
            setState(.connected)
            subscribeToESS()
            startCurrentCellPolling()
        }
    }

    /// Called when a characteristic value is read or a notification is received. Routes data to pending continuations, log stream callbacks, or ESS/cell-data sensor update handlers.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        // Handle pending async reads
        if let continuation = pendingReads.removeValue(forKey: uuid) {
            if let error {
                continuation.resume(throwing: error)
            } else if let data = characteristic.value {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: BLEError.noData)
            }
            return
        }

        // Handle log stream notifications (Phase 2)
        if uuid == BLEConstants.charLogStream {
            if let data = characteristic.value {
                onLogStreamNotification?(data)
            }
            return
        }

        // Handle ESS notifications and reads
        guard let data = characteristic.value else { return }

        switch uuid {
        case BLEConstants.essTemperature:
            let temp = BLEParsers.parseTemperature(data)
            onSensorUpdate?(PartialSensorUpdate(temperature: temp))

        case BLEConstants.essHumidity:
            let hum = BLEParsers.parseHumidity(data)
            onSensorUpdate?(PartialSensorUpdate(humidity: hum))

        case BLEConstants.essCO2:
            let co2 = BLEParsers.parseCO2(data)
            onSensorUpdate?(PartialSensorUpdate(co2: co2))

        case BLEConstants.essPM2_5:
            let pm = BLEParsers.parsePM(data)
            onSensorUpdate?(PartialSensorUpdate(pm2_5: pm))

        case BLEConstants.essPressure:
            let pres = BLEParsers.parsePressure(data)
            onSensorUpdate?(PartialSensorUpdate(pressure: pres))

        case BLEConstants.essPM1_0:
            let pm = BLEParsers.parsePM(data)
            onSensorUpdate?(PartialSensorUpdate(pm1_0: pm))

        case BLEConstants.essPM10:
            let pm = BLEParsers.parsePM(data)
            onSensorUpdate?(PartialSensorUpdate(pm10: pm))

        case BLEConstants.charCellData:
            // Current cell poll result — extract VOC, NOx, PM4.0
            if data.count >= BLEConstants.logCellNotificationSize {
                let cell = BLEParsers.parseLogCell(data)
                var update = PartialSensorUpdate()
                if cell.voc > 0 { update.voc = Double(cell.voc) }
                if cell.nox > 0 { update.nox = Double(cell.nox) }
                update.pm4_0 = cell.pm.2 // PM4.0
                onSensorUpdate?(update)
            }

        default:
            break
        }
    }

    /// Called after a write-with-response completes. Resumes the pending write continuation.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        if let continuation = pendingWrites.removeValue(forKey: uuid) {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    /// Called when notification subscription state changes for a characteristic. Logs success or failure.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.warning("Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
        }
    }
}

// MARK: - Errors

enum BLEError: LocalizedError {
    case notConnected
    case characteristicNotFound(CBUUID)
    case noData
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to device"
        case .characteristicNotFound(let uuid): return "Characteristic not found: \(uuid)"
        case .noData: return "No data received"
        case .timeout: return "Connection timed out"
        }
    }
}
