import Foundation

/// High-level typed read/write functions for each BLE characteristic.
/// Ported from src/ble/characteristics.ts
enum BLECharacteristics {

    // MARK: - Device Name

    /// Read device name string.
    static func readDeviceName(using manager: BLEManager) async throws -> String {
        let data = try await manager.readCharacteristic(BLEConstants.charDeviceName)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    /// Write device name string.
    static func writeDeviceName(_ name: String, using manager: BLEManager) async throws {
        guard let data = name.data(using: .utf8) else { throw BLEError.noData }
        try await manager.writeCharacteristic(BLEConstants.charDeviceName, data: data)
    }

    // MARK: - Device Time

    /// Read device time as Unix timestamp (seconds).
    static func readTime(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charTime)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    /// Write device time (Unix timestamp seconds).
    static func writeTime(_ unixSeconds: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(unixSeconds, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charTime, data: data)
    }

    // MARK: - Log Cells

    /// Read total log cell count.
    static func readCellCount(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charCellCount)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    /// Set cell selector index.
    static func writeCellSelector(_ index: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(index, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charCellSelector, data: data)
    }

    /// Read selected cell data (57 bytes: 4-byte cell_nr + 53-byte cell data).
    static func readCellData(using manager: BLEManager) async throws -> ParsedLogCell {
        let data = try await manager.readCharacteristic(BLEConstants.charCellData)
        guard data.count >= BLEConstants.logCellNotificationSize else {
            throw BLEError.noData
        }
        return BLEParsers.parseLogCell(data)
    }

    // MARK: - Pet Stats

    /// Read pet stats (6 bytes).
    static func readStats(using manager: BLEManager) async throws -> PetStats {
        let data = try await manager.readCharacteristic(BLEConstants.charStats)
        guard data.count >= 6 else { throw BLEError.noData }
        return BLEParsers.parseStats(data)
    }

    // MARK: - Items

    /// Read items owned bitmap (32 bytes = 256 bits).
    static func readItemsOwned(using manager: BLEManager) async throws -> Data {
        try await manager.readCharacteristic(BLEConstants.charItemsOwned)
    }

    /// Read items placed bitmap (32 bytes).
    static func readItemsPlaced(using manager: BLEManager) async throws -> Data {
        try await manager.readCharacteristic(BLEConstants.charItemsPlaced)
    }

    // MARK: - Bonus

    /// Read bonus value.
    static func readBonus(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charBonus)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    /// Write bonus value.
    static func writeBonus(_ value: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(value, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charBonus, data: data)
    }

    // MARK: - Pet Name

    /// Read pet name string.
    static func readPetName(using manager: BLEManager) async throws -> String {
        let data = try await manager.readCharacteristic(BLEConstants.charPetName)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    /// Write pet name string.
    static func writePetName(_ name: String, using manager: BLEManager) async throws {
        guard let data = name.data(using: .utf8) else { throw BLEError.noData }
        try await manager.writeCharacteristic(BLEConstants.charPetName, data: data)
    }

    // MARK: - Device Config

    /// Read device configuration (16 bytes).
    static func readDeviceConfig(using manager: BLEManager) async throws -> DeviceConfig {
        let data = try await manager.readCharacteristic(BLEConstants.charDeviceConfig)
        guard data.count >= 16 else { throw BLEError.noData }
        return DeviceConfig.parse(from: data)
    }

    /// Write device configuration.
    static func writeDeviceConfig(_ config: DeviceConfig, using manager: BLEManager) async throws {
        let data = config.serialize()
        try await manager.writeCharacteristic(BLEConstants.charDeviceConfig, data: data)
    }
}
