import CoreBluetooth

/// BLE service and characteristic UUIDs matching the uCrit firmware.
/// Ported from src/ble/constants.ts
enum BLEConstants {
    // MARK: - Custom Vendor Service

    /// Primary custom GATT service UUID for the uCrit device (suffix `0x0000`).
    static let customServiceUUID = CBUUID(string: "FC7D4395-1019-49C4-A91B-7491ECC40000")

    /// Build full 128-bit UUID from 16-bit suffix for vendor characteristics.
    static func vendorCharUUID(_ suffix: UInt16) -> CBUUID {
        CBUUID(string: String(format: "FC7D4395-1019-49C4-A91B-7491ECC4%04X", suffix))
    }

    /// User-configurable device name (firmware char ID `0x0001`).
    static let charDeviceName   = vendorCharUUID(0x0001)
    /// Device RTC time as a local-epoch `UInt32` (firmware char ID `0x0002`).
    static let charTime         = vendorCharUUID(0x0002)
    /// Total number of stored log cells on the device (firmware char ID `0x0003`).
    static let charCellCount    = vendorCharUUID(0x0003)
    /// Write a cell index to select which log cell to read; `0xFFFFFFFF` selects the live cell (firmware char ID `0x0004`).
    static let charCellSelector = vendorCharUUID(0x0004)
    /// 53-byte payload of the currently selected log cell (firmware char ID `0x0005`).
    static let charCellData     = vendorCharUUID(0x0005)
    /// Notification-based bulk log cell streaming channel (firmware char ID `0x0006`).
    static let charLogStream    = vendorCharUUID(0x0006)
    /// Virtual pet game stats (XP, level, coins) (firmware char ID `0x0010`).
    static let charStats        = vendorCharUUID(0x0010)
    /// Bitmask of owned shop items (firmware char ID `0x0011`).
    static let charItemsOwned   = vendorCharUUID(0x0011)
    /// Array of placed/equipped item IDs (firmware char ID `0x0012`).
    static let charItemsPlaced  = vendorCharUUID(0x0012)
    /// Bonus/reward state (firmware char ID `0x0013`).
    static let charBonus        = vendorCharUUID(0x0013)
    /// Pet display name, UTF-8 encoded (firmware char ID `0x0014`).
    static let charPetName      = vendorCharUUID(0x0014)
    /// Device configuration flags and settings (firmware char ID `0x0015`).
    static let charDeviceConfig = vendorCharUUID(0x0015)

    // MARK: - Environmental Sensing Service (ESS)

    /// Bluetooth SIG Environmental Sensing Service UUID (`0x181A`).
    static let essServiceUUID   = CBUUID(string: "181A")
    /// Temperature characteristic (`0x2A6E`). Value is `Int16` in 0.01 C units.
    static let essTemperature   = CBUUID(string: "2A6E")
    /// Humidity characteristic (`0x2A6F`). Value is `UInt16` in 0.01% units.
    static let essHumidity      = CBUUID(string: "2A6F")
    /// Pressure characteristic (`0x2A6D`). Value is `UInt32` in 0.1 Pa units.
    static let essPressure      = CBUUID(string: "2A6D")
    /// CO2 concentration characteristic (`0x2B8C`). Value is `UInt16` in ppm.
    static let essCO2           = CBUUID(string: "2B8C")
    /// PM2.5 concentration characteristic (`0x2BD6`). Value is `UInt16` in ug/m3.
    static let essPM2_5         = CBUUID(string: "2BD6")
    /// PM1.0 concentration characteristic (`0x2BD5`). Value is `UInt16` in ug/m3.
    static let essPM1_0         = CBUUID(string: "2BD5")
    /// PM10 concentration characteristic (`0x2BD7`). Value is `UInt16` in ug/m3.
    static let essPM10          = CBUUID(string: "2BD7")

    // MARK: - Log Cell Constants

    /// RTC epoch offset used to convert log cell timestamps to Unix time.
    /// cell.timestamp (internal RTC seconds) - this = Unix seconds.
    static let rtcEpochOffset: UInt64 = 59_958_144_000

    /// Log cell BLE payload size (64-byte struct minus 11-byte pad).
    static let logCellBLESize = 53

    /// Full notification: 4-byte cell_nr + 53-byte cell data.
    static let logCellNotificationSize = 57

    /// End marker for log streaming.
    static let logStreamEndMarker: UInt32 = 0xFFFF_FFFF

    // MARK: - All custom characteristic UUIDs (for service discovery)

    /// All vendor-specific characteristic UUIDs to discover under the custom service.
    static let allCustomCharacteristicUUIDs: [CBUUID] = [
        charDeviceName, charTime, charCellCount, charCellSelector,
        charCellData, charLogStream, charStats, charItemsOwned,
        charItemsPlaced, charBonus, charPetName, charDeviceConfig,
    ]

    /// ESS characteristics we want notifications for.
    static let essNotifyCharacteristicUUIDs: [CBUUID] = [
        essTemperature, essHumidity, essCO2, essPM2_5,
    ]

    /// ESS characteristics we read (no notification support).
    static let essReadCharacteristicUUIDs: [CBUUID] = [
        essPressure, essPM1_0, essPM10,
    ]

    /// Combined list of all ESS characteristic UUIDs to discover under the ESS service.
    static let allESSCharacteristicUUIDs: [CBUUID] = essNotifyCharacteristicUUIDs + essReadCharacteristicUUIDs
}
