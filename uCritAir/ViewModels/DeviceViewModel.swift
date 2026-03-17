import Foundation
@preconcurrency import SwiftData
import os.log

@Observable
final class DeviceViewModel {

    var connectionState: ConnectionState = .disconnected

    var deviceName: String?

    var petName: String?

    var deviceTime: UInt32?

    var petStats: PetStats?

    var config: DeviceConfig?

    var itemsOwned: Data?

    var itemsPlaced: Data?

    var bonus: UInt32?

    var cellCount: UInt32?

    var error: String?

    var bluetoothStatusMessage: String? {
        guard let state = bleManager?.bluetoothState else { return nil }
        switch state {
        case .poweredOff:
            return "Bluetooth is turned off. Enable it in Settings to connect."
        case .unauthorized:
            return "Bluetooth permission denied. Enable it in Settings > Privacy > Bluetooth."
        case .unsupported:
            return "This device does not support Bluetooth Low Energy."
        default:
            return nil
        }
    }

    var knownDevices: [DeviceProfile] = []

    private(set) var bleManager: BLEManager?

    private var modelContext: ModelContext?

    private var connectionObserverToken: UUID?

    private var configuredBLEManagerID: ObjectIdentifier?

    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "Device")

    deinit {
        if let manager = bleManager, let token = connectionObserverToken {
            manager.removeConnectionStateObserver(token)
        }
    }

    var activeDeviceId: String? {
        bleManager?.connectedDeviceId
    }

    var activeProfile: DeviceProfile? {
        guard let id = activeDeviceId else { return nil }
        return knownDevices.first { $0.deviceId == id }
    }

    @MainActor
    func configure(bleManager: BLEManager) {
        let managerID = ObjectIdentifier(bleManager)
        if configuredBLEManagerID == managerID, connectionObserverToken != nil {
            return
        }

        if let oldManager = self.bleManager, let token = connectionObserverToken {
            oldManager.removeConnectionStateObserver(token)
        }

        self.bleManager = bleManager
        configuredBLEManagerID = managerID

        connectionObserverToken = bleManager.addConnectionStateObserver { [weak self] state in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.connectionState = state

                if state == .connected {
                    Task { @MainActor in
                        await self.refreshDeviceInfo()
                        self.upsertDeviceProfile()
                    }
                }

                if state == .disconnected {
                    self.clearDeviceInfo()
                }
            }
        }

        connectionState = bleManager.connectionState
    }

    @MainActor
    func configureStorage(modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.info("configureStorage: modelContext set")
        loadKnownDevices()
    }

    @MainActor
    func loadKnownDevices() {
        guard let ctx = modelContext else {
            logger.warning("loadKnownDevices: no modelContext")
            return
        }
        do {
            let descriptor = FetchDescriptor<DeviceProfile>()
            knownDevices = try ctx.fetch(descriptor).sorted(by: Self.deviceProfileSort)
            logger.info("loadKnownDevices: found \(self.knownDevices.count) devices")
        } catch {
            self.error = "Failed to load devices. Try restarting the app."
            logger.error("loadKnownDevices failed: \(error)")
        }
    }

    @MainActor
    func upsertDeviceProfile() {
        logger.info("upsertDeviceProfile: hasContext=\(self.modelContext != nil) activeDeviceId=\(self.activeDeviceId ?? "nil")")
        guard let ctx = modelContext,
              let deviceId = activeDeviceId else {
            logger.warning("upsertDeviceProfile: skipping — missing context or deviceId")
            return
        }

        do {
            let existing = knownDevices.first { $0.deviceId == deviceId }

            if let profile = existing {
                profile.deviceName = deviceName ?? profile.deviceName
                profile.petName = petName ?? profile.petName
                profile.lastConnectedAt = .now
                if let cc = cellCount { profile.lastKnownCellCount = Int(cc) }
                logger.info("upsertDeviceProfile: updated existing profile for \(deviceId)")
            } else {
                let nextOrder = knownDevices.count
                let profile = DeviceProfile(
                    deviceId: deviceId,
                    deviceName: deviceName ?? "Unknown",
                    petName: petName ?? "",
                    lastConnectedAt: .now,
                    lastKnownCellCount: Int(cellCount ?? 0),
                    sortOrder: nextOrder
                )
                ctx.insert(profile)
                logger.info("upsertDeviceProfile: created new profile for \(deviceId)")
            }

            try ctx.save()
            loadKnownDevices()
            logger.info("upsertDeviceProfile: saved. knownDevices count = \(self.knownDevices.count)")
        } catch {
            self.error = "Failed to save device profile. Try restarting the app."
            logger.error("upsertDeviceProfile failed: \(error)")
        }
    }

    @MainActor
    func removeDevice(_ profile: DeviceProfile, deleteCachedData: Bool) {
        guard let ctx = modelContext else { return }
        do {
            if deleteCachedData {
                try LogCellStore.clearAllCells(deviceId: profile.deviceId, context: ctx)
            }
            ctx.delete(profile)
            try ctx.save()
            loadKnownDevices()
        } catch {
            self.error = "Failed to remove device. Try again."
        }
    }

    @MainActor
    func setRoomLabel(_ label: String?, for profile: DeviceProfile) {
        guard let ctx = modelContext else { return }
        profile.roomLabel = label
        do {
            try ctx.save()
            loadKnownDevices()
        } catch {
            self.error = "Failed to update room label. Try again."
        }
    }

    @MainActor
    func autoConnectToLastDevice() {
        guard connectionState == .disconnected else {
            logger.info("autoConnectToLastDevice: skipping — already \(self.connectionState.rawValue)")
            return
        }
        if knownDevices.isEmpty && modelContext != nil {
            loadKnownDevices()
        }
        guard let mostRecent = knownDevices.max(by: { $0.lastConnectedAt < $1.lastConnectedAt }) else {
            logger.info("autoConnectToLastDevice: no known devices")
            return
        }
        logger.info("autoConnectToLastDevice: reconnecting to \(mostRecent.deviceName) (\(mostRecent.deviceId))")
        connectToKnownDevice(mostRecent)
    }

    func connectToKnownDevice(_ profile: DeviceProfile) {
        guard let manager = bleManager,
              let uuid = UUID(uuidString: profile.deviceId) else { return }
        manager.reconnectToKnownDevice(identifier: uuid)
    }

    func scan() {
        error = nil
        bleManager?.scan()
    }

    func disconnect() {
        bleManager?.disconnect()
        clearDeviceInfo()
    }

    @MainActor
    func refreshDeviceInfo() async {
        guard let manager = bleManager else { return }

        error = nil
        var failedFields: [String] = []

        if let value = await refreshDeviceInfoField(named: "device name", read: {
            try await BLECharacteristics.readDeviceName(using: manager)
        }) {
            deviceName = value
        } else {
            failedFields.append("device name")
        }

        if let value = await refreshDeviceInfoField(named: "pet name", read: {
            try await BLECharacteristics.readPetName(using: manager)
        }) {
            petName = value
        } else {
            failedFields.append("pet name")
        }

        if let value = await refreshDeviceInfoField(named: "device time", read: {
            try await BLECharacteristics.readTime(using: manager)
        }) {
            deviceTime = value
        } else {
            failedFields.append("device time")
        }

        if let value = await refreshDeviceInfoField(named: "pet stats", read: {
            try await BLECharacteristics.readStats(using: manager)
        }) {
            petStats = value
        } else {
            failedFields.append("pet stats")
        }

        if let value = await refreshDeviceInfoField(named: "device config", read: {
            try await BLECharacteristics.readDeviceConfig(using: manager)
        }) {
            config = value
        } else {
            failedFields.append("device config")
        }

        if let value = await refreshDeviceInfoField(named: "owned items", read: {
            try await BLECharacteristics.readItemsOwned(using: manager)
        }) {
            itemsOwned = value
        } else {
            failedFields.append("owned items")
        }

        if let value = await refreshDeviceInfoField(named: "placed items", read: {
            try await BLECharacteristics.readItemsPlaced(using: manager)
        }) {
            itemsPlaced = value
        } else {
            failedFields.append("placed items")
        }

        if let value = await refreshDeviceInfoField(named: "bonus", read: {
            try await BLECharacteristics.readBonus(using: manager)
        }) {
            bonus = value
        } else {
            failedFields.append("bonus")
        }

        if let value = await refreshDeviceInfoField(named: "cell count", read: {
            try await BLECharacteristics.readCellCount(using: manager)
        }) {
            cellCount = value
        } else {
            failedFields.append("cell count")
        }

        if !failedFields.isEmpty {
            logger.warning("refreshDeviceInfo completed with partial failures: \(failedFields.joined(separator: ", "))")
            error = "Some device info could not be refreshed. Showing the last known values. Pull to retry."
        }
    }

    @MainActor
    func syncTime() async {
        guard let manager = bleManager else { return }
        let epoch = UnitFormatters.getLocalTimeAsEpoch()
        do {
            try await BLECharacteristics.writeTime(epoch, using: manager)
            deviceTime = epoch
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to sync time")
        }
    }

    @MainActor
    func writeDeviceName(_ name: String) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writeDeviceName(name, using: manager)
            deviceName = name
            upsertDeviceProfile()
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to save device name")
            logger.error("writeDeviceName failed: \(error)")
        }
    }

    @MainActor
    func writePetName(_ name: String) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writePetName(name, using: manager)
            petName = name
            upsertDeviceProfile()
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to save pet name")
            logger.error("writePetName failed: \(error)")
        }
    }

    @MainActor
    func writeConfig(_ newConfig: DeviceConfig) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writeDeviceConfig(newConfig, using: manager)
            config = try await BLECharacteristics.readDeviceConfig(using: manager)
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to save config")
            logger.error("writeConfig failed: \(error)")
        }
    }

    @MainActor
    func writeTime(_ unixSeconds: UInt32) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writeTime(unixSeconds, using: manager)
            deviceTime = unixSeconds
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to set time")
            logger.error("writeTime failed: \(error)")
        }
    }

    @MainActor
    func readLogCell(at index: UInt32) async throws -> ParsedLogCell {
        guard let manager = bleManager else { throw BLEError.notConnected }
        try await BLECharacteristics.writeCellSelector(index, using: manager)
        return try await BLECharacteristics.readCellData(using: manager)
    }

    private func clearDeviceInfo() {
        deviceName = nil
        petName = nil
        deviceTime = nil
        petStats = nil
        config = nil
        itemsOwned = nil
        itemsPlaced = nil
        bonus = nil
        cellCount = nil
    }

    @MainActor
    private func refreshDeviceInfoField<Value>(
        named fieldName: String,
        read: () async throws -> Value
    ) async -> Value? {
        do {
            return try await read()
        } catch {
            logger.error("Failed to refresh \(fieldName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func friendlyMessage(for error: Error, context: String) -> String {
        let nsError = error as NSError
        if nsError.domain == "CBErrorDomain" || nsError.domain == "CBATTErrorDomain" {
            switch nsError.code {
            case 6, 7:
                return "\(context): Connection lost. Make sure the device is nearby and try again."
            case 14:
                return "\(context): The device rejected the request. Try reconnecting."
            default:
                return "\(context): Bluetooth error. Try reconnecting to the device."
            }
        }
        if error is BLEError {
            return "\(context): \(error.localizedDescription)"
        }
        return "\(context): \(error.localizedDescription)"
    }

    private static func deviceProfileSort(_ lhs: DeviceProfile, _ rhs: DeviceProfile) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }

        return lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName) == .orderedAscending
    }
}
