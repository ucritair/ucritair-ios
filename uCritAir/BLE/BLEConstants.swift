import CoreBluetooth

enum BLEConstants {

    static let customServiceUUID = CBUUID(string: "FC7D4395-1019-49C4-A91B-7491ECC40000")

    static func vendorCharUUID(_ suffix: UInt16) -> CBUUID {
        CBUUID(string: String(format: "FC7D4395-1019-49C4-A91B-7491ECC4%04X", suffix))
    }

    static let charDeviceName   = vendorCharUUID(0x0001)

    static let charTime         = vendorCharUUID(0x0002)

    static let charCellCount    = vendorCharUUID(0x0003)

    static let charCellSelector = vendorCharUUID(0x0004)

    static let charCellData     = vendorCharUUID(0x0005)

    static let charLogStream    = vendorCharUUID(0x0006)

    static let charStats        = vendorCharUUID(0x0010)

    static let charItemsOwned   = vendorCharUUID(0x0011)

    static let charItemsPlaced  = vendorCharUUID(0x0012)

    static let charBonus        = vendorCharUUID(0x0013)

    static let charPetName      = vendorCharUUID(0x0014)

    static let charDeviceConfig = vendorCharUUID(0x0015)

    static let essServiceUUID   = CBUUID(string: "181A")

    static let discoveryServiceDataUUID = CBUUID(string: "FCD2")

    static let essTemperature   = CBUUID(string: "2A6E")

    static let essHumidity      = CBUUID(string: "2A6F")

    static let essPressure      = CBUUID(string: "2A6D")

    static let essCO2           = CBUUID(string: "2B8C")

    static let essPM2_5         = CBUUID(string: "2BD6")

    static let essPM1_0         = CBUUID(string: "2BD5")

    static let essPM10          = CBUUID(string: "2BD7")

    /// Seconds between the NTP epoch (Jan 1, 1900) and Unix epoch (Jan 1, 1970).
    /// Used to convert device RTC timestamps to Unix time.
    static let rtcEpochOffset: UInt64 = 59_958_144_000

    /// Log cell payload size when read via BLE characteristic (no notification header).
    static let logCellBLESize = 53

    /// Log cell payload size in BLE notifications (53-byte cell + 4-byte cell-number header).
    static let logCellNotificationSize = 57

    static let logStreamEndMarker: UInt32 = 0xFFFF_FFFF

    static let allCustomCharacteristicUUIDs: [CBUUID] = [
        charDeviceName, charTime, charCellCount, charCellSelector,
        charCellData, charLogStream, charStats, charItemsOwned,
        charItemsPlaced, charBonus, charPetName, charDeviceConfig,
    ]

    static let requiredCustomCharacteristicUUIDs: [CBUUID] = allCustomCharacteristicUUIDs

    static let essNotifyCharacteristicUUIDs: [CBUUID] = [
        essTemperature, essHumidity, essCO2, essPM2_5,
    ]

    static let essReadCharacteristicUUIDs: [CBUUID] = [
        essPressure, essPM1_0, essPM10,
    ]

    static let allESSCharacteristicUUIDs: [CBUUID] = essNotifyCharacteristicUUIDs + essReadCharacteristicUUIDs

    static let requiredESSCharacteristicUUIDs: [CBUUID] = allESSCharacteristicUUIDs
}

enum BLEDiscovery {

    static func isLikelyUCritDevice(
        peripheralName: String?,
        advertisementData: [String: Any]
    ) -> Bool {
        if matchesUCritName(advertisementData[CBAdvertisementDataLocalNameKey] as? String) {
            return true
        }

        if matchesUCritName(peripheralName) {
            return true
        }

        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           serviceUUIDs.contains(BLEConstants.customServiceUUID) {
            return true
        }

        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           serviceData.keys.contains(BLEConstants.discoveryServiceDataUUID) {
            return true
        }

        return false
    }

    private static func matchesUCritName(_ name: String?) -> Bool {
        guard let normalized = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return false
        }

        return normalized.hasPrefix("ucrit")
    }
}
