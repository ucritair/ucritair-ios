import Foundation

enum BLECharacteristics {

    static func readDeviceName(using manager: BLEManager) async throws -> String {
        let data = try await manager.readCharacteristic(BLEConstants.charDeviceName)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    static func writeDeviceName(_ name: String, using manager: BLEManager) async throws {
        guard let data = name.data(using: .utf8) else { throw BLEError.noData }
        try await manager.writeCharacteristic(BLEConstants.charDeviceName, data: data)
    }

    static func readTime(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charTime)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    static func writeTime(_ unixSeconds: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(unixSeconds, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charTime, data: data)
    }

    static func readCellCount(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charCellCount)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    static func writeCellSelector(_ index: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(index, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charCellSelector, data: data)
    }

    static func readCellData(using manager: BLEManager) async throws -> ParsedLogCell {
        let data = try await manager.readCharacteristic(BLEConstants.charCellData)
        guard data.count >= BLEConstants.logCellNotificationSize else {
            throw BLEError.noData
        }
        do {
            return try BLEParsers.parseLogCell(data)
        } catch {
            throw BLEError.noData
        }
    }

    static func readStats(using manager: BLEManager) async throws -> PetStats {
        let data = try await manager.readCharacteristic(BLEConstants.charStats)
        guard data.count >= 6 else { throw BLEError.noData }
        do {
            return try BLEParsers.parseStats(data)
        } catch {
            throw BLEError.noData
        }
    }

    static func readItemsOwned(using manager: BLEManager) async throws -> Data {
        try await manager.readCharacteristic(BLEConstants.charItemsOwned)
    }

    static func readItemsPlaced(using manager: BLEManager) async throws -> Data {
        try await manager.readCharacteristic(BLEConstants.charItemsPlaced)
    }

    static func readBonus(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charBonus)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    static func writeBonus(_ value: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(value, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charBonus, data: data)
    }

    static func readPetName(using manager: BLEManager) async throws -> String {
        let data = try await manager.readCharacteristic(BLEConstants.charPetName)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    static func writePetName(_ name: String, using manager: BLEManager) async throws {
        guard let data = name.data(using: .utf8) else { throw BLEError.noData }
        try await manager.writeCharacteristic(BLEConstants.charPetName, data: data)
    }

    static func readDeviceConfig(using manager: BLEManager) async throws -> DeviceConfig {
        let data = try await manager.readCharacteristic(BLEConstants.charDeviceConfig)
        guard data.count >= 16, let config = DeviceConfig.parse(from: data) else { throw BLEError.noData }
        return config
    }

    static func writeDeviceConfig(_ config: DeviceConfig, using manager: BLEManager) async throws {
        let data = config.serialize()
        try await manager.writeCharacteristic(BLEConstants.charDeviceConfig, data: data)
    }
}
