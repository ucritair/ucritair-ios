@preconcurrency import CoreBluetooth
import os.log

enum ConnectionState: String, Sendable {
    case disconnected

    case scanning

    case connecting

    case connected

    case reconnecting
}

@Observable
final class BLEManager: NSObject, @unchecked Sendable {

    var connectionState: ConnectionState = .disconnected

    private(set) var discoveredPeripherals: [CBPeripheral] = []

    private(set) var bluetoothState: CBManagerState = .unknown

    private(set) var connectedPeripheral: CBPeripheral?

    private let centralManager: CBCentralManager

    private var customService: CBService?

    private var essService: CBService?

    private var characteristicCache: [CBUUID: CBCharacteristic] = [:]

    private var expectedCharacteristicServices: Set<CBUUID> = []

    private var completedCharacteristicServices: Set<CBUUID> = []

    private var reconnectAttempts = 0

    private let maxReconnectAttempts = 2

    private let reconnectDelay: TimeInterval = 3.0

    private let connectTimeout: TimeInterval = 5.0

    private var connectTimeoutWork: DispatchWorkItem?

    private var pollTimer: Timer?

    // Thread safety: All mutable state (including these dictionaries) is accessed
    // exclusively on the main queue. CBCentralManager is initialised with queue: .main,
    // so all delegate callbacks run on main. Async read/write methods dispatch to main
    // before touching pendingReads/Writes. No additional locking is needed.
    private var pendingReads: [CBUUID: CheckedContinuation<Data, Error>] = [:]

    private var pendingWrites: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    private var pendingWriteCallbacks: [CBUUID: (Error?) -> Void] = [:]

    private var sensorUpdateObservers: [UUID: (PartialSensorUpdate) -> Void] = [:]

    private var connectionStateObservers: [UUID: (ConnectionState) -> Void] = [:]

    var onLogStreamNotification: ((Data) -> Void)?

    private var onBluetoothReady: (() -> Void)?

    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "BLE")

#if DEBUG
    private var mockConnectedDeviceID: String?
#endif

    override init() {
        centralManager = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        centralManager.delegate = self
    }

    deinit {
        pollTimer?.invalidate()
    }

    var connectedDeviceId: String? {
#if DEBUG
        mockConnectedDeviceID ?? connectedPeripheral?.identifier.uuidString
#else
        connectedPeripheral?.identifier.uuidString
#endif
    }

    func whenBluetoothReady(_ callback: @escaping () -> Void) {
        if centralManager.state == .poweredOn {
            callback()
        } else {
            onBluetoothReady = callback
        }
    }

    @discardableResult
    func addConnectionStateObserver(_ observer: @escaping (ConnectionState) -> Void) -> UUID {
        let token = UUID()
        connectionStateObservers[token] = observer
        return token
    }

    func removeConnectionStateObserver(_ token: UUID) {
        connectionStateObservers.removeValue(forKey: token)
    }

    @discardableResult
    func addSensorUpdateObserver(_ observer: @escaping (PartialSensorUpdate) -> Void) -> UUID {
        let token = UUID()
        sensorUpdateObservers[token] = observer
        return token
    }

    func removeSensorUpdateObserver(_ token: UUID) {
        sensorUpdateObservers.removeValue(forKey: token)
    }

#if DEBUG
    func _testEmitConnectionState(_ state: ConnectionState) {
        emitConnectionStateChange(state)
    }

    func _testEmitSensorUpdate(_ update: PartialSensorUpdate) {
        emitSensorUpdate(update)
    }

    func _testSetMockConnectionState(_ state: ConnectionState, deviceId: String? = nil) {
        mockConnectedDeviceID = deviceId
        connectionState = state
        emitConnectionStateChange(state)
    }
#endif

    func reconnectToKnownDevice(identifier: UUID) {
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = peripherals.first {
            connect(to: peripheral)
        } else {
            logger.info("Known device not found nearby, starting scan")
            scan()
        }
    }

    func scan() {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot scan: Bluetooth not powered on")
            return
        }

        discoveredPeripherals = []
        setState(.scanning)

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        expectedCharacteristicServices = []
        completedCharacteristicServices = []
        setState(.connecting)
        reconnectAttempts = 0

        startConnectTimeout()
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        centralManager.stopScan()
        stopCurrentCellPolling()
        cancelConnectTimeout()

        reconnectAttempts = maxReconnectAttempts

        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        cleanupConnection()
        setState(.disconnected)
    }

    func readCharacteristic(_ uuid: CBUUID) async throws -> Data {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                if self.pendingReads[uuid] != nil {
                    continuation.resume(throwing: BLEError.operationInProgress)
                    return
                }
                self.pendingReads[uuid] = continuation
                peripheral.readValue(for: char)
            }
        }
    }

    func writeCharacteristic(_ uuid: CBUUID, data: Data) async throws {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                if self.pendingWrites[uuid] != nil || self.pendingWriteCallbacks[uuid] != nil {
                    continuation.resume(throwing: BLEError.operationInProgress)
                    return
                }
                self.pendingWrites[uuid] = continuation
                peripheral.writeValue(data, for: char, type: .withResponse)
            }
        }
    }

    func writeCharacteristic(_ uuid: CBUUID, data: Data, completion: @escaping (Error?) -> Void) {
        guard let char = characteristicCache[uuid] else {
            completion(BLEError.characteristicNotFound(uuid))
            return
        }
        guard let peripheral = connectedPeripheral else {
            completion(BLEError.notConnected)
            return
        }

        DispatchQueue.main.async {
            if self.pendingWrites[uuid] != nil || self.pendingWriteCallbacks[uuid] != nil {
                completion(BLEError.operationInProgress)
                return
            }
            self.pendingWriteCallbacks[uuid] = completion
            peripheral.writeValue(data, for: char, type: .withResponse)
        }
    }


    private func setState(_ state: ConnectionState) {
        connectionState = state
        emitConnectionStateChange(state)
    }

    private func emitConnectionStateChange(_ state: ConnectionState) {
        for observer in Array(connectionStateObservers.values) {
            observer(state)
        }
    }

    private func emitSensorUpdate(_ update: PartialSensorUpdate) {
        for observer in Array(sensorUpdateObservers.values) {
            observer(update)
        }
    }

    private func failPendingContinuations() {
        for (_, continuation) in pendingReads {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingReads = [:]

        for (_, continuation) in pendingWrites {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingWrites = [:]

        for (_, callback) in pendingWriteCallbacks {
            callback(BLEError.notConnected)
        }
        pendingWriteCallbacks = [:]

    }

    private func cleanupConnection() {
        connectedPeripheral = nil
        customService = nil
        essService = nil
        characteristicCache = [:]
        expectedCharacteristicServices = []
        completedCharacteristicServices = []
        failPendingContinuations()
        onLogStreamNotification = nil
    }

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

    private func cancelConnectTimeout() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
    }

    private func handleDiscoveryFailure(_ message: String) {
        logger.error("\(message, privacy: .public)")
        guard connectionState == .connecting || connectionState == .reconnecting else { return }
        handleDisconnect()
    }

    private func resetForUnavailableBluetoothState() {
        guard connectionState != .disconnected else { return }
        centralManager.stopScan()
        discoveredPeripherals = []
        stopCurrentCellPolling()
        cancelConnectTimeout()
        cleanupConnection()
        setState(.disconnected)
    }

    private func finalizeConnectionIfDiscoveryComplete() {
        guard connectionState == .connecting || connectionState == .reconnecting else { return }
        guard !expectedCharacteristicServices.isEmpty else { return }
        guard expectedCharacteristicServices.isSubset(of: completedCharacteristicServices) else { return }

        let discovered = Set(characteristicCache.keys)
        let requiredCustom = Set(BLEConstants.requiredCustomCharacteristicUUIDs)
        let missingCustom = requiredCustom.subtracting(discovered)
        guard missingCustom.isEmpty else {
            let missing = missingCustom.map(\.uuidString).sorted().joined(separator: ", ")
            handleDiscoveryFailure("Missing required custom characteristics: \(missing)")
            return
        }

        if expectedCharacteristicServices.contains(BLEConstants.essServiceUUID) {
            let requiredESS = Set(BLEConstants.requiredESSCharacteristicUUIDs)
            let missingESS = requiredESS.subtracting(discovered)
            guard missingESS.isEmpty else {
                let missing = missingESS.map(\.uuidString).sorted().joined(separator: ", ")
                handleDiscoveryFailure("Missing required ESS characteristics: \(missing)")
                return
            }
        }

        cancelConnectTimeout()
        reconnectAttempts = 0
        setState(.connected)
        subscribeToESS()
        startCurrentCellPolling()
    }

    private func subscribeToESS() {
        guard let peripheral = connectedPeripheral else { return }

        for uuid in BLEConstants.essNotifyCharacteristicUUIDs {
            if let char = characteristicCache[uuid] {
                peripheral.setNotifyValue(true, for: char)
            } else {
                logger.warning("ESS characteristic not found for notification: \(uuid)")
            }
        }

        for uuid in BLEConstants.essReadCharacteristicUUIDs {
            if let char = characteristicCache[uuid] {
                peripheral.readValue(for: char)
            }
        }
    }

    func setLogStreamNotifications(enabled: Bool) {
        guard let peripheral = connectedPeripheral,
              let char = characteristicCache[BLEConstants.charLogStream] else { return }
        peripheral.setNotifyValue(enabled, for: char)
    }

    func pausePolling() {
        stopCurrentCellPolling()
    }

    func resumePolling() {
        guard connectionState == .connected else { return }
        startCurrentCellPolling()
    }

    private func startCurrentCellPolling() {
        stopCurrentCellPolling()

        pollCurrentCell()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollCurrentCell()
        }
    }

    private func stopCurrentCellPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollCurrentCell() {
        guard connectionState == .connected else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var selectorData = Data(count: 4)
                selectorData.writeUInt32LE(BLEConstants.logStreamEndMarker, at: 0)
                try await self.writeCharacteristic(BLEConstants.charCellSelector, data: selectorData)

                let data = try await self.readCharacteristic(BLEConstants.charCellData)
                guard data.count >= BLEConstants.logCellNotificationSize else { return }

                let cell = try BLEParsers.parseLogCell(data)

                var update = PartialSensorUpdate()
                if cell.voc > 0 { update.voc = Double(cell.voc) }
                if cell.nox > 0 { update.nox = Double(cell.nox) }
                update.pm4_0 = cell.pm.pm4_0
                self.emitSensorUpdate(update)
            } catch {
                self.logger.debug("Current-cell poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleDisconnect() {
        stopCurrentCellPolling()
        cancelConnectTimeout()

        customService = nil
        essService = nil
        characteristicCache = [:]
        expectedCharacteristicServices = []
        completedCharacteristicServices = []

        failPendingContinuations()

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

    private func discoverServices() {
        guard let peripheral = connectedPeripheral else { return }
        peripheral.discoverServices([BLEConstants.customServiceUUID, BLEConstants.essServiceUUID])
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central manager state: \(central.state.rawValue)")

#if DEBUG
        if DebugAppScenario.current == .uiConnected {
            bluetoothState = .poweredOn
            return
        }
#endif

        bluetoothState = central.state

        switch central.state {
        case .poweredOn:
            onBluetoothReady?()
            onBluetoothReady = nil

        case .poweredOff, .unauthorized, .unsupported, .resetting, .unknown:
            resetForUnavailableBluetoothState()

        @unknown default:
            resetForUnavailableBluetoothState()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard BLEDiscovery.isLikelyUCritDevice(
            peripheralName: peripheral.name,
            advertisementData: advertisementData
        ) else {
            return
        }

        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            logger.info("Discovered: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.name ?? "Unknown")")
        customService = nil
        essService = nil
        characteristicCache = [:]
        expectedCharacteristicServices = []
        completedCharacteristicServices = []
        discoverServices()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "Unknown")")
        cancelConnectTimeout()
        handleDisconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectionState != .disconnected else { return }
        logger.info("Disconnected: \(error?.localizedDescription ?? "clean")")
        handleDisconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            handleDiscoveryFailure("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            handleDiscoveryFailure("Service discovery returned no services")
            return
        }

        expectedCharacteristicServices = []
        completedCharacteristicServices = []

        for service in services {
            if service.uuid == BLEConstants.customServiceUUID {
                customService = service
                expectedCharacteristicServices.insert(service.uuid)
                peripheral.discoverCharacteristics(BLEConstants.allCustomCharacteristicUUIDs, for: service)
            } else if service.uuid == BLEConstants.essServiceUUID {
                essService = service
                expectedCharacteristicServices.insert(service.uuid)
                peripheral.discoverCharacteristics(BLEConstants.allESSCharacteristicUUIDs, for: service)
            }
        }

        if customService == nil {
            handleDiscoveryFailure("Required custom service not found on connected peripheral")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            handleDiscoveryFailure("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            handleDiscoveryFailure("Characteristic discovery returned no characteristics for service \(service.uuid)")
            return
        }

        for char in characteristics {
            characteristicCache[char.uuid] = char
        }
        completedCharacteristicServices.insert(service.uuid)
        finalizeConnectionIfDiscoveryComplete()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

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

        if uuid == BLEConstants.charLogStream {
            if let data = characteristic.value {
                onLogStreamNotification?(data)
            }
            return
        }

        guard let data = characteristic.value else { return }

        switch uuid {
        case BLEConstants.essTemperature:
            guard data.count >= 2 else { break }
            if let temp = try? BLEParsers.parseTemperature(data) {
                emitSensorUpdate(PartialSensorUpdate(temperature: temp))
            } else {
                logger.warning("Malformed ESS temperature payload (\(data.count) bytes)")
            }

        case BLEConstants.essHumidity:
            guard data.count >= 2 else { break }
            if let hum = try? BLEParsers.parseHumidity(data) {
                emitSensorUpdate(PartialSensorUpdate(humidity: hum))
            } else {
                logger.warning("Malformed ESS humidity payload (\(data.count) bytes)")
            }

        case BLEConstants.essCO2:
            guard data.count >= 2 else { break }
            if let co2 = try? BLEParsers.parseCO2(data) {
                emitSensorUpdate(PartialSensorUpdate(co2: co2))
            } else {
                logger.warning("Malformed ESS CO2 payload (\(data.count) bytes)")
            }

        case BLEConstants.essPM2_5:
            guard data.count >= 2 else { break }
            if let pm = try? BLEParsers.parsePM(data) {
                emitSensorUpdate(PartialSensorUpdate(pm2_5: pm))
            } else {
                logger.warning("Malformed ESS PM2.5 payload (\(data.count) bytes)")
            }

        case BLEConstants.essPressure:
            guard data.count >= 4 else { break }
            if let pres = try? BLEParsers.parsePressure(data) {
                emitSensorUpdate(PartialSensorUpdate(pressure: pres))
            } else {
                logger.warning("Malformed ESS pressure payload (\(data.count) bytes)")
            }

        case BLEConstants.essPM1_0:
            guard data.count >= 2 else { break }
            if let pm = try? BLEParsers.parsePM(data) {
                emitSensorUpdate(PartialSensorUpdate(pm1_0: pm))
            } else {
                logger.warning("Malformed ESS PM1.0 payload (\(data.count) bytes)")
            }

        case BLEConstants.essPM10:
            guard data.count >= 2 else { break }
            if let pm = try? BLEParsers.parsePM(data) {
                emitSensorUpdate(PartialSensorUpdate(pm10: pm))
            } else {
                logger.warning("Malformed ESS PM10 payload (\(data.count) bytes)")
            }

        case BLEConstants.charCellData:
            if data.count >= BLEConstants.logCellNotificationSize {
                if let cell = try? BLEParsers.parseLogCell(data) {
                    var update = PartialSensorUpdate()
                    if cell.voc > 0 { update.voc = Double(cell.voc) }
                    if cell.nox > 0 { update.nox = Double(cell.nox) }
                    update.pm4_0 = cell.pm.pm4_0
                    emitSensorUpdate(update)
                } else {
                    logger.warning("Malformed current-cell payload (\(data.count) bytes)")
                }
            }

        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        if let callback = pendingWriteCallbacks.removeValue(forKey: uuid) {
            callback(error)
            return
        }

        if let continuation = pendingWrites.removeValue(forKey: uuid) {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.warning("Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
        }
    }
}

// MARK: - BLE Errors

enum BLEError: LocalizedError {
    case notConnected

    case characteristicNotFound(CBUUID)

    case noData

    case timeout

    case operationInProgress

    case logStreamIncomplete(expected: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to device"
        case .characteristicNotFound(let uuid): return "Characteristic not found: \(uuid)"
        case .noData: return "No data received"
        case .timeout: return "Connection timed out"
        case .operationInProgress: return "Another operation is already in progress for this characteristic"
        case .logStreamIncomplete(let expected, let received):
            return "Log stream ended before completion (\(received)/\(expected) cells)"
        }
    }
}
