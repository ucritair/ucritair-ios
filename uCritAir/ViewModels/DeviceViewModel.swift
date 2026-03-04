import Foundation
import SwiftData
import os.log

/// View model for device connection, info, and multi-device registry.
/// Ported from src/stores/device.ts → useDeviceStore, extended for multi-device support.
@Observable
final class DeviceViewModel {

    // MARK: - State

    /// Current BLE connection state (disconnected, scanning, connecting, connected, etc.).
    var connectionState: ConnectionState = .disconnected

    /// The advertised device name read from the connected peripheral.
    var deviceName: String?

    /// The user-assigned pet name stored on the device.
    var petName: String?

    /// The device's RTC clock value as a Unix-epoch `UInt32`.
    var deviceTime: UInt32?

    /// Virtual pet statistics (vigour, focus, spirit, age, interventions) read from the device.
    var petStats: PetStats?

    /// Device configuration parameters (sensor wake period, brightness, persist flags, etc.).
    var config: DeviceConfig?

    /// Raw bitmap of items owned by the virtual pet.
    var itemsOwned: Data?

    /// Raw bitmap of items currently placed in the virtual pet's room.
    var itemsPlaced: Data?

    /// Accumulated bonus points on the device.
    var bonus: UInt32?

    /// Total number of log cells stored on the device's flash memory.
    var cellCount: UInt32?

    /// User-facing error message from the most recent failed operation, or `nil` if no error.
    var error: String?

    /// Human-readable Bluetooth status message shown when BT is unavailable (off, denied, unsupported).
    /// `nil` when Bluetooth is powered on and available.
    /// Derived from ``BLEManager/bluetoothState`` — auto-updates via `@Observable`.
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

    /// All device profiles persisted in SwiftData, sorted by ``DeviceProfile/sortOrder``.
    var knownDevices: [DeviceProfile] = []

    /// Reference to the shared BLE manager for connection and characteristic operations.
    /// Exposed as read-only for the Raw BLE Inspector in the Developer Tools view.
    private(set) var bleManager: BLEManager?

    /// SwiftData model context for persisting device profiles and log cells.
    private var modelContext: ModelContext?

    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "Device")

    // MARK: - Computed

    /// The deviceId of the currently connected peripheral (CBPeripheral UUID).
    var activeDeviceId: String? {
        bleManager?.connectedDeviceId
    }

    /// The DeviceProfile for the currently connected device, if known.
    var activeProfile: DeviceProfile? {
        guard let id = activeDeviceId else { return nil }
        return knownDevices.first { $0.deviceId == id }
    }

    // MARK: - Configuration

    /// Wire up BLE manager callbacks. Call once at app startup.
    @MainActor
    func configure(bleManager: BLEManager) {
        self.bleManager = bleManager

        bleManager.onConnectionStateChanged = { [weak self] state in
            guard let self else { return }
            // BLE callbacks are dispatched on the main queue (CBCentralManager queue: .main).
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
    }

    /// Provide SwiftData model context. Called from a view's .onAppear
    /// where @Environment(\.modelContext) is available.
    @MainActor
    func configureStorage(modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.info("configureStorage: modelContext set")
        loadKnownDevices()
    }

    // MARK: - Multi-Device Registry

    /// Load all known devices from SwiftData, sorted by sortOrder.
    @MainActor
    func loadKnownDevices() {
        guard let ctx = modelContext else {
            logger.warning("loadKnownDevices: no modelContext")
            return
        }
        do {
            let descriptor = FetchDescriptor<DeviceProfile>(
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            knownDevices = try ctx.fetch(descriptor)
            logger.info("loadKnownDevices: found \(self.knownDevices.count) devices")
        } catch {
            self.error = "Failed to load devices. Try restarting the app."
            logger.error("loadKnownDevices failed: \(error)")
        }
    }

    /// Create or update the DeviceProfile for the currently connected device.
    /// Called automatically on each successful connection.
    @MainActor
    func upsertDeviceProfile() {
        logger.info("upsertDeviceProfile: hasContext=\(self.modelContext != nil) activeDeviceId=\(self.activeDeviceId ?? "nil")")
        guard let ctx = modelContext,
              let deviceId = activeDeviceId else {
            logger.warning("upsertDeviceProfile: skipping — missing context or deviceId")
            return
        }

        do {
            let descriptor = FetchDescriptor<DeviceProfile>(
                predicate: #Predicate { $0.deviceId == deviceId }
            )
            let existing = try ctx.fetch(descriptor).first

            if let profile = existing {
                // Update existing profile
                profile.deviceName = deviceName ?? profile.deviceName
                profile.petName = petName ?? profile.petName
                profile.lastConnectedAt = .now
                if let cc = cellCount { profile.lastKnownCellCount = Int(cc) }
                logger.info("upsertDeviceProfile: updated existing profile for \(deviceId)")
            } else {
                // Create new profile
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

    /// Remove a device profile and optionally its cached log cells.
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

    /// Update the user-editable room label for a device.
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

    /// Attempt to auto-reconnect to the most recently connected known device.
    /// Called once at app launch after Bluetooth becomes ready.
    @MainActor
    func autoConnectToLastDevice() {
        guard connectionState == .disconnected else {
            logger.info("autoConnectToLastDevice: skipping — already \(self.connectionState.rawValue)")
            return
        }
        // Ensure devices loaded (may not be if called before ContentView.onAppear)
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

    /// Attempt to reconnect to a known device via its stored UUID.
    func connectToKnownDevice(_ profile: DeviceProfile) {
        guard let manager = bleManager,
              let uuid = UUID(uuidString: profile.deviceId) else { return }
        manager.reconnectToKnownDevice(identifier: uuid)
    }

    // MARK: - Actions

    /// Start scanning for devices.
    func scan() {
        error = nil
        bleManager?.scan()
    }

    /// Disconnect from the current device.
    func disconnect() {
        bleManager?.disconnect()
        clearDeviceInfo()
    }

    /// Read all device info from the connected device.
    /// Reads are sequential to avoid overwhelming the BLE stack and to prevent
    /// data races on BLEManager's internal dictionaries.
    /// Ported from device.ts → refreshDeviceInfo()
    @MainActor
    func refreshDeviceInfo() async {
        guard let manager = bleManager else { return }

        do {
            deviceName = try await BLECharacteristics.readDeviceName(using: manager)
            petName = try await BLECharacteristics.readPetName(using: manager)
            deviceTime = try await BLECharacteristics.readTime(using: manager)
            petStats = try await BLECharacteristics.readStats(using: manager)
            config = try await BLECharacteristics.readDeviceConfig(using: manager)
            itemsOwned = try await BLECharacteristics.readItemsOwned(using: manager)
            itemsPlaced = try await BLECharacteristics.readItemsPlaced(using: manager)
            bonus = try await BLECharacteristics.readBonus(using: manager)
            cellCount = try await BLECharacteristics.readCellCount(using: manager)
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to read device info")
            logger.error("Failed to read device info: \(error)")
        }
    }

    /// Sync device time to current local time.
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

    /// Write a new device name to the connected device and refresh cached state.
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

    /// Write a new pet name to the connected device and refresh cached state.
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

    /// Write updated device configuration to the connected device and re-read to confirm.
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

    /// Write an arbitrary Unix timestamp to the device's RTC clock.
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

    /// Read a single log cell by index. Writes the cell selector, then reads cell data.
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

    /// Map BLE errors to concise, user-friendly messages.
    /// Raw CoreBluetooth error strings are cryptic; users need actionable guidance.
    private static func friendlyMessage(for error: Error, context: String) -> String {
        let nsError = error as NSError
        // CBError domain
        if nsError.domain == "CBErrorDomain" || nsError.domain == "CBATTErrorDomain" {
            switch nsError.code {
            case 6, 7: // disconnectedDuringRead/Write, connectionTimeout
                return "\(context): Connection lost. Make sure the device is nearby and try again."
            case 14: // CBATTError.unlikelyError
                return "\(context): The device rejected the request. Try reconnecting."
            default:
                return "\(context): Bluetooth error. Try reconnecting to the device."
            }
        }
        // BLEError from our own code
        if error is BLEError {
            return "\(context): \(error.localizedDescription)"
        }
        return "\(context): \(error.localizedDescription)"
    }
}
